//  ISHSignalTestSupport.m
//  ISHCoexist — Stage 1 coexistence prototype. TEST ONLY. See header.
//
//  The benign prev handler is the harness's stand-in for Node/V8's
//  handler during tests ⑤⑥⑧. It is deliberately boring: count the call,
//  repair the fault if it knows how, otherwise longjmp to a checkpoint,
//  otherwise (nothing registered) restore SIG_DFL and let the fault
//  re-fault — the app dies with a truthful crash report rather than
//  spinning forever on a re-executed faulting instruction.

#import "ISHSignalTestSupport.h"
#import "ISHCrashHandler.h"

#include <execinfo.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// ish_thread_marker lives in libish_emu (asbestos.c). Setting it on a
// probe thread makes that thread look like an iSH thread to the handler
// (marker==1, in_jit==0) — exactly the stage 1.2 test ⑤ situation.
extern __thread int ish_thread_marker;

// --- Benign handler state -------------------------------------------------

static volatile sig_atomic_t g_benign_invocations = 0;

typedef struct { void *page; size_t size; } FixablePage;
static FixablePage g_fixable[8];
static int g_fixable_count = 0;

static __thread sigjmp_buf *g_longjmp_target = NULL; // per-thread arm

static void ish_benign_prev_handler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    g_benign_invocations++;

    // Repair path: fault inside a registered PROT_NONE page -> make it
    // readable/writable and return; the faulting instruction re-runs OK.
    if (info != NULL && info->si_addr != NULL) {
        uintptr_t addr = (uintptr_t)info->si_addr;
        for (int i = 0; i < g_fixable_count; i++) {
            uintptr_t base = (uintptr_t)g_fixable[i].page;
            if (addr >= base && addr < base + g_fixable[i].size) {
                mprotect(g_fixable[i].page, g_fixable[i].size,
                         PROT_READ | PROT_WRITE);
                return;
            }
        }
    }
    // Longjmp path (stack-overflow test): never return into the fault.
    if (g_longjmp_target != NULL) {
        sigjmp_buf *target = g_longjmp_target;
        g_longjmp_target = NULL;
        siglongjmp(*target, 1);
    }
    // No repair registered: do NOT return (a synchronous fault would
    // re-execute forever). Restore SIG_DFL and let it re-fault into a
    // real crash report.
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
}

// --- Swap in / restore -----------------------------------------------------

static struct sigaction g_saved_prod_prev[NSIG];
static int g_prod_prev_saved = 0;

int ish_test_swap_in_benign_prev(void) {
    static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
    // Save the production g_prev (Node's) before touching anything.
    if (!g_prod_prev_saved) {
        for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
            ISHSignalDisposition d;
            ish_crash_handler_prev_disposition(sigs[i], &d);
            memset(&g_saved_prod_prev[sigs[i]], 0, sizeof(struct sigaction));
            g_saved_prod_prev[sigs[i]].sa_flags = d.flags;
            if (d.isSiginfo) g_saved_prod_prev[sigs[i]].sa_sigaction =
                (void (*)(int, siginfo_t *, void *))d.handler;
            else g_saved_prod_prev[sigs[i]].sa_handler =
                (void (*)(int))d.handler;
        }
        g_prod_prev_saved = 1;
    }
    struct sigaction benign;
    memset(&benign, 0, sizeof(benign));
    benign.sa_sigaction = ish_benign_prev_handler;
    benign.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&benign.sa_mask);
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &benign, NULL);
    }
    // Reinstall ours: install queries current (benign) and records it as
    // g_prev, so forwarding now lands in the benign handler.
    return ish_crash_handler_install();
}

int ish_test_restore_production_chain(void) {
    if (!g_prod_prev_saved) return -1;
    static const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &g_saved_prod_prev[sigs[i]], NULL);
    }
    // Reinstall ours: g_prev is re-captured as the production handler.
    ish_crash_handler_install();
    g_prod_prev_saved = 0;
    return 0;
}

int ish_test_benign_invocations(void) {
    return (int)g_benign_invocations;
}

int ish_test_register_fixable_page(void *page, size_t size) {
    if (g_fixable_count >= 8 || page == NULL || size == 0) return -1;
    g_fixable[g_fixable_count].page = page;
    g_fixable[g_fixable_count].size = size;
    g_fixable_count++;
    return 0;
}

int ish_test_arm_longjmp(sigjmp_buf jmp) {
    g_longjmp_target = jmp;
    return 0;
}

void ish_test_disarm_longjmp(void) {
    g_longjmp_target = NULL;
}

// --- Probe threads ---------------------------------------------------------

static volatile sig_atomic_t g_probe_state[9]; // indexed by probe id
static pthread_t g_probe_thread[9];
static uintptr_t g_overflow_alt_base = 0;
static size_t g_overflow_alt_size = 0;

static void *ish_probe_ish_thread_fault(void *arg) {
    (void)arg;
    ish_thread_marker = 1; // look like an iSH thread; in_jit stays 0
    ish_crash_handler_install_altstack_for_current_thread();
    size_t page_size = (size_t)getpagesize();
    void *page = mmap(NULL, page_size, PROT_NONE,
                      MAP_PRIVATE | MAP_ANON, -1, 0);
    if (page == MAP_FAILED) { g_probe_state[5] = -1; return NULL; }
    ish_test_register_fixable_page(page, page_size);
    // Synchronous SIGSEGV. Our handler: main? no. in_jit? 0. marker? 1
    // -> branch 3, forward to g_prev (benign), which mprotects the page
    // and returns; the load then succeeds.
    volatile uint8_t v = *(volatile uint8_t *)page;
    (void)v;
    munmap(page, page_size);
    g_probe_state[5] = 1;
    return NULL;
}

static void *ish_probe_stack_overflow_fault(void *arg) {
    (void)arg;
    ish_crash_handler_install_altstack_for_current_thread();
    stack_t ss;
    if (sigaltstack(NULL, &ss) == 0 && !(ss.ss_flags & SS_DISABLE)) {
        g_overflow_alt_base = (uintptr_t)ss.ss_sp;
        g_overflow_alt_size = ss.ss_size;
    }
    // Recurse on a 64 KiB stack until the guard page faults. The benign
    // handler longjmps back here; the checkpoint below distinguishes the
    // first entry (recurse) from the longjmp return (report).
    static __thread sigjmp_buf jmp;
    if (sigsetjmp(jmp, 1) == 0) {
        ish_test_arm_longjmp(jmp);
        // Deliberately unbounded recursion. Each frame is ~64 bytes;
        // 64 KiB of stack overflows after ~1000 frames.
        void (*recurse)(int);
        // Local recursive function via a block (no nested-function
        // extension needed): use a self-referential block.
        __block void (^r)(int);
        r = ^(int depth) {
            volatile char pad[48];
            pad[0] = (char)depth;
            pad[47] = (char)(depth >> 8);
            r(depth + 1);
            // Use after the call: keeps this frame alive so the compiler
            // cannot turn the recursion into a tail-call loop (which
            // would never grow the stack and never fault).
            pad[0] = pad[47];
        };
        (void)recurse;
        r(0);
        // Unreachable: overflow must fault first.
        ish_test_disarm_longjmp();
        g_probe_state[6] = -1;
        return NULL;
    }
    // Longjmp landing: the fault happened, our handler ran, the benign
    // handler jumped back. Thread is alive and usable.
    ish_test_disarm_longjmp();
    g_probe_state[6] = 1;
    return NULL;
}

static void *ish_probe_double_fault(void *arg) {
    (void)arg;
    ish_crash_handler_install_altstack_for_current_thread();
    size_t page_size = (size_t)getpagesize();
    void *p1 = mmap(NULL, page_size, PROT_NONE,
                    MAP_PRIVATE | MAP_ANON, -1, 0);
    void *p2 = mmap(NULL, page_size, PROT_NONE,
                    MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p1 == MAP_FAILED || p2 == MAP_FAILED) {
        g_probe_state[8] = -1;
        return NULL;
    }
    ish_test_register_fixable_page(p1, page_size);
    ish_test_register_fixable_page(p2, page_size);
    volatile uint8_t v = *(volatile uint8_t *)p1; // fault #1, repaired
    (void)v;
    v = *(volatile uint8_t *)p2;                   // fault #2, repaired
    (void)v;
    munmap(p1, page_size);
    munmap(p2, page_size);
    g_probe_state[8] = 1;
    return NULL;
}

static int ish_spawn_probe(int probeId, void *(*fn)(void *)) {
    g_probe_state[probeId] = 0;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    if (probeId == 6) {
        // Small stack so the recursion overflows fast. PTHREAD_STACK_MIN
        // on Darwin arm64 is 16 KiB; 64 KiB leaves room for the handler
        // frame while still overflowing after ~1000 frames.
        pthread_attr_setstacksize(&attr, 64 * 1024);
    }
    int rc = pthread_create(&g_probe_thread[probeId], &attr, fn, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        g_probe_state[probeId] = -1;
        return -1;
    }
    return 0;
}

int ish_test_run_ish_thread_fault(void) {
    return ish_spawn_probe(5, ish_probe_ish_thread_fault);
}

int ish_test_run_stack_overflow_fault(void) {
    return ish_spawn_probe(6, ish_probe_stack_overflow_fault);
}

int ish_test_run_double_fault(void) {
    return ish_spawn_probe(8, ish_probe_double_fault);
}

int ish_test_probe_state(int probeId) {
    if (probeId < 0 || probeId > 8) return -1;
    return (int)g_probe_state[probeId];
}

uintptr_t ish_test_last_handler_entry_sp(void) {
    return ish_crash_handler_last_entry_sp;
}

void ish_test_overflow_altstack_range(uintptr_t *base, size_t *size) {
    if (base) *base = g_overflow_alt_base;
    if (size) *size = g_overflow_alt_size;
}
