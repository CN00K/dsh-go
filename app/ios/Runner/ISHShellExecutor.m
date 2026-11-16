//  ISHShellExecutor.m
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1).
//
//  One-shot guest execution over host pipes (design §1.7). The DSH
//  agent path: short-lived guest processes, stdout/stderr captured.
//  Ported concepts from ISHKernel (become_new_init_child, do_execve,
//  task_start, [FIX 1.4a-rev] zombie-marking); the pipe wiring is new.
//
//  PIPE OWNERSHIP (read this before touching the close() calls — a
//  double-close here silently closes an unrelated fd that reused the
//  number, and a missed close blocks a reader forever):
//  - stdinPipe[1] (host write end): owned by the stdin writer block,
//    which closes it when the data is written (or on EPIPE / cancel).
//  - stdoutPipe[0] / stderrPipe[0] (host read ends): owned by their
//    reader blocks, which close them on EOF / error.
//  - stdinPipe[0] / stdoutPipe[1] / stderrPipe[1] (guest ends): owned
//    by the GUEST via real_fd. On a successful start they are closed by
//    the guest's fdtable release on exit (realfs_close closes real_fd),
//    which delivers EOF to the host readers. On a FAILED start the
//    start block closes them by hand (closeGuestPipeEnds) — a zombie's
//    fdtable is never released, so nothing else would close them and
//    the readers would block forever.
//  - If pipe() itself fails, no reader/writer exists yet, so the start
//    block owns all six fds and closes them directly.
//  NEVER close a host end from the start block after the reader/writer
//  has been dispatched; NEVER close a guest end after a successful
//  task_start.
//
//  FINALIZATION: the result is built when BOTH the exit notification
//  (ISHGuestExitedNotification, via ISHKernel's exit_hook) AND pipe EOF
//  have arrived. A timeout / cancel kills the group and finalizes with
//  -3 / -4 after a 500 ms grace period for the output tail; if the
//  normal path finalizes first inside that window, the sentinel still
//  wins (timedOut / cancelled flag overrides the decoded code).
//  NEVER call do_exit() here (stage 1 build 14 crash — see ISHKernel.m).

#import "ISHShellExecutor.h"
#import "ISHKernel.h"

#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fd.h"
#include "ish/fs/real.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/errno.h"
#include "ish/util/sync.h"
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <dispatch/dispatch.h>

static const NSTimeInterval kISHExecDefaultTimeout = 30.0;
static const NSTimeInterval kISHExecKillGrace = 0.5;      // 500 ms output tail
static const NSTimeInterval kISHExecSweeperInterval = 30.0;
static const NSTimeInterval kISHExecStuckThreshold = 30.0;
static const size_t kISHExecArgvCapacity = 16384;
static const size_t kISHExecEnvpCapacity = 8192;

// --- ISHShellExecutionResult -------------------------------------------------

@interface ISHShellExecutionResult ()
- (instancetype)initWithExitCode:(int)exitCode
                      stdoutData:(NSData *)stdoutData
                      stderrData:(NSData *)stderrData
                        duration:(NSTimeInterval)duration
                        timedOut:(BOOL)timedOut
                       cancelled:(BOOL)cancelled
                             pid:(int)pid;
@end

@implementation ISHShellExecutionResult

- (instancetype)initWithExitCode:(int)exitCode
                      stdoutData:(NSData *)stdoutData
                      stderrData:(NSData *)stderrData
                        duration:(NSTimeInterval)duration
                        timedOut:(BOOL)timedOut
                       cancelled:(BOOL)cancelled
                             pid:(int)pid {
    self = [super init];
    if (self) {
        _exitCode = exitCode;
        _stdoutData = stdoutData ?: [NSData data];
        _stderrData = stderrData ?: [NSData data];
        _duration = duration;
        _timedOut = timedOut;
        _cancelled = cancelled;
        _pid = pid;
    }
    return self;
}

@end

// --- Private record ----------------------------------------------------------

@interface ISHExecRecord : NSObject
@property (nonatomic, strong) NSString *token;
@property (nonatomic, copy, nullable) void (^completion)(ISHShellExecutionResult *result);
/// Streaming output sink (stage 2.4 loopback /ish/exec). Invoked on an
/// arbitrary queue with (isStderr, chunk) as each pipe read returns;
/// chunks are raw bytes in arrival order per stream. Nil = non-streaming
/// (output only visible in the final result). Set once at start; never
/// changed afterwards, so no lock is needed to read it.
@property (nonatomic, copy, nullable) void (^outputHandler)(BOOL isStderr, NSData *chunk);
@property (nonatomic, strong) NSMutableData *stdoutData;
@property (nonatomic, strong) NSMutableData *stderrData;
@property (nonatomic, strong) NSLock *outputLock;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic) NSTimeInterval timeout;
/// Guest pid, 0 until the task has started. Single aligned-word
/// read/write; a stale read just looks like "not started yet".
@property (nonatomic) int pid;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL timedOut;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL pipesDone;
/// YES for a PTY execution (no pipes: pipesDone is set at start and
/// completion waits only for the exit notification + the final
/// session-buffer drain in finishRecord).
@property (nonatomic) BOOL isTty;
/// ISHKernel PTY session id for a PTY execution (nil for pipe runs).
@property (nonatomic, strong, nullable) NSString *ptySessionId;
/// Wait-encoded exit status from ISHGuestExitedNotification, nil until
/// the guest exits.
@property (nonatomic, strong, nullable) NSNumber *exitCode;
@property (nonatomic) dispatch_group_t pipeGroup;
@end

@implementation ISHExecRecord

- (instancetype)init {
    self = [super init];
    if (self) {
        _token = [[NSUUID UUID] UUIDString];
        _stdoutData = [NSMutableData data];
        _stderrData = [NSMutableData data];
        _outputLock = [[NSLock alloc] init];
        _startTime = [NSDate date];
        _pipeGroup = dispatch_group_create();
    }
    return self;
}

@end

// Forward declaration: ISHShellExecution.cancel (below) calls this, but
// the full private interface (class extension) is declared further down.
// Without it ARC rejects the call: no visible @interface declares it.
@interface ISHShellExecutor (CancelForward)
- (void)cancelRecord:(ISHExecRecord *)record;
@end

// --- ISHShellExecution (handle) ----------------------------------------------

@interface ISHShellExecution ()
@property (nonatomic, strong) ISHExecRecord *record;
- (instancetype)initWithRecord:(ISHExecRecord *)record;
@end

@implementation ISHShellExecution

- (instancetype)initWithRecord:(ISHExecRecord *)record {
    self = [super init];
    if (self) _record = record;
    return self;
}

- (int)pid { return _record.pid; }
- (BOOL)finished { return _record.finished; }

- (void)cancel {
    [[ISHShellExecutor shared] cancelRecord:_record];
}

@end

// --- adhoc fd from a host fd -------------------------------------------------
// Replicates kernel/init.c open_fd_from_actual_fd (static there, so it
// cannot be called). Same logic verbatim: adhoc fd + real_fd + fstat
// population. The stat matters: Node.js/libuv fstats stdout/stderr to
// decide TTY vs pipe vs file, and all-zero stat makes console.log
// silently fail. Sockets / TTYs are reported as S_IFCHR (what Linux
// shows for TTY fds) so libuv's uv_guess_handle() falls back to a
// generic stream instead of failing.
static struct fd *ish_executor_fd_from_host_fd(int host_fd) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd == NULL) return NULL;
    fd->real_fd = host_fd;
    fd->dir = NULL;
    struct stat real_stat;
    if (fstat(host_fd, &real_stat) == 0) {
        fd->stat.mode = real_stat.st_mode;
        fd->stat.rdev = dev_fake_from_real(real_stat.st_rdev);
        fd->stat.inode = real_stat.st_ino;
        fd->stat.size = real_stat.st_size;
        if (S_ISSOCK(fd->stat.mode) || isatty(host_fd)) {
            fd->stat.mode = S_IFCHR | 0620;
            fd->stat.rdev = dev_make(TTY_PSEUDO_SLAVE_MAJOR, 0);
        }
    }
    return fd;
}

static void ish_executor_close_fd(int fd) {
    if (fd >= 0) close(fd);
}

// --- Executor ----------------------------------------------------------------

@interface ISHShellExecutor ()
@property (nonatomic, strong) dispatch_queue_t stateQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ISHExecRecord *> *executions;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *executionsByPid;

// Private methods (defined below; declared here so the handle class and
// the early methods can call them without a warning).
- (ISHShellExecution *)startExecutionWithArgv:(NSArray<NSString *> *)argv
                                    stdinData:(nullable NSData *)stdinData
                                    fsContext:(uint64_t)fsContext
                                      timeout:(NSTimeInterval)timeout
                                outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                                   completion:(void (^)(ISHShellExecutionResult *result))completion;
- (ISHShellExecution *)startExecutionWithArgv:(NSArray<NSString *> *)argv
                                    stdinData:(nullable NSData *)stdinData
                                    fsContext:(uint64_t)fsContext
                                      timeout:(NSTimeInterval)timeout
                                         isTty:(BOOL)isTty
                                          cols:(int)cols
                                          rows:(int)rows
                                outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                                   completion:(void (^)(ISHShellExecutionResult *result))completion;
- (void)runRecord:(ISHExecRecord *)record
             argv:(NSArray<NSString *> *)argv
        stdinData:(nullable NSData *)stdinData
        fsContext:(uint64_t)fsContext;
- (void)runTtyRecord:(ISHExecRecord *)record
                argv:(NSArray<NSString *> *)argv
           stdinData:(nullable NSData *)stdinData
           fsContext:(uint64_t)fsContext
                cols:(int)cols
                rows:(int)rows;
- (void)feedTtyStdin:(nullable NSData *)data
           sessionId:(NSString *)sessionId;
- (void)drainTtyTailForRecord:(ISHExecRecord *)record;
- (void)readPipeFd:(int)fd into:(NSMutableData *)buffer lock:(NSLock *)lock
            record:(ISHExecRecord *)record isStderr:(BOOL)isStderr;
- (void)writeStdinData:(nullable NSData *)data
                  toFd:(int)fd
                record:(ISHExecRecord *)record;
- (void)closeGuestPipeEnds:(int[2])stdinPipe
                stdoutPipe:(int[2])stdoutPipe
                stderrPipe:(int[2])stderrPipe;
- (ISHShellExecutionResult *)buildResultForRecord:(ISHExecRecord *)record
                                        exitCode:(int)exitCode;
- (void)finishRecord:(ISHExecRecord *)record withExitCode:(int)exitCode;
- (void)tryFinalizeRecord:(ISHExecRecord *)record;
- (void)forceFinalizeRecord:(ISHExecRecord *)record
               withExitCode:(int)exitCode;
- (void)failRecord:(ISHExecRecord *)record withCode:(int)code;
- (void)timeoutRecord:(ISHExecRecord *)record;
- (void)cancelRecord:(ISHExecRecord *)record;
- (void)cancelRecordOnStateQueue:(ISHExecRecord *)record;
- (void)sweepStuckExecutions;
@end

@implementation ISHShellExecutor {
    id _exitObserver;
    dispatch_source_t _sweeper;
}

+ (instancetype)shared {
    static ISHShellExecutor *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[ISHShellExecutor alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("me.zzuu.dsh.ish.executor",
                                            DISPATCH_QUEUE_SERIAL);
        _executions = [NSMutableDictionary dictionary];
        _executionsByPid = [NSMutableDictionary dictionary];
        // Host pipe writes must never kill the app with SIGPIPE: a guest
        // that closes stdin early makes write() raise it. Dart/Flutter
        // already ignore SIGPIPE; set it explicitly so the executor is
        // safe regardless of engine startup order. The guest's SIGPIPE
        // is emulated inside iSH and unaffected.
        signal(SIGPIPE, SIG_IGN);
        // Observe guest exits (posted by ISHKernel's exit_hook on the
        // main queue) and route them to the state queue. Only executor
        // children have a pid entry; PTY shells are ignored.
        __weak ISHShellExecutor *weakSelf = self;
        _exitObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:ISHGuestExitedNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            ISHShellExecutor *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSNumber *pid = note.userInfo[@"pid"];
            NSNumber *code = note.userInfo[@"code"];
            if (!pid || !code) return;
            dispatch_async(strongSelf.stateQueue, ^{
                NSString *token = strongSelf.executionsByPid[pid];
                if (!token) return;
                ISHExecRecord *record = strongSelf.executions[token];
                if (!record || record.finished) return;
                record.exitCode = code;
                [strongSelf tryFinalizeRecord:record];
            });
        }];
        // Sweeper: every 30 s, log executions live longer than 30 s.
        // The executor is a singleton, so the self-retaining timer is
        // never a leak in practice.
        _sweeper = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          _stateQueue);
        dispatch_source_set_timer(_sweeper,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kISHExecSweeperInterval * NSEC_PER_SEC)),
            (uint64_t)(kISHExecSweeperInterval * NSEC_PER_SEC),
            (uint64_t)(1 * NSEC_PER_SEC));
        __weak ISHShellExecutor *weakSweeperSelf = self;
        dispatch_source_set_event_handler(_sweeper, ^{
            [weakSweeperSelf sweepStuckExecutions];
        });
        dispatch_resume(_sweeper);
    }
    return self;
}

// --- Public API ---------------------------------------------------------------

- (ISHShellExecution *)executeExecutable:(NSString *)executable
                               arguments:(NSArray<NSString *> *)arguments
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                              completion:(void (^)(ISHShellExecutionResult *result))completion {
    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:executable];
    if (arguments) [argv addObjectsFromArray:arguments];
    return [self startExecutionWithArgv:argv
                              stdinData:stdinData
                              fsContext:fsContext
                                timeout:timeout
                          outputHandler:nil
                             completion:completion];
}

- (ISHShellExecution *)executeCommand:(NSString *)command
                            stdinData:(nullable NSData *)stdinData
                            fsContext:(uint64_t)fsContext
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(ISHShellExecutionResult *result))completion {
    return [self executeCommand:command stdinData:stdinData fsContext:fsContext
                        timeout:timeout outputHandler:nil completion:completion];
}

/// Streaming variant (stage 2.4 loopback /ish/exec): stdout/stderr
/// chunks are delivered to `outputHandler` as they arrive (arbitrary
/// queue, raw bytes, per-stream arrival order). The completion still
/// fires at the end with the full result.
///
/// ENV-01: the exec shell is /bin/bash (the guest ships bash 5.2.37;
/// /bin/sh is BusyBox ash, whose missing bash syntax broke commands
/// the bash tool advertises as "bash -c"). This is the ONLY place the
/// exec shell is chosen: the loopback service passes a ready-made
/// command string, and the PTY path uses ISHKernel.executeCommand
/// (not this method), so this change cannot affect interactive
/// terminals.
- (ISHShellExecution *)executeCommand:(NSString *)command
                            stdinData:(nullable NSData *)stdinData
                            fsContext:(uint64_t)fsContext
                              timeout:(NSTimeInterval)timeout
                        outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                           completion:(void (^)(ISHShellExecutionResult *result))completion {
    return [self startExecutionWithArgv:@[@"/bin/bash", @"-c", command ?: @""]
                              stdinData:stdinData
                              fsContext:fsContext
                                timeout:timeout
                          outputHandler:outputHandler
                             completion:completion];
}

/// PTY variant (stage 5.3, ENV-02). Same one-shot shape as
/// executeCommand: but the command runs on a fresh fake PTY (see the
/// header). Output is merged (isStderr is always NO); the result's
/// stderrData is empty. Shell is /bin/bash, same ENV-01 rule as the
/// pipe exec: the command string is built for bash, and /bin/sh is
/// BusyBox ash.
- (ISHShellExecution *)executeCommandTty:(NSString *)command
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                                    cols:(int)cols
                                    rows:(int)rows
                           outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                              completion:(void (^)(ISHShellExecutionResult *result))completion {
    return [self startExecutionWithArgv:@[@"/bin/bash", @"-c", command ?: @""]
                              stdinData:stdinData
                              fsContext:fsContext
                                timeout:timeout
                                  isTty:YES
                                   cols:cols
                                   rows:rows
                          outputHandler:outputHandler
                             completion:completion];
}

- (ISHShellExecution *)executeCommandTty:(NSString *)command
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                                    cols:(int)cols
                                    rows:(int)rows
                              completion:(void (^)(ISHShellExecutionResult *result))completion {
    return [self executeCommandTty:command stdinData:stdinData fsContext:fsContext
                           timeout:timeout cols:cols rows:rows
                     outputHandler:nil completion:completion];
}

- (ISHShellExecution *)startExecutionWithArgv:(NSArray<NSString *> *)argv
                                    stdinData:(nullable NSData *)stdinData
                                    fsContext:(uint64_t)fsContext
                                      timeout:(NSTimeInterval)timeout
                                outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                                   completion:(void (^)(ISHShellExecutionResult *result))completion {
    return [self startExecutionWithArgv:argv stdinData:stdinData fsContext:fsContext
                                timeout:timeout isTty:NO cols:0 rows:0
                          outputHandler:outputHandler completion:completion];
}

- (ISHShellExecution *)startExecutionWithArgv:(NSArray<NSString *> *)argv
                                    stdinData:(nullable NSData *)stdinData
                                    fsContext:(uint64_t)fsContext
                                      timeout:(NSTimeInterval)timeout
                                         isTty:(BOOL)isTty
                                          cols:(int)cols
                                          rows:(int)rows
                                outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                                   completion:(void (^)(ISHShellExecutionResult *result))completion {
    ISHExecRecord *record = [[ISHExecRecord alloc] init];
    record.completion = completion;
    record.outputHandler = outputHandler;
    record.timeout = (timeout > 0 ? timeout : kISHExecDefaultTimeout);
    record.isTty = isTty;
    if (isTty) {
        // No pipes to wait for: the only completion gate is the exit
        // notification (plus the final session-buffer drain in
        // finishRecord). The PTY session id is the kernel routing key.
        record.pipesDone = YES;
        record.ptySessionId = [[NSUUID UUID] UUIDString];
    }
    ISHShellExecution *handle = [[ISHShellExecution alloc] initWithRecord:record];
    // Register synchronously so the handle is usable immediately.
    dispatch_sync(_stateQueue, ^{
        self.executions[record.token] = record;
    });
    if (![ISHKernel shared].isBooted) {
        // No guest can start (become_new_init_child asserts pid 1
        // exists); complete immediately with -1.
        dispatch_async(_stateQueue, ^{
            [self finishRecord:record
                  withExitCode:ISHShellExecutionErrorCreationFailed];
        });
        return handle;
    }
    if (isTty) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [self runTtyRecord:record argv:argv stdinData:stdinData
                     fsContext:fsContext cols:cols rows:rows];
        });
        return handle;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self runRecord:record argv:argv stdinData:stdinData fsContext:fsContext];
    });
    return handle;
}

// --- PTY start path (stage 5.3, ENV-02; runs on a global-queue thread) -----

- (void)runTtyRecord:(ISHExecRecord *)record
                argv:(NSArray<NSString *> *)argv
           stdinData:(nullable NSData *)stdinData
           fsContext:(uint64_t)fsContext
                cols:(int)cols
                rows:(int)rows {
    // Cancelled before we even started? (cancel / cancelAll raced us.)
    if (record.cancelled) {
        [self failRecord:record withCode:ISHShellExecutionErrorCancelled];
        return;
    }
    // Register the kernel session handler FIRST, so no output can be
    // missed. Output can only start after task_start, which runs after
    // executeCommand returns — but registering first costs nothing.
    // The handler appends to stdoutData UNCONDITIONALLY (under the
    // record lock) and only gates the STREAMING forward on finished:
    // finishRecord snapshots stdoutData, so an append that lands after
    // the snapshot would otherwise be lost from the result even
    // though the kernel buffer already gave it up. (Same shape as the
    // pipe readers: append first, stream second.)
    void (^handler)(NSData *) = ^(NSData *chunk) {
        [record.outputLock lock];
        [record.stdoutData appendData:chunk];
        [record.outputLock unlock];
        if (record.finished) return;
        void (^outHandler)(BOOL, NSData *) = record.outputHandler;
        if (outHandler) outHandler(NO, chunk);
    };
    [[ISHKernel shared] setPtyOutputHandler:handler forSession:record.ptySessionId];
    int guestPid = 0;
    int rc = [[ISHKernel shared] executeCommand:argv pid:&guestPid
                                       sessionId:record.ptySessionId
                                       fsContext:fsContext
                                            cols:cols rows:rows];
    if (rc != 0 || guestPid <= 0) {
        NSLog(@"ISHShellExecutor: tty exec start failed (rc=%d)", rc);
        [[ISHKernel shared] setPtyOutputHandler:nil forSession:record.ptySessionId];
        if (rc != -3) {
            // Release the registry slot. (-3 = the spawn block is
            // still stuck after 10 s; the record stays registered so
            // a late success still routes, and stopGuest purges it.)
            [[ISHKernel shared] closePtySession:record.ptySessionId];
        } else {
            NSLog(@"ISHShellExecutor: tty exec start timed out; session %@ stays registered until stopGuest",
                  record.ptySessionId);
        }
        [self failRecord:record withCode:ISHShellExecutionErrorCreationFailed];
        return;
    }
    // Cancelled while exec was running? Do not start a task we were
    // asked to kill (same check as runRecord, after do_execve).
    if (record.cancelled) {
        [[ISHKernel shared] closePtySession:record.ptySessionId];
        [self failRecord:record withCode:ISHShellExecutionErrorCancelled];
        return;
    }
    // Stdin: feed in <= 2 KiB chunks (paced), then EOT (0x04) so the
    // guest sees EOF — the same end-of-input semantics as the pipe
    // path closing stdin. See feedTtyStdin:sessionId: for why chunks.
    [self feedTtyStdin:stdinData sessionId:record.ptySessionId];
    // Record the pid + start the timeout, serialized on the state queue
    // with any concurrent cancel. (Same block as runRecord.)
    dispatch_async(_stateQueue, ^{
        record.pid = guestPid;
        self.executionsByPid[@(guestPid)] = record.token;
        if (record.cancelled) {
            [self killProcessGroup:guestPid];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(kISHExecKillGrace * NSEC_PER_SEC)),
                self.stateQueue, ^{
                [self forceFinalizeRecord:record
                             withExitCode:ISHShellExecutionErrorCancelled];
            });
            return;
        }
        // FAST-EXIT GUARD (tty only): executeCommand hides task_start,
        // so — unlike runRecord, which enqueues this block BEFORE
        // task_start — the guest can exit before this block runs, and
        // the exit observer drops notifications for pids it cannot
        // map yet. Re-read the recorded exit code via an ASYNC hop to
        // the main queue (exitCodeForGuestPid does dispatch_sync to
        // main when called off-main — never call it directly from
        // this queue: a main-thread caller blocked in dispatch_sync
        // on _stateQueue would deadlock). If the guest already
        // exited, finalize through the normal path. (If the
        // observer's dispatch lands first instead, this is a no-op:
        // tryFinalizeRecord returns early once finished.)
        __weak ISHShellExecutor *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNumber *earlyExit = [[ISHKernel shared] exitCodeForGuestPid:guestPid];
            if (!earlyExit) return;
            ISHShellExecutor *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.stateQueue, ^{
                if (record.finished) return;
                record.exitCode = earlyExit;
                [strongSelf tryFinalizeRecord:record];
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(record.timeout * NSEC_PER_SEC)),
            self.stateQueue, ^{
            [self timeoutRecord:record];
        });
    });
    NSLog(@"ISHShellExecutor: started tty guest process PID %d (%s)",
          guestPid, argv[0].UTF8String);
}

/// Feed stdin to a PTY session in <= 2 KiB chunks, 20 ms apart, then
/// an EOT byte (0x04). The tty input buffer is 4 KiB and a
/// non-blocking tty_input drops what does not fit, so one bulk write
/// would silently truncate large stdin; pacing lets the guest drain
/// between chunks. A nil/empty stdin still gets the EOT (an
/// interactive command with no stdin must see EOF, e.g. a bare
/// `python3` REPL must exit instead of blocking until timeout).
/// Chunks go through the kernel's serial input queue, so order is
/// preserved. Each send is best-effort: if the session closed or the
/// guest exited mid-feed, later chunks are dropped by the kernel.
- (void)feedTtyStdin:(nullable NSData *)data
           sessionId:(NSString *)sessionId {
    static const NSUInteger kISHExecTtyStdinChunk = 2048;
    static const NSTimeInterval kISHExecTtyStdinPace = 0.02; // 20 ms
    NSUInteger total = data.length;
    NSUInteger chunks = (total + kISHExecTtyStdinChunk - 1) / kISHExecTtyStdinChunk;
    for (NSUInteger i = 0; i < chunks; i++) {
        NSUInteger offset = i * kISHExecTtyStdinChunk;
        NSUInteger len = MIN(kISHExecTtyStdinChunk, total - offset);
        NSData *chunk = [data subdataWithRange:NSMakeRange(offset, len)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)((i * kISHExecTtyStdinPace) * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [[ISHKernel shared] sendInput:chunk sessionId:sessionId];
        });
    }
    const uint8_t eot = 0x04;
    NSData *eotData = [NSData dataWithBytes:&eot length:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((chunks * kISHExecTtyStdinPace) * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [[ISHKernel shared] sendInput:eotData sessionId:sessionId];
    });
}

/// Final tail-drain for a PTY execution: pull any bytes still sitting
/// in the session buffer (not yet dispatched) into stdoutData and
/// stream them, BEFORE finishRecord snapshots the result. Called from
/// finishRecord (single completion point) while `finished` is still
/// NO, so the streaming forward always lands. The kernel session is
/// closed by finishRecord right after (see below).
- (void)drainTtyTailForRecord:(ISHExecRecord *)record {
    if (!record.ptySessionId) return;
    NSData *tail = [[ISHKernel shared] drainOutputForSession:record.ptySessionId];
    if (tail.length == 0) return;
    [record.outputLock lock];
    [record.stdoutData appendData:tail];
    [record.outputLock unlock];
    void (^outHandler)(BOOL, NSData *) = record.outputHandler;
    if (outHandler) outHandler(NO, tail);
}

// --- Start path (runs on a global-queue thread) -------------------------------

- (void)runRecord:(ISHExecRecord *)record
             argv:(NSArray<NSString *> *)argv
        stdinData:(nullable NSData *)stdinData
        fsContext:(uint64_t)fsContext {
    int stdinPipe[2] = {-1, -1};
    int stdoutPipe[2] = {-1, -1};
    int stderrPipe[2] = {-1, -1};
    if (pipe(stdinPipe) != 0 || pipe(stdoutPipe) != 0 ||
        pipe(stderrPipe) != 0) {
        NSLog(@"ISHShellExecutor: pipe() failed: %d", errno);
        ish_executor_close_fd(stdinPipe[0]);
        ish_executor_close_fd(stdinPipe[1]);
        ish_executor_close_fd(stdoutPipe[0]);
        ish_executor_close_fd(stdoutPipe[1]);
        ish_executor_close_fd(stderrPipe[0]);
        ish_executor_close_fd(stderrPipe[1]);
        [self failRecord:record withCode:ISHShellExecutionErrorCreationFailed];
        return;
    }
    // Blocks cannot capture C arrays: copy the fds they own into scalars.
    int stdoutReadFd = stdoutPipe[0];
    int stderrReadFd = stderrPipe[0];
    int stdinWriteFd = stdinPipe[1];
    // Readers: start BEFORE task_start so no output is missed.
    dispatch_group_enter(record.pipeGroup);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self readPipeFd:stdoutReadFd into:record.stdoutData
                    lock:record.outputLock record:record isStderr:NO];
        close(stdoutReadFd);
        dispatch_group_leave(record.pipeGroup);
    });
    dispatch_group_enter(record.pipeGroup);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self readPipeFd:stderrReadFd into:record.stderrData
                    lock:record.outputLock record:record isStderr:YES];
        close(stderrReadFd);
        dispatch_group_leave(record.pipeGroup);
    });
    // Pipes-done gate: when both readers hit EOF, mark pipesDone and try.
    dispatch_group_notify(record.pipeGroup, _stateQueue, ^{
        record.pipesDone = YES;
        [self tryFinalizeRecord:record];
    });
    // Stdin writer: feed stdinData, then close (EOF). Owns stdinPipe[1].
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self writeStdinData:stdinData toFd:stdinWriteFd record:record];
        close(stdinWriteFd);
    });
    // Cancelled before we even started? (cancel / cancelAll raced us.)
    if (record.cancelled) {
        [self closeGuestPipeEnds:stdinPipe stdoutPipe:stdoutPipe
                      stderrPipe:stderrPipe];
        [self failRecord:record withCode:ISHShellExecutionErrorCancelled];
        return;
    }
    // Spawn as a child of init (pid >= 2). Never on the supervisor
    // thread, never as pid 1. The child gets a FRESH fdtable
    // (fdtable_new(3) via construct_task) — files[0/1/2] start empty.
    int err = become_new_init_child();
    if (err < 0) {
        NSLog(@"ISHShellExecutor: become_new_init_child failed: %d", err);
        [self closeGuestPipeEnds:stdinPipe stdoutPipe:stdoutPipe
                      stderrPipe:stderrPipe];
        [self failRecord:record withCode:ISHShellExecutionErrorCreationFailed];
        return;
    }
    // fs_context for the path-translate hook (inherited verbatim on fork).
    current->group->fs_context = fsContext;
    // Wire stdio: adhoc fds over the (dup'd) host pipe fds.
    struct fd *inFd = ish_executor_fd_from_host_fd(stdinPipe[0]);
    struct fd *outFd = ish_executor_fd_from_host_fd(stdoutPipe[1]);
    struct fd *errFd = ish_executor_fd_from_host_fd(stderrPipe[1]);
    if (!inFd || !outFd || !errFd) {
        NSLog(@"ISHShellExecutor: adhoc fd creation failed");
        [self closeGuestPipeEnds:stdinPipe stdoutPipe:stdoutPipe
                      stderrPipe:stderrPipe];
        // The task was created but never exec'd: zombie-mark it (same
        // [FIX 1.4a-rev] as ISHKernel) so it does not leak as a live
        // task. The successfully-created adhoc fds are not in any
        // fdtable and are never used; their structs leak (bounded,
        // one per failed start).
        lock(&pids_lock);
        current->exiting = true;
        current->zombie = true;
        unlock(&pids_lock);
        [self failRecord:record withCode:ISHShellExecutionErrorCreationFailed];
        return;
    }
    current->files->files[0] = inFd;
    current->files->files[1] = outFd;
    current->files->files[2] = errFd;
    // argv (16 KB) + envp (8 KB), same packing as ISHKernel.
    char argvBuf[kISHExecArgvCapacity];
    size_t argvPos = 0;
    size_t argc = 0;
    for (NSString *arg in argv) {
        const char *carg = arg.UTF8String;
        size_t len = strlen(carg) + 1;
        if (argvPos + len >= sizeof(argvBuf)) break;
        memcpy(argvBuf + argvPos, carg, len);
        argvPos += len;
        argc++;
    }
    argvBuf[argvPos] = '\0';
    char envpBuf[kISHExecEnvpCapacity];
    size_t envpPos = 0;
#define EXEC_ENVP_APPEND(s) do { \
        const char *_s = (s); \
        size_t _len = strlen(_s) + 1; \
        if (envpPos + _len < sizeof(envpBuf) - 256) { \
            memcpy(envpBuf + envpPos, _s, _len); \
            envpPos += _len; \
        } \
    } while (0)
    // ENV-12: no TERM here. An exec has no tty (pipes only); faking
    // TERM=xterm-256color made non-tty tools believe a terminal was
    // present. TERM is set only when a pty is present: the PTY path
    // sets it in ISHKernel.executeCommand, and the bridge forwards it
    // only when the exec is pty-backed (guestEnv opts.hasPty).
    EXEC_ENVP_APPEND("HOME=/root");
    EXEC_ENVP_APPEND("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    EXEC_ENVP_APPEND("LANG=C.UTF-8");
    EXEC_ENVP_APPEND("ENV=/etc/profile");
    // Shared custom environment (set once by the channel layer on
    // ISHKernel.customEnvironment). Never contains secrets.
    for (NSString *key in [ISHKernel shared].customEnvironment) {
        NSString *value = [ISHKernel shared].customEnvironment[key];
        if (![key isKindOfClass:[NSString class]] ||
            ![value isKindOfClass:[NSString class]]) continue;
        NSString *pair = [NSString stringWithFormat:@"%@=%@", key, value];
        EXEC_ENVP_APPEND(pair.UTF8String);
    }
#undef EXEC_ENVP_APPEND
    envpBuf[envpPos] = '\0';
    const char *execPath = argv[0].UTF8String;
    err = do_execve(execPath, argc, argvBuf, envpBuf);
    if (err < 0) {
        NSLog(@"ISHShellExecutor: do_execve(%s) failed: %d", execPath, err);
        [self closeGuestPipeEnds:stdinPipe stdoutPipe:stdoutPipe
                      stderrPipe:stderrPipe];
        // [FIX 1.4a-rev] Never do_exit() on a GCD thread (stage 1 build
        // 14 crash). Mark the child a zombie directly.
        lock(&pids_lock);
        current->exiting = true;
        current->zombie = true;
        unlock(&pids_lock);
        [self failRecord:record withCode:ISHShellExecutionErrorExecFailed];
        return;
    }
    // Cancelled while exec was running? Do not start a task we were
    // asked to kill.
    if (record.cancelled) {
        lock(&pids_lock);
        current->exiting = true;
        current->zombie = true;
        unlock(&pids_lock);
        [self closeGuestPipeEnds:stdinPipe stdoutPipe:stdoutPipe
                      stderrPipe:stderrPipe];
        [self failRecord:record withCode:ISHShellExecutionErrorCancelled];
        return;
    }
    int guestPid = current->pid;
    // Record the pid + start the timeout, serialized on the state queue
    // with any concurrent cancel. If a cancel already landed (pid was 0
    // when it ran, so it could not kill), kill now.
    dispatch_async(_stateQueue, ^{
        record.pid = guestPid;
        self.executionsByPid[@(guestPid)] = record.token;
        if (record.cancelled) {
            [self killProcessGroup:guestPid];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(kISHExecKillGrace * NSEC_PER_SEC)),
                self.stateQueue, ^{
                [self forceFinalizeRecord:record
                             withExitCode:ISHShellExecutionErrorCancelled];
            });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(record.timeout * NSEC_PER_SEC)),
            self.stateQueue, ^{
            [self timeoutRecord:record];
        });
    });
    NSLog(@"ISHShellExecutor: started guest process PID %d (%s)",
          guestPid, execPath);
    // Runs the emulator loop on a REAL pthread spawned by task_start
    // (pthread_create) — that is the thread do_exit's pthread_exit runs
    // on when the guest exits, which is why normal exits are safe.
    task_start(current);
}

// --- Pipe helpers ------------------------------------------------------------

// Close only the GUEST ends (see the ownership comment at the top).
// Called on a FAILED start, when the guest never took ownership.
- (void)closeGuestPipeEnds:(int[2])stdinPipe
                stdoutPipe:(int[2])stdoutPipe
                stderrPipe:(int[2])stderrPipe {
    ish_executor_close_fd(stdinPipe[0]);
    ish_executor_close_fd(stdoutPipe[1]);
    ish_executor_close_fd(stderrPipe[1]);
}

// Blocking read loop: appends to `buffer` under `lock` until EOF (all
// write ends closed) or a non-EINTR error. Runs on a global-queue
// thread; the caller closes `fd` when this returns.
- (void)readPipeFd:(int)fd into:(NSMutableData *)buffer lock:(NSLock *)lock
            record:(ISHExecRecord *)record isStderr:(BOOL)isStderr {
    uint8_t chunk[8192];
    for (;;) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n > 0) {
            NSData *data = [NSData dataWithBytes:chunk length:(NSUInteger)n];
            [lock lock];
            [buffer appendBytes:chunk length:(NSUInteger)n];
            [lock unlock];
            // Stream the chunk out (stage 2.4). Called AFTER releasing
            // the lock: the handler may call back into the executor and
            // must never deadlock on outputLock. The handler is set once
            // at start and never changed, so no lock is needed to read it.
            void (^handler)(BOOL, NSData *) = record.outputHandler;
            if (handler) handler(isStderr, data);
        } else if (n == 0) {
            break; // EOF
        } else {
            if (errno == EINTR) continue;
            break; // e.g. EBADF — treat as EOF
        }
    }
}

// Feed stdinData into `fd`, then the caller closes it (EOF for the
// guest). Stops early on EPIPE (guest closed stdin), on cancel /
// finish, or on any other write error. SIGPIPE is ignored process-wide
// (see -init), so a broken pipe returns EPIPE instead of killing us.
- (void)writeStdinData:(nullable NSData *)data
                  toFd:(int)fd
                record:(ISHExecRecord *)record {
    if (!data || data.length == 0) return;
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    size_t offset = 0;
    while (remaining > 0) {
        if (record.finished || record.cancelled) break;
        ssize_t n = write(fd, bytes + offset, remaining);
        if (n > 0) {
            offset += (size_t)n;
            remaining -= (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

// --- Finalization (all on _stateQueue unless noted) --------------------------

// Build the immutable result from the record + an already-decoded exit
// code. Snapshots the output buffers under the record lock.
- (ISHShellExecutionResult *)buildResultForRecord:(ISHExecRecord *)record
                                        exitCode:(int)exitCode {
    NSData *outData;
    NSData *errData;
    [record.outputLock lock];
    outData = [record.stdoutData copy];
    errData = [record.stderrData copy];
    [record.outputLock unlock];
    NSTimeInterval duration =
        [[NSDate date] timeIntervalSinceDate:record.startTime];
    return [[ISHShellExecutionResult alloc]
        initWithExitCode:exitCode
              stdoutData:outData
              stderrData:errData
                duration:duration
                timedOut:record.timedOut
               cancelled:record.cancelled
                     pid:record.pid];
}

// The single completion point. No-op if already finished. Removes the
// record from both indexes and invokes the completion OFF the state
// queue (it may call back into the executor, e.g. to start the next
// command). For a PTY execution the session-buffer tail is drained
// BEFORE `finished` is set (so the streaming forward lands) and the
// kernel session is closed AFTER the result is built (kills the
// group — a no-op when the guest already exited — removes the
// handler, frees the registry slot). The close must happen here, in
// the single completion point, not in tryFinalize: a timeout / cancel
// that finalizes via forceFinalizeRecord must free the slot too.
- (void)finishRecord:(ISHExecRecord *)record withExitCode:(int)exitCode {
    if (record.finished) return;
    if (record.isTty) [self drainTtyTailForRecord:record];
    record.finished = YES;
    [self.executions removeObjectForKey:record.token];
    if (record.pid > 0) [self.executionsByPid removeObjectForKey:@(record.pid)];
    ISHShellExecutionResult *result =
        [self buildResultForRecord:record exitCode:exitCode];
    if (record.isTty && record.ptySessionId) {
        [[ISHKernel shared] closePtySession:record.ptySessionId];
    }
    void (^completion)(ISHShellExecutionResult *) = record.completion;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        if (completion) completion(result);
    });
}

// Normal path: called when the exit notification arrives and when the
// pipes drain. Finalizes only when BOTH have arrived. A timeout /
// cancel that landed first still wins its sentinel.
- (void)tryFinalizeRecord:(ISHExecRecord *)record {
    if (record.finished) return;
    if (record.exitCode == nil || !record.pipesDone) return;
    int code = ISHDecodeWaitStatus(record.exitCode.intValue);
    if (record.timedOut) code = ISHShellExecutionErrorTimeout;
    else if (record.cancelled) code = ISHShellExecutionErrorCancelled;
    [self finishRecord:record withExitCode:code];
}

// Backstop: the guest was killed (timeout / cancel) but the exit
// notification and/or pipe EOF never arrived within the grace period.
// Finalizes with the sentinel and whatever output exists.
- (void)forceFinalizeRecord:(ISHExecRecord *)record
               withExitCode:(int)exitCode {
    if (record.finished) return;
    [self finishRecord:record withExitCode:exitCode];
}

// Failed start (no task was started, or the task is a zombie with its
// pipes closed by hand): no exit notification or pipe EOF will ever
// arrive, so finalize directly. Callable from any queue.
- (void)failRecord:(ISHExecRecord *)record withCode:(int)code {
    dispatch_async(_stateQueue, ^{
        record.pipesDone = YES;
        [self finishRecord:record withExitCode:code];
    });
}

// --- Timeout / cancel (on _stateQueue) ---------------------------------------

- (void)timeoutRecord:(ISHExecRecord *)record {
    if (record.finished || record.cancelled || record.timedOut) return;
    record.timedOut = YES;
    NSLog(@"ISHShellExecutor: pid %d timed out after %.0fs — killing",
          record.pid, record.timeout);
    if (record.pid > 0) [self killProcessGroup:record.pid];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(kISHExecKillGrace * NSEC_PER_SEC)),
        _stateQueue, ^{
        [self forceFinalizeRecord:record
                     withExitCode:ISHShellExecutionErrorTimeout];
    });
}

- (void)cancelRecord:(ISHExecRecord *)record {
    dispatch_async(_stateQueue, ^{
        [self cancelRecordOnStateQueue:record];
    });
}

- (void)cancelRecordOnStateQueue:(ISHExecRecord *)record {
    if (record.finished || record.cancelled) return;
    record.cancelled = YES;
    if (record.pid > 0) {
        [self killProcessGroup:record.pid];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kISHExecKillGrace * NSEC_PER_SEC)),
            _stateQueue, ^{
            [self forceFinalizeRecord:record
                         withExitCode:ISHShellExecutionErrorCancelled];
        });
    }
    // pid == 0: the start block sees cancelled and aborts with -4.
}

- (void)cancelAll {
    dispatch_async(_stateQueue, ^{
        for (ISHExecRecord *record in [self.executions allValues]) {
            [self cancelRecordOnStateQueue:record];
        }
    });
}

// --- killProcessGroup ----------------------------------------------------------

- (void)killProcessGroup:(int)pid {
    if (pid <= 1) {
        NSLog(@"ISHShellExecutor: refusing to kill pid %d", pid);
        return;
    }
    // Collect the target + all descendants in one scan: walk each live
    // task's parent chain (bounded) and keep it when the chain reaches
    // the target. pids_lock is held for the whole walk — parent
    // pointers are only stable under it, and tasks are not freed while
    // it is held.
    int pidsToKill[256];
    int count = 0;
    lock(&pids_lock);
    for (int j = 2; j < MAX_PID && count < 256; j++) {
        struct task *t = pid_get_task((dword_t)j);
        if (!t) continue;
        struct task *cur = t;
        for (int depth = 0; depth < 64 && cur; depth++) {
            if (cur->pid == pid) {
                pidsToKill[count++] = t->pid;
                break;
            }
            cur = cur->parent;
        }
    }
    struct siginfo_ info = SIGINFO_NIL;
    for (int i = 0; i < count; i++) {
        struct task *t = pid_get_task((dword_t)pidsToKill[i]);
        if (t) send_signal(t, SIGTERM_, info);
    }
    unlock(&pids_lock);
    NSLog(@"ISHShellExecutor: SIGTERM to %d pids in group of %d", count, pid);
    // SIGKILL to survivors after 200 ms. Re-check the COLLECTED pids
    // (not a fresh tree walk): children reparented to init after their
    // parent died would be missed by a re-walk, but they are still the
    // same tasks and still need the SIGKILL.
    int survivorCount = count;
    int *survivorPids = malloc(sizeof(int) * (size_t)(count > 0 ? count : 1));
    if (!survivorPids) return;
    memcpy(survivorPids, pidsToKill, sizeof(int) * (size_t)count);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        lock(&pids_lock);
        for (int i = 0; i < survivorCount; i++) {
            struct task *t = pid_get_task((dword_t)survivorPids[i]);
            if (t) send_signal(t, SIGKILL_, info);
        }
        unlock(&pids_lock);
        free(survivorPids);
    });
}

// --- Sweeper / leak guard ------------------------------------------------------

- (void)sweepStuckExecutions {
    NSDate *now = [NSDate date];
    for (ISHExecRecord *record in [self.executions allValues]) {
        NSTimeInterval elapsed = [now timeIntervalSinceDate:record.startTime];
        if (elapsed > kISHExecStuckThreshold) {
            NSLog(@"ISHShellExecutor: LEAK GUARD: pid %d live %.0fs "
                  @"(timeout %.0fs, finished=%d, pipesDone=%d, exitCode=%@)",
                  record.pid, elapsed, record.timeout,
                  record.finished, record.pipesDone, record.exitCode);
        }
    }
}

- (NSDictionary<NSNumber *, NSNumber *> *)leakGuardStatus {
    __block NSDictionary *result = nil;
    dispatch_sync(_stateQueue, ^{
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        NSDate *now = [NSDate date];
        for (ISHExecRecord *record in [self.executions allValues]) {
            NSTimeInterval elapsed = [now timeIntervalSinceDate:record.startTime];
            if (elapsed > kISHExecStuckThreshold && record.pid > 0) {
                dict[@(record.pid)] = @(elapsed);
            }
        }
        result = [dict copy];
    });
    return result;
}

// --- Synchronous one-shot ------------------------------------------------------

- (nullable ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                               stdinData:(nullable NSData *)stdinData
                                               fsContext:(uint64_t)fsContext
                                                 timeout:(NSTimeInterval)timeout {
    if ([NSThread isMainThread]) {
        NSLog(@"ISHShellExecutor: executeCommandSync must not run on the "
              @"main thread");
        return nil;
    }
    if (![ISHKernel shared].isBooted) {
        NSLog(@"ISHShellExecutor: kernel not booted");
        return nil;
    }
    __block ISHShellExecutionResult *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self executeCommand:command stdinData:stdinData fsContext:fsContext
                 timeout:timeout completion:^(ISHShellExecutionResult *r) {
        result = r;
        dispatch_semaphore_signal(sem);
    }];
    NSTimeInterval effectiveTimeout =
        (timeout > 0 ? timeout : kISHExecDefaultTimeout);
    long ok = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((effectiveTimeout + 10.0) * NSEC_PER_SEC)));
    if (ok != 0) {
        // The async path never finalized (it should always finalize:
        // timeout / cancel / exit all converge on finishRecord). Return
        // a synthetic timeout; the late async completion is ignored.
        NSLog(@"ISHShellExecutor: sync wait timed out — async path never "
              @"finalized");
        return [[ISHShellExecutionResult alloc]
            initWithExitCode:ISHShellExecutionErrorTimeout
                  stdoutData:[NSData data]
                  stderrData:[NSData data]
                    duration:effectiveTimeout + 10.0
                    timedOut:YES
                   cancelled:NO
                         pid:0];
    }
    return result;
}

@end
