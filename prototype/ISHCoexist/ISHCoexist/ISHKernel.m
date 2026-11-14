//  ISHKernel.m
//  ISHCoexist — Stage 1 coexistence prototype
//
//  Boot steps follow OpenMinis ISHKernel.m bootWithRootPath: L1191–1437,
//  renumbered here with the prototype's changes marked [PROTO-DELTA-K*].
//  executeCommand: follows L1725–1900 (become_new_init_child,
//  pty_open_fake, create_stdio, do_execve, task_start). stopGuest follows
//  ISHShellExecutor.m killProcessGroup L772+ (TERM -> wait -> KILL,
//  refuse pid <= 1), applied to ALL guest pids >= 2.

#import "ISHKernel.h"
#import "ISHCrashHandler.h"

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
#include <unistd.h>
#include <errno.h>
#include <sys/syslimits.h>
#include <execinfo.h>
#include <resolv.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <mach/mach.h>

NSNotificationName const ISHCoexistGuestExitedNotification =
    @"ISHCoexistGuestExited";

static ISHKernel *g_sharedKernel = nil;

// Guest exit records (pid -> code), written on the main queue via
// dispatch_async from exit_hook (same pattern as OpenMinis
// handle_process_exit, L1085–1100: exit_hook never blocks on a lock).
static NSMutableDictionary<NSNumber *, NSNumber *> *g_guestExits = nil;

// Captured PTY/console output since the last drain.
static NSMutableData *g_ptyOutput = nil;
static NSLock *g_ptyOutputLock = nil;

// --- TTY driver: guest output -> host buffer + callback -------------------
// Same shape as OpenMinis ish_console_ops / ish_console_driver (L1055–1096).
static int ish_proto_tty_write(struct tty *tty, const void *buf, size_t len,
                               bool blocking) {
    (void)tty; (void)blocking;
    if (len == 0) return 0;
    NSData *data = [NSData dataWithBytes:buf length:len];
    [g_ptyOutputLock lock];
    [g_ptyOutput appendData:data];
    [g_ptyOutputLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_sharedKernel.outputCallback) g_sharedKernel.outputCallback(data);
    });
    return (int)len;
}
static int ish_proto_tty_init(struct tty *tty) { (void)tty; return 0; }
static void ish_proto_tty_cleanup(struct tty *tty) { (void)tty; }

static struct tty_driver_ops ish_proto_console_ops = {
    .init = ish_proto_tty_init,
    .write = ish_proto_tty_write,
    .cleanup = ish_proto_tty_cleanup,
};

DEFINE_TTY_DRIVER(ish_proto_console_driver, &ish_proto_console_ops,
                  TTY_CONSOLE_MAJOR, 8);
static struct tty_driver ish_proto_pty_driver = { .ops = &ish_proto_console_ops };

// --- exit_hook + die_handler ----------------------------------------------
// [PROTO-DELTA-K1] die(): embedded iSH must never abort() the app.
// Same semantics as OpenMinis embedded_die_handler (L651–~670): log and
// park only the faulting guest thread. (Rewritten here; the OpenMinis
// original also feeds its crash breadcrumbs — this prototype just logs.)
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
            postNotificationName:ISHCoexistGuestExitedNotification
                          object:nil
                        userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

@implementation ISHKernel {
    BOOL _isBooted;
    BOOL _didResetWhileBooted;
    struct tty *_consoleTTY;
    NSString *_rootPath;
    NSString *_dataPath;
    dispatch_semaphore_t _bootSemaphore;
    int _bootResult;
}

+ (ISHKernel *)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_sharedKernel = [[ISHKernel alloc] init];
        g_guestExits = [NSMutableDictionary dictionary];
        g_ptyOutput = [NSMutableData data];
        g_ptyOutputLock = [[NSLock alloc] init];
    });
    return g_sharedKernel;
}

- (BOOL)isBooted { return _isBooted; }
- (BOOL)didResetWhileBooted { return _didResetWhileBooted; }

- (NSData *)drainOutput {
    [g_ptyOutputLock lock];
    NSData *out = [g_ptyOutput copy];
    [g_ptyOutput setLength:0];
    [g_ptyOutputLock unlock];
    return out;
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
    return ish_host_phys_footprint_bytes();
}

- (uint64_t)hostAvailableMemoryBytes {
    return ish_host_available_memory_bytes();
}

// --- Boot ------------------------------------------------------------------

- (int)bootWithRootPath:(NSString *)rootPath {
    if (_isBooted) {
        NSLog(@"ISHKernel: already booted");
        return 0;
    }
    if (_didResetWhileBooted) {
        NSLog(@"ISHKernel: reset flag set — relaunch the app to boot again");
        return -100;
    }
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
    supervisor.name = @"ISHCoexist PID1 supervisor";
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
    // [PROTO-DELTA-K2] No handler install here. OpenMinis boot step 0
    // installs the JIT crash handler before any JIT code runs; this
    // prototype installs it in the coordinator AFTER Node is ready, so
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
    // [PROTO-DELTA-K3] Design §2.7: share 0.5, NOT OpenMinis's 0.8 —
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

    // [PROTO-DELTA-K4] No native offload registration (OpenMinis step 9,
    // 28 handlers) — v1 scope excludes offloads. No memory/CPU/fork
    // governors either (stage 2 work); only the anon cap above is set.
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
    // this prototype writes the shipped file directly.
    NSError *error = nil;
    BOOL ok = [resolvConf writeToFile:path atomically:NO
                             encoding:NSUTF8StringEncoding error:&error];
    NSLog(@"ISHKernel: DNS configured (%@): %@",
          ok ? @"ok" : @"FAILED", ok ? path : error);
}

// --- Execution ---------------------------------------------------------------

- (int)executeCommand:(NSArray<NSString *> *)command
                  pid:(int *)outPid {
    if (!_isBooted) {
        NSLog(@"ISHKernel: kernel not booted");
        return -1;
    }
    if (_didResetWhileBooted) {
        NSLog(@"ISHKernel: refusing execute — reset flag set, relaunch app");
        return -100;
    }
    if (command.count == 0) return -2;
    NSArray<NSString *> *commandCopy = [command copy];
    [self drainOutput]; // fresh capture for this run
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
        struct tty *tty = pty_open_fake(&ish_proto_pty_driver);
        if (tty == NULL || IS_ERR(tty)) {
            NSLog(@"ISHKernel: pty_open_fake failed: %ld",
                  (long)PTR_ERR(tty));
            dispatch_semaphore_signal(started);
            return;
        }
        self->_consoleTTY = tty;
        struct winsize_ winsize = {
            .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        tty_set_winsize(tty, winsize);
        NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d",
                               tty->num];
        err = create_stdio(stdioFile.fileSystemRepresentation,
                           TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (err < 0) {
            NSLog(@"ISHKernel: create_stdio failed: %d", err);
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
#undef KERNEL_ENVP_APPEND
        envp_buf[envp_pos] = '\0';
        const char *exec_path = commandCopy[0].UTF8String;
        err = do_execve(exec_path, exec_argc, argv, envp_buf);
        if (err < 0) {
            NSLog(@"ISHKernel: do_execve failed: %d", err);
            dispatch_semaphore_signal(started);
            return;
        }
        NSLog(@"ISHKernel: started guest process PID %d", current->pid);
        startResult = 0;
        dispatch_semaphore_signal(started);
        // Runs the emulator loop. Assumed to return after the guest task
        // exits (unverified for this libish build — see README); the
        // harness relies on exit_hook, not on this thread returning.
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

- (void)stopGuest {
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
    _didResetWhileBooted = YES;
    [self stopGuest];
    NSString *rootfs = _rootPath;
    if (rootfs) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            NSError *error = nil;
            [[NSFileManager defaultManager]
                removeItemAtPath:rootfs error:&error];
            if (error) {
                NSLog(@"ISHKernel: rootfs delete failed (best effort): %@",
                      error);
            } else {
                NSLog(@"ISHKernel: rootfs deleted; didResetWhileBooted set — "
                      @"relaunch the app to reinstall");
            }
        });
    }
}

@end
