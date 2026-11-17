//  ISHCrashHandler.m
//  dsh-go — Stage 2 native bridge layer. See ISHCrashHandler.h.
//  Ported from the Stage 1 prototype (ISHCoexist/ISHCrashHandler.m)
//  unchanged except for this header comment. The [PROTO-DELTA-N] tags
//  are kept verbatim for traceability.
//
//  Mechanism borrowed from OpenMinis `src/ios/iSH/ISHKernel.m`:
//    install_jit_crash_handler()  L1004–1043
//    jit_crash_handler()          L470–~610
//    jit_forward_non_ish_signal() L461–469
//    jit_altstack_alloc()         L677–692
//  plus the JIT-recovery reference in ish-arm64 `main.c` L60–140.

#import "ISHCrashHandler.h"

#include <execinfo.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

// Field offsets into the JIT/emulator state. Taken from the
// Meson-generated header for the SAME libish build this app links
// (build_ish.sh copies it to IShArtifacts/include/ish/cpu-offsets.h),
// exactly as OpenMinis ISHKernel.m L412–421 does. The hand-copied
// literals drifted before (main.c documents segfault_addr 832 vs 840,
// jit_exit_sp 920 vs 936; a wrong jit_exit_sp restores SP from the wrong
// slot and the process dies with SIGILL) — never re-type these numbers;
// if the build does not produce cpu-offsets.h, the build is broken.
#include "ish/cpu-offsets.h"
#define CRASH_CPU_pc                  CPU_pc
#define CRASH_CPU_segfault_addr       CPU_segfault_addr
#define CRASH_CPU_segfault_was_write  CPU_segfault_was_write
#define CRASH_LOCAL_jit_exit_sp       LOCAL_jit_exit_sp

// Thread-local JIT recovery state (defined in libish_emu, asbestos.c).
extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;

// Assembly trampoline: returns INT_JIT_CRASH via fiber_exit (entry.S).
extern void jit_crash_trampoline(void);

// Diagnostics read by handle_interrupt after a recovered fault (calls.c).
extern __thread volatile uint64_t jit_last_host_fault;
extern __thread volatile uint64_t jit_last_x7;
extern __thread volatile uint64_t jit_last_x10;
extern __thread volatile int jit_crash_count;

// iSH execution-thread marker (asbestos.c): 1 on iSH guest threads,
// never set on foreign threads. Used to tell an iSH thread with
// in_jit==0 (between JIT runs) apart from a non-iSH thread.
extern __thread int ish_thread_marker;

// Native (AOT/JIT) code keeps pinned guest registers only in host
// registers; copy them back before the block re-runs. Lives in
// libish_emu (jit.c); a no-op while no native code is loaded. Weak, so a
// libish built without -Djit still links. (OpenMinis ISHKernel.m L402.)
extern bool jit_crash_sync(void *ucontext) __attribute__((weak_import));

volatile sig_atomic_t ish_crash_handler_invocations = 0;
volatile sig_atomic_t ish_crash_handler_jit_recoveries = 0;
volatile sig_atomic_t ish_crash_handler_forwards = 0;
volatile sig_atomic_t ish_crash_handler_last_sig = 0;
volatile sig_atomic_t ish_crash_handler_last_branch = -1;
volatile sig_atomic_t ish_crash_handler_last_forward_kind = -1;
volatile uintptr_t ish_crash_handler_last_entry_sp = 0;

/// The dispositions that were installed before ours, per signal.
/// Captured at install time; forwarding hands the fault to these.
static struct sigaction g_prev_crash_actions[NSIG];

static void ish_jit_crash_handler(int sig, siginfo_t *info, void *ctx);

// ---------------------------------------------------------------------------
// [PROTO-DELTA-1] Forwarding semantics — the core of mitigation ①.
//
// OpenMinis (ISHKernel.m L461–469 jit_forward_non_ish_signal) does NOT
// call the previous handler. It only records the fault
// (minis_crash_signal_record) and then calls minis_signal_finish()
// (CrashSignalPolicy.h L88–98): restore SIG_DFL, then return for a
// synchronous fault (it re-faults) or raise() for a sent signal. The
// previous handler — Node/V8's trap handler — is NEVER invoked, so a
// Wasm out-of-bounds fault that reaches the iSH handler is reported as a
// plain crash instead of being caught by V8, and Node's own crash
// handling is bypassed entirely.
//
// Mitigation ① (design §6 risk 1) replaces that with: hand the fault
// DIRECTLY to g_prev's sa_sigaction. Rules, in order:
//   (a) g_prev is a real SA_SIGINFO function pointer  -> call it, return.
//   (b) g_prev is a real plain sa_handler pointer     -> call it, return.
//   (c) g_prev is SIG_IGN                             -> return.
//   (d) g_prev is SIG_DFL (or nothing was ever recorded)
//                                                    -> restore SIG_DFL,
//       then return for a synchronous fault (si_code > 0: the faulting
//       instruction re-executes under DFL and the system records the REAL
//       exception) or raise(sig) for a sent signal (si_code <= 0:
//       SI_USER/SI_QUEUE; a sent signal does not re-fault on its own).
// The DFL sub-rule (d) is the only part kept from minis_signal_finish,
// because it is the only correct way to end a handler with no previous
// handler: resetting to DFL and re-faulting is what produces a truthful
// crash report. No crash-record call is made here: this prototype has no
// CrashSignalHandler, and recording must never precede forwarding.
// ---------------------------------------------------------------------------
static void ish_forward_restore_dfl_and_finish(int sig, siginfo_t *info) {
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    // si_code > 0: kernel-generated synchronous fault codes
    // (SEGV_MAPERR/SEGV_ACCERR/BUS_ADRERR/ILL_ILLOPC/...). Return and let
    // it re-fault under SIG_DFL. si_code <= 0: sent signal (SI_USER 0,
    // SI_QUEUE -1, ...); re-raise so it is delivered with SIG_DFL.
    if (info != NULL && info->si_code <= 0) {
        ish_crash_handler_last_forward_kind = 3;
        raise(sig);
    } else {
        ish_crash_handler_last_forward_kind = 2;
    }
}

static void ish_forward_to_prev(int sig, siginfo_t *info, void *ctx) {
    ish_crash_handler_forwards++;
    if (sig <= 0 || sig >= NSIG) {
        ish_crash_handler_last_forward_kind = 5;
        return;
    }
    struct sigaction prev = g_prev_crash_actions[sig];
    if (prev.sa_flags & SA_SIGINFO) {
        void *fn = (void *)prev.sa_sigaction;
        if (fn == NULL) {
            // SIG_DFL recorded (sa_sigaction NULL under SA_SIGINFO).
            ish_forward_restore_dfl_and_finish(sig, info);
            return;
        }
        if (fn == (void *)SIG_IGN) {
            ish_crash_handler_last_forward_kind = 4;
            return;
        }
        if (fn == (void *)ish_jit_crash_handler) {
            // Should not happen (install skips recording ourselves), but
            // never call ourselves: fall back to the DFL path.
            ish_forward_restore_dfl_and_finish(sig, info);
            return;
        }
        // (a) Real SA_SIGINFO predecessor — Node/V8's trap handler in
        // production. Call it directly and return; it owns the fault now.
        ish_crash_handler_last_forward_kind = 0;
        prev.sa_sigaction(sig, info, ctx);
        return;
    }
    // Plain (non-SA_SIGINFO) predecessor.
    if (prev.sa_handler == SIG_DFL) {
        ish_forward_restore_dfl_and_finish(sig, info);
        return;
    }
    if (prev.sa_handler == SIG_IGN) {
        ish_crash_handler_last_forward_kind = 4;
        return;
    }
    if (prev.sa_handler != NULL) {
        // (b) Real plain handler.
        ish_crash_handler_last_forward_kind = 1;
        prev.sa_handler(sig);
        return;
    }
    ish_crash_handler_last_forward_kind = 5;
}

// ---------------------------------------------------------------------------
// Altstack. Copied in mechanism from OpenMinis jit_altstack_alloc()
// (ISHKernel.m L677–692): a signal altstack in its own mmap'd mapping
// with a PROT_NONE guard page on each side. It used to be a 128 KB static
// array in __bss, between the TLV descriptors and Swift's once tokens;
// anything running past either end silently overwrote those words
// (2026-10-05 crash). An overrun now faults at the guard page with its
// own address. NULL when the mapping fails: no altstack, signals run on
// the thread stack. The mapping is intentionally never freed (process
// lifetime); every installing thread gets its OWN — never a shared
// static altstack.
// ---------------------------------------------------------------------------
static void *ish_altstack_alloc(size_t size) {
    size_t page = (size_t)getpagesize();
    size = (size + page - 1) & ~(page - 1);
    size_t total = size + 2 * page;
    char *base = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base == MAP_FAILED) return NULL;
    if (mprotect(base, page, PROT_NONE) != 0 ||
        mprotect(base + page + size, page, PROT_NONE) != 0) {
        munmap(base, total);
        return NULL;
    }
    return base + page;
}

int ish_crash_handler_install_altstack_for_current_thread(void) {
    stack_t old;
    if (sigaltstack(NULL, &old) == 0 &&
        !(old.ss_flags & SS_DISABLE) && old.ss_sp != NULL) {
        return 0; // Keep an altstack this thread already has.
    }
    void *altstack = ish_altstack_alloc(SIGSTKSZ);
    if (altstack == NULL) {
        NSLog(@"ISHCrashHandler: guarded signal altstack mmap failed - "
              @"crash signals run on the thread stack");
        return -1;
    }
    stack_t ss = { .ss_sp = altstack, .ss_size = SIGSTKSZ, .ss_flags = 0 };
    return sigaltstack(&ss, NULL);
}

int ish_crash_handler_install(void) {
    ish_crash_handler_install_altstack_for_current_thread();
    // [PROTO-DELTA-3] No BSS canary (OpenMinis bss_canary_start()): the
    // canary existed to detect the old shared-static-altstack overwrite.
    // With per-thread mmap'd altstacks there is no static array to guard.
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = ish_jit_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    // SIGABRT intentionally NOT handled — it is used by the system
    // (assert(), Swift runtime, malloc failure) and intercepting it
    // prevents normal crash reporting and can mask OOM conditions.
    // (Same exclusion as OpenMinis ISHKernel.m L1038–1040.)
    static const int crash_signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
    for (size_t i = 0; i < sizeof(crash_signals) / sizeof(crash_signals[0]); i++) {
        int s = crash_signals[i];
        struct sigaction current;
        if (sigaction(s, NULL, &current) == 0) {
            // A second install must not record our own handler as
            // "previous", or the forward path would loop.
            int isOurs = (current.sa_flags & SA_SIGINFO) &&
                         current.sa_sigaction == ish_jit_crash_handler;
            if (!isOurs) g_prev_crash_actions[s] = current;
        }
        sigaction(s, &sa, NULL);
    }
    NSLog(@"ISHCrashHandler: JIT crash recovery handler installed "
          @"(forwards non-JIT faults to g_prev)");
    return 0;
}

void *ish_crash_handler_function(void) {
    return (void *)ish_jit_crash_handler;
}

void ish_crash_handler_current_disposition(int sig, ISHSignalDisposition *out) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    if (sig <= 0 || sig >= NSIG) return;
    struct sigaction cur;
    if (sigaction(sig, NULL, &cur) != 0) return;
    out->flags = (unsigned int)cur.sa_flags;
    out->isSiginfo = (cur.sa_flags & SA_SIGINFO) != 0;
    out->handler = out->isSiginfo ? (void *)cur.sa_sigaction
                                  : (void *)cur.sa_handler;
}

void ish_crash_handler_prev_disposition(int sig, ISHSignalDisposition *out) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    if (sig <= 0 || sig >= NSIG) return;
    struct sigaction prev = g_prev_crash_actions[sig];
    out->flags = (unsigned int)prev.sa_flags;
    out->isSiginfo = (prev.sa_flags & SA_SIGINFO) != 0;
    out->handler = out->isSiginfo ? (void *)prev.sa_sigaction
                                  : (void *)prev.sa_handler;
}

int ish_crash_handler_restore_prev_chain(void) {
    static const int crash_signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
    for (size_t i = 0; i < sizeof(crash_signals) / sizeof(crash_signals[0]); i++) {
        int s = crash_signals[i];
        sigaction(s, &g_prev_crash_actions[s], NULL);
    }
    return ish_crash_handler_install();
}

uint64_t ish_host_phys_footprint_bytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        return info.phys_footprint;
    }
    return 0;
}

uint64_t ish_host_available_memory_bytes(void) {
    return (uint64_t)os_proc_available_memory();
}

// ---------------------------------------------------------------------------
// The handler itself. Structure mirrors OpenMinis jit_crash_handler()
// (ISHKernel.m L470–~610) with exactly two behavioural changes, both
// tagged below. Everything else — register sync, exit_sp check, PC
// rewrite to the trampoline — is the same mechanism.
// ---------------------------------------------------------------------------
static void ish_jit_crash_handler(int sig, siginfo_t *info, void *ctx) {
    ish_crash_handler_invocations++;
    ish_crash_handler_last_sig = sig;
#if defined(__aarch64__)
    {
        uintptr_t sp;
        __asm__ volatile("mov %0, sp" : "=r"(sp));
        ish_crash_handler_last_entry_sp = sp;
    }
#endif

    // The main thread is never an iSH thread: forward BEFORE touching any
    // `__thread` variable. Reading `in_jit` / `ish_thread_marker` calls
    // the TLV descriptor's thunk; in the 2026-10-05 crash that thunk had
    // been zeroed, so the handler itself jumped to 0x0 and the report
    // showed only "PC 0 / CODESIGNING Invalid Page" instead of the real
    // fault in the main thread. (OpenMinis L470–480, [T-crash-quickaction-tlv].)
    if (pthread_main_np()) {
        ish_crash_handler_last_branch = 0;
        ish_forward_to_prev(sig, info, ctx);
        return;
    }

#ifdef __aarch64__
    // JIT recovery: only when the fault happened inside JIT-translated
    // native code (stale TLB pointers from concurrent CoW). Redirect to
    // jit_crash_trampoline so the block re-runs in the gadget interpreter.
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;

        // _cpu is in x1 — pointer to cpu_state within fiber_frame.
        uint64_t cpu_ptr = uc->uc_mcontext->__ss.__x[1];

        // [T-jit-recovery-offsets] Never resume on a stack pointer that
        // is not this thread's: a bad one faults again with nowhere to
        // put the signal frame, and XNU then kills the WHOLE app
        // (SIGILL). fiber_enter saved exit_sp above the frames we are
        // unwinding, so it must be 16-byte aligned and lie in
        // (current sp, top of this thread's stack]. If not, fall through
        // to the marker check below (do NOT attempt recovery).
        uint64_t exit_sp = *(uint64_t *)(cpu_ptr + CRASH_LOCAL_jit_exit_sp);
        uint64_t cur_sp = uc->uc_mcontext->__ss.__sp;
        uint64_t stack_top = (uint64_t)pthread_get_stackaddr_np(pthread_self());
        bool sp_ok = exit_sp != 0 && (exit_sp & 0xf) == 0 &&
                     exit_sp > cur_sp && exit_sp <= stack_top;
        if (sp_ok) {
            if (jit_crash_sync) jit_crash_sync(uc);

            // Reconstruct guest segfault_addr from registers.
            uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
            uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
            uint64_t guest_addr = (x7 - x10) & 0xffffffffffffULL;

            jit_last_host_fault = (uint64_t)info->si_addr;
            jit_last_x7 = x7;
            jit_last_x10 = x10;
            jit_crash_count++;

            // Determine read/write from host ESR (bit 6 WnR).
            uint64_t esr = uc->uc_mcontext->__es.__esr;
            bool was_write = (esr & 0x40) != 0;

            // Write crash info directly to cpu_state. segfault_was_write
            // is a `bool`: store 1 byte (the gadgets use strb), not an int.
            *(uint64_t *)(cpu_ptr + CRASH_CPU_segfault_addr) = guest_addr;
            *(uint8_t *)(cpu_ptr + CRASH_CPU_segfault_was_write) = (uint8_t)was_write;
            *(uint64_t *)(cpu_ptr + CRASH_CPU_pc) = (uint64_t)jit_saved_pc;

            // Restore SP to the value saved by fiber_enter.
            uc->uc_mcontext->__ss.__sp = exit_sp;

            // Redirect execution to crash trampoline.
            uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;

            // Unblock signal so it can fire again.
            sigset_t unblock;
            sigemptyset(&unblock);
            sigaddset(&unblock, sig);
            sigprocmask(SIG_UNBLOCK, &unblock, NULL);

            ish_crash_handler_last_branch = 1;
            ish_crash_handler_jit_recoveries++;
            return;
        }
        char msg[160];
        int mlen = snprintf(msg, sizeof(msg),
            "\n=== iSH JIT recovery refused: exit_sp 0x%llx outside "
            "(sp 0x%llx, top 0x%llx] ===\n",
            (unsigned long long)exit_sp, (unsigned long long)cur_sp,
            (unsigned long long)stack_top);
        write(STDERR_FILENO, msg, mlen);
    }
#endif

    // `in_jit` is 0 here (the in_jit==1 case was handled above). Use the
    // separate thread-local marker set when iSH threads start, to
    // distinguish iSH threads with in_jit==0 (between JIT runs) from
    // non-iSH threads (never set). (OpenMinis L543–553.)
    if (!ish_thread_marker) {
        ish_crash_handler_last_branch = 2;
        ish_forward_to_prev(sig, info, ctx);
        return;
    }
    // Branch 3: non-JIT fault on an iSH guest thread.
    // [PROTO-DELTA-1b RESTORED for AOT (build 49)] OpenMinis PARKED this
    // fault (log diagnostics + block all signals + select() forever) so
    // that only the faulting guest thread died and the app survived.
    // The prototype forwarded it to g_prev instead, but g_prev is now
    // Node/V8's trap handler, which treats a non-Wasm fault as fatal
    // (SIG_DFL + re-raise) and kills the whole app — the suspected cause
    // of the AOT builds 25–28 terminal failures. Park it here, as
    // OpenMinis does. (Stage 1.2 test ⑤ asserted the forward; that
    // expectation is superseded now that Node owns g_prev.)
    ish_crash_handler_last_branch = 3;
    {
        char buf[512];
        int len;
        ucontext_t *uc = (ucontext_t *)ctx;
        len = snprintf(buf, sizeof(buf), "\n=== iSH GUEST CRASH: signal %d ===\nfault addr: %p\n", sig, info->si_addr);
        write(STDERR_FILENO, buf, len);
#ifdef __aarch64__
        len = snprintf(buf, sizeof(buf),
            "pc:  0x%llx\nlr:  0x%llx\nsp:  0x%llx\n"
            "x0:  0x%llx\nx1:  0x%llx\nx2:  0x%llx\n"
            "x7:  0x%llx\nx28: 0x%llx\n",
            uc->uc_mcontext->__ss.__pc, uc->uc_mcontext->__ss.__lr,
            uc->uc_mcontext->__ss.__sp,
            uc->uc_mcontext->__ss.__x[0], uc->uc_mcontext->__ss.__x[1],
            uc->uc_mcontext->__ss.__x[2],
            uc->uc_mcontext->__ss.__x[7], uc->uc_mcontext->__ss.__x[28]);
        write(STDERR_FILENO, buf, len);
#endif
        void *bt[20];
        int n = backtrace(bt, 20);
        backtrace_symbols_fd(bt, n, STDERR_FILENO);

        // Block all signals and suspend this thread forever.
        // pthread_exit() triggers SIGTRAP on iOS in certain thread states.
        sigset_t all;
        sigfillset(&all);
        pthread_sigmask(SIG_BLOCK, &all, NULL);
        select(0, NULL, NULL, NULL, NULL);
        __builtin_unreachable();
    }
}
