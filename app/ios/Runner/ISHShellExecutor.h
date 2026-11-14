//  ISHShellExecutor.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1).
//
//  One-shot guest command execution over host pipes (design §1.7).
//  This is the AGENT path: the DSH agent loop runs tools (apk, ls, cat,
//  npm, ...) as short-lived guest processes whose stdout/stderr are
//  captured and returned. It is NOT the interactive terminal — that
//  stays on ISHKernel's shared PTY (executeCommand: / sendInput:).
//
//  Mechanism (design §1.7, verified against ish-src):
//  - become_new_init_child() gives the child a FRESH fdtable
//    (fdtable_new(3) via construct_task) — files[0/1/2] start empty,
//    so stdio is wired directly, no create_stdio.
//  - Each stdio slot gets an adhoc fd: adhoc_fd_create(&realfs_fdops)
//    + fd->real_fd = the (dup'd) host pipe fd. realfs_read/write call
//    host read()/write() on that fd; realfs_close closes it, so the
//    guest's fdtable release on exit closes the guest pipe ends and
//    delivers EOF to the host readers.
//  - The stat is populated from fstat(host fd) (same as
//    kernel/init.c open_fd_from_actual_fd, which is static — replicated
//    in ISHShellExecutor.m): Node.js/libuv fstats stdout/stderr to
//    decide TTY vs pipe vs file, and all-zero stat makes console.log
//    silently fail. Sockets / TTYs are reported as S_IFCHR.
//  - fsContext is written to current->group->fs_context before exec
//    (inherited verbatim on fork; the fakefs path-translate hook reads
//    it to scope a bind-mount / workspace to one agent run).
//  - Exit is observed via ISHGuestExitedNotification (posted by
//    ISHKernel's exit_hook) AND via pipe EOF; the result is finalized
//    when BOTH have arrived (exit code + complete output). A timeout
//    kills the process group and finalizes with -3 after a 500 ms grace
//    period for the tail of the output.
//  - NEVER call do_exit() on a GCD thread (stage 1 build 14 crash). A
//    failed do_execve marks the child a zombie directly, exactly as
//    ISHKernel does ([FIX 1.4a-rev]), and closes the guest pipe ends
//    by hand (a zombie's fdtable is never released, so nothing else
//    would close them — the host readers would block forever).
//
//  TIMEOUTS: timeout <= 0 means the default (30 s). There is no
//  "run forever" — a guest that closes stdout/stderr but never exits
//  would otherwise never complete. The sync variant waits timeout + 10 s
//  of grace for the async path to finalize; if that still has not
//  happened it returns a synthetic -3 result (the async completion is
//  then ignored).
//
//  CONCURRENCY: executions are independent (one GCD block + two pipe
//  reader threads each). The DSH agent runs one command at a time, so
//  in practice there is rarely more than one live execution. The
//  sweeper (every 30 s) logs any execution live longer than 30 s;
//  leakGuardStatus exposes the same scan for the channel layer.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error / sentinel exit codes. The result's exitCode is the
/// WEXITSTATUS-decoded guest exit code (0–255), or 128 + signal when the
/// guest was killed by a signal, or one of these sentinels when the
/// execution itself failed. ISHDecodeWaitStatus() (ISHKernel.h) performs
/// the wait-status decode; the sentinels pass through unchanged.
typedef NS_ENUM(NSInteger, ISHShellExecutionError) {
    ISHShellExecutionErrorNone = 0,
    /// become_new_init_child / pipe / fd setup failed, or the kernel is
    /// not booted. No guest process was started.
    ISHShellExecutionErrorCreationFailed = -1,
    /// do_execve failed (e.g. ENOENT for a missing binary). The child
    /// was marked a zombie (see the header comment) and no output exists.
    ISHShellExecutionErrorExecFailed = -2,
    /// The timeout fired; the process group was killed. stdout/stderr
    /// hold whatever was captured before the kill (+500 ms grace).
    ISHShellExecutionErrorTimeout = -3,
    /// The execution was cancelled (cancel / cancelAll) before it
    /// completed. The process group was killed.
    ISHShellExecutionErrorCancelled = -4,
};

/// Immutable result of one execution.
@interface ISHShellExecutionResult : NSObject
/// WEXITSTATUS-decoded exit code, 128 + signal, or a
/// ISHShellExecutionError sentinel (-1..-4).
@property (nonatomic, readonly) int exitCode;
/// Captured guest stdout (complete at finalization).
@property (nonatomic, readonly) NSData *stdoutData;
/// Captured guest stderr (complete at finalization).
@property (nonatomic, readonly) NSData *stderrData;
/// Wall-clock time from start to finalization.
@property (nonatomic, readonly) NSTimeInterval duration;
/// YES when the timeout fired (exitCode is then -3).
@property (nonatomic, readonly) BOOL timedOut;
/// YES when cancel / cancelAll killed it (exitCode is then -4).
@property (nonatomic, readonly) BOOL cancelled;
/// The guest pid, or 0 when no guest process was started.
@property (nonatomic, readonly) int pid;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Handle for a running (or finished) async execution. Returned
/// synchronously by the async methods; pid is 0 until the guest task
/// has started, then the real guest pid. cancel kills the process group
/// (or abandons the start if it has not started yet). The completion
/// block still fires after a cancel, with exitCode -4.
@interface ISHShellExecution : NSObject
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) BOOL finished;
- (void)cancel;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface ISHShellExecutor : NSObject

+ (instancetype)shared;

/// Run a binary directly: argv = [executable] + arguments. Returns a
/// handle immediately; the completion fires on an arbitrary queue when
/// the guest exits (or times out / is cancelled). Refuses with -1 when
/// the kernel is not booted.
- (ISHShellExecution *)executeExecutable:(NSString *)executable
                               arguments:(NSArray<NSString *> *)arguments
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                              completion:(void (^)(ISHShellExecutionResult *result))completion;

/// Run through /bin/sh -c <command> (argv = ["/bin/sh", "-c", command]).
/// Shell syntax errors exit 2 with the diagnostic on stderr — that is
/// sh's own behaviour, returned verbatim in the result.
- (ISHShellExecution *)executeCommand:(NSString *)command
                            stdinData:(nullable NSData *)stdinData
                            fsContext:(uint64_t)fsContext
                              timeout:(NSTimeInterval)timeout
                           completion:(void (^)(ISHShellExecutionResult *result))completion;

/// Synchronous one-shot, for agent preflight checks (e.g. `test -x
/// /sbin/apk`). Blocks the calling thread until the result is ready.
/// Never call on the main thread. Returns nil only if the async path
/// itself could not be started (kernel not booted).
- (nullable ISHShellExecutionResult *)executeCommandSync:(NSString *)command
                                               stdinData:(nullable NSData *)stdinData
                                               fsContext:(uint64_t)fsContext
                                                 timeout:(NSTimeInterval)timeout;

/// Kill one guest pid AND its descendants (BFS over parent pointers
/// under pids_lock): SIGTERM to the whole set, SIGKILL to survivors
/// after 200 ms. Refuses pid <= 1 (never pid 1 — its death calls
/// halt_system() == _exit(0) and kills the app).
- (void)killProcessGroup:(int)pid;

/// Kill every live execution (teardown path). Each result completes
/// with exitCode -4.
- (void)cancelAll;

/// Sweeper diagnostics: @{ pid : elapsed-seconds } for every live
/// execution older than 30 s. Empty when nothing is stuck.
- (NSDictionary<NSNumber *, NSNumber *> *)leakGuardStatus;

@end

NS_ASSUME_NONNULL_END
