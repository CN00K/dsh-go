//  ISHResourceGovernor.m
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.5).
//
//  Implementation of the four guards declared in ISHResourceGovernor.h.
//  Mechanism follows OpenMinis's ISHKernel.m (memory governor L619–650,
//  fork guard minis_fork_memory_guard L101–~380, fork-rate governor,
//  background CPU governor L2399–2670); the code here is rewritten for
//  dsh-go. All kernel hook names/signatures are verified against the
//  pinned fork OpenMinis/ish-arm64 @ 0fd17a13 (third_party/ish/source.json):
//    kernel/mm.h   ish_set_memory_status / ish_footprint_mode
//    kernel/task.h ish_set_fork_guard / ish_set_fork_rate_limit /
//                  ish_fork_rate_stats / ish_set_timer_tick_hook
//
//  STAGE 1 FIXES — DO NOT REGRESS (none of them live in this file, but
//  the file must not reintroduce them):
//  (1) +shared statics are alloc/init (+1 owned), never autoreleased
//      convenience constructors (stage 1 build 12 crash).
//  (2) NEVER call do_exit() — this file contains no do_exit call.
//  (3) A failed exec marks its child a zombie directly (ISHKernel.m);
//      this file never touches guest task lifetime.

#import "ISHResourceGovernor.h"

#import "ish/kernel/mm.h"    // ish_set_memory_status, ish_footprint_mode
#import "ish/kernel/task.h"  // ish_set_fork_guard, ish_set_fork_rate_limit,
                             // ish_fork_rate_stats, ish_set_timer_tick_hook
#import <os/proc.h>          // os_proc_available_memory
#import <mach/mach.h>        // task_info, TASK_VM_INFO
#import <sys/resource.h>     // getrusage
#import <UIKit/UIKit.h>      // UIApplication lifecycle notifications
#import <stdatomic.h>
#import <time.h>

// --- Tunables (design §1.11, §2.7; sources noted per item) -----------------

// Memory governor: 250 ms feed cadence (OpenMinis ish_memory_governor_tick).
static const uint64_t kMemGovernorIntervalNs = 250 * NSEC_PER_MSEC;
// Feed staleness window — mirrors ISH_MEM_STALE_MS (kernel/mmap.c):
// the kernel fails closed when no feed arrives for this long.
static const uint64_t kMemStaleMs = 2000;

// Fork guard: limit = physical memory x 0.25, clamped to [500 MB, 2 GB]
// (design §2.7; 2 GB ceiling is OpenMinis MINIS_FORK_GUARD_CEIL_BYTES).
static const uint64_t kForkGuardMinBytes = 500ULL * 1024 * 1024;
static const uint64_t kForkGuardMaxBytes = 2ULL * 1024 * 1024 * 1024;
// Stall slices of 50 ms, re-checking pressure/footprint; a single stall
// never exceeds 10 s (timeout releases, only logs).
static const uint64_t kForkGuardStallSliceNs = 50 * NSEC_PER_MSEC;
static const uint64_t kForkGuardMaxStallNs = 10 * NSEC_PER_SEC;
// Footprint cache: at most one task_info per second, so a fork storm
// cannot blow the Mach port limit (OpenMinis 2026-09-15, 114835 ceiling).
static const uint64_t kForkFootprintCacheMs = 1000;

// Fork-rate governor: dsh-go tuning (see header — NOT OpenMinis numbers).
// The kernel's own reference point is the ~1200 forks/s storm in
// kernel/fork.c; light forkers (per-task EWMA < 12) bypass the bucket
// in-kernel, so these caps only ever slow a storm, never a fresh shell.
static const unsigned kForkRateNominalPerSec = 240;
static const unsigned kForkRateFairPerSec = 120;
static const unsigned kForkRateSeriousPerSec = 60;
static const unsigned kForkRateCriticalPerSec = 30;

// Background CPU governor: 4 Hz sampler, 60 s sliding window, budget
// 48 CPU-seconds / 60 s (design §1.11 #4). Thresholds in CPU-seconds:
// GREEN predicted < 30, YELLOW 30–38 (duty 100% -> 5% linear),
// RED >= 38 (duty 5%); RED exits only when the ACTUAL window < 32.
static const double kCpuSampleIntervalSec = 0.25;
static const double kCpuWindowSec = 60.0;
static const double kCpuBudgetSec = 48.0;
static const double kCpuGreenMaxSec = 30.0;
static const double kCpuYellowMaxSec = 38.0;
static const double kCpuRedExitSec = 32.0;
static const double kCpuMinDuty = 0.05;
// One guest timer tick (guest HZ=100 -> 10 ms); the hook sleeps
// (1-duty)/duty ticks' worth per tick, capped at 200 ms per call.
static const uint64_t kCpuTickQuantumNs = 10 * NSEC_PER_MSEC;
static const uint64_t kCpuTickMaxSleepNs = 200 * NSEC_PER_MSEC;
// Ring capacity: 250 ms cadence x 256 = 64 s > 60 s window.
#define ISH_CPU_RING_SIZE 256

// --- File-static shared state (atomics only — the two C callbacks run on
// guest threads and must never touch ObjC state or locks) -------------------

// Memory pressure as last reported by the DISPATCH_MEMORYPRESSURE source:
// 0 normal, 1 warn, 2 critical. Starts NORMAL; until the first event the
// fork guard's pressure gate reads NORMAL (documented gap: a fork storm
// in the first moments of abnormal pressure is bounded instead by the
// fork-rate governor + the anon cap, and the memory governor's
// avail-based BRAKE still engages).
static _Atomic int g_memPressure = 0;
// Mirror of the kernel footprint-brake state machine (kernel/mmap.c
// ish_set_memory_status) for status reporting: 0 OK, 1 BRAKE.
static _Atomic int g_memMirrorState = 0;
static _Atomic uint64_t g_memMirrorLimit = 0;
static _Atomic uint64_t g_memMirrorAvail = 0;
static _Atomic uint64_t g_memLastFeedMs = 0;
static _Atomic bool g_bootGovernorsStarted = false;

// Fork guard.
static _Atomic uint64_t g_forkGuardLimitBytes = 0;
static _Atomic uint64_t g_forkFootprintCacheBytes = 0;
static _Atomic uint64_t g_forkFootprintCacheMs = 0;
static _Atomic uint64_t g_forkStalls = 0;
static _Atomic uint64_t g_forkStallTimeouts = 0;

// Fork-rate governor (thermal-driven table; values set at boot).
static _Atomic unsigned g_forkRatePerSec = 0;
static _Atomic unsigned g_forkRateBurst = 0;

// Background CPU governor: duty in thousandths (1000 = full speed),
// state 0 off / 1 green / 2 yellow / 3 red, window + predicted seconds
// in milliseconds (the sampler writes them, the status snapshot reads them).
static _Atomic int g_cpuDutyMilli = 1000;
static _Atomic int g_cpuState = 0;
static _Atomic uint64_t g_cpuWindowMs = 0;
static _Atomic uint64_t g_cpuPredictedMs = 0;

// --- Pure C helpers --------------------------------------------------------

static uint64_t ish_dsh_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static uint64_t ish_dsh_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Whole-process physical footprint (task_info TASK_VM_INFO). 0 when it
// cannot be measured — callers treat 0 as "no reading", never as a real
// value (same convention as ISHKernel.hostPhysFootprintBytes).
static uint64_t ish_dsh_phys_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (uint64_t)info.phys_footprint;
}

// --- PURE-LOGIC-BEGIN ---
// Pure logic, unit-tested by the stage-2.5 Linux harness (the harness
// extracts this block verbatim — keep it free of ObjC and globals).

// Mirror of the kernel state machine in kernel/mmap.c ish_set_memory_status
// (verbatim arithmetic: avail*10 < limit brakes below 10% headroom,
// avail*100 < limit*15 holds BRAKE until above 15% — hysteresis).
// Returns 0 OK, 1 BRAKE.
static int ish_dsh_mem_next_state(int prev, uint64_t limit, uint64_t avail,
                                  bool critical) {
    if (critical) return 1;
    if (avail * 10 < limit) return 1;
    if (prev == 1 && avail * 100 < limit * 15) return 1;
    return 0;
}

// CPU governor decision (design §1.11 #4): next state + duty for a
// predicted window sum and the actual window sum. RED exits only when
// the ACTUAL window falls below 32 s; YELLOW duty falls linearly from
// 1.0 at 30 s to 0.05 at 38 s. States: 1 green, 2 yellow, 3 red.
static void ish_dsh_cpu_decide(double predicted, double windowSec,
                               int prevState, int *nextState, double *duty) {
    if (predicted >= 38.0) {
        *nextState = 3;
        *duty = 0.05;
        return;
    }
    if (prevState == 3) {
        if (windowSec >= 32.0) {
            *nextState = 3;
            *duty = 0.05;
            return;
        }
        // Falls through to the green/yellow decision below.
    }
    if (predicted >= 30.0) {
        *nextState = 2;
        *duty = 1.0 - (predicted - 30.0) / 8.0 * 0.95;
        if (*duty < 0.05) *duty = 0.05;
        return;
    }
    *nextState = 1;
    *duty = 1.0;
}

// Fork-guard limit: physical memory x 0.25, clamped to [500 MB, 2 GB]
// (design §2.7).
static uint64_t ish_dsh_fork_guard_limit(uint64_t physMem) {
    uint64_t limit = physMem / 4;
    if (limit < 500ULL * 1024 * 1024) limit = 500ULL * 1024 * 1024;
    if (limit > 2ULL * 1024 * 1024 * 1024) limit = 2ULL * 1024 * 1024 * 1024;
    return limit;
}

// --- PURE-LOGIC-END ---

// --- Memory governor tick --------------------------------------------------

// One feed: footprint + available -> the kernel's live jetsam allowance.
// Runs on the governor queue every 250 ms. A failed measurement skips
// the feed (the kernel's >2 s staleness rule then fails closed).
static void ish_dsh_memory_tick(void) {
    uint64_t footprint = ish_dsh_phys_footprint();
    uint64_t avail = (uint64_t)os_proc_available_memory();
    if (footprint == 0 || avail == 0) {
        NSLog(@"ISHResourceGovernor: memory tick could not measure "
              @"(footprint=%llu avail=%llu) — feed skipped, kernel fails "
              @"closed after 2 s without a feed",
              (unsigned long long)footprint, (unsigned long long)avail);
        return;
    }
    // Live jetsam allowance: what the app holds + what the OS will still
    // give it (kernel/mm.h: limit_bytes = phys_footprint + available).
    uint64_t limit = footprint + avail;
    bool critical = (atomic_load(&g_memPressure) == 2);
    int prev = atomic_load(&g_memMirrorState);
    int next = ish_dsh_mem_next_state(prev, limit, avail, critical);
    atomic_store(&g_memMirrorLimit, limit);
    atomic_store(&g_memMirrorAvail, avail);
    atomic_store(&g_memMirrorState, next);
    atomic_store(&g_memLastFeedMs, ish_dsh_monotonic_ms());
    if (next != prev) {
        NSLog(@"ISHResourceGovernor: memory brake %s — footprint %llu MB / "
              @"limit %llu MB (avail %llu MB)%s",
              next == 1 ? "ENGAGED" : "released",
              (unsigned long long)((limit - avail) >> 20),
              (unsigned long long)(limit >> 20),
              (unsigned long long)(avail >> 20),
              critical ? " [OS pressure critical]" : "");
    }
    ish_set_memory_status(limit, avail, critical);
}

// --- Fork guard callback ---------------------------------------------------

// Cached footprint for the guard: at most one task_info per second.
// Returns the cached value (0 only if nothing was ever measured).
static uint64_t ish_dsh_cached_footprint(void) {
    uint64_t now = ish_dsh_monotonic_ms();
    uint64_t cachedMs = atomic_load(&g_forkFootprintCacheMs);
    if (now - cachedMs < kForkFootprintCacheMs) {
        return atomic_load(&g_forkFootprintCacheBytes);
    }
    uint64_t fp = ish_dsh_phys_footprint();
    if (fp != 0) {
        atomic_store(&g_forkFootprintCacheBytes, fp);
        atomic_store(&g_forkFootprintCacheMs, now);
        return fp;
    }
    return atomic_load(&g_forkFootprintCacheBytes);
}

// [fork-guard] Called in sys_clone before a new task is created
// (kernel/fork.c). Runs on the forking thread; the task.h contract is
// "must not allocate or take kernel locks" — this uses only atomics,
// the cached footprint reading, and nanosleep. It NEVER denies
// (always returns 0): musl does not retry a failed fork, it exits 126
// and the work is lost, so a stall is the only safe backpressure.
// Stall condition (design §1.11 #3): system memory pressure is
// non-normal AND the app footprint exceeds the scaled limit.
static int ish_dsh_fork_memory_guard(void) {
    uint64_t limit = atomic_load(&g_forkGuardLimitBytes);
    if (limit == 0) return 0; // guard not configured yet
    if (atomic_load(&g_memPressure) == 0) return 0; // pressure normal
    uint64_t waitedNs = 0;
    bool counted = false;
    for (;;) {
        if (ish_dsh_cached_footprint() <= limit) return 0;
        if (atomic_load(&g_memPressure) == 0) return 0; // pressure eased
        if (waitedNs >= kForkGuardMaxStallNs) {
            atomic_fetch_add(&g_forkStallTimeouts, 1);
            NSLog(@"ISHResourceGovernor: fork guard stall timed out after "
                  @"10 s — releasing fork (pure delay, not backpressure)");
            return 0;
        }
        if (!counted) {
            atomic_fetch_add(&g_forkStalls, 1);
            counted = true;
        }
        struct timespec ts = { .tv_sec = 0,
                               .tv_nsec = (long)kForkGuardStallSliceNs };
        nanosleep(&ts, NULL);
        waitedNs += kForkGuardStallSliceNs;
    }
}

// --- Timer-tick throttle (background CPU governor) -------------------------

// Called by the kernel on every guest timer interrupt (INT_TIMER,
// kernel/calls.c). Sleeps (1-duty)/duty tick quanta per tick, so the
// guest thread's effective duty cycle is `duty`. Duty 1000 returns
// immediately (no sleep, no syscall). No allocation, no locks.
static int ish_dsh_timer_tick_throttle(void) {
    int dutyMilli = atomic_load(&g_cpuDutyMilli);
    if (dutyMilli >= 1000) return 0;
    if (dutyMilli < 50) dutyMilli = 50; // floor 5%
    uint64_t sleepNs = (uint64_t)(1000 - dutyMilli) * kCpuTickQuantumNs /
                       (uint64_t)dutyMilli;
    if (sleepNs > kCpuTickMaxSleepNs) sleepNs = kCpuTickMaxSleepNs;
    struct timespec ts = { .tv_sec = (time_t)(sleepNs / 1000000000ULL),
                           .tv_nsec = (long)(sleepNs % 1000000000ULL) };
    nanosleep(&ts, NULL);
    return 0;
}

// --- CPU sampler ring ------------------------------------------------------

typedef struct {
    uint64_t atNs;   // CLOCK_MONOTONIC timestamp of the sample
    double cpuSec;   // process CPU seconds consumed in this interval
} ISHCPUSample;

@implementation ISHResourceGovernor {
    dispatch_queue_t _governorQueue;
    dispatch_source_t _memTimer;
    dispatch_source_t _memPressureSource;
    dispatch_source_t _cpuTimer;
    BOOL _cpuRunning;
    // CPU sampler ring (governor queue only — no locks needed).
    ISHCPUSample _cpuRing[ISH_CPU_RING_SIZE];
    NSUInteger _cpuRingHead;
    NSUInteger _cpuRingCount;
    double _cpuLastTotalSec; // -1 until the first sample
    uint64_t _cpuSamplerStartNs;
    id _thermalObserver;
    id _bgObserver;
    id _fgObserver;
}

+ (ISHResourceGovernor *)shared {
    static dispatch_once_t once;
    static ISHResourceGovernor *shared = nil;
    dispatch_once(&once, ^{
        // alloc/init (+1 owned), never an autoreleased convenience
        // constructor — same rule as ISHKernel.shared (stage 1 build 12).
        shared = [[ISHResourceGovernor alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _governorQueue = dispatch_queue_create("me.zzuu.dsh.ish.governor",
                                               DISPATCH_QUEUE_SERIAL);
        _cpuLastTotalSec = -1;
    }
    return self;
}

// --- Boot-time guards ------------------------------------------------------

- (void)startBootGovernors {
    if (atomic_exchange(&g_bootGovernorsStarted, true)) return; // idempotent

    // 1. Memory governor: prime the feed BEFORE the guest boots. The
    //    first allocations happen during exec of init, long before a
    //    250 ms tick would land — until the feed exists the kernel is
    //    still on the legacy ledger cap (same reason as main.c
    //    ish_cli_memory_governor_start).
    ish_dsh_memory_tick();
    [self startMemoryTimerAndPressureSource];

    // 2. Fork guard. Inert until the first fork (no guest task exists
    //    before PID 1), so installing it here rather than at OpenMinis's
    //    boot step 6.5 is equivalent.
    uint64_t phys = [[NSProcessInfo processInfo] physicalMemory];
    uint64_t limit = ish_dsh_fork_guard_limit(phys);
    atomic_store(&g_forkGuardLimitBytes, limit);
    ish_set_fork_guard(ish_dsh_fork_memory_guard);
    NSLog(@"ISHResourceGovernor: fork guard installed (limit %llu MB = "
          @"phys %llu MB x 0.25, clamped [500 MB, 2 GB])",
          (unsigned long long)(limit >> 20),
          (unsigned long long)(phys >> 20));

    // 3. Fork-rate governor: thermal-driven, re-applied on change.
    [self applyForkRateForCurrentThermalState];
    __weak typeof(self) weakSelf = self;
    _thermalObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf applyForkRateForCurrentThermalState];
                }];

    // 4. Background CPU governor: auto lifecycle (begin on background,
    //    end on foreground). No silent-audio keep-alive (design §2.7).
    [self registerAppLifecycleObservers];

    NSLog(@"ISHResourceGovernor: boot governors started (memory 250 ms, "
          @"fork guard, fork-rate)");
}

- (void)startMemoryTimerAndPressureSource {
    _memTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       _governorQueue);
    if (!_memTimer) {
        NSLog(@"ISHResourceGovernor: memory timer source creation failed — "
              @"memory governor feed disabled");
    } else {
        dispatch_source_set_timer(_memTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  kMemGovernorIntervalNs,
                                  25 * NSEC_PER_MSEC); // 25 ms leeway
        dispatch_source_set_event_handler(_memTimer, ^{
            ish_dsh_memory_tick();
        });
        dispatch_resume(_memTimer);
    }

    // Memory-pressure source: the mask selects the levels to monitor.
    // mask=0 is rejected by dispatch_source_create on this iOS (it
    // returns NULL and the following set_event_handler crashed at boot
    // with EXC_BAD_ACCESS, build 19 crash log). Pass all three levels;
    // the handler maps the data bits to 0/1/2. If creation still fails,
    // the governor keeps working timer-only with pressure pinned NORMAL
    // (the documented fallback — the 250 ms footprint feed is the
    // primary mechanism, the pressure source only refines it).
    dispatch_source_t pressure = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
            DISPATCH_MEMORYPRESSURE_CRITICAL,
        _governorQueue);
    if (!pressure) {
        NSLog(@"ISHResourceGovernor: memory pressure source unavailable — "
              @"continuing timer-only (pressure NORMAL)");
        return;
    }
    _memPressureSource = pressure;
    dispatch_source_set_event_handler(pressure, ^{
        unsigned long data = dispatch_source_get_data(pressure);
        int state;
        if (data & DISPATCH_MEMORYPRESSURE_CRITICAL) state = 2;
        else if (data & DISPATCH_MEMORYPRESSURE_WARN) state = 1;
        else state = 0; // DISPATCH_MEMORYPRESSURE_NORMAL
        int prev = atomic_exchange(&g_memPressure, state);
        if (state != prev) {
            NSLog(@"ISHResourceGovernor: memory pressure %d -> %d "
                  @"(0 normal, 1 warn, 2 critical)", prev, state);
        }
    });
    dispatch_resume(pressure);
}

- (void)applyForkRateForCurrentThermalState {
    NSProcessInfoThermalState state =
        [NSProcessInfo processInfo].thermalState;
    unsigned perSec;
    switch (state) {
        case NSProcessInfoThermalStateNominal: perSec = kForkRateNominalPerSec; break;
        case NSProcessInfoThermalStateFair: perSec = kForkRateFairPerSec; break;
        case NSProcessInfoThermalStateSerious: perSec = kForkRateSeriousPerSec; break;
        case NSProcessInfoThermalStateCritical: perSec = kForkRateCriticalPerSec; break;
        default: perSec = kForkRateNominalPerSec; break;
    }
    unsigned burst = perSec / 2;
    ish_set_fork_rate_limit(perSec, burst);
    atomic_store(&g_forkRatePerSec, perSec);
    atomic_store(&g_forkRateBurst, burst);
    NSLog(@"ISHResourceGovernor: fork-rate limit %u/s burst %u "
          @"(thermal state %ld)", perSec, burst, (long)state);
}

- (void)registerAppLifecycleObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];
    __weak typeof(self) weakSelf = self;
    _bgObserver = [nc addObserverForName:
                       UIApplicationDidEnterBackgroundNotification
                   object:nil queue:main usingBlock:^(NSNotification *note) {
                       (void)note;
                       [weakSelf beginBackgroundCPUGovernor];
                       NSLog(@"ISHResourceGovernor: app backgrounded — "
                             @"CPU governor started");
                   }];
    _fgObserver = [nc addObserverForName:
                       UIApplicationWillEnterForegroundNotification
                   object:nil queue:main usingBlock:^(NSNotification *note) {
                       (void)note;
                       [weakSelf endBackgroundCPUGovernor];
                       NSLog(@"ISHResourceGovernor: app foregrounded — "
                             @"CPU governor stopped");
                   }];
    // Booted while already backgrounded (rare): start immediately.
    if ([UIApplication sharedApplication].applicationState ==
        UIApplicationStateBackground) {
        [self beginBackgroundCPUGovernor];
    }
}

// --- Background CPU governor -----------------------------------------------

- (void)beginBackgroundCPUGovernor {
    // Runs on the governor queue; safe from any thread except that
    // queue itself (callers are the main-queue lifecycle observers and
    // ISHKernel's public methods — never the governor queue).
    __block BOOL already = NO;
    dispatch_sync(_governorQueue, ^{
        if (_cpuRunning) { already = YES; return; }
        _cpuRunning = YES;
        _cpuRingHead = 0;
        _cpuRingCount = 0;
        _cpuLastTotalSec = -1;
        _cpuSamplerStartNs = ish_dsh_monotonic_ns();
        atomic_store(&g_cpuState, 1); // GREEN
        atomic_store(&g_cpuDutyMilli, 1000);
        atomic_store(&g_cpuWindowMs, 0);
        atomic_store(&g_cpuPredictedMs, 0);
        ish_set_timer_tick_hook(ish_dsh_timer_tick_throttle);
        _cpuTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           _governorQueue);
        if (!_cpuTimer) {
            // Same guard as the memory timer: never set a handler on a
            // NULL source (would crash in _dispatch_source_set_handler).
            _cpuRunning = NO;
            ish_set_timer_tick_hook(NULL);
            NSLog(@"ISHResourceGovernor: CPU timer source creation failed — "
                  @"background CPU governor disabled");
            return;
        }
        dispatch_source_set_timer(_cpuTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  (uint64_t)(kCpuSampleIntervalSec * NSEC_PER_SEC),
                                  25 * NSEC_PER_MSEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_cpuTimer, ^{
            [weakSelf cpuGovernorTick];
        });
        dispatch_resume(_cpuTimer);
    });
    if (!already) {
        NSLog(@"ISHResourceGovernor: background CPU governor started "
              @"(budget %.0f CPU-s / %.0f s window)", kCpuBudgetSec, kCpuWindowSec);
    }
}

- (void)endBackgroundCPUGovernor {
    __block BOOL wasRunning = NO;
    __block dispatch_source_t timer = NULL;
    dispatch_sync(_governorQueue, ^{
        if (!_cpuRunning) return;
        wasRunning = YES;
        _cpuRunning = NO;
        timer = _cpuTimer;
        _cpuTimer = NULL;
    });
    if (!wasRunning) return;
    // The hook is process-global: remove it before cancelling the timer
    // so no guest thread can observe a half-torn-down governor.
    ish_set_timer_tick_hook(NULL);
    atomic_store(&g_cpuDutyMilli, 1000);
    atomic_store(&g_cpuState, 0); // off
    if (timer) dispatch_source_cancel(timer);
    NSLog(@"ISHResourceGovernor: background CPU governor stopped");
}

// One 250 ms sample (governor queue only). Measures WHOLE-process CPU
// (getrusage RUSAGE_SELF) — the iOS background budget is per-app, and
// the guest tick is the only throttle lever we own.
- (void)cpuGovernorTick {
    if (!_cpuRunning) return;
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return; // try again next tick
    double total = (double)ru.ru_utime.tv_sec +
                   (double)ru.ru_utime.tv_usec / 1e6 +
                   (double)ru.ru_stime.tv_sec +
                   (double)ru.ru_stime.tv_usec / 1e6;
    uint64_t now = ish_dsh_monotonic_ns();
    double delta = 0;
    if (_cpuLastTotalSec >= 0) {
        delta = total - _cpuLastTotalSec;
        if (delta < 0) delta = 0; // rusage never goes backwards in practice
    }
    _cpuLastTotalSec = total;

    _cpuRing[_cpuRingHead] = (ISHCPUSample){ .atNs = now, .cpuSec = delta };
    _cpuRingHead = (_cpuRingHead + 1) % ISH_CPU_RING_SIZE;
    if (_cpuRingCount < ISH_CPU_RING_SIZE) _cpuRingCount++;

    // Window sums over samples younger than 60 s. `span` is the time the
    // surviving samples cover; before the window fills, the prediction
    // extrapolates the recent rate over the uncovered remainder, so the
    // governor reacts in seconds rather than waiting a full minute.
    double windowSec = 0;
    double last10Sec = 0;
    uint64_t oldestNs = now;
    for (NSUInteger i = 0; i < _cpuRingCount; i++) {
        NSUInteger idx = (_cpuRingHead + ISH_CPU_RING_SIZE - 1 - i) %
                         ISH_CPU_RING_SIZE;
        ISHCPUSample s = _cpuRing[idx];
        if (now - s.atNs > (uint64_t)(kCpuWindowSec * NSEC_PER_SEC)) break;
        windowSec += s.cpuSec;
        if (now - s.atNs <= (uint64_t)(10 * NSEC_PER_SEC)) last10Sec += s.cpuSec;
        oldestNs = s.atNs;
    }
    double spanSec = (double)(now - oldestNs) / NSEC_PER_SEC;
    if (spanSec > kCpuWindowSec) spanSec = kCpuWindowSec;
    double elapsedSec = (double)(now - _cpuSamplerStartNs) / NSEC_PER_SEC;
    double rateWindowSec = elapsedSec < 10.0 ? elapsedSec : 10.0;
    double rate10 = rateWindowSec > 0 ? last10Sec / rateWindowSec : 0;
    double predicted = windowSec + rate10 * (kCpuWindowSec - spanSec);

    int prevState = atomic_load(&g_cpuState);
    int nextState = prevState;
    double duty = 1.0;
    ish_dsh_cpu_decide(predicted, windowSec, prevState, &nextState, &duty);
    atomic_store(&g_cpuWindowMs, (uint64_t)(windowSec * 1000.0));
    atomic_store(&g_cpuPredictedMs, (uint64_t)(predicted * 1000.0));
    atomic_store(&g_cpuDutyMilli, (int)lround(duty * 1000.0));
    if (nextState != prevState) {
        atomic_store(&g_cpuState, nextState);
        NSLog(@"ISHResourceGovernor: CPU governor %s -> %s "
              @"(window %.1f CPU-s, predicted %.1f, duty %.0f%%)",
              prevState == 0 ? "off" : prevState == 1 ? "green" :
              prevState == 2 ? "yellow" : "red",
              nextState == 1 ? "green" : nextState == 2 ? "yellow" : "red",
              windowSec, predicted, duty * 100.0);
    } else {
        atomic_store(&g_cpuState, nextState);
    }
}

// --- Status ------------------------------------------------------------------

- (NSDictionary<NSString *, id> *)statusSnapshot {
    BOOL started = atomic_load(&g_bootGovernorsStarted);
    uint64_t nowMs = ish_dsh_monotonic_ms();
    uint64_t lastFeed = atomic_load(&g_memLastFeedMs);
    BOOL stale = !started || lastFeed == 0 || (nowMs - lastFeed > kMemStaleMs);
    BOOL braked = started && (stale || atomic_load(&g_memMirrorState) == 1);
    int pressure = atomic_load(&g_memPressure);
    NSString *pressureStr = pressure == 2 ? @"critical" :
                            pressure == 1 ? @"warn" : @"normal";
    NSString *memState = !started ? @"off" : (braked ? @"brake" : @"ok");
    int cpuState = atomic_load(&g_cpuState);
    NSString *cpuStr = cpuState == 3 ? @"red" :
                       cpuState == 2 ? @"yellow" :
                       cpuState == 1 ? @"green" : @"off";
    uint64_t rateThrottled = 0, rateBypassed = 0, rateSleepNs = 0;
    ish_fork_rate_stats(&rateThrottled, &rateBypassed, &rateSleepNs);
    return @{
        @"memoryGovernor": @{
            @"active": @(started),
            @"state": memState,
            @"staleFeed": @(stale),
            @"footprintMode": @(ish_footprint_mode()),
            @"limitBytes": @(atomic_load(&g_memMirrorLimit)),
            @"availableBytes": @(atomic_load(&g_memMirrorAvail)),
            @"pressure": pressureStr,
        },
        @"forkGuard": @{
            @"limitBytes": @(atomic_load(&g_forkGuardLimitBytes)),
            @"stalls": @(atomic_load(&g_forkStalls)),
            @"stallTimeouts": @(atomic_load(&g_forkStallTimeouts)),
        },
        @"forkRate": @{
            @"perSecond": @(atomic_load(&g_forkRatePerSec)),
            @"burst": @(atomic_load(&g_forkRateBurst)),
            @"throttled": @(rateThrottled),
            @"bypassed": @(rateBypassed),
            @"sleepMs": @(rateSleepNs / 1000000ULL),
        },
        @"cpuGovernor": @{
            @"active": @(cpuState != 0),
            @"state": cpuStr,
            @"duty": @((double)atomic_load(&g_cpuDutyMilli) / 1000.0),
            @"windowCpuSeconds": @((double)atomic_load(&g_cpuWindowMs) / 1000.0),
            @"predictedWindowCpuSeconds": @((double)atomic_load(&g_cpuPredictedMs) / 1000.0),
            @"budgetCpuSeconds": @(kCpuBudgetSec),
        },
    };
}

@end
