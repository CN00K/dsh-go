// iSH bridge adapter for the 1.1.1 VirtualSubprocessRuntime (dsh-go port).
//
// The bridge (./ish-bridge.mjs) presents a ChildProcess-shaped spawn
// (spawnIshExec) and a node-pty-shaped terminal (ishPtySpawn). The 1.1.1
// virtual runtime speaks a different handle shape (collected readers,
// done/started promises, terminate/waitForExit/start). This module
// converts between the two. It is iOS-only, imported by the
// specialize-runtime.py edits to runtime/ohos/process/runtime.mjs, and
// returns undefined from both entry points when the bridge is not
// installed — then the virtual shell / virtual PTY error run exactly as
// in stock 1.1.1.
//
// Confinement: the ticket unwrap in VirtualSubprocessRuntime.spawn has
// already run before this adapter is called (confine() validated the
// cwd/mode when the ticket was issued), and the bridge's toGuest()
// rejects every host path outside the workspace and the rootfs data
// dir. The adapter does not re-check the grant: the guest can only
// ever see the workspace and the rootfs data dir, whichever cwd it
// is given (an unmapped cwd falls back to the guest default, as in
// 1.0.x). See ENGINE_HOOK.md.
import { basename } from 'node:path';
import { PassThrough } from 'node:stream';
import { OutputCollector } from '@deepseek-ai/dsh-subprocess-local/output';
import { scrubbedParentEnv } from '@deepseek-ai/dsh-subprocess';
import { ISH_RUNNER_COMMAND, spawnIshExec, ishPtySpawn } from './ish-bridge.mjs';

const ISH_PTY_SYMBOL = Symbol.for('dsh.ish.pty');

// True when installIshBridge() has run (preload.mjs, main thread only).
const bridgeInstalled = () => globalThis[ISH_PTY_SYMBOL] !== undefined;

// Only agent bash goes to the guest: ['bash', '-c', command]. Anything
// else (rg/git/node workers, 'sh', node scripts) stays virtual.
const isBashArgv = (argv) => Array.isArray(argv) && argv.length === 3
  && basename(argv[0]) === 'bash' && argv[1] === '-c' && typeof argv[2] === 'string';

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
export function ishSpawnFor(argv, spec, { temporaryRoot, onSpillFailure = () => {} } = {}) {
  if (!bridgeInstalled() || !isBashArgv(argv)) return undefined;
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
  // ['bash', '-c', command] argv.
  const child = spawnIshExec([ISH_RUNNER_COMMAND, '--', ...argv], {
    cwd: spec.cwd,
    env,
    signal: spec.signal,
    stdio: [spec.stdio.stdin === 'ignore' ? 'ignore' : 'pipe', 'pipe', 'pipe'],
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
 * Adapt one interactive terminal spawn to the guest PTY, or return
 * undefined to let VirtualSubprocessRuntime.spawnTerminal throw
 * ERR_OHOS_PTY_UNAVAILABLE as in stock 1.1.1.
 *
 * Only the guest shell is a PTY terminal. ishPtySpawn ignores the host
 * argv (the service always spawns the guest shell) and ignores cwd/env:
 * the shell starts in its own default directory, as in 1.0.x — the
 * controller's cwd is not honoured (known gap, see ENGINE_HOOK.md).
 */
export function ishSpawnTerminalFor(spec) {
  if (!bridgeInstalled()) return undefined;
  const argv = spec?.argv;
  if (!Array.isArray(argv) || !argv.length) return undefined;
  const name = basename(argv[0]);
  if (name !== 'bash' && name !== 'sh') return undefined;
  return ishPtySpawn(argv[0], argv.slice(1), { cols: spec.cols, rows: spec.rows });
}
