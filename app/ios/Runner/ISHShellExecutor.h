//  ISHShellExecutor.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1).
//
//  One-shot guest command execution over host pipes (design §1.7),
//  plus a PTY variant (stage 5.3, ENV-02) that runs the command on a
//  fresh fake PTY (ISHKernel per-session API) so interactive programs
//  work: vi/vim/less/top, REPLs, login prompts.
//  This is the AGENT path: the DSH agent loop runs tools (apk, ls, cat,
//  npm, ...) as short-lived guest processes whose stdout/stderr are
//  captured and returned. It is NOT the interactive terminal — that
//  stays on ISHKernel's per-session PTY API (executeCommand:pid:
//  sessionId:... / sendInput:sessionId:).
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
//  PTY executions additionally share ISHKernel's ISHPtyMaxSessions
//  cap with interactive terminals (a refused start fails with -1).

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

/// Streaming variant (stage 2.4 loopback /ish/exec): stdout/stderr
/// chunks are delivered to `outputHandler` as they arrive (arbitrary
/// queue, raw bytes, per-stream arrival order). The completion still
/// fires at the end with the full result. Pass nil for outputHandler to
/// get the non-streaming behaviour.
- (ISHShellExecution *)executeCommand:(NSString *)command
                            stdinData:(nullable NSData *)stdinData
                            fsContext:(uint64_t)fsContext
                              timeout:(NSTimeInterval)timeout
                        outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                           completion:(void (^)(ISHShellExecutionResult *result))completion;

/// Direct argv exec (route B, /ish/exec argv mode): argv runs WITHOUT
/// a shell — argv[0] is the program, the rest are its arguments
/// verbatim. A bare argv[0] (no '/') is resolved against the effective
/// PATH (execvp semantics; the kernel does no PATH lookup); a path
/// argv[0] is used as given. `env` overlays the fixed defaults
/// (request wins; invalid shell names are ignored) and `cwd` becomes
/// the child's working directory (no shell `cd`); both are nil for the
/// command path, which keeps baking them into the shell string.
/// Pipe-only (no PTY); streaming, timeout and sentinels are the same
/// as executeCommand above.
- (ISHShellExecution *)executeArgv:(NSArray<NSString *> *)argv
                               env:(nullable NSDictionary<NSString *, NSString *> *)env
                               cwd:(nullable NSString *)cwd
                         stdinData:(nullable NSData *)stdinData
                         fsContext:(uint64_t)fsContext
                           timeout:(NSTimeInterval)timeout
                     outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                        completion:(void (^)(ISHShellExecutionResult *result))completion;

/// PTY variant (stage 5.3, ENV-02): run through /bin/sh -c <command>
/// on a fresh fake PTY (its own ISHKernel session, own winsize)
/// instead of host pipes. stdout/stderr are MERGED — a PTY has one
/// stream — so chunks always arrive with isStderr == NO and the
/// result's stderrData is empty. stdinData is fed to the PTY in
/// <= 2 KiB chunks, then an EOT byte (0x04) is sent so the guest sees
/// EOF (the same end-of-input semantics as the pipe path closing
/// stdin). TERM is xterm-256color (a tty IS present — this is the
/// "has tty" case of ENV-02; the pipe path's TERM handling is owned
/// by the env/executor workstream, not this method). cols/rows set the initial
/// winsize (<= 0 means 80x24). Timeout / cancel / finalization are
/// the same as the pipe path (exit notification, 500 ms grace,
/// -3 / -4 sentinels). The kernel session id is internal; the result
/// carries no session id. Counts against the kernel's
/// ISHPtyMaxSessions cap (a refused start fails with -1).
- (ISHShellExecution *)executeCommandTty:(NSString *)command
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                                    cols:(int)cols
                                    rows:(int)rows
                           outputHandler:(nullable void (^)(BOOL isStderr, NSData *chunk))outputHandler
                              completion:(void (^)(ISHShellExecutionResult *result))completion;

/// Non-streaming wrapper of the PTY variant above.
- (ISHShellExecution *)executeCommandTty:(NSString *)command
                               stdinData:(nullable NSData *)stdinData
                               fsContext:(uint64_t)fsContext
                                 timeout:(NSTimeInterval)timeout
                                    cols:(int)cols
                                    rows:(int)rows
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

// --- Persistent shell worker (ENV-04) --------------------------------------
// A long-lived guest /bin/bash per DSH session, so agent execs stop
// paying a fresh process creation + shell start per command. The
// worker is started exactly like a one-shot exec (become_new_init_child
// + adhoc-fd pipes + do_execve of /bin/bash --noprofile --norc), but
// its stdin stays open and it has no timeout and no exit-notification
// finalization: commands are written to its stdin by the loopback
// service (see IShLoopbackService.buildWorkerCommand for the wrapper:
// per-command env overlay, `{ cmd; } < /dev/null` stdin guard, END
// marker + jobs snapshot), and output streams back through the same
// pipe readers as one-shot execs.
//
// LIFECYCLE: created lazily by workerForSession (at most
// ISHWorkerMaxSessions live workers; creating one more evicts the
// least-recently-used, killing its jobs first). The worker dies when
// its shell exits (e.g. the command was `exit`), when it is stopped,
// or when the guest stops; a dead worker is dropped from the registry
// and the next run recreates it (the bridge resends the remembered
// cwd, so the rebuild lands in the same directory). stopAllWorkers is
// the teardown path (service stop); stopGuest kills the guest pids
// directly, and the exit observer drops the records.
//
// JOBS: a command's `&` children are jobs of the worker shell (they
// are NOT wrapped in a subshell, so `jobs -l` sees them). The loopback
// service reports the last `jobs -p` snapshot into jobPids; killing
// the foreground command excludes those pids, killing a job validates
// it is a descendant of the worker first. Stopping a worker kills its
// whole process tree (killProcessGroup on the worker pid), so no
// background job survives its session.

@end

/// Max live workers (same cap as the PTY sessions: one guest task +
/// three host pipe fds each, and the agent is serial per session, so
/// more would only be idle shells).
extern const NSUInteger ISHWorkerMaxSessions;

/// A live (or recently dead) worker shell.
@interface ISHWorkerShell : NSObject
/// DSH session id this worker belongs to.
@property (nonatomic, readonly, copy) NSString *sessionId;
/// Guest pid of the bash process, 0 until it has started.
@property (nonatomic, readonly) int pid;
/// NO once the shell has exited (readers hit EOF or the exit
/// notification arrived). A dead worker is dropped from the registry.
@property (nonatomic, readonly, getter=isAlive) BOOL alive;
/// fs_context the worker was started with (0 = none). A run with a
/// different fsContext rebuilds the worker (checked loopback-side).
@property (nonatomic, readonly) uint64_t fsContext;
/// Last time a run started on this worker (LRU eviction).
@property (nonatomic, readonly, strong) NSDate *lastUsedAt;
/// Wait-encoded exit code (ISHDecodeWaitStatus decodes it), or nil
/// when the shell has not exited yet / died without a notification.
@property (nonatomic, readonly, strong, nullable) NSNumber *exitCode;
/// Pids of the worker's background jobs, from the last `jobs -p`
/// snapshot the loopback service reported. Used to exclude jobs when
/// killing the foreground command.
@property (nonatomic, copy) NSSet<NSNumber *> *jobPids;
/// Invoked exactly once when the shell dies (readers EOF or exit
/// notification), with the wait-encoded exit code or nil. Set by the
/// loopback service per run; cleared when the run ends.
@property (nonatomic, copy, nullable) void (^onDeath)(NSNumber * _Nullable exitCode);
- (instancetype)init NS_UNAVAILABLE;
@end

/// Worker-session methods (ENV-04), declared on a category so the
/// worker-shell interface can sit above them in this header.
@interface ISHShellExecutor (Worker)

/// The registered worker for a session, if one exists (alive or
/// recently dead). Does NOT create one. Used by the jobs-kill endpoint,
/// which must not start a shell just to answer "no such job".
- (nullable ISHWorkerShell *)workerForSessionIfPresent:(NSString *)sessionId;

/// Get (or start) the worker for a session. Starts /bin/bash
/// --noprofile --norc with host pipes; `baseEnvText` (e.g.
/// "export FOO='bar'; ...", may be nil/empty) is written to the
/// worker's stdin before any command, so the worker's base environment
/// holds the session env (PYTHONDONTWRITEBYTECODE=0, DSH_* — a
/// background job forked from the worker inherits this, not the
/// per-command overlay). Returns nil when the kernel is not booted or
/// the start fails / times out (15 s). May evict the LRU worker.
/// Thread-safe; blocks the caller while the worker starts.
- (nullable ISHWorkerShell *)workerForSession:(NSString *)sessionId
                                    fsContext:(uint64_t)fsContext
                                  baseEnvText:(nullable NSString *)baseEnvText;

/// Start one run on the worker: set the output handler (called with
/// (isStderr, chunk) on the worker queue as pipe reads return) and
/// write the (already wrapped) command text to the worker's stdin.
/// The handler stays installed until endWorkerRun. No-op when the
/// worker is dead (the caller then rebuilds via workerForSession).
- (void)beginWorkerRun:(ISHWorkerShell *)worker
           commandText:(NSString *)commandText
         outputHandler:(void (^)(BOOL isStderr, NSData *chunk))outputHandler;

/// End a run: clear the output handler (output arriving between runs —
/// e.g. a background job printing while idle — is dropped). Safe to
/// call twice.
- (void)endWorkerRun:(ISHWorkerShell *)worker;

/// Kill the foreground command of a worker run: every direct child of
/// the worker pid EXCEPT the known background-job pids, each with its
/// whole descendant tree (killProcessGroup). Returns the pids killed.
/// Empty when the foreground command is a shell builtin (no child —
/// e.g. `wait`): the caller must then escalate (kill the worker) if
/// the run still does not complete.
- (NSArray<NSNumber *> *)killWorkerForegroundCommand:(ISHWorkerShell *)worker;

/// Kill one background job (and its descendants). The pid must be a
/// live descendant of the worker (anything else — including the worker
/// itself — is refused). Returns YES when the kill was issued.
- (BOOL)killWorkerJob:(ISHWorkerShell *)worker pid:(int)pid;

/// Stop one session's worker: kill its whole process tree (worker +
/// foreground command + background jobs), close its stdin, drop it
/// from the registry. Idempotent; no-op when there is no worker.
- (void)stopWorkerForSession:(NSString *)sessionId;

/// Stop every live worker (teardown path; the loopback service calls
/// this from stop()). Each worker's process tree is killed, so no
/// background job survives the service stop.
- (void)stopAllWorkers;

/// Kill every live execution (teardown path). Each result completes
/// with exitCode -4.
- (void)cancelAll;

/// Sweeper diagnostics: @{ pid : elapsed-seconds } for every live
/// execution older than 30 s. Empty when nothing is stuck.
- (NSDictionary<NSNumber *, NSNumber *> *)leakGuardStatus;

@end

NS_ASSUME_NONNULL_END
