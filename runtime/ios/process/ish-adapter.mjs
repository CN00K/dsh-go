// iSH bridge adapter for the 1.1.1 VirtualSubprocessRuntime (dsh-go port).
//
// The bridge (./ish-bridge.mjs) presents a ChildProcess-shaped spawn
// (spawnIshExec) and a node-pty-shaped terminal (ishPtySpawn). The 1.1.1
// virtual runtime speaks a different handle shape (collected readers,
// done/started promises, terminate/waitForExit/start). This module
// converts between the two. It is iOS-only, imported by the
// specialize-runtime.py edits to runtime/ohos/process/runtime.mjs. The
// adapter installs the bridge lazily in the calling thread on first use
// (the preload only installs it on the main thread, while the engine app
// runs in the engine worker thread), and returns undefined from both
// entry points only for non-guest argv — then the virtual shell /
// virtual PTY error run exactly as in stock 1.1.1.
//
// Confinement: the ticket unwrap in VirtualSubprocessRuntime.spawn has
// already run before this adapter is called (confine() validated the
// cwd/mode when the ticket was issued), and the bridge's toGuest()
// rejects every host path outside the workspace and the rootfs data
// dir. A logical workspace path (a user-granted external directory)
// has no guest mapping, and a policy carrying a grant limits the
// session to that directory while the guest can only ever see the
// workspace bind mount — so both decline here (M-15) and the virtual
// runtime rejects the spawn explicitly instead of running it in the
// guest default directory. See ENGINE_HOOK.md.
import { basename } from 'node:path';
import { randomUUID } from 'node:crypto';
import { PassThrough } from 'node:stream';
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output';
import { scrubbedParentEnv } from '@deepseek-ai/dsh-subprocess';
import { isLogicalWorkspacePath } from '../../ohos/process/files/process-authority.mjs';
import { ISH_RUNNER_COMMAND, spawnIshExec, ishPtySpawn, ishWorkerExec, installIshBridge, nextSyntheticPid, toGuest } from './ish-bridge.mjs';

const ISH_PTY_SYMBOL = Symbol.for('dsh.ish.pty');

// True when installIshBridge() has run in this thread. The preload installs
// the bridge on the main thread only, but the engine app (and therefore this
// adapter) runs in the engine worker thread, where that install never
// landed — on device both entry points bailed to the virtual shell /
// virtual PTY error even though the loopback was up. Install lazily on
// first use, in the calling thread; the guard keeps each thread to a
// single install. (T-2) installIshBridge is documented as never
// throwing, but nothing in its body guarantees that: if it does throw,
// catch it here, log it once, and keep the message in
// bridgeInstallDetail so the caller can report why the bridge is
// unavailable instead of silently falling back.
let bridgeInstallFailed = false;
let bridgeInstallDetail = null;
const bridgeInstalled = () => globalThis[ISH_PTY_SYMBOL] !== undefined;
const ensureBridge = () => {
  if (bridgeInstalled()) return true;
  try {
    installIshBridge();
  } catch (error) {
    bridgeInstallDetail = error?.message ?? String(error);
    if (!bridgeInstallFailed) {
      bridgeInstallFailed = true;
      console.error(`[ish-adapter] installIshBridge failed, falling back to the virtual shell: ${bridgeInstallDetail}`);
    }
    return false;
  }
  return bridgeInstalled();
};

// Only agent bash goes to the guest as a shell command: ['bash',
// '-c', command]. Agent rg/git/node/gh/python3/pip go to the guest
// as a direct argv exec (B): the argv is passed verbatim, no shell
// is involved. Anything else (other commands, 'sh', node scripts)
// stays virtual.
const isBashArgv = (argv) => Array.isArray(argv) && argv.length === 3
  && basename(argv[0]) === 'bash' && argv[1] === '-c' && typeof argv[2] === 'string';

/** Guest CLI commands routed as a direct argv exec (B). */
const GUEST_CLI_COMMANDS = new Set(['rg', 'git', 'node', 'gh', 'python3', 'pip', 'pip3']);

/**
 * The guest CLI name for a direct argv exec, or null. All elements
 * must be strings; the command itself must be a bare name (a path
 * such as /usr/bin/rg is not an agent CLI call — it stays virtual).
 */
const guestCliName = (argv) => {
  if (!Array.isArray(argv) || argv.length === 0
    || argv.some((a) => typeof a !== 'string' || a.length === 0)) return null;
  const name = basename(argv[0]);
  if (name !== argv[0]) return null;
  return GUEST_CLI_COMMANDS.has(name) ? name : null;
};

/**
 * Adapt one bash spawn to the virtual handle shape, or return undefined
 * to let VirtualSubprocessRuntime.spawn run its virtual shell.
 *
 * The exec starts immediately (spawnIshExec begins the HTTP request on
 * call), so start() is a no-op and done resolves even if the caller
 * never calls start(). stdin 'pipe' falls through: the virtual shell
 * rejects interactive stdin for bash (ERR_OHOS_STREAM_UNAVAILABLE) and
 * the adapter preserves that contract instead of silently dropping
 * bytes the bridge only collects for 25ms.
 */
export function ishSpawnFor(argv, spec, { temporaryRoot, onSpillFailure = () => {}, policy, concurrent } = {}) {
  // M-15: a logical workspace cwd (or a policy carrying a grant) has no
  // guest mapping: toGuest() returns null and the bridge would silently
  // run in the guest default directory, outside the granted directory.
  // Decline before installing the bridge so the virtual runtime rejects
  // the spawn explicitly (ERR_WORKSPACE_CONFINEMENT_REQUIRED without a
  // grant, ERR_WORKSPACE_SCOPE_UNSUPPORTED for node/git with one).
  if (isLogicalWorkspacePath(spec.cwd) || policy?.grant) return undefined;
  const isBash = isBashArgv(argv);
  // B: agent rg/git/node/gh/python3/pip go to the guest as a direct
  // argv exec (no shell). `node` is special: pluginNode spawns `node`
  // for engine plugin scripts, so it is only routed when the caller
  // says this is the agent-facing (non-concurrent) runtime; the other
  // CLIs have no such collision and route unless explicitly concurrent.
  // (The specialize patch passes concurrent: this.#concurrent.)
  const cliName = isBash ? null : guestCliName(argv);
  const isCli = cliName !== null && (cliName === 'node'
    ? concurrent === false
    : concurrent !== true);
  if (!ensureBridge() || (!isBash && !isCli)) return undefined;
  if (spec.stdio.control === 'pipe' || spec.stdio.stdin === 'pipe') return undefined;

  const collected = {};
  const output = {};
  const input = undefined; // bash stdin is batch data ({data}) or 'ignore', never a live pipe
  for (const label of ['stdout', 'stderr']) {
    const mode = spec.stdio[label];
    if (mode === 'pipe') output[label] = new PassThrough();
    else if (mode !== 'inherit') collected[label] = new OutputCollector(mode.maxBytes, label, mode.spill && {
      maxBytes: mode.spill.maxBytes, dir: temporaryRoot, onFailure: onSpillFailure,
    });
  }
  const write = (label, bytes) => {
    if (collected[label]) collected[label].push(bytes);
    else if (output[label]) return output[label].write(bytes);
    else return process[label].write(bytes);
    return true;
  };

  // Same env construction as VirtualSubprocessRuntime.spawn; guestEnv()
  // inside the bridge drops the host paths (PATH/HOME/TMPDIR/DSH_HOME)
  // and only forwards DSH_SESSION_ID / locale / TERM-on-pty.
  const env = { ...scrubbedParentEnv(), ...spec.env };
  for (const [key, value] of Object.entries(env)) if (value === undefined) delete env[key];

  // spawnIshExec expects the confined argv (['/ish-runner', '--', ...]);
  // extractBashCommand splits at '--'. The '--' re-wrap is the adapter's
  // own: virtual.spawn already unwrapped the ohos ticket to the plain
  // ['bash', '-c', command] argv. B: a CLI argv goes verbatim (no wrap)
  // — spawnIshExec detects a non-bash argv as argv mode.
  // H-1: the ticket unwrap already validated the session mode; forward
  // it so the server can refuse a read-only exec (the workspace bind
  // mount is always writable, so the virtual path's EACCES enforcement
  // has no equivalent here unless the server denies per request).
  const readOnly = policy?.mode === 'read-only';
  const child = spawnIshExec(isBash ? [ISH_RUNNER_COMMAND, '--', ...argv] : argv, {
    cwd: spec.cwd,
    env,
    signal: spec.signal,
    stdio: [spec.stdio.stdin === 'ignore' ? 'ignore' : 'pipe', 'pipe', 'pipe'],
    ...(readOnly ? { readOnly: true } : {}),
  });

  const completion = Promise.withResolvers();
  const gone = Promise.withResolvers();
  const started = Promise.withResolvers();
  completion.promise.catch(() => {});
  gone.promise.catch(() => {});
  started.promise.catch(() => {});
  let settled = false;
  let didStart = false;
  let rangeFailure;
  let outcome = { exitCode: 1, signal: null };
  child.stdout?.on('data', (chunk) => write('stdout', chunk));
  child.stderr?.on('data', (chunk) => write('stderr', chunk));
  child.once('spawn', () => { didStart = true; started.resolve(); });
  child.once('error', (error) => {
    // The bridge fails closed with exit 1 + a detail line on stderr and
    // never emits 'error' in practice; this is a backstop only.
    if (settled) return;
    write('stderr', Buffer.from(`ISH_BRIDGE_UNAVAILABLE: ${error?.message ?? error}\n`));
    outcome = { exitCode: 1, signal: null };
    settle();
  });
  const settle = () => {
    if (settled) return;
    settled = true;
    spec.signal?.removeEventListener('abort', terminate);
    for (const collector of Object.values(collected)) {
      try { collector.seal(); } catch (error) { rangeFailure ??= error; }
    }
    for (const stream of Object.values(output)) {
      try { stream.end(); } catch (error) { rangeFailure ??= error; }
    }
    if (!didStart) started.reject(Object.assign(new Error('任务在启动前已结束'), { code: 'ERR_OHOS_NOT_STARTED' }));
    if (rangeFailure) gone.reject(rangeFailure);
    else gone.resolve(true);
    if (rangeFailure) completion.reject(rangeFailure);
    else completion.resolve(outcome);
  };
  child.once('close', (code, signal) => {
    outcome = { exitCode: typeof code === 'number' ? code : null, signal: signal ?? null };
    settle();
  });

  // Batch stdin: the bash executor writes its data synchronously after
  // spawn; the bridge collects it for 25ms, then POSTs. Write + end
  // immediately so the window always covers it.
  if (typeof spec.stdio.stdin === 'object' && spec.stdio.stdin !== null) {
    child.stdin?.end(spec.stdio.stdin.data ?? '');
  }

  const terminate = (signal) => {
    if (settled) return;
    // Aborts the HTTP request; the Swift side kills the guest process
    // group, and the bridge emits exit(null, signal), which settles
    // done as {exitCode: null, signal} — the stopped-handle shape.
    child.kill(typeof signal === 'string' ? signal : 'SIGTERM');
  };
  spec.signal?.addEventListener('abort', terminate, { once: true });

  const handle = {
    stdin: input, stdout: output.stdout, stderr: output.stderr, control: undefined, collected,
    done: completion.promise, started: started.promise,
    terminate,
    waitForExit: async (signal) => {
      if (settled) {
        if (rangeFailure) throw rangeFailure;
        return true;
      }
      if (signal?.aborted) return false;
      const interrupted = Promise.withResolvers();
      const abort = () => interrupted.resolve(false);
      signal?.addEventListener('abort', abort, { once: true });
      try { return await Promise.race([gone.promise, interrupted.promise]); }
      finally { signal?.removeEventListener('abort', abort); }
    },
    // The exec already started at spawn time; nothing to kick.
    start: () => {},
  };
  return handle;
}

/**
 * Adapt one interactive terminal spawn to the guest PTY, or explain why
 * not: { handle } on success, { declined: 'bridge' | 'argv', detail }
 * otherwise. 'bridge' means installIshBridge() failed in this thread
 * (detail is its message); 'argv' means the argv is not a guest shell.
 * Callers never get a silent undefined to fall back from.
 *
 * Only the guest shell is a PTY terminal. ishPtySpawn ignores the host
 * argv (the service always spawns the guest shell) and ignores cwd/env:
 * the shell starts in its own default directory, as in 1.0.x — the
 * controller's cwd is not honoured (known gap, see ENGINE_HOOK.md).
 *
 * N-2 (H-1 residual): a terminal opened under a read-only policy
 * carries it to the server (options.readOnly), so handlePTYUpgrade
 * can refuse before spawning the shell — the same denial as exec.
 * Only a spawnTerminal call that attached a policy is constrained;
 * a manually opened terminal has no policy and is unaffected: the
 * read-only policy constrains agent tools, and a terminal is the
 * user's own keystrokes.
 *
 * The shim returns a node-pty-shaped terminal (onData/onExit/write/
 * resize/kill), but the 1.1.1 terminal controller (BrowserTerminal)
 * consumes the virtual handle shape (done/output/terminate/
 * inspectActivity/write/resize). The raw shim must never leak through:
 * its `done` is undefined and BrowserTerminal.consume() crashes the
 * engine on `this.handle.done.then(...)` (build 46 device log: fatal
 * load failure, Node exit code 1). The wrap below mirrors
 * LocalTerminalHandle (dsh-subprocess-local) with the
 * ishProcessInspector stub semantics: activity is "unknown" while the
 * shell runs and "idle" once it has exited, so retention never closes
 * a live terminal for inactivity.
 */
export function ishSpawnTerminalFor(spec, policy) {
  if (!ensureBridge()) return { declined: 'bridge', detail: bridgeInstallDetail ?? 'installIshBridge failed in this thread' };
  const argv = spec?.argv;
  if (!Array.isArray(argv) || !argv.length) return { declined: 'argv', detail: 'terminal argv is missing or empty' };
  const name = basename(argv[0]);
  if (name !== 'bash' && name !== 'sh') return { declined: 'argv', detail: `terminal argv[0] is ${name}, not bash/sh` };
  const readOnly = policy?.mode === 'read-only';
  const terminal = ishPtySpawn(argv[0], argv.slice(1),
    { cols: spec.cols, rows: spec.rows, ...(readOnly ? { readOnly: true } : {}) });
  return { handle: adaptIshPtyTerminal(terminal, spec) };
}
function adaptIshPtyTerminal(terminal, spec) {
  const output = new PassThrough();
  const completion = Promise.withResolvers();
  completion.promise.catch(() => {});
  let exited = false;
  let outputPaused = false;
  let activityRevision = 0;
  const settle = (outcome) => {
    if (exited) return;
    exited = true;
    activityRevision++;
    spec.signal?.removeEventListener('abort', terminate);
    output.end();
    completion.resolve({
      exitCode: outcome.signal == null ? (outcome.exitCode ?? null) : null,
      signal: outcome.signal ?? null,
    });
  };
  const resume = () => {
    if (!outputPaused) return;
    outputPaused = false;
    if (!exited) terminal.resume();
  };
  output.on('drain', resume);
  output.once('close', () => {
    output.off('drain', resume);
  });
  terminal.onData((data) => {
    activityRevision++;
    if (!output.write(Buffer.from(data, 'utf8')) && !outputPaused) {
      outputPaused = true;
      terminal.pause();
    }
  });
  terminal.onExit((outcome) => settle(outcome));
  let cleanup;
  const terminate = (signal) => {
    if (cleanup !== undefined) return cleanup;
    if (outputPaused) {
      outputPaused = false;
      terminal.resume();
    }
    cleanup = (async () => {
      terminal.kill(typeof signal === 'string' ? signal : 'SIGTERM');
      await completion.promise;
    })();
    cleanup.catch(() => {
      cleanup = undefined;
    });
    return cleanup;
  };
  spec.signal?.addEventListener('abort', terminate, { once: true });
  return {
    pid: terminal.pid,
    output,
    done: completion.promise,
    started: terminal.ready,
    terminate,
    waitForExit: async (signal) => {
      if (exited) return true;
      if (signal?.aborted) return false;
      const interrupted = Promise.withResolvers();
      const abort = () => interrupted.resolve(false);
      signal?.addEventListener('abort', abort, { once: true });
      try {
        return await Promise.race([completion.promise.then(() => true), interrupted.promise]);
      } finally {
        signal?.removeEventListener('abort', abort);
      }
    },
    // The PTY already started at spawn time; nothing to kick.
    start: () => {},
    write: async (data) => {
      if (exited) throw new Error('terminal process has exited');
      terminal.write(data);
    },
    resize: async (cols, rows) => {
      if (exited) throw new Error('terminal process has exited');
      terminal.resize(cols, rows);
    },
    inspectActivity: async () => ({
      state: exited ? 'idle' : 'unknown',
      revision: activityRevision,
    }),
  };
}

/**
 * Line-buffered pseudo-terminal fallback, used when the bridge cannot
 * be installed in this thread (ishSpawnTerminalFor declined 'bridge').
 * Same handle shape as adaptIshPtyTerminal — done is always a real
 * promise, never undefined — driven by the session worker shell
 * (ishWorkerExec, which needs only the loopback service file, not the
 * installed bridge symbols): write() buffers input until a newline,
 * then runs the line on the worker and streams its output. The
 * submitted line is echoed first (the worker exec has no tty echo).
 * resize is a no-op: there is no pty to resize. A command's own
 * non-zero exit does not end the terminal; a transport failure (bridge
 * down, service not booted) is written to the output and ends it.
 */
export function ishFallbackTerminalFor(spec, policy) {
  const sessionId = randomUUID();
  const output = new PassThrough();
  const completion = Promise.withResolvers();
  completion.promise.catch(() => {});
  const abort = new AbortController();
  let exited = false;
  let activityRevision = 0;
  let pending = '';
  let stopSignal = null;
  let queue = Promise.resolve();
  const guestCwd = spec?.cwd ? toGuest(spec.cwd) ?? undefined : undefined;
  const readOnly = policy?.mode === 'read-only';
  const settle = (outcome) => {
    if (exited) return;
    exited = true;
    activityRevision++;
    spec.signal?.removeEventListener('abort', terminate);
    output.end();
    completion.resolve({
      exitCode: outcome.signal == null ? (outcome.exitCode ?? null) : null,
      signal: outcome.signal ?? null,
    });
  };
  const runLine = async (line) => {
    if (exited || line === '') return;
    output.write(line + '\n');
    try {
      await ishWorkerExec({
        sessionId, command: line,
        ...(guestCwd ? { cwd: guestCwd } : {}),
        ...(readOnly ? { readOnly: true } : {}),
        signal: abort.signal,
        onLine: (frame) => {
          activityRevision++;
          output.write(frame.line + '\n');
        },
      });
    } catch (error) {
      if (exited) return;
      if (abort.signal.aborted) { settle({ exitCode: null, signal: stopSignal ?? 'SIGTERM' }); return; }
      output.write(`ish: ${error?.message ?? error}\n`);
      settle({ exitCode: 1, signal: null });
    }
  };
  let cleanup;
  const terminate = (signal) => {
    if (cleanup !== undefined) return cleanup;
    stopSignal = typeof signal === 'string' ? signal : 'SIGTERM';
    cleanup = (async () => {
      abort.abort();
      settle({ exitCode: null, signal: stopSignal });
      await completion.promise;
    })();
    cleanup.catch(() => {
      cleanup = undefined;
    });
    return cleanup;
  };
  spec.signal?.addEventListener('abort', terminate, { once: true });
  return {
    pid: nextSyntheticPid(),
    output,
    done: completion.promise,
    started: Promise.resolve(),
    terminate,
    waitForExit: async (signal) => {
      if (exited) return true;
      if (signal?.aborted) return false;
      const interrupted = Promise.withResolvers();
      const abortWait = () => interrupted.resolve(false);
      signal?.addEventListener('abort', abortWait, { once: true });
      try {
        return await Promise.race([completion.promise.then(() => true), interrupted.promise]);
      } finally {
        signal?.removeEventListener('abort', abortWait);
      }
    },
    // Nothing to kick: lines run when write() completes them.
    start: () => {},
    write: async (data) => {
      if (exited) throw new Error('terminal process has exited');
      pending += String(data);
      let index;
      while ((index = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, index);
        pending = pending.slice(index + 1);
        queue = queue.then(() => runLine(line), () => runLine(line));
      }
    },
    // No pty exists to resize; the size is accepted and ignored.
    resize: async () => {
      if (exited) throw new Error('terminal process has exited');
    },
    inspectActivity: async () => ({
      state: exited ? 'idle' : 'unknown',
      revision: activityRevision,
    }),
  };
}
