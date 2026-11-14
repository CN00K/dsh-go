//  ISHSignalTestSupport.h
//  ISHCoexist — Stage 1 coexistence prototype
//
//  TEST-ONLY support for stage 1.2 signal tests ⑤⑥⑧. Not part of the
//  production signal path. It installs a BENIGN previous handler so the
//  harness can observe forwarding to g_prev WITHOUT killing the app:
//  the benign handler records the fault and either repairs it (mprotect
//  a registered PROT_NONE page readable) or longjmps back to a test
//  checkpoint (stack-overflow test). In production g_prev is Node/V8's
//  handler, which treats a non-Wasm fault as fatal — never install this
//  benign handler outside the signal tests.
//
//  Usage (harness order):
//    ish_test_swap_in_benign_prev()   // current := benign, then install
//                                     // ours, so g_prev == benign
//    ... run tests ⑤⑥⑧ ...
//    ish_test_restore_production_chain() // current := saved production
//                                     // prev (Node's), then install ours,
//                                     // so g_prev == Node's again
//  Test ④ (Node true crash) MUST run after the production chain is
//  restored, otherwise the benign handler would swallow it.

#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Install the benign handler as current, then (re)install our handler
/// so g_prev becomes the benign handler. Saves the production g_prev
/// (Node's) for restore. Returns 0 on success.
int ish_test_swap_in_benign_prev(void);

/// Restore the production chain saved by ish_test_swap_in_benign_prev().
/// Returns 0 on success, -1 if no production chain was saved.
int ish_test_restore_production_chain(void);

/// How many times the benign handler has been invoked (all signals).
int ish_test_benign_invocations(void);

/// Register a page that the benign handler may repair: when a fault's
/// si_addr falls inside [page, page+size), mprotect it PROT_READ|PROT_WRITE
/// and return (execution re-runs the faulting instruction, now OK).
/// At most 8 pages. Returns 0 on success.
int ish_test_register_fixable_page(void *page, size_t size);

/// Arm a siglongjmp checkpoint for the CALLING thread: if the benign
/// handler is invoked on this thread while armed, it siglongjmps back
/// with value 1 instead of repairing. Returns 0 on success.
/// `jmp` must stay alive until disarmed. Disarm with
/// ish_test_disarm_longjmp().
int ish_test_arm_longjmp(sigjmp_buf jmp);
void ish_test_disarm_longjmp(void);

/// --- Sacrificial-thread fault probes (each runs on its own thread) ---
/// The harness polls these; the probe threads never touch the main thread.

/// Test ⑤: fault on a thread marked as an iSH thread (ish_thread_marker=1,
/// in_jit==0). The faulting page is registered fixable, so the benign
/// handler repairs it and the thread survives and reports.
/// Returns 0 if the probe thread was started. Poll with
/// ish_test_probe_state().
int ish_test_run_ish_thread_fault(void);

/// Test ⑥: stack-overflow fault on a thread with a 64 KiB stack and its
/// own altstack. Arms a longjmp checkpoint; the handler must run on the
/// altstack (verified via ish_crash_handler_last_entry_sp) and the benign
/// handler longjmps back out. Returns 0 if started.
int ish_test_run_stack_overflow_fault(void);

/// Test ⑧: two consecutive recoverable faults on one thread (two
/// separately registered PROT_NONE pages). Returns 0 if started.
int ish_test_run_double_fault(void);

/// Probe state: 0 = not started / running, 1 = probe thread finished
/// normally (survived), 2 = probe thread started but not finished within
/// the harness timeout (only meaningful for the parked-thread variant —
/// unused while forwarding is the rule), -1 = probe thread died.
/// `probeId`: 5, 6 or 8.
int ish_test_probe_state(int probeId);

/// Handler-entry SP recorded by the last fault, for the altstack check.
/// (Read from ISHCrashHandler's ish_crash_handler_last_entry_sp.)
uintptr_t ish_test_last_handler_entry_sp(void);

/// Altstack range of the stack-overflow probe thread (test ⑥), for the
/// "did the handler run on the altstack?" comparison. Returns 0 if the
/// probe never installed one.
void ish_test_overflow_altstack_range(uintptr_t *base, size_t *size);

NS_ASSUME_NONNULL_END
