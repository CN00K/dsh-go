//  ISHKernel.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1).
//
//  ObjC bridge to the iSH C API. Interface shape follows OpenMinis
//  `src/ios/iSH/ISHKernel.h` (bootWithRootPath:, executeCommand:,
//  sendInput:, setTerminalSize:, bindMountPath:, ...); the implementation
//  is rewritten for dsh-go from the mechanism in design §1 (boot L1191–
//  1437, executeCommand: L1725–1900, killProcessGroup in
//  ISHShellExecutor.m L772+). Ported from the Stage 1 prototype
//  (ISHCoexist/ISHKernel.{h,m}), which verified boot / echo / stop /
//  re-boot and the three crash fixes on device (stage 1, 14 pass 0 fail).
//
//  HARD RULES (design §2.4(a), §6 risk 2) — carried over from stage 1:
//  - PID 1 is a supervisor that NEVER exits and NEVER execs a shell.
//    The thread that becomes PID 1 parks forever (pause loop) after boot.
//    Interactive shells are always its children (pid >= 2).
//  - stopGuest kills only pid >= 2 (SIGTERM, then SIGKILL). It NEVER
//    kills pid 1 and NEVER calls halt_system / _exit.
//  - boot is one-way: become_first_process() cannot be un-done. A second
//    bootWithRootPath: is a no-op returning 0. After stopGuest the kernel
//    is still booted; "boot again" means: run a new command.
//  - This boot does NOT install the crash handler (unlike OpenMinis boot
//    step 0). The coordinator installs it AFTER Node is ready, so g_prev
//    captures Node's handler (mitigation ① order requirement, design §6
//    risk 1). bootWithRootPath: VERIFIES the handler is already installed
//    and refuses with -3 if it is not.
//  - No AOT images in v1: pure gadget interpreter. No native offloads.
//  - NEVER call do_exit() from a GCD workqueue thread: do_exit ends in
//    pthread_exit, which libpthread aborts on a non-pthread_create thread
//    (stage 1 build 14 crash). A failed exec marks its child a zombie
//    directly (see ISHKernel.m, fix 1.4a-rev). Only task_start() spawns
//    the real pthread a guest task runs on.
//  - This target builds with CLANG_ENABLE_OBJC_ARC = YES (stage 1 build
//    12 crash: autoreleased statics dangled without ARC). The +shared
//    statics are still alloc/init (+1 owned) so they survive either way.
//
//  OUTPUT BATCHING (design §1.6): the guest writes PTY bytes through
//  ish_proto_tty_write, which appends to an internal buffer. The
//  outputCallback is invoked on the main queue at most once per burst
//  (a pending-drain flag coalesces the thousands of tiny writes a
//  command like `ls` produces); drainOutput returns everything buffered
//  since the last drain. The channel layer (stage 2.3) keeps the log
//  ring buffer for getLogs from outputCallback.
//  DSR/CPR (design §1.8): the terminal layer answers ESC[6n / ESC[5n /
//  ESC[c / ESC[>c by writing the response bytes back through sendInput:;
//  the kernel only provides the write path, it does not interpret them.
//
//  BUILD NOTES (stage 4 wires these into the Xcode project):
//  - HEADER_SEARCH_PATHS must include IShArtifacts/include (ish/*.h).
//  - GCC_PREPROCESSOR_DEFINITIONS must define GUEST_ARM64=1 and
//    ISH_INTERNAL=1 (stage 1 builds 7–8: emu/cpu.h arch select, fs/fake.h
//    internal-use gate).
//  - OTHER_LDFLAGS must link -lish_emu -lish -lfakefs -lsqlite3 -lz
//    -lresolv (res_ninit for refreshDns).
//  - IShArtifacts/include/ish/cpu-offsets.h must exist (ISHCrashHandler
//    needs it); the build fails loudly without it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a guest process exits (userInfo:
/// @{@"pid": NSNumber, @"code": NSNumber}). The code is the wait-encoded
/// status (exit code << 8, or signal bits); decode with
/// ISHDecodeWaitStatus(). Only init and init's direct children post
/// (deeper descendants are ignored to avoid pids_lock contention).
extern NSNotificationName const ISHGuestExitedNotification;

/// Decode a wait-encoded guest exit status (as posted by
/// ISHGuestExitedNotification / exitCodeForGuestPid:) into a plain exit
/// code: normal exit -> WEXITSTATUS, killed by signal N -> 128 + N,
/// stopped -> 128 + stop signal. Negative values pass through unchanged
/// (executor sentinels: -1 creation failed, -2 exec failed, -3 timeout,
/// -4 cancelled).
int ISHDecodeWaitStatus(int status);

@interface ISHKernel : NSObject

@property (class, readonly) ISHKernel *shared;

/// YES once the supervisor thread has finished boot (PID 1 parked).
@property (nonatomic, readonly) BOOL isBooted;

/// Guest output (PTY/console bytes) sink, called on the main queue.
/// Batched: at most one invocation per burst of guest writes. Also used
/// by the harness to capture one-shot command output.
@property (nonatomic, copy, nullable) void (^outputCallback)(NSData *data);

/// Extra environment variables injected into every guest command's envp
/// (after the fixed TERM/HOME/PATH/LANG/ENV entries). Keys and values
/// must be plain strings; entries that would overflow the 8 KB envp
/// buffer are dropped. Never put the DSH token or any secret here.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *customEnvironment;

/// Boot the kernel with `rootPath` pointing at the fakefs root
/// (contains data/ + meta.db). Spawns the dedicated PID 1 supervisor
/// thread and waits (max 30 s) for it to finish setup. Idempotent:
/// returns 0 immediately if already booted. Returns 0 on success,
/// negative on failure (-1 = data/ missing, -2 = supervisor timeout,
/// -3 = crash handler not installed, -100 = reset flag set).
- (int)bootWithRootPath:(NSString *)rootPath;

/// Run a guest command as a child of init (pid >= 2) on its own host
/// thread, with a fresh fake PTY for stdio. Returns 0 on success and
/// writes the guest pid to `outPid` (may be NULL). The guest runs
/// asynchronously; poll exitCodeForGuestPid: for completion.
/// This is the INTERACTIVE-terminal path (single shared _consoleTTY);
/// one-shot agent commands use ISHShellExecutor instead.
- (int)executeCommand:(NSArray<NSString *> *)command
                  pid:(nullable int *)outPid;

/// Write raw bytes into the interactive terminal's PTY (the guest
/// shell's stdin). Must be called from any queue EXCEPT the main
/// queue's runloop is fine — the write is forwarded to a dedicated
/// serial queue because tty_input() takes a pthread mutex and blocks
/// while the kernel is busy. Safe to call before boot (no-op).
- (void)sendInput:(NSData *)data;

/// Convenience for sendInput: with a UTF-8 string.
- (void)sendInputString:(NSString *)string;

/// Resize the interactive terminal's PTY (cols x rows) and deliver
/// SIGWINCH to the foreground process group. No-op before boot or
/// before any executeCommand:.
- (void)setTerminalSize:(int)cols rows:(int)rows;

/// Exit code of a guest pid (wait-encoded; decode with
/// ISHDecodeWaitStatus), or nil if it has not exited yet (recorded
/// via exit_hook). Thread-safe; may be called from any queue.
- (nullable NSNumber *)exitCodeForGuestPid:(int)pid;

/// Number of live guest tasks (pid 1 + children). Zombies are not
/// counted (pid_get_task returns NULL for them).
- (int)guestProcessCount;

/// Guest load sampling for the memory governor (stage 2.5): writes the
/// live guest task count to `outCount` and the current guest anonymous
/// memory in bytes to `outAnonBytes` (anon_page_count x 4 KiB). Either
/// out-parameter may be NULL. Returns the process count, or -1 if the
/// task table could not be scanned.
- (int)getGuestProcessCount:(nullable int *)outCount
                  anonBytes:(nullable uint64_t *)outAnonBytes;

/// Stop the guest: SIGTERM then SIGKILL to every task with pid >= 2.
/// Never touches pid 1, never calls halt_system. The kernel stays
/// booted; a later executeCommand works again.
- (void)stopGuest;

/// Stage 1.4 reset path: stop the guest and delete the rootfs
/// directory synchronously (best effort). The next boot reinstalls
/// the rootfs from the bundled zip via RootfsManager.ensureInstalled.
/// (Retired 2026-11-15: the didResetWhileBooted flag used to refuse
/// every boot until an App relaunch, but the relaunch did not
/// reliably clear it on device, leaving the terminal permanently
/// wedged. Reset is now synchronous and self-healing.)
- (void)resetRootfsWhileBooted;

/// Re-write the guest's /etc/resolv.conf from the iOS system resolver
/// (fallback 8.8.8.8 / 8.8.4.4). Non-atomic in-place write: an atomic
/// replace would change the inode and desync fakefs meta.db.
/// (Stage 3 replaces this with a bind-mount, as OpenMinis does.)
- (void)refreshDns;

/// Drain and return all PTY/console output captured since the last drain.
- (NSData *)drainOutput;

/// Bind-mount a host directory into the guest: creates a symlink in
/// data/ at `guestPath`, registers it in meta.db, and calls
/// fakefs_bind_mount. `guestPath` must be absolute (e.g.
/// "/home/workspace"); `hostPath` must be an absolute host path.
/// When `readOnly` is YES the mount point is registered with mode
/// 0555 so the kernel's access_check refuses writes with EACCES.
/// Returns 0 on success, -1 on failure (logged). Safe to call before
/// boot (the symlink + meta.db registration persist; the kernel-side
/// bind takes effect on the next boot — call again after boot to be
/// sure, it is idempotent).
- (int)bindMountPath:(NSString *)guestPath
          toHostPath:(NSString *)hostPath
            readOnly:(BOOL)readOnly;

/// Install the guest→host path-translate hook (fakefs consults it before
/// the global bind-mount table on every path operation). The block
/// receives the normalized absolute guest path and the calling task
/// group's opaque fs_context, and returns the host path to use, or nil
/// to fall through to the bind-mount table. The block MUST be reentrant
/// and non-blocking (hot fs path — no locks, no I/O, no allocation
/// beyond the returned string). Pass nil to uninstall. The hook is
/// process-global, not per-kernel-instance.
- (void)installPathTranslateHandler:(nullable NSString * _Nullable (^)(NSString *guestPath, uint64_t fsContext))handler;

/// Install the reverse (host→guest) path-translate hook, consulted by
/// realfs_getpath() after the static bind-mount table. Same hot-path
/// contract as the forward hook. Pass nil to uninstall.
- (void)installPathReverseHandler:(nullable NSString * _Nullable (^)(NSString *hostPath))handler;

/// Background CPU governor (stage 2.5, ISHResourceGovernor): start/stop
/// the 4 Hz sampler that throttles the iSH timer tick by duty cycle when
/// the 60 s sliding window exceeds budget (GREEN < 30 CPU-s, YELLOW
/// 30–38 s, RED >= 38 s at 5% duty; design §2.7). Idempotent; normally
/// driven by the app-lifecycle observers installed at boot, so manual
/// calls are only needed for tests or an explicit Dart trigger.
- (void)beginBackgroundCPUGovernor;
- (void)endBackgroundCPUGovernor;

/// Live resource-governor snapshot for the dsh/ish `status` payload
/// (stage 2.5): memory governor state, fork-guard counters, fork-rate
/// stats, background CPU governor state. JSON-safe nested dictionary;
/// see ISHResourceGovernor.statusSnapshot for the shape.
- (NSDictionary<NSString *, id> *)resourceGovernorStatus;

/// Host footprint helpers for stage 1.3 sampling / governor input.
- (uint64_t)hostPhysFootprintBytes;
- (uint64_t)hostAvailableMemoryBytes;

@end

NS_ASSUME_NONNULL_END
