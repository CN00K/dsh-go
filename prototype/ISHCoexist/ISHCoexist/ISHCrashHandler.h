//  ISHCrashHandler.h
//  ISHCoexist — Stage 1 coexistence prototype (dsh-go route D, §3 stage 1.2)
//
//  Signal handler that lets the iSH JIT crash-recovery path coexist with
//  NodeMobile/V8's trap handler in one process. Mechanism borrowed from
//  OpenMinis `src/ios/iSH/ISHKernel.m` (install_jit_crash_handler L1004–1043,
//  jit_crash_handler L470–, jit_forward_non_ish_signal L461–469); the code
//  here is rewritten for this prototype, NOT copied verbatim, and the
//  forwarding semantics are deliberately changed — see [PROTO-DELTA-1]
//  below and §"Changes vs OpenMinis" in the staging README.
//
//  INSTALL ORDER (design §6 risk 1, mitigation ① — mandatory):
//  install this handler ONLY AFTER NodeMobile has initialised, so that
//  g_prev captures Node/V8's handler. bootWithRootPath: does NOT install
//  it (unlike OpenMinis boot step 0); the coordinator installs it between
//  the Node start and the iSH boot.

#import <Foundation/Foundation.h>
#include <signal.h>

NS_ASSUME_NONNULL_BEGIN

/// Snapshot of one signal's disposition, for the stage 1.2 test ①.
/// `handler` is the raw sa_sigaction/sa_handler value: NULL == SIG_DFL,
/// (void *)1 == SIG_IGN, anything else is a function pointer.
/// `isSiginfo` says whether SA_SIGINFO was set (i.e. whether `handler`
/// must be read as sa_sigaction rather than sa_handler).
typedef struct {
    void *handler;
    unsigned int flags;
    int isSiginfo;
} ISHSignalDisposition;

/// Install the handler for SIGSEGV / SIGBUS / SIGILL / SIGTRAP
/// (SA_SIGINFO | SA_ONSTACK), with a per-thread guarded altstack for the
/// calling thread. Saves whatever was installed before into g_prev
/// (skipping a previous install of this same handler, so a second install
/// cannot record itself as "previous" and loop). Returns 0 on success.
int ish_crash_handler_install(void);

/// Install a guarded altstack (SIGSTKSZ + PROT_NONE guard page on each
/// side, mmap'd — never a shared static array) for the calling thread.
/// No-op if this thread already has an enabled altstack. Returns 0 on
/// success, -1 if the mapping failed (signals then run on the thread
/// stack). Used by ish_crash_handler_install() and by test threads that
/// need their own altstack before faulting (stage 1.2 test ⑥).
int ish_crash_handler_install_altstack_for_current_thread(void);

/// Our handler's address (for test ①: "is iSH's handler outermost?").
void *ish_crash_handler_function(void);

/// Current disposition of `sig` (what sigaction() reports right now).
void ish_crash_handler_current_disposition(int sig, ISHSignalDisposition *out);

/// The disposition captured into g_prev for `sig` at install time
/// (what a forwarded fault is handed to). Zeroed struct if never installed.
void ish_crash_handler_prev_disposition(int sig, ISHSignalDisposition *out);

/// Reinstall the captured g_prev dispositions as the current handlers,
/// then reinstall our handler (which re-captures g_prev). Restores the
/// production chain after a test temporarily swapped g_prev — see
/// ISHSignalTestSupport. Returns 0 on success.
int ish_crash_handler_restore_prev_chain(void);

/// Host memory-footprint helpers for stage 1.3 sampling.
/// phys_footprint from TASK_VM_INFO; available memory from
/// os_proc_available_memory() (the live jetsam distance).
uint64_t ish_host_phys_footprint_bytes(void);
uint64_t ish_host_available_memory_bytes(void);

/// --- Handler diagnostics (written by the handler itself) ---
/// All plain async-signal-safe stores; the harness reads them after a
/// fault to verify which path the handler took. No locks, no allocation,
/// no NSLog inside the handler.
/// [PROTO-DELTA-4] These counters do not exist in OpenMinis; they exist
/// only so stage 1.2 tests can observe the handler without a debugger.
extern volatile sig_atomic_t ish_crash_handler_invocations;  // entries
extern volatile sig_atomic_t ish_crash_handler_jit_recoveries; // in_jit==1 recoveries
extern volatile sig_atomic_t ish_crash_handler_forwards;     // forwards to g_prev
extern volatile sig_atomic_t ish_crash_handler_last_sig;     // last signal seen
extern volatile sig_atomic_t ish_crash_handler_last_branch;  // 0=main-thread fwd,
    // 1=JIT recovery, 2=non-iSH-thread fwd, 3=iSH-thread non-JIT fwd
extern volatile sig_atomic_t ish_crash_handler_last_forward_kind; // 0=called prev
    // sa_sigaction, 1=called prev sa_handler, 2=SIG_DFL + sync re-fault,
    // 3=SIG_DFL + re-raise (sent signal), 4=SIG_IGN return, 5=no prev recorded
extern volatile uintptr_t ish_crash_handler_last_entry_sp;   // SP on handler entry

NS_ASSUME_NONNULL_END
