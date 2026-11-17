//  ISHResourceGovernor.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.5).
//
//  Resource guards for the iSH guest, ported from OpenMinis's
//  ISHKernel.m (mechanism copied, implementation rewritten for dsh-go).
//  Without these the guest collides with jetsam / the iOS background
//  CPU limit on a real device (design §1.11 — "must copy, not optional").
//
//  FOUR GUARDS (design §1.11, §2.7):
//
//  1. Guest anonymous-memory cap — SET AT BOOT (ISHKernel step 0.5,
//     already in 2.1, NOT here): os_proc_available_memory() x 0.5
//     (dsh-go retune; OpenMinis used 0.8 — this process also runs
//     NodeMobile + DSH's JS heap + Flutter), 2 GB kernel ceiling
//     (ANON_MMAP_LIMIT_PAGES). Host page size in the conversion
//     (the 2026-08-25 lesson: guest 4 KB units authorised ~4x the cap).
//
//  2. Memory governor (continuous): a 250 ms timer + a
//     DISPATCH_MEMORYPRESSURE source feed the kernel's footprint brake
//     (ish_set_memory_status, kernel/mm.h). The kernel owns the
//     BRAKE/OK state machine: headroom < 10% brakes, > 15% releases,
//     a CRITICAL pressure event forces the brake, and a feed older
//     than 2 s reads as brake (fail-closed). BRAKE refuses NEW
//     anonymous commitments (mmap/brk ENOMEM); the growsdown fault page
//     and COW breaks stay admitted by design. This file mirrors the
//     kernel state machine for status reporting only — the kernel
//     decides, the mirror just displays (same approach as the fork's
//     regress_footprint_brake.c test).
//
//  3. Fork guard: installed with ish_set_fork_guard(). When a guest
//     fork arrives AND system memory pressure is non-normal AND the
//     app's physical footprint exceeds the scaled limit, the forking
//     thread is STALLED (not denied — musl does not retry a failed
//     fork, it exits 126 and the work is lost), re-checked every
//     50 ms, released when the footprint drops back under the limit
//     or pressure returns to normal, and released anyway after 10 s
//     (timeout release, logged — a pure delay, not backpressure).
//     Limit = physical memory x 0.25, clamped to [500 MB, 2 GB]
//     (design §2.7). Footprint is read via task_info(TASK_VM_INFO)
//     and cached for at most 1 s, so a fork storm cannot blow the
//     Mach port limit (OpenMinis 2026-09-15: two crashes, 114835
//     system port ceiling). The guard callback runs on the forking
//     thread and must not allocate or take kernel locks (task.h
//     contract): it uses only atomics, the cached reading, and
//     nanosleep. Threads (CLONE_THREAD_) are exempt in-kernel: they
//     share the parent's address space, so they do not add the
//     per-process memory cost the guard exists to bound.
//
//  4. Fork-rate governor: the kernel's token bucket
//     (ish_set_fork_rate_limit, kernel/fork.c) bounds the aggregate
//     fork rate — a 40-way `while :; do /bin/true; done` storm forks
//     ~1200/s and eats every core. Light forkers (per-task EWMA < 12)
//     bypass the bucket in-kernel, so a fresh shell doing a few forks
//     (a tool call) is never delayed by the storm's deficit. The rate
//     is driven by NSProcessInfo thermal state. The per-state rates
//     below are DSH-GO TUNING (not OpenMinis numbers — their table
//     lives in docs/internal, not in the public repo): nominal 240/s,
//     fair 120/s, serious 60/s, critical 30/s, burst = rate / 2.
//
//  5. Background CPU governor: 4 Hz sampler (250 ms) over a 60 s
//     sliding window; budget 48 CPU-seconds / 60 s (iOS kills a
//     backgrounded app that exceeds its CPU allowance). GREEN
//     (predicted window < 30 s, full speed) / YELLOW (30–38 s, duty
//     falls linearly 100% -> 5%) / RED (>= 38 s, hard brake at 5%
//     duty; exits RED only when the ACTUAL window falls below 32 s).
//     Enforcement is a throttle on the iSH timer-tick hook
//     (ish_set_timer_tick_hook): each guest timer interrupt
//     nanosleeps (1-duty)/duty x one tick (10 ms, guest HZ=100),
//     capped at 200 ms per tick. The measured CPU is the WHOLE
//     process (getrusage RUSAGE_SELF) — the iOS budget is per-app,
//     and the guest tick is the only throttle lever we own; if Node
//     or Flutter dominate background CPU, braking the guest cannot
//     bring the app under budget (per-thread attribution is a
//     stage-5 refinement). Started when the app enters background,
//     stopped when it returns to foreground (auto-wired to
//     UIApplication notifications; begin/end stay public for manual
//     control). Idempotent. No silent-audio keep-alive (design §2.7:
//     vetoed, App Store guideline 2.5.4) — background guest work
//     stays best-effort.
//
//  LIFETIME: the memory governor, fork guard and fork-rate governor
//  start once at boot (startBootGovernors, called from ISHKernel
//  boot step 0.5) and run for the life of the process — they protect
//  the whole app, not just the guest, so stopping the guest does not
//  stop them. The CPU governor only runs while backgrounded.
//
//  STATUS: statusSnapshot returns a JSON-safe nested dictionary for
//  the dsh/ish `status` payload (design §3 step 2.5: "status reports
//  guest memory usage" — guestMemoryBytes/guestProcessCount already
//  come from ISHKernel.getGuestProcessCount:anonBytes:; this adds
//  the governors' live state so Dart can stop the guest before DSH
//  when memory pressure bites, design §6 risk 5).
//
//  THREADING: all mutable governor state lives on one private serial
//  queue; the two C callbacks (fork guard, tick hook) read only
//  atomics. begin/end/startBootGovernors are safe from any thread
//  except the governor queue itself (they dispatch_sync to it).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISHResourceGovernor : NSObject

@property (class, readonly) ISHResourceGovernor *shared;

/// Start the boot-time guards: memory governor (feed primed BEFORE
/// the guest boots), fork guard, fork-rate governor, and the
/// background-CPU governor's app-lifecycle observers. Idempotent;
/// call once from ISHKernel boot step 0.5.
- (void)startBootGovernors;

/// Start the background CPU governor (4 Hz sampler + timer-tick
/// throttle). Idempotent; safe to call before boot (the tick hook is
/// inert until a guest runs) and from any thread. Normally driven by
/// the app-lifecycle observers installed in startBootGovernors.
- (void)beginBackgroundCPUGovernor;

/// Stop the background CPU governor (removes the tick hook, stops
/// the sampler, restores full duty). Idempotent.
- (void)endBackgroundCPUGovernor;

/// Live snapshot for the dsh/ish `status` payload. JSON-safe nested
/// dictionary:
///   memoryGovernor: {active, state "off"/"ok"/"brake", staleFeed,
///     footprintMode, limitBytes, availableBytes, pressure
///     "normal"/"warn"/"critical"}
///   forkGuard: {limitBytes, stalls, stallTimeouts}
///   forkRate: {perSecond, burst, throttled, bypassed, sleepMs}
///   cpuGovernor: {active, state "off"/"green"/"yellow"/"red", duty
///     0.0-1.0, windowCpuSeconds, predictedWindowCpuSeconds,
///     budgetCpuSeconds}
- (NSDictionary<NSString *, id> *)statusSnapshot;

@end

NS_ASSUME_NONNULL_END
