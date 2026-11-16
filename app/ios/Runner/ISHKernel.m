//  ISHKernel.m
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1).
//
//  Boot steps follow OpenMinis ISHKernel.m bootWithRootPath: L1191–1437,
//  renumbered here with dsh-go's changes marked [DSH-DELTA-K*] (the
//  Stage 1 prototype used [PROTO-DELTA-K*]; the tags are renamed, the
//  content is the same). executeCommand: follows L1725–1900
//  (become_new_init_child, pty_open_fake, create_stdio, do_execve,
//  task_start). stopGuest follows ISHShellExecutor.m killProcessGroup
//  L772+ (TERM -> wait -> KILL, refuse pid <= 1), applied to ALL guest
//  pids >= 2. Ported from the Stage 1 prototype (ISHCoexist/ISHKernel.m,
//  fix11), which verified boot / echo / stop / re-boot and three crash
//  fixes on device (stage 1, 14 pass 0 fail).
//
//  STAGE 1 FIXES — DO NOT REGRESS:
//  (1) UITableView launch crash -> results UI is a scroll view (not in
//      this file; noted because the fix lives in the harness UI).
//  (2) drainOutput ARC crash -> +shared statics are alloc/init (+1
//      owned) AND the target sets CLANG_ENABLE_OBJC_ARC = YES.
//  (3) exec-failure task leak -> a failed do_execve marks its child a
//      zombie directly (see the [FIX 1.4a-rev] block in executeCommand:).
//      NEVER call do_exit() here: it ends in pthread_exit, illegal on a
//      GCD workqueue thread (stage 1 build 14 crash).

#import "ISHKernel.h"
#import "ISHCrashHandler.h"
#import "ISHFakefsMeta.h"
#import "ISHResourceGovernor.h"
#import "ISHShellExecutor.h" // killProcessGroup (stage 5.3 session close)

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fake.h"
#include "ish/fs/tty.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/fs/path.h"
#include "ish/fs/fd.h"
#include "ish/fs/sock.h"    // ish_sock_set_tmp_prefix (AF_UNIX backing prefix)
#include "ish/emu/cpu.h"
#include "ish/kernel/mm.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/errno.h"
#include "ish/debug.h"      // die_handler
#include "ish/misc.h"       // IS_ERR / PTR_ERR
#include "ish/util/sync.h"  // lock / unlock (pids_lock)
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include <errno.h>
#include <sys/syslimits.h>
#include <sys/resource.h>  // setrlimit (ENV-05 host fd cap)
#include <execinfo.h>
#include <resolv.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <mach/mach.h>

NSNotificationName const ISHGuestExitedNotification =
    @"ISHGuestExitedNotification";

const NSInteger ISHPtyMaxSessions = 8;

int ISHDecodeWaitStatus(int status) {
    if (status < 0) return status; // executor sentinel, pass through
    if ((status & 0x7f) == 0) return (status >> 8) & 0xff; // normal exit
    if ((status & 0x7f) == 0x7f) return 128 + ((status >> 8) & 0xff); // stopped
    return 128 + (status & 0x7f); // killed by signal
}

static ISHKernel *g_sharedKernel = nil;

// Guest exit records (pid -> code), written on the main queue via
// dispatch_async from exit_hook (same pattern as OpenMinis
// handle_process_exit, L1085–1100: exit_hook never blocks on a lock).
static NSMutableDictionary<NSNumber *, NSNumber *> *g_guestExits = nil;

// Captured PTY/console output since the last drain (CONSOLE tty only
// now — see below).
static NSMutableData *g_ptyOutput = nil;
static NSLock *g_ptyOutputLock = nil;
// YES while a batched outputCallback drain is already queued on the
// main queue. Guarded by g_ptyOutputLock. See ish_proto_tty_write.
static BOOL g_outputDispatchPending = NO;

// --- Per-session PTY routing (stage 5.3, multi-terminal) ------------------
//
// WHY: the old code had ONE shared buffer + ONE outputCallback for
// every guest PTY write, so a second terminal could only be refused
// (close 1008). iSH itself already gives every shell its own tty:
// pty_open_fake() reserves a fresh pty number (pty_reserve_next,
// fs/pty.c) and allocates a distinct `struct tty` (own input buffer,
// termios, winsize), and the driver's .write op receives that tty
// pointer — so routing by tty pointer is sound. Each session owns one
// record (buffer + handler + tty pointer); writes are fanned out to
// the owning session AND to the legacy outputCallback (log ring).
//
// LOCKING (read before touching — two lock orders, never mixed):
// - Registry lock (_ptySessionsLock): guards the session dictionary
//   only. Taken briefly for lookup/insert/remove. NEVER held while
//   calling into tty functions.
// - Record lock (per-record NSLock): guards that record's tty pointer,
//   closed flag, buffer and pending flag. Taken for append/drain and
//   for the ttyForInput snapshot. NEVER held while calling into tty
//   functions either: sendInput snapshots the tty pointer under the
//   record lock, releases it, and only then calls tty_input().
// - ish_proto_tty_write takes the registry lock (lookup + retain),
//   releases it, then takes the record lock (append). Order is always
//   registry -> record, never the reverse, and neither nests with the
//   guest tty->lock (tty_input takes tty->lock only after all our
//   locks are released).
// - ish_proto_tty_cleanup runs under the guest tty->lock (tty_release
//   holds it), so it takes NO lock at all: it only does an atomic
//   store into g_ptyDead[]. Taking any NSLock there would invert the
//   order against sendInput (record lock -> tty->lock) and deadlock.
//
// TTY LIFETIME (residual race, same shape as the shipped single-
// terminal code — narrowed, not eliminated): the kernel frees a tty
// in tty_release() when its last fd closes (guest exit). A sendInput
// that snapshots the pointer a moment before the free can still touch
// freed memory. The closed flag (set synchronously by
// closePtySession:) + the pid-exit check in sendInput:sessionId: /
// setTerminalSize:rows:sessionId: close the window for every
// programmatic close; the dead flag below closes it for the
// cleanup ran. A host-side refcount on the tty would be needed to
// close it fully (deferred — see VERIFY.md).
//
// g_ptyDead[ptyNum]: set by ish_proto_tty_cleanup when a tty is
// freed, cleared when a session claims that number. Indexed by
// tty->num (0..MAX_PTYS-1, 4096 in fs/pty.c). A number can be reused
// after its tty is freed, but reuse only happens after the old
// session is closed (its sendInput is already gated off by `closed`),
// so a stale `true` can never misroute a live session. The console
// tty (PID 1 stdio, nums 0..7 in its own driver table) never consults
// this array — only session sendInput/resize do, after a registry
// lookup has already matched the record.
static _Atomic bool g_ptyDead[4096];

/// One live PTY session: an interactive terminal shell or a tty exec.
/// Owned by the ISHKernel session registry (strong); the tty pointer
/// is NOT owned — the iSH kernel frees it on guest exit (see above).
@interface ISHPtySessionRecord : NSObject
@property (nonatomic, readonly) NSString *sessionId;
@property (nonatomic) int guestPid;
- (instancetype)initWithSessionId:(NSString *)sessionId;
/// The guest tty (struct tty *), or NULL before the spawn block
/// assigns it / after the session is closed. Guarded by _lock.
- (struct tty *)ttySnapshot;
- (void)setTty:(struct tty *)tty num:(int)num;
/// The tty number captured with the pointer (for g_ptyDead), or -1.
@property (nonatomic, readonly) int ttyNum;
/// YES once closePtySession: ran. Further input/resize is dropped.
@property (nonatomic, readonly) BOOL closed;
- (void)markClosed;
/// True when the session is open AND its tty is (as far as we know)
/// still alive. Callers snapshot the tty with this check, release
/// the lock, and only then call tty_input()/tty_set_winsize().
- (nullable struct tty *)ttyForInput;
/// Append guest output; returns YES when a batched dispatch should be
/// scheduled (a sink exists — session handler or legacy outputCallback
/// — and no dispatch is already pending).
- (BOOL)appendOutput:(NSData *)data;
/// Drain for a scheduled dispatch: clears the pending flag BEFORE
/// draining (same ordering as the legacy global path — a write that
/// lands after the clear but before the drain schedules a second
/// dispatch, so no data is lost).
- (NSData *)drainForDispatch;
/// Drain for a synchronous consumer (drainOutputForSession: / the
/// executor's final tail-drain). Does not touch the pending flag; a
/// pending dispatch block later drains empty.
- (NSData *)drain;
/// The per-session output handler (atomic copy property; nil = none).
@property (atomic, copy, nullable) void (^outputHandler)(NSData *data);
@end

@implementation ISHPtySessionRecord {
    NSLock *_lock;
    struct tty *_tty;
    int _ttyNum;
    BOOL _closed;
    NSMutableData *_buffer;
    BOOL _dispatchPending;
}

- (instancetype)initWithSessionId:(NSString *)sessionId {
    self = [super init];
    if (self) {
        _sessionId = [sessionId copy];
        _guestPid = 0;
        _lock = [[NSLock alloc] init];
        _tty = NULL;
        _ttyNum = -1;
        _closed = NO;
        _buffer = [[NSMutableData alloc] init];
        _dispatchPending = NO;
    }
    return self;
}

- (struct tty *)ttySnapshot {
    [_lock lock];
    struct tty *tty = _tty;
    [_lock unlock];
    return tty;
}

- (void)setTty:(struct tty *)tty num:(int)num {
    [_lock lock];
    _tty = tty;
    _ttyNum = num;
    [_lock unlock];
}

- (int)ttyNum {
    [_lock lock];
    int num = _ttyNum;
    [_lock unlock];
    return num;
}

- (BOOL)closed {
    [_lock lock];
    BOOL closed = _closed;
    [_lock unlock];
    return closed;
}

- (void)markClosed {
    [_lock lock];
    _closed = YES;
    [_lock unlock];
}

- (nullable struct tty *)ttyForInput {
    [_lock lock];
    struct tty *tty = NULL;
    if (!_closed && _tty != NULL && _ttyNum >= 0 && _ttyNum < 4096 &&
        !atomic_load(&g_ptyDead[_ttyNum])) {
        tty = _tty;
    }
    [_lock unlock];
    return tty;
}

- (BOOL)appendOutput:(NSData *)data {
    [_lock lock];
    [_buffer appendData:data];
    BOOL hasSink = (self.outputHandler != nil) ||
        (g_sharedKernel.outputCallback != nil);
    BOOL needsDispatch = hasSink && !_dispatchPending;
    if (needsDispatch) _dispatchPending = YES;
    [_lock unlock];
    return needsDispatch;
}

- (NSData *)drainForDispatch {
    [_lock lock];
    _dispatchPending = NO;
    NSData *batch = [_buffer copy];
    [_buffer setLength:0];
    [_lock unlock];
    return batch;
}

- (NSData *)drain {
    [_lock lock];
    NSData *out = [_buffer copy];
    [_buffer setLength:0];
    [_lock unlock];
    return out;
}

@end

// Path-translate hooks (design §2.4(b)). Stored blocks, called from C
// trampolines installed with fakefs_set_path_translate_hook /
// fakefs_set_path_reverse_hook. Process-global; the blocks must be
// reentrant and non-blocking (hot fs path).
static NSString * _Nullable (^g_forwardTranslateHandler)(NSString *guestPath, uint64_t fsContext) = nil;
static NSString * _Nullable (^g_reverseTranslateHandler)(NSString *hostPath) = nil;

static bool ish_forward_translate_trampoline(const char *guest_path,
                                             uint64_t fs_context,
                                             char *out_host_path,
                                             size_t out_size) {
    NSString *(^handler)(NSString *, uint64_t) = g_forwardTranslateHandler;
    if (!handler || !guest_path || !out_host_path || out_size == 0) return false;
    NSString *guest = [NSString stringWithUTF8String:guest_path];
    if (!guest) return false;
    NSString *host = handler(guest, fs_context);
    if (!host) return false;
    const char *cHost = host.UTF8String;
    if (!cHost) return false;
    size_t len = strlen(cHost);
    if (len >= out_size) return false;
    memcpy(out_host_path, cHost, len + 1);
    return true;
}

static bool ish_reverse_translate_trampoline(const char *host_path,
                                             char *out_guest_path,
                                             size_t out_size) {
    NSString *(^handler)(NSString *) = g_reverseTranslateHandler;
    if (!handler || !host_path || !out_guest_path || out_size == 0) return false;
    NSString *host = [NSString stringWithUTF8String:host_path];
    if (!host) return false;
    NSString *guest = handler(host);
    if (!guest) return false;
    const char *cGuest = guest.UTF8String;
    if (!cGuest) return false;
    size_t len = strlen(cGuest);
    if (len >= out_size) return false;
    memcpy(out_guest_path, cGuest, len + 1);
    return true;
}

// Forward declarations for the session registry (defined on
// ISHKernel below; the C TTY callbacks above the @implementation need
// them). ptySessionRecordForTty: returns a retained record (or nil);
// drainConsoleOutput drains the legacy console/global buffer.
@interface ISHKernel (PtySessions)
- (nullable ISHPtySessionRecord *)ptySessionRecordForTty:(struct tty *)tty;
- (NSData *)drainConsoleOutput;
@end

// --- TTY driver: guest output -> per-session buffer + callback --------
// Same shape as OpenMinis ish_console_ops / ish_console_driver (L1055–1096).
// MULTI-SESSION (stage 5.3): the `tty` parameter is the routing key —
// it is NOT ignored any more. pty_open_fake() gives every session a
// distinct `struct tty`, so a write is appended to exactly that
// session's buffer and dispatched to exactly that session's handler.
// A tty with no session (the console tty PID 1 writes to, or a tty
// whose session was already closed) falls back to the legacy global
// buffer + outputCallback, so PID 1 output and the log ring keep
// working exactly as before.
// OUTPUT BATCHING (design §1.6): the guest can write thousands of tiny
// chunks per millisecond. The callback is invoked on the main queue at
// most once per burst: a pending flag coalesces the writes, and the
// dispatched block drains the whole buffer in one go. A session's
// batch is ALSO fanned out to the legacy outputCallback (same batch,
// same call) so the dsh/ish log ring keeps seeing every terminal's
// output. When no sink is set, nothing is dispatched and the data
// simply accumulates for drainOutputForSession: (polling consumers).
// A byte is delivered exactly once: the handler batch and the drain
// are two views of the same buffer — whoever drains first takes it.
static int ish_proto_tty_write(struct tty *tty, const void *buf, size_t len,
                               bool blocking) {
    (void)blocking;
    if (len == 0) return 0;
    NSData *data = [NSData dataWithBytes:buf length:len];
    ISHPtySessionRecord *record =
        [g_sharedKernel ptySessionRecordForTty:tty];
    if (record) {
        if (![record appendOutput:data]) return (int)len;
        // STRONG capture (not weak): the block is one-shot and the
        // record does not own it, so there is no cycle — but a weak
        // capture would let closePtySession: deallocate the record
        // before this block runs, silently dropping the buffered
        // batch (e.g. a shell's last lines before `exit`).
        ISHPtySessionRecord *strongRecord = record;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Clear the flag BEFORE draining: a write that lands after
            // the clear but before the drain schedules a second dispatch
            // (which drains empty — harmless), so no data is ever lost.
            NSData *batch = [strongRecord drainForDispatch];
            if (batch.length == 0) return;
            void (^handler)(NSData *) = strongRecord.outputHandler;
            if (handler) handler(batch);
            // Fan-out to the log ring (legacy outputCallback).
            if (g_sharedKernel.outputCallback) {
                g_sharedKernel.outputCallback(batch);
            }
        });
        return (int)len;
    }
    // Unregistered tty (console / stale): legacy global buffer.
    [g_ptyOutputLock lock];
    [g_ptyOutput appendData:data];
    BOOL hasCallback = (g_sharedKernel.outputCallback != nil);
    BOOL needsDispatch = hasCallback && !g_outputDispatchPending;
    if (needsDispatch) g_outputDispatchPending = YES;
    [g_ptyOutputLock unlock];
    if (needsDispatch) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Clear the flag BEFORE draining: a write that lands after
            // the clear but before the drain schedules a second dispatch
            // (which drains empty — harmless), so no data is ever lost.
            [g_ptyOutputLock lock];
            g_outputDispatchPending = NO;
            [g_ptyOutputLock unlock];
            NSData *batch = [g_sharedKernel drainConsoleOutput];
            if (batch.length > 0 && g_sharedKernel.outputCallback) {
                g_sharedKernel.outputCallback(batch);
            }
        });
    }
    return (int)len;
}
static int ish_proto_tty_init(struct tty *tty) { (void)tty; return 0; }
// Runs under the guest tty->lock (tty_release holds it): take NO lock
// here — only an atomic store. See the locking note above the record.
static void ish_proto_tty_cleanup(struct tty *tty) {
    if (tty && tty->num >= 0 && tty->num < 4096) {
        atomic_store(&g_ptyDead[tty->num], true);
    }
}

static struct tty_driver_ops ish_proto_console_ops = {
    .init = ish_proto_tty_init,
    .write = ish_proto_tty_write,
    .cleanup = ish_proto_tty_cleanup,
};

DEFINE_TTY_DRIVER(ish_proto_console_driver, &ish_proto_console_ops,
                  TTY_CONSOLE_MAJOR, 8);
static struct tty_driver ish_proto_pty_driver = { .ops = &ish_proto_console_ops };

// --- exit_hook + die_handler ----------------------------------------------
// [DSH-DELTA-K1] die(): embedded iSH must never abort() the app.
// Same semantics as OpenMinis embedded_die_handler (L651–~670): log and
// park only the faulting guest thread. (Rewritten here; the OpenMinis
// original also feeds its crash breadcrumbs — this version just logs.)
static void ish_proto_embedded_die_handler(const char *msg) {
    char buf[256];
    int len = snprintf(buf, sizeof(buf), "\n=== iSH die(): %s ===\n",
                       msg ? msg : "(null)");
    if (len > 0) write(STDERR_FILENO, buf, (size_t)len);
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    for (;;) select(0, NULL, NULL, NULL, NULL);
    __builtin_unreachable();
}

static void ish_proto_handle_process_exit(struct task *task, int code) {
    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_guestExits[@(pid)] = @(code);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ISHGuestExitedNotification
                          object:nil
                        userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

@implementation ISHKernel {
    BOOL _isBooted;
    NSString *_rootPath;
    NSString *_dataPath;
    dispatch_semaphore_t _bootSemaphore;
    int _bootResult;
    dispatch_queue_t _inputQueue; // serial queue for sendInput (tty_input blocks)
    // PTY session registry (stage 5.3): sessionId -> record. Guarded by
    // _ptySessionsLock; see the locking note above ISHPtySessionRecord.
    // _consoleTTY is gone: there is no single shared tty any more.
    NSMutableDictionary<NSString *, ISHPtySessionRecord *> *_ptySessions;
    NSLock *_ptySessionsLock;
    NSString *_defaultSessionId; // most recent legacy executeCommand:pid:
}

+ (ISHKernel *)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_sharedKernel = [[ISHKernel alloc] init];
        // [FIX build 12 crash] These are long-lived statics. The
        // convenience constructors return AUTORELEASED objects; this
        // target has no CLANG_ENABLE_OBJC_ARC (defaults off), so the
        // assignment did NOT retain and both dangled after the pool
        // drained. drainOutput then sent setLength: to freed memory
        // reused by an NSValue -> unrecognized selector -> abort.
        // alloc/init returns +1 owned objects, safe with or without ARC.
        // (The formal target sets CLANG_ENABLE_OBJC_ARC = YES as well;
        // the alloc/init is kept as belt-and-braces.)
        g_guestExits = [[NSMutableDictionary alloc] init];
        g_ptyOutput = [[NSMutableData alloc] init];
        g_ptyOutputLock = [[NSLock alloc] init];
    });
    return g_sharedKernel;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _inputQueue = dispatch_queue_create("me.zzuu.dsh.ish.input",
                                            DISPATCH_QUEUE_SERIAL);
        _ptySessions = [[NSMutableDictionary alloc] init];
        _ptySessionsLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)isBooted { return _isBooted; }

- (NSString *)defaultPtySessionId {
    [_ptySessionsLock lock];
    NSString *sessionId = _defaultSessionId;
    [_ptySessionsLock unlock];
    return sessionId;
}

/// Drain the legacy console/global buffer (unregistered-tty output
/// only). Used by the TTY driver's fallback path.
- (NSData *)drainConsoleOutput {
    [g_ptyOutputLock lock];
    NSData *out = [g_ptyOutput copy];
    [g_ptyOutput setLength:0];
    [g_ptyOutputLock unlock];
    return out;
}

- (NSData *)drainOutput {
    // LEGACY: default session first, then the console buffer.
    NSMutableData *out = [[NSMutableData alloc] init];
    NSString *defaultId = self.defaultPtySessionId;
    if (defaultId) [out appendData:[self drainOutputForSession:defaultId]];
    [out appendData:[self drainConsoleOutput]];
    return [out copy];
}

// --- PTY session registry (stage 5.3) --------------------------------------

/// Retained record for a tty pointer (linear scan; <= ISHPtyMaxSessions
/// live sessions). Called from ish_proto_tty_write on guest threads:
/// takes only the registry lock, retains under it, releases it — the
/// caller then uses the record without holding the lock, so no guest
/// lock is ever nested under ours.
- (nullable ISHPtySessionRecord *)ptySessionRecordForTty:(struct tty *)tty {
    if (!tty) return nil;
    [_ptySessionsLock lock];
    ISHPtySessionRecord *found = nil;
    for (ISHPtySessionRecord *record in _ptySessions.allValues) {
        if ([record ttySnapshot] == tty) { found = record; break; }
    }
    [_ptySessionsLock unlock];
    return found;
}

/// Retained record for a session id (or nil). Same locking as above.
- (nullable ISHPtySessionRecord *)ptySessionRecordForId:(NSString *)sessionId {
    if (!sessionId) return nil;
    [_ptySessionsLock lock];
    ISHPtySessionRecord *record = _ptySessions[sessionId];
    [_ptySessionsLock unlock];
    return record;
}

- (void)setPtyOutputHandler:(nullable void (^)(NSData *data))handler
                 forSession:(NSString *)sessionId {
    ISHPtySessionRecord *record = [self ptySessionRecordForId:sessionId];
    if (!record) return;
    record.outputHandler = handler;
}

- (NSData *)drainOutputForSession:(NSString *)sessionId {
    ISHPtySessionRecord *record = [self ptySessionRecordForId:sessionId];
    if (!record) return [NSData data];
    return [record drain];
}

- (NSUInteger)ptySessionCount {
    [_ptySessionsLock lock];
    NSUInteger count = _ptySessions.count;
    [_ptySessionsLock unlock];
    return count;
}

/// Remove a session record WITHOUT killing anything: for spawn
/// failures inside executeCommand:sessionId:... (pty/create_stdio/
/// do_execve failed — no guest is running, so there is nothing to
/// kill). Only removes when the registry still maps the id to this
/// exact record. The tty itself is left to the kernel (same leak
/// profile as the old code on these paths: one orphaned tty struct
/// per failed spawn, no task behind it).
- (void)discardPtySessionRecord:(ISHPtySessionRecord *)record {
    if (!record) return;
    [_ptySessionsLock lock];
    if (_ptySessions[record.sessionId] == record) {
        [_ptySessions removeObjectForKey:record.sessionId];
    }
    [_ptySessionsLock unlock];
    [record markClosed];
    record.outputHandler = nil;
}

- (void)closePtySession:(NSString *)sessionId {
    if (!sessionId) return;
    ISHPtySessionRecord *record = nil;
    [_ptySessionsLock lock];
    record = _ptySessions[sessionId];
    if (record) {
        [_ptySessions removeObjectForKey:sessionId];
        if ([_defaultSessionId isEqualToString:sessionId]) {
            _defaultSessionId = nil;
        }
    }
    [_ptySessionsLock unlock];
    if (!record) return; // unknown id: idempotent no-op
    // Mark closed FIRST (drops further input/resize at the gate),
    // then kill the group. Never dereference record.tty here: the
    // guest may already have exited and the kernel may have freed it
    // (tty_release); the kill is by pid, which is always safe.
    [record markClosed];
    record.outputHandler = nil;
    if (record.guestPid > 0) {
        [[ISHShellExecutor shared] killProcessGroup:record.guestPid];
    }
    NSLog(@"ISHKernel: pty session %@ closed (guest pid %d)",
          sessionId, record.guestPid);
}

- (void)closeAllPtySessions {
    [_ptySessionsLock lock];
    NSArray<NSString *> *ids = [_ptySessions.allKeys copy];
    [_ptySessionsLock unlock];
    for (NSString *sessionId in ids) {
        [self closePtySession:sessionId];
    }
}

- (nullable NSNumber *)exitCodeForGuestPid:(int)pid {
    if ([NSThread isMainThread]) return g_guestExits[@(pid)];
    __block NSNumber *code = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        code = g_guestExits[@(pid)];
    });
    return code;
}

- (uint64_t)hostPhysFootprintBytes {
    // No ish_* helper exists for this; measure directly (same code as
    // ish-src app/AppDelegate.m ish_memory_governor_tick and main.c
    // ish_cli_phys_footprint). 0 on failure — callers treat 0 as
    // "could not measure", never as a real reading.
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (uint64_t)info.phys_footprint;
}

- (uint64_t)hostAvailableMemoryBytes {
    // os_proc_available_memory() returns 0 when it cannot measure.
    return (uint64_t)os_proc_available_memory();
}

// --- Boot ------------------------------------------------------------------

- (int)bootWithRootPath:(NSString *)rootPath {
    if (_isBooted) {
        NSLog(@"ISHKernel: already booted");
        return 0;
    }
    // [DSH-ISH-FIX-P0] Point the iSH AF_UNIX backing prefix at a writable
    // container dir. The default "/tmp/ishsock" is outside the iOS sandbox,
    // so every guest AF_UNIX bind() failed with EPERM (including the
    // abstract namespace, which never touches the guest filesystem). Must
    // run before boot: no guest socket can exist yet, and the setter is
    // only called once. NSTemporaryDirectory() ends with a slash, so the
    // backing path becomes "<tmp>/ishsock<pid>.<id>".
    {
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *prefix = [tmpDir stringByAppendingString:@"ishsock"];
        ish_sock_set_tmp_prefix(prefix.UTF8String);
        NSLog(@"ISHKernel: AF_UNIX backing prefix set to %@", prefix);
    }
    // (Retired 2026-11-15: the didResetWhileBooted refusal is gone.
    // Reset is now synchronous and self-healing; the next boot just
    // reinstalls the rootfs from the bundled zip. See
    // resetRootfsWhileBooted.)
    _rootPath = [rootPath copy];
    _dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:_dataPath]) {
        NSLog(@"ISHKernel: rootfs data/ missing at %@", _dataPath);
        return -1;
    }
    _bootSemaphore = dispatch_semaphore_create(0);
    _bootResult = -1;
    // The PID 1 supervisor thread. It becomes PID 1, runs the rest of
    // boot in the init task context, reports, and then parks forever.
    NSThread *supervisor = [[NSThread alloc]
        initWithTarget:self
              selector:@selector(supervisorMain:)
                object:nil];
    supervisor.name = @"dsh-go ISH PID1 supervisor";
    // 512 KiB default secondary-thread stack is enough: the supervisor
    // never runs guest code, it only parks.
    [supervisor start];
    long ok = dispatch_semaphore_wait(
        _bootSemaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    if (ok != 0) {
        NSLog(@"ISHKernel: supervisor boot timed out after 30s");
        return -2;
    }
    return _bootResult;
}

// Runs on the supervisor thread. Returns 0 on success; on success the
// caller (supervisorMain) parks this thread forever — it IS pid 1.
- (int)bootOnSupervisorThread {
    // [DSH-DELTA-K2] No handler install here. OpenMinis boot step 0
    // installs the JIT crash handler before any JIT code runs; this
    // version installs it in the coordinator AFTER Node is ready, so
    // g_prev captures Node's handler (mitigation ① order requirement).
    // Boot therefore REQUIRES the handler to be already installed; it
    // only verifies that.
    {
        ISHSignalDisposition d;
        ish_crash_handler_current_disposition(SIGSEGV, &d);
        if (d.handler != ish_crash_handler_function()) {
            NSLog(@"ISHKernel: refusing boot — crash handler not installed "
                  @"(install it after Node start, before boot)");
            return -3;
        }
    }

    // Step 0.5: guest anonymous-memory cap.
    // [DSH-DELTA-K3] Design §2.7: share 0.5, NOT OpenMinis's 0.8 —
    // this process also runs NodeMobile + DSH's JS heap + Flutter, so
    // the guest must leave more headroom. 2 GB ceiling unchanged
    // (ANON_MMAP_LIMIT_PAGES in kernel/mm.h). Host page size, not guest
    // 4 KB, in the conversion: the 2026-08-25 lesson — converting a
    // host-byte budget with 4096 authorised ~4x the intended cap.
    {
        size_t avail = os_proc_available_memory();
        size_t hostPage = (size_t)getpagesize();
        if (avail > 0 && hostPage > 0) {
            static const double kGuestMemoryShare = 0.5;
            long pages = (long)((double)avail * kGuestMemoryShare /
                                (double)hostPage);
            ish_set_anon_page_limit(pages);
            NSLog(@"ISHKernel: guest anon cap share %.0f%% of %.0f MB "
                  @"available (host page %zu KB)",
                  kGuestMemoryShare * 100.0,
                  (double)avail / (1024 * 1024), hostPage / 1024);
        } else {
            NSLog(@"ISHKernel: os_proc_available_memory unavailable — "
                  @"keeping default anon cap");
        }
    }

    // Step 0.5 (continued): start the host-side guards (stage 2.5).
    // The memory feed is primed BEFORE the guest boots: the first
    // allocations happen during exec of init, long before a 250 ms
    // tick would land — until the feed exists the kernel is still on
    // the legacy ledger cap (same reason as main.c
    // ish_cli_memory_governor_start). The fork guard is inert until
    // the first fork (no guest task exists before PID 1), so installing
    // it here rather than at OpenMinis's boot step 6.5 is equivalent.
    [[ISHResourceGovernor shared] startBootGovernors];

    // Step 1: mount rootfs. die() must not abort the app.
    extern void (*die_handler)(const char *msg);
    die_handler = ish_proto_embedded_die_handler;
    int err = mount_root(&fakefs, _dataPath.fileSystemRepresentation);
    if (err < 0) {
        NSLog(@"ISHKernel: mount_root failed: %d", err);
        return err;
    }
    NSLog(@"ISHKernel: rootfs mounted at %@", _dataPath);
    char canonical_data_path[PATH_MAX];
    if (realpath(_dataPath.fileSystemRepresentation,
                 canonical_data_path) != NULL) {
        fakefs_set_rootfs_data_path(canonical_data_path);
    } else {
        NSLog(@"ISHKernel: realpath(_dataPath) failed (errno=%d), "
              @"bind-mount cycle guard disabled", errno);
    }

    // Step 1.5 (ENV-05): raise the HOST process's RLIMIT_NOFILE before
    // the guest boots. The kernel's init_rlimits sets the guest soft
    // limit to 4096 (hard 8192), but the host limit is the outer bound:
    // if the host is capped lower, the guest cannot exceed it and `ulimit
    // -n` would still show the host value. 8192/8192 matches the guest
    // hard limit; failure only logs (the guest still boots with the
    // kernel's own limits, and fd exhaustion then fails gracefully).
    {
        struct rlimit rl = { .rlim_cur = 8192, .rlim_max = 8192 };
        if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
            NSLog(@"ISHKernel: setrlimit(RLIMIT_NOFILE, 8192) failed: %d "
                  @"(guest keeps kernel init_rlimits)", errno);
        }
    }

    // Step 2: become PID 1. From here on, `current` is the init task and
    // this thread is its host thread. Nothing after this point may exec a
    // shell on this thread or return from the supervisor (see below).
    err = become_first_process();
    if (err < 0) {
        NSLog(@"ISHKernel: become_first_process failed: %d", err);
        return err;
    }
    current->thread = pthread_self();
    NSLog(@"ISHKernel: init process created (PID 1)");

    // Step 3: device nodes (same list as OpenMinis createDeviceNodes).
    [self createDeviceNodes];

    // Step 4: mount proc and devpts.
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"ISHKernel: /proc and /dev/pts mounted");

    // Step 5: DNS + netlink stub.
    setenv("ISH_NETLINK_STUB", "1", 0);
    [self refreshDns];

    // Step 6: exit hook.
    exit_hook = ish_proto_handle_process_exit;

    // Step 7: TTY driver + console stdio for init.
    tty_drivers[TTY_CONSOLE_MAJOR] = &ish_proto_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        NSLog(@"ISHKernel: create_stdio failed: %d (non-fatal)", err);
    }

    // [DSH-DELTA-K4] No native offload registration (OpenMinis step 9,
    // 28 handlers) — v1 scope excludes offloads. The memory/fork
    // governors start in boot step 0.5 (stage 2.5, ISHResourceGovernor);
    // the background CPU governor starts when the app backgrounds.
    NSLog(@"ISHKernel: kernel initialized successfully");
    return 0;
}

- (void)supervisorMain:(id)unused {
    (void)unused;
    @autoreleasepool {
        _bootResult = [self bootOnSupervisorThread];
        if (_bootResult == 0) _isBooted = YES;
        dispatch_semaphore_signal(_bootSemaphore);
        if (_bootResult != 0) return; // Boot failed: nothing to supervise.
        // PID 1 NEVER EXITS and NEVER EXECS. Park forever. pause()
        // returns on signal delivery; loop to re-park. Shells are always
        // children (pid >= 2) started via executeCommand:.
        NSLog(@"ISHKernel: PID 1 supervisor parked (never exits)");
        for (;;) pause();
    }
}

- (void)createDeviceNodes {
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty3", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/tty4", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 4));
    generic_mknodat(AT_PWD, "/dev/tty5", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/tty6", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 6));
    generic_mknodat(AT_PWD, "/dev/tty7", S_IFCHR | 0666,
                    dev_make(TTY_CONSOLE_MAJOR, 7));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666,
                    dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666,
                    dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666,
                    dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666,
                    dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666,
                    dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666,
                    dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666,
                    dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666,
                    dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    // [DSH-ISH-FIX-P1] Standard /dev/fd + /dev/std* symlinks. These only
    // work because sys_openat now resolves proc-fd magic links by dup (see
    // the iSH kernel patch, kernel/fs.c); without that, opening them fails
    // with ENOENT because procfs readlink returns "anon_inode:[...]" for
    // pipes/ttys/sockets. The targets need not exist yet: /proc is mounted
    // in step 4, after this runs, and a symlink may dangle until then.
    generic_symlinkat("/proc/self/fd", AT_PWD, "/dev/fd");
    generic_symlinkat("/proc/self/fd/0", AT_PWD, "/dev/stdin");
    generic_symlinkat("/proc/self/fd/1", AT_PWD, "/dev/stdout");
    generic_symlinkat("/proc/self/fd/2", AT_PWD, "/dev/stderr");
    NSLog(@"ISHKernel: device nodes created");
}

- (void)refreshDns {
    if (!_dataPath) return;
    NSMutableString *resolvConf = [NSMutableString new];
    struct __res_state res;
    memset(&res, 0, sizeof(res));
    BOOL initOk = (res_ninit(&res) == 0);
    if (initOk) {
        union res_sockaddr_union servers[NI_MAXSERV];
        int serverCount = res_getservers(&res, servers, NI_MAXSERV);
        for (int i = 0; i < serverCount; i++) {
            if (servers[i].sin.sin_len == 0) continue;
            char addrStr[INET6_ADDRSTRLEN];
            const char *result = NULL;
            if (servers[i].sin.sin_family == AF_INET) {
                result = inet_ntop(AF_INET, &servers[i].sin.sin_addr,
                                   addrStr, sizeof(addrStr));
            } else if (servers[i].sin.sin_family == AF_INET6) {
                result = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr,
                                   addrStr, sizeof(addrStr));
            }
            if (result != NULL) [resolvConf appendFormat:@"nameserver %s\n", result];
        }
        res_nclose(&res);
    }
    if ([resolvConf rangeOfString:@"nameserver"].location == NSNotFound) {
        [resolvConf appendString:@"nameserver 8.8.8.8\nnameserver 8.8.4.4\n"];
    }
    NSString *path = [_dataPath stringByAppendingPathComponent:@"etc/resolv.conf"];
    // In-place write (options:0), NOT atomic: an atomic replace would
    // change the inode and desync fakefs meta.db. Production uses a
    // bind-mount for resolv.conf instead (OpenMinis writeResolvConf);
    // this version writes the shipped file directly (stage 3 replaces
    // it with the bind-mount).
    NSError *error = nil;
    BOOL ok = [resolvConf writeToFile:path atomically:NO
                             encoding:NSUTF8StringEncoding error:&error];
    NSLog(@"ISHKernel: DNS configured (%@): %@",
          ok ? @"ok" : @"FAILED", ok ? path : error);
}

// --- Execution ---------------------------------------------------------------

- (int)executeCommand:(NSArray<NSString *> *)command
                  pid:(int *)outPid {
    // LEGACY: one fresh session, remembered as the default for the
    // legacy sendInput: / setTerminalSize:rows: / drainOutput shims.
    NSString *sessionId = [[NSUUID UUID] UUIDString];
    int rc = [self executeCommand:command pid:outPid sessionId:sessionId
                        fsContext:0 cols:0 rows:0];
    if (rc == 0) {
        [_ptySessionsLock lock];
        _defaultSessionId = sessionId;
        [_ptySessionsLock unlock];
    }
    return rc;
}

- (int)executeCommand:(NSArray<NSString *> *)command
                  pid:(int *)outPid
            sessionId:(NSString *)sessionId
            fsContext:(uint64_t)fsContext
                 cols:(int)cols
                 rows:(int)rows {
    if (!_isBooted) {
        NSLog(@"ISHKernel: kernel not booted");
        return -1;
    }
    // (Retired 2026-11-15: the didResetWhileBooted refusal is gone.
    // See resetRootfsWhileBooted.)
    if (command.count == 0) return -2;
    if (!sessionId || sessionId.length == 0) return -2;
    // Session cap (stage 5.3): refuse before spawning anything, so a
    // refused open never leaks a shell or a tty.
    ISHPtySessionRecord *record =
        [[ISHPtySessionRecord alloc] initWithSessionId:sessionId];
    [_ptySessionsLock lock];
    BOOL duplicate = (_ptySessions[sessionId] != nil);
    BOOL atCap = (_ptySessions.count >= (NSUInteger)ISHPtyMaxSessions);
    if (!duplicate && !atCap) _ptySessions[sessionId] = record;
    [_ptySessionsLock unlock];
    if (duplicate) {
        NSLog(@"ISHKernel: duplicate pty session id %@", sessionId);
        return -4;
    }
    if (atCap) {
        NSLog(@"ISHKernel: pty session cap reached (%ld)",
              (long)ISHPtyMaxSessions);
        return -5;
    }
    NSArray<NSString *> *commandCopy = [command copy];
    NSDictionary<NSString *, NSString *> *customEnv = self.customEnvironment;
    // NOTE: no [self drainOutput] here any more (the old "fresh
    // capture"): draining would steal OTHER sessions' buffered output.
    // A new session starts with an empty buffer by construction.
    __block int guestPid = -1;
    __block int startResult = -4; // 0 only after do_execve succeeded
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        // Spawn as a child of init (pid >= 2). Never on the supervisor
        // thread, never as pid 1.
        int err = become_new_init_child();
        if (err < 0) {
            NSLog(@"ISHKernel: become_new_init_child failed: %d", err);
            dispatch_semaphore_signal(started);
            return;
        }
        guestPid = current->pid;
        // fs_context for the path-translate hook (inherited verbatim
        // on fork; same line as ISHShellExecutor's pipe path). The
        // interactive path passes 0; the tty executor passes the
        // agent run's context.
        current->group->fs_context = fsContext;
        struct tty *tty = pty_open_fake(&ish_proto_pty_driver);
        if (tty == NULL || IS_ERR(tty)) {
            NSLog(@"ISHKernel: pty_open_fake failed: %ld",
                  (long)PTR_ERR(tty));
            [self discardPtySessionRecord:record];
            dispatch_semaphore_signal(started);
            return;
        }
        // Register the tty on the record (routing key for
        // ish_proto_tty_write) and clear its death flag: the number
        // may have been used by an earlier, already-freed session.
        record.guestPid = guestPid;
        [record setTty:tty num:tty->num];
        if (tty->num >= 0 && tty->num < 4096) {
            atomic_store(&g_ptyDead[tty->num], false);
        }
        // OpenMinis default: 24 rows x 200 cols (when the caller
        // passes no size). The UI corrects this to the real size on
        // first layout via setTerminalSize:rows:. A tty exec passes
        // its size up front so `stty size` is right from the start.
        struct winsize_ winsize = {
            .row = (word_t)(rows > 0 ? rows : 24),
            .col = (word_t)(cols > 0 ? cols : 200),
            .xpixel = 0, .ypixel = 0 };
        tty_set_winsize(tty, winsize);
        NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d",
                               tty->num];
        err = create_stdio(stdioFile.fileSystemRepresentation,
                           TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (err < 0) {
            NSLog(@"ISHKernel: create_stdio failed: %d", err);
            [self discardPtySessionRecord:record];
            dispatch_semaphore_signal(started);
            return;
        }
        // argv (16 KB) + envp (8 KB), same packing as OpenMinis.
        char argv[16384];
        size_t pos = 0;
        int exec_argc = 0;
        for (NSString *arg in commandCopy) {
            const char *carg = arg.UTF8String;
            size_t len = strlen(carg) + 1;
            if (pos + len >= sizeof(argv)) break;
            memcpy(argv + pos, carg, len);
            pos += len;
            exec_argc++;
        }
        argv[pos] = '\0';
        char envp_buf[8192];
        size_t envp_pos = 0;
#define KERNEL_ENVP_APPEND(s) do { \
            const char *_s = (s); \
            size_t _len = strlen(_s) + 1; \
            if (envp_pos + _len < sizeof(envp_buf) - 256) { \
                memcpy(envp_buf + envp_pos, _s, _len); \
                envp_pos += _len; \
            } \
        } while (0)
        KERNEL_ENVP_APPEND("TERM=xterm-256color");
        KERNEL_ENVP_APPEND("HOME=/root");
        KERNEL_ENVP_APPEND("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        KERNEL_ENVP_APPEND("LANG=C.UTF-8");
        KERNEL_ENVP_APPEND("ENV=/etc/profile");
        // Custom environment (design §2.4(b)): appended after the fixed
        // entries; entries that would overflow the buffer are dropped.
        // Never contains the DSH token or any secret (see the header).
        for (NSString *key in customEnv) {
            NSString *value = customEnv[key];
            if (![key isKindOfClass:[NSString class]] ||
                ![value isKindOfClass:[NSString class]]) continue;
            NSString *pair = [NSString stringWithFormat:@"%@=%@", key, value];
            KERNEL_ENVP_APPEND(pair.UTF8String);
        }
#undef KERNEL_ENVP_APPEND
        envp_buf[envp_pos] = '\0';
        const char *exec_path = commandCopy[0].UTF8String;
        err = do_execve(exec_path, exec_argc, argv, envp_buf);
        if (err < 0) {
            NSLog(@"ISHKernel: do_execve failed: %d", err);
            [self discardPtySessionRecord:record];
            dispatch_semaphore_signal(started);
            // [FIX 1.4a-rev] The child task was created by become_new_init_child
            // but exec failed, so it never ran task_start and never exited.
            // Without cleanup it stays in the pid table as a live task forever:
            // no host thread runs its emulator loop, so stopGuest's SIGTERM /
            // SIGKILL can never be delivered (send_signal queues the signal
            // and pokes task->thread, which is not processing guest signals),
            // and pid_get_task keeps returning it (it is not a zombie).
            // Observed on device (build 13, test 1.4a): 1.3c's two
            // "/bin/apk" execs failed (ENOENT — apk lives at /sbin/apk),
            // leaking 2 live tasks; guestProcessCount stayed 3 after stop
            // instead of dropping to 1 (only PID 1).
            // Do NOT call do_exit here (fix10 did, and it crashed the app):
            // do_exit ends in pthread_exit, which is illegal on this GCD
            // workqueue thread — libpthread aborts with "BUG IN CLIENT OF
            // LIBPTHREAD: pthread_exit() called from a thread not created by
            // pthread_create()" (build 14 crash, thread "echo-10", 21:00:56).
            // Normal guest tasks are safe because task_start spawns a REAL
            // pthread (pthread_create) for them; this child never reached
            // task_start, so no real pthread exists for it. Instead, mark
            // it a zombie directly: pid_get_task returns NULL for zombies
            // (kernel/task.c), so guestProcessCount / stopGuest ignore it.
            // The task struct + its mm/files are not released — a small,
            // bounded leak per failed exec (failed execs are rare). A full
            // cleanup would need a real pthread to run do_exit on.
            lock(&pids_lock);
            current->exiting = true;
            current->zombie = true;
            unlock(&pids_lock);
            return;
        }
        NSLog(@"ISHKernel: started guest process PID %d (pty session %@)",
              current->pid, sessionId);
        startResult = 0;
        dispatch_semaphore_signal(started);
        // Runs the emulator loop on a REAL pthread spawned by task_start
        // (pthread_create) — that is the thread do_exit's pthread_exit
        // runs on when the guest exits, which is why normal exits are
        // safe. The harness relies on exit_hook, not on this returning.
        task_start(current);
    });
    long ok = dispatch_semaphore_wait(
        started, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    if (ok != 0) {
        NSLog(@"ISHKernel: execute start timed out after 10s");
        return -3;
    }
    if (guestPid <= 0) return -4;
    if (outPid) *outPid = guestPid;
    return startResult;
}

- (int)guestProcessCount {
    int n = 0;
    lock(&pids_lock);
    for (int i = 1; i < MAX_PID; i++) {
        if (pid_get_task((dword_t)i) != NULL) n++;
    }
    unlock(&pids_lock);
    return n;
}

- (int)getGuestProcessCount:(int *)outCount anonBytes:(uint64_t *)outAnonBytes {
    int n = [self guestProcessCount];
    if (outCount) *outCount = n;
    if (outAnonBytes) {
        // anon_page_count counts GUEST pages (4 KiB each) across all
        // guest processes (kernel/mm.h). Host-page units apply only to
        // the CAP (boot step 0.5), never to this reading.
        long pages = atomic_load(&anon_page_count);
        if (pages < 0) pages = 0;
        *outAnonBytes = (uint64_t)pages * 4096ULL;
    }
    return n;
}

- (void)stopGuest {
    // (Stage 5.3) Close the PTY sessions first: a guest stop kills
    // every shell anyway, and leaving their records behind would leak
    // registry slots (and let a stale record's handler fire). The
    // Swift PTY sessions observe the shell-exit notification and close
    // their WebSockets as usual; their closePtySession: calls then
    // hit unknown ids and no-op.
    [self closeAllPtySessions];
    // Kill every guest task with pid >= 2. NEVER pid 1: an ancestry sweep
    // rooted at init would match every task and tear the kernel down,
    // and pid 1's death calls halt_system() == _exit(0) (kernel/exit.c),
    // killing the whole app. (OpenMinis killProcessGroup refuses
    // pid <= 1 for exactly this reason.)
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    for (int i = 2; i < MAX_PID; i++) {
        struct task *t = pid_get_task((dword_t)i);
        if (!t) continue;
        send_signal(t, SIGTERM_, info);
    }
    unlock(&pids_lock);
    NSLog(@"ISHKernel: stopGuest sent SIGTERM to all pid >= 2");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        lock(&pids_lock);
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task((dword_t)i);
            if (!t) continue;
            send_signal(t, SIGKILL_, info);
        }
        unlock(&pids_lock);
        NSLog(@"ISHKernel: stopGuest sent SIGKILL to survivors (pid >= 2)");
    });
}

- (void)resetRootfsWhileBooted {
    // Retired the didResetWhileBooted flag (2026-11-15, build 28):
    // it refused every boot/execute until an App relaunch, but the
    // flag is in-memory and the relaunch did not reliably clear it
    // on device (build 27: force-quit + relaunch still showed
    // ish_boot_reset_flag), leaving the terminal permanently wedged.
    // Now the reset is synchronous and self-healing: stop the guest,
    // delete the rootfs inline (no async window where the rootfs is
    // half-deleted), and let the next boot reinstall it from the
    // bundled zip via RootfsManager.ensureInstalled. No flag, no
    // relaunch required.
    [self stopGuest];
    NSString *rootfs = _rootPath;
    if (rootfs) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:rootfs error:&error];
        if (error) {
            NSLog(@"ISHKernel: rootfs delete failed (best effort): %@",
                  error);
        } else {
            NSLog(@"ISHKernel: rootfs deleted synchronously; next boot reinstalls from the bundled zip");
        }
        // (Build 38) Verify the delete actually took: the kernel still
        // has the rootfs mounted and pid 1 parked on it, so the delete
        // can fail or be partial while the caller still reports
        // success — then the next boot sees the stale markers and
        // returns .alreadyInstalled on a broken tree. If the tree is
        // still there, rename it out of the way (same fallback as
        // RootfsManager.clearBrokenInstall) so ensureInstalled is
        // forced to re-extract.
        if ([[NSFileManager defaultManager] fileExistsAtPath:rootfs]) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            fmt.dateFormat = @"yyyyMMdd-HHmmss";
            NSString *stamp = [fmt stringFromDate:[NSDate date]];
            NSString *parent = [rootfs stringByDeletingLastPathComponent];
            NSString *broken = [parent stringByAppendingPathComponent:
                [NSString stringWithFormat:@".rootfs-broken-%@", stamp]];
            NSError *renameError = nil;
            if ([[NSFileManager defaultManager] moveItemAtPath:rootfs toPath:broken error:&renameError]) {
                NSLog(@"ISHKernel: rootfs delete incomplete, renamed to %@", [broken lastPathComponent]);
            } else {
                NSLog(@"ISHKernel: rootfs delete AND rename failed (%@) — next boot may reuse a broken tree", renameError);
            }
        }
    }
}

// --- Input / resize ----------------------------------------------------------

- (void)sendInput:(NSData *)data sessionId:(NSString *)sessionId {
    if (!data || data.length == 0) return;
    ISHPtySessionRecord *record = [self ptySessionRecordForId:sessionId];
    if (!record) return;
    // tty_input() takes a pthread mutex and blocks while the kernel is
    // busy — never call it on the main thread or on a caller thread
    // that must stay responsive. A dedicated serial queue preserves
    // input order (design §1.6). The tty pointer is snapshotted under
    // the record lock and used only after the lock is released (see
    // the locking note above ISHPtySessionRecord); a closed session
    // or a dead tty drops the input.
    dispatch_async(_inputQueue, ^{
        // Re-check liveness at write time, not at enqueue time: the
        // session may have closed while this block waited in the
        // queue (e.g. the user closed the tab). Also refuse input
        // once the guest pid has exited — its tty may already be
        // freed (tty_release), and tty_input would touch freed memory.
        if (record.closed) return;
        if (record.guestPid > 0 &&
            [self exitCodeForGuestPid:record.guestPid] != nil) return;
        struct tty *tty = [record ttyForInput];
        if (!tty) return;
        tty_input(tty, data.bytes, data.length, false);
    });
}

- (void)sendInputString:(NSString *)string sessionId:(NSString *)sessionId {
    if (!string) return;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendInput:data sessionId:sessionId];
}

- (void)setTerminalSize:(int)cols rows:(int)rows sessionId:(NSString *)sessionId {
    if (cols <= 0 || rows <= 0) return;
    ISHPtySessionRecord *record = [self ptySessionRecordForId:sessionId];
    if (!record || record.closed) return;
    if (record.guestPid > 0 &&
        [self exitCodeForGuestPid:record.guestPid] != nil) return;
    struct tty *tty = [record ttyForInput];
    if (!tty) return;
    struct winsize_ winsize = {
        .row = (word_t)rows, .col = (word_t)cols, .xpixel = 0, .ypixel = 0 };
    tty_set_winsize(tty, winsize);
    // The kernel sends SIGWINCH to the foreground process group on a
    // winsize change (standard semantics).
}

- (void)sendInput:(NSData *)data {
    NSString *defaultId = self.defaultPtySessionId;
    if (!defaultId) return;
    [self sendInput:data sessionId:defaultId];
}

- (void)sendInputString:(NSString *)string {
    NSString *defaultId = self.defaultPtySessionId;
    if (!defaultId) return;
    [self sendInputString:string sessionId:defaultId];
}

- (void)setTerminalSize:(int)cols rows:(int)rows {
    NSString *defaultId = self.defaultPtySessionId;
    if (!defaultId) return;
    [self setTerminalSize:cols rows:rows sessionId:defaultId];
}

// --- Mounts / path translation -----------------------------------------------

- (int)bindMountPath:(NSString *)guestPath
          toHostPath:(NSString *)hostPath
            readOnly:(BOOL)readOnly {
    if (!guestPath || !hostPath ||
        ![guestPath hasPrefix:@"/"] || ![hostPath hasPrefix:@"/"]) {
        NSLog(@"ISHKernel: bindMountPath needs absolute guest + host paths");
        return -1;
    }
    if (!_dataPath) {
        NSLog(@"ISHKernel: bindMountPath needs a rootfs path (boot first, "
              @"or set _rootPath before boot)");
        return -1;
    }
    // 1. Symlink in data/ at the guest path, pointing at the host dir.
    //    (OpenMinis performMount: a bind mount IS a symlink in data/.)
    NSString *linkPath = [_dataPath stringByAppendingPathComponent:
                          [guestPath substringFromIndex:1]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    // Remove a stale link/dir at the mount point (a real directory is
    // only removed if it is empty — never delete guest data to make a
    // mount point).
    NSDictionary *attrs = [fm attributesOfItemAtPath:linkPath error:NULL];
    if (attrs) {
        NSString *type = attrs[NSFileType];
        if ([type isEqualToString:NSFileTypeSymbolicLink]) {
            [fm removeItemAtPath:linkPath error:&error];
        } else if ([type isEqualToString:NSFileTypeDirectory]) {
            NSArray *contents = [fm contentsOfDirectoryAtPath:linkPath error:NULL];
            if (contents.count == 0) [fm removeItemAtPath:linkPath error:&error];
            else {
                NSLog(@"ISHKernel: bind mount point %@ is a non-empty "
                      @"directory, refusing to replace it", guestPath);
                return -1;
            }
        } else {
            NSLog(@"ISHKernel: bind mount point %@ is a %@, refusing",
                  guestPath, type);
            return -1;
        }
        if (error) {
            NSLog(@"ISHKernel: clearing bind mount point failed: %@", error);
            return -1;
        }
    }
    NSString *parent = [linkPath stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES
                        attributes:nil error:&error]) {
        NSLog(@"ISHKernel: bind mount parent create failed: %@", error);
        return -1;
    }
    if (![fm createSymbolicLinkAtPath:linkPath
                 withDestinationPath:hostPath error:&error]) {
        NSLog(@"ISHKernel: bind mount symlink failed: %@", error);
        return -1;
    }
    // 2. Register the link (and its parents) in meta.db so the kernel
    //    sees it. Read-only mounts get mode 0555 so access_check
    //    refuses writes with EACCES.
    NSString *metaDB = [_rootPath stringByAppendingPathComponent:@"meta.db"];
    const char *metaDBPath = metaDB.fileSystemRepresentation;
    const char *guestCPath = guestPath.fileSystemRepresentation;
    if (ish_fakefs_meta_ensure_parents(metaDBPath, guestCPath) != 0 ||
        ish_fakefs_meta_register_path(metaDBPath, guestCPath,
                                      readOnly ? 0040555 : 0040755) != 0) {
        NSLog(@"ISHKernel: bind mount meta.db registration failed for %@",
              guestPath);
        return -1;
    }
    // 3. Kernel-side bind (only meaningful once booted; harmless before).
    if (_isBooted) {
        int err = fakefs_bind_mount(guestCPath,
                                    hostPath.fileSystemRepresentation,
                                    readOnly);
        if (err != 0) {
            NSLog(@"ISHKernel: fakefs_bind_mount(%@) failed: %d", guestPath, err);
            return -1;
        }
    }
    NSLog(@"ISHKernel: bind mount %@ -> %@ (%@)", guestPath, hostPath,
          readOnly ? @"read-only" : @"read-write");
    return 0;
}

- (void)installPathTranslateHandler:(NSString * _Nullable (^)(NSString *, uint64_t))handler {
    g_forwardTranslateHandler = handler;
    if (handler) {
        fakefs_set_path_translate_hook(ish_forward_translate_trampoline);
    } else {
        fakefs_set_path_translate_hook(NULL);
    }
}

- (void)installPathReverseHandler:(NSString * _Nullable (^)(NSString *))handler {
    g_reverseTranslateHandler = handler;
    if (handler) {
        fakefs_set_path_reverse_hook(ish_reverse_translate_trampoline);
    } else {
        fakefs_set_path_reverse_hook(NULL);
    }
}

// --- Background CPU governor (stage 2.5, ISHResourceGovernor) ------------

- (void)beginBackgroundCPUGovernor {
    [[ISHResourceGovernor shared] beginBackgroundCPUGovernor];
}

- (void)endBackgroundCPUGovernor {
    [[ISHResourceGovernor shared] endBackgroundCPUGovernor];
}

// --- Resource governor status ----------------------------------------------

- (NSDictionary<NSString *, id> *)resourceGovernorStatus {
    return [[ISHResourceGovernor shared] statusSnapshot];
}

@end
