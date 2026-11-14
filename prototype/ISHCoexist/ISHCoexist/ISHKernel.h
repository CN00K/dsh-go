//  ISHKernel.h
//  ISHCoexist — Stage 1 coexistence prototype
//
//  Minimal ObjC bridge to the iSH C API. Interface shape borrowed from
//  OpenMinis `src/ios/iSH/ISHKernel.h` (bootWithRootPath:,
//  executeCommand:, sendInput:, setTerminalSize:, bindMountPath:, ...);
//  this prototype implements only the subset stage 1 needs, rewritten
//  from the mechanism in ISHKernel.m (boot L1191–1437, executeCommand:
//  L1725–1900, killProcessGroup in ISHShellExecutor.m L772+).
//
//  HARD RULES (design §2.4(a), §6 risk 2):
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
//    captures Node's handler (mitigation ① order requirement).
//  - No AOT images in v1: pure gadget interpreter. No offloads, no
//    bind mounts, no background governors in this prototype.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ISHCoexistGuestExitedNotification;

@interface ISHKernel : NSObject

@property (class, readonly) ISHKernel *shared;

/// YES once the supervisor thread has finished boot (PID 1 parked).
@property (nonatomic, readonly) BOOL isBooted;

/// Set by resetRootfsWhileBooted. While set, boot/execute refuse work
/// until the app is relaunched (in-memory flag; a fresh launch clears it
/// and the rootfs is re-installed from the bundle zip).
@property (nonatomic, readonly) BOOL didResetWhileBooted;

/// Guest output (PTY/console bytes) sink, called on the main queue.
/// Also used by the harness to capture one-shot command output.
@property (nonatomic, copy, nullable) void (^outputCallback)(NSData *data);

/// Boot the kernel with `rootPath` pointing at the fakefs root
/// (contains data/ + meta.db). Spawns the dedicated PID 1 supervisor
/// thread and waits (max 30 s) for it to finish setup. Idempotent:
/// returns 0 immediately if already booted. Returns 0 on success,
/// negative on failure (-100 = reset flag set, relaunch required).
- (int)bootWithRootPath:(NSString *)rootPath;

/// Run a guest command as a child of init (pid >= 2) on its own host
/// thread, with a fresh fake PTY for stdio. Returns 0 on success and
/// writes the guest pid to `outPid` (may be NULL). The guest runs
/// asynchronously; poll exitCodeForGuestPid: for completion.
/// Refuses with -100 while didResetWhileBooted is set.
- (int)executeCommand:(NSArray<NSString *> *)command
                  pid:(nullable int *)outPid;

/// Exit code of a guest pid, or nil if it has not exited yet (recorded
/// via exit_hook). Thread-safe; may be called from any queue.
- (nullable NSNumber *)exitCodeForGuestPid:(int)pid;

/// Number of live guest tasks (pid 1 + children). -1 if the task table
/// could not be scanned.
- (int)guestProcessCount;

/// Stop the guest: SIGTERM then SIGKILL to every task with pid >= 2.
/// Never touches pid 1, never calls halt_system. The kernel stays
/// booted; a later executeCommand works again.
- (void)stopGuest;

/// Stage 1.4 reset path: stop the guest, set didResetWhileBooted, and
/// delete the rootfs directory (best effort). Afterwards executeCommand:
/// refuses until the app is relaunched.
- (void)resetRootfsWhileBooted;

/// Re-write the guest's /etc/resolv.conf from the iOS system resolver
/// (fallback 8.8.8.8 / 8.8.4.4). Non-atomic in-place write: an atomic
/// replace would change the inode and desync fakefs meta.db.
- (void)refreshDns;

/// Drain and return all PTY/console output captured since the last drain.
- (NSData *)drainOutput;

/// Host footprint helpers for stage 1.3 sampling.
- (uint64_t)hostPhysFootprintBytes;
- (uint64_t)hostAvailableMemoryBytes;

@end

NS_ASSUME_NONNULL_END
