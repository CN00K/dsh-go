/**
 * iSH Linux sandbox bridge (Stage 3).
 *
 * Forwards DSH shell execution from Node to the iSH guest through the Swift
 * loopback service (IShLoopbackService: GET /ish/status, POST /ish/exec,
 * WS /ish/pty on 127.0.0.1, Bearer token from ish-service.json). Installed
 * by engine-worker.mjs before DSH starts, next to the pnpm in-process shim.
 *
 * Architecture (design doc §2.4(d), Stage 0 correction):
 * - iOS forbids fork()/exec(), so child_process.spawn() can never start a
 *   real process. The sandbox backend therefore cannot return a host argv
 *   to spawn (that only works where spawn works). Instead the backend is
 *   registered by config (runnerCommand, see the 137th patch) so
 *   ctx.sandbox.confine() succeeds, and the actual execution is intercepted
 *   HERE, in-process, at the spawn layer — the same monkey-patch technique
 *   as pnpm-ios.mjs (childProcess.spawn + syncBuiltinESMExports).
 * - Agent `bash` tool: confine() returns ["/ish-runner", ...bwrap args,
 *   "--", "bash", "-c", command]. The patched spawn() recognises the
 *   "/ish-runner" sentinel, extracts the command after "--", POSTs it to
 *   /ish/exec, and returns a ChildProcess-shaped handle (PassThrough
 *   stdout/stderr, synthetic pid, kill() aborts the request, which makes
 *   the Swift side kill the guest process group on disconnect).
 * - Interactive terminal: subprocess.spawnTerminal() is patched (same
 *   137th patch) to use the PTY shim below when the argv starts with the
 *   "/ish-runner" (confined, dsh-terminal-bash path) or "/ish-pty"
 *   (terminal/* path, shell resolved by dsh.go.direct) sentinel. The shim
 *   is a node-pty-compatible Terminal backed by WS /ish/pty (raw binary
 *   frames both ways, JSON control frames for resize/close). A stub process
 *   inspector is used because /bin/ps does not exist in the app sandbox.
 * - dsh.go.direct: the spawn-layer path-translation hook (zz-direct-
 *   runtime.diff). executable() maps "/bin/sh" to the "/ish-pty" sentinel
 *   so terminal shell resolution succeeds; toGuest()/toHost() translate
 *   between the host workspace (<root>/home/workspace) and the guest
 *   workspace (/home/workspace), plus <root>/tmp <-> /tmp.
 *
 * Env / cwd contract for the exec path (ENV-12/13/14, 2026-11-17):
 * - The guest shell for /ish/exec is /bin/bash (GUEST_EXEC_SHELL,
 *   enforced in ISHShellExecutor.executeCommand), not /bin/sh.
 * - TERM is forwarded only when the exec runs with a pty
 *   (guestEnv opts.hasPty, set from spawn options.pty — see the
 *   interface note on spawnIshExec). A piped exec has no TERM at all:
 *   the old code defaulted it to xterm-256color and forwarded the
 *   engine's TERM=dumb, both of which lie about the terminal.
 * - PYTHONDONTWRITEBYTECODE=0 is set so .pyc files are written (the
 *   kernel used to force =1, which made every pip import recompile
 *   from source; see the kernel patch for the matching removal).
 *   GOMAXPROCS / UV_THREADPOOL_SIZE are NOT set here: the kernel
 *   patch deletes their hardcoded values so Go/libuv use their own
 *   per-CPU defaults. PIP_PROGRESS_BAR=off is kept by the kernel
 *   injection (deliberate: keeps tool output clean).
 * - Session cwd (ENV-14): each exec is a fresh shell, so a bare `cd`
 *   inside one exec is invisible to the engine — the engine's workdir
 *   (options.cwd) is the only cwd the bridge is given, and it only
 *   changes when the model uses the working-directory cd tool. The
 *   bridge therefore remembers the guest's final cwd per session from
 *   a nonce-tagged marker line the Swift wrapper prints on stderr
 *   (see resolveExecCwd / ishExec opts.cwdNonce), and reuses it while
 *   the engine cwd is unchanged. See the REPORT for the full contract.
 * - Persistent shell worker (ENV-04): piped execs with a session id
 *   run on the session's long-lived guest /bin/bash (ishWorkerExec,
 *   POST /ish/worker/run) instead of a fresh shell per command — the
 *   per-command process creation + shell start under emulation was
 *   1–2 s of fixed cost. The worker keeps its cwd natively, scopes
 *   per-command env with a save/restore overlay, and tracks `&`
 *   background jobs (ishWorkerJobs / ishWorkerKillJob; the agent uses
 *   plain `jobs` / `kill %1` in the worker). One-shot /ish/exec stays
 *   as the fallback (no session id, stdin data, tty exec, or an old
 *   service). Timeout is a no-output watchdog (120 s of silence kills
 *   the foreground command; the DSH deadline still aborts first for a
 *   model-requested limit).
 *
 * What this file does NOT do:
 * - It does not change the sandbox policy. The guest only sees the
 *   bind-mounted workspace (and /tmp); the DSH token never enters the
 *   guest (the ish-service.json token is a separate token, and it is only
 *   ever sent to 127.0.0.1).
 * - It does not enforce the DSH network policy inside the guest (guest
 *   networking is host-stack passthrough; documented in design §2.7).
 * - It does not implement DSR/CPR: the DSH terminal stack's headless
 *   xterm answers DSR itself; this bridge forwards PTY bytes transparently
 *   (no line buffering, no escape-sequence mangling), which is all the
 *   bridge has to do for DSR/CPR to work.
 *
 * Failure mode is fail-closed everywhere: if the loopback service is not
 * reachable, the spawn shim writes a fatal signature to stderr and exits
 * non-zero (so dsh-bash-sandbox classifies it as SANDBOX_UNAVAILABLE),
 * and the PTY shim reports the failure on its output stream and fires
 * onExit. Installing the bridge never throws.
 *
 * Node 24.20.0 (NodeMobile) only: uses node:http / node:net / node:crypto /
 * node:stream / node:string_decoder / node:worker_threads-free APIs. No
 * global fetch, no global WebSocket (the WS handshake is hand-rolled over
 * node:net because the loopback service authenticates the upgrade with an
 * Authorization header, which the built-in WebSocket client cannot send).
 */
import childProcess from 'node:child_process';
import {createHash, randomBytes} from 'node:crypto';
import {EventEmitter} from 'node:events';
import {readFileSync} from 'node:fs';
import {request as httpRequest, Agent as HttpAgent} from 'node:http';
import {syncBuiltinESMExports} from 'node:module';
import {connect as netConnect} from 'node:net';
import {join, resolve, sep} from 'node:path';
import {PassThrough, Writable} from 'node:stream';
import {StringDecoder} from 'node:string_decoder';

/** Sentinel argv[0] the sandbox runnerCommand config uses (bash path). */
export const ISH_RUNNER_COMMAND = '/ish-runner';
/** Sentinel shell path the terminal resolves to (terminal/* path). */
export const ISH_PTY_COMMAND = '/ish-pty';
/** Symbol the patched spawnTerminal reads for the PTY shim. */
export const ISH_PTY_SYMBOL = Symbol.for('dsh.ish.pty');
/** Symbol the DSH direct-engine hook lives on (zz-direct-runtime.diff). */
export const DSH_DIRECT_SYMBOL = Symbol.for('dsh.go.direct');

/** Guest workspace (bind-mounted to the host workspace, design §2.6). */
export const GUEST_WORKSPACE = '/home/workspace';
/** Guest temp dir (bind-mounted to the host tmp dir). */
export const GUEST_TMP = '/tmp';
/**
 * Guest shell the loopback service spawns for /ish/pty (hardcoded
 * Swift-side in ISHKernel.executeCommand). PTY ONLY — it does not govern
 * the agent exec path. The exec shell is /bin/bash, enforced Swift-side
 * in ISHShellExecutor.executeCommand (ENV-01: the guest ships bash
 * 5.2.37; /bin/sh is BusyBox ash, whose missing bash syntax broke
 * commands that the bash tool advertises as "bash -c"). Do not change
 * this constant for ENV-01; the PTY shell is the multi-terminal owner's
 * scope.
 */
export const GUEST_SHELL = '/bin/sh';
/** Guest shell for the agent exec path (/ish/exec). See GUEST_SHELL. */
export const GUEST_EXEC_SHELL = '/bin/bash';

/**
 * A pid no run in the app owns (same idea as pnpm-ios.mjs, different base
 * so an iSH child can never collide with a pnpm in-process child).
 * Process-group signalling against it always fails closed (ESRCH), which
 * is why guest termination goes through the loopback service, not kill().
 */
const SYNTHETIC_PID_BASE = 2_147_482_000;
let syntheticPidCounter = 0;
function nextSyntheticPid() {
  syntheticPidCounter += 1;
  return SYNTHETIC_PID_BASE + syntheticPidCounter;
}

/** Fatal signatures the runner writes on stderr when the bridge is down. */
export const ISH_BRIDGE_UNAVAILABLE = 'ish bridge unavailable';
export const ISH_NOT_BOOTED = 'ish_not_booted';

/**
 * Default /ish/exec timeoutMs. 600s = the bash executor's maxTimeoutMs
 * (dsh-bash-local: default 120s, max 600s; the model-requested timeout
 * is clamped into that range by clampTimeout). The DSH-side deadline
 * is the operative timeout — it reaches the bridge as options.signal
 * (plumbed by the patched spawnSubprocess) and aborts the request,
 * so the tool reports "[timed out after Nms]" with partial output.
 * The server timeout is only a backstop (for commands whose DSH
 * deadline is disabled, e.g. background jobs, or if the abort path
 * fails); it must never fire first for a DSH-timed command, or the
 * tool would see exitCode -3 with no timeout marker. The old 60s
 * value cut every 60–120s command (e.g. `sleep 70`) at 60s.
 * The server clamps to 1s–15min, so 600s is in range.
 */
export const DEFAULT_EXEC_TIMEOUT_MS = 600_000;
/**
 * First call waits this long for ish-service.json to appear. 30 s, not
 * 10 s: a first boot (rootfs install + kernel boot) routinely takes
 * longer than 10 s, and a 10 s wait made the terminal fail on a healthy
 * but slow first boot (stage 3 device test, build 21).
 */
const SERVICE_FILE_WAIT_MS = 30_000;
/** Poll interval while waiting for the service file. */
const SERVICE_FILE_POLL_MS = 250;
/**
 * Re-read the service file at most this often when it is missing.
 * 5 s, not 30 s: after the one 30 s wait, a user who reopens the
 * terminal a few seconds later must get a fresh check, not an instant
 * fail-fast (stage 3 device test: reopening after 30 s still failed
 * instantly because the 30 s window had not elapsed).
 */
const SERVICE_FILE_RETRY_MIN_MS = 5_000;
/** Give up a WS handshake after this long (M-3): a clean server FIN
 * during the upgrade otherwise leaves `ready` pending forever. */
const WS_HANDSHAKE_TIMEOUT_MS = 10_000;
/** Cap for input queued before the WS handshake completes (M-6). */
const PTY_PENDING_MAX_BYTES = 64 * 1024;

/**
 * The loopback service is down: ish-service.json is missing (iSH not
 * booted, or the service failed to bind). The message names the file
 * that was checked and whether HOME was even set, so the next device
 * test can tell a missing boot from a wrong path without guessing.
 * The `ISH_BRIDGE_UNAVAILABLE` code (and the `ish bridge unavailable`
 * line the callers prefix) is unchanged, so the runner-failure
 * signatures still classify this as SANDBOX_UNAVAILABLE.
 */
function bridgeUnavailableError(opts = {}) {
  const roots = hostRoots();
  const serviceFile = opts.serviceFile ?? roots?.serviceFile ?? null;
  const detail = serviceFile != null
    ? `ish-service.json not found at ${serviceFile}`
    : 'HOME is not set (cannot locate ish-service.json)';
  return Object.assign(new Error(detail), {code: 'ISH_BRIDGE_UNAVAILABLE'});
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/**
 * Host roots, derived from the 1.1.1 worker environment (no supervisor):
 * host_core.cpp sets HOME=<guestRoot>/root (guestRoot =
 * filesDirectory/runtime/rootfs) and TMPDIR=<cache>/ohos-process
 * before Node starts; Dart cannot override HOME (EngineChannel
 * validated() reserves it). The token file lives at
 * <guestRoot>/ish-service.json (Application Support/runtime/rootfs/
 * ish-service.json). The guest rootfs data dir (RootfsManager.dataURL)
 * is three levels up from HOME: Application Support/iSH/rootfs/data.
 */
function hostRoots() {
  const home = process.env.HOME;
  if (!home) return null;
  return {
    home,
    workspace: join(home, 'workspace'),
    // Host-only TMPDIR — NOT the guest /tmp. host_core sets
    // TMPDIR=<cache>/ohos-process in 1.1.1 (in 1.0.x the supervisor
    // set TMPDIR=<root>/tmp); fall back to the old derivation when
    // TMPDIR is unset (e.g. tests). The guest /tmp lives under the
    // rootfs data dir (see `data` below); the old code mapped guest
    // /tmp here, which is a host-only directory.
    tmp: process.env.TMPDIR || join(home, '..', 'tmp'),
    // Guest rootfs data dir: the guest root (/) maps here — every
    // guest path that is not the workspace bind mount lives under it
    // (/tmp, /etc, /root, /usr, ...). HOME is one level deeper than
    // in 1.0.x (guestRoot/root vs <root>/home), so the climb is three
    // levels, not two: <AppSupport>/runtime/rootfs/root -> ../../..
    // -> <AppSupport>/iSH/rootfs/data. The old two-level climb landed
    // under <AppSupport>/runtime/iSH/rootfs/data, which does not exist.
    data: join(home, '..', '..', '..', 'iSH', 'rootfs', 'data'),
    // The engine's own runtime tree (RuntimeInstaller base/tree):
    // the DSH engine runs from here, so every path under it is
    // already a host path — never a guest path. The C++ host writes
    // patch plugin names from here and Swift writes the phone plugin
    // name from here; toHost() must leave them alone instead of
    // mapping them under the rootfs data dir (build 46: the doubled
    // path broke all six patch plugins, so no session could start).
    // Same three-level climb as `data` above.
    runtime: join(home, '..', '..', '..', 'dsh-runtime', 'tree'),
    serviceFile: join(home, '..', 'ish-service.json'),
  };
}

/**
 * Translate a host absolute path to its guest equivalent.
 * @param hostPath host absolute path.
 * @returns guest path, or null when the path is outside the shared dirs.
 */
export function toGuest(hostPath) {
  const roots = hostRoots();
  if (!roots || typeof hostPath !== 'string' || hostPath.length === 0) return null;
  const resolved = resolve(hostPath);
  const relWorkspace = relativeUnderHostRoot(resolved, roots.workspace);
  if (relWorkspace !== null) return joinGuest(GUEST_WORKSPACE, relWorkspace);
  // Guest /tmp lives under the rootfs data dir, not under <root>/tmp
  // (that is the host-only TMPDIR — the old mapping claimed host temp
  // files were guest /tmp files).
  const relDataTmp = relativeUnderHostRoot(resolved, join(roots.data, 'tmp'));
  if (relDataTmp !== null) return joinGuest(GUEST_TMP, relDataTmp);
  // Any other file under the rootfs data dir is a guest file.
  const relData = relativeUnderHostRoot(resolved, roots.data);
  if (relData !== null) return joinGuest('/', relData);
  return null;
}

/**
 * Translate a guest absolute path to its host equivalent.
 * @param guestPath guest absolute path.
 * @returns host path. Host paths (already under a host root) and
 *   relative paths are returned unchanged. Kernel-virtual guest paths
 *   (/proc, /sys, /dev) throw: they have no file in the rootfs, so
 *   the file tools can never read them — the error says so instead of
 *   a bare "not found".
 */
export function toHost(guestPath) {
  const roots = hostRoots();
  if (!roots || typeof guestPath !== 'string' || guestPath.length === 0) return guestPath;
  // Relative paths are resolved against the engine cwd by the caller;
  // never rewrite them here (the data-dir fallback below must only
  // see absolute paths).
  if (!guestPath.startsWith('/')) return guestPath;
  // Kernel-virtual guest paths have no file in the rootfs: /proc,
  // /sys and /dev are generated by the iSH kernel, so the file tools
  // (host-side fs reads) can never see them. Fail with the reason
  // instead of a bare "not found" that looks like a missing file —
  // the shell is the only way to read them.
  if (guestPath === '/proc' || guestPath.startsWith('/proc/') ||
      guestPath === '/sys' || guestPath.startsWith('/sys/') ||
      guestPath === '/dev' || guestPath.startsWith('/dev/')) {
    throw new Error(
      `"${guestPath}" is a guest virtual file (/proc, /sys and /dev have no file in the rootfs); read it from the shell instead (e.g. \`cat ${guestPath}\`)`);
  }
  // Already a host path (the engine's cwd and other host-side paths
  // are passed through here too): leave it alone. Guest paths never
  // start with a host root. The runtime tree is a host root too: the
  // engine's patch plugin names live under it, and mapping them
  // under the rootfs data dir breaks every plugin import (build 46).
  for (const root of [roots.workspace, roots.data, roots.tmp, roots.home, roots.runtime]) {
    if (underHostRoot(guestPath, root)) return guestPath;
  }
  const relWorkspace = relativeTo(guestPath, GUEST_WORKSPACE);
  if (relWorkspace !== null) return join(roots.workspace, relWorkspace);
  const relTmp = relativeTo(guestPath, GUEST_TMP);
  if (relTmp !== null) return join(roots.data, 'tmp', relTmp);
  // Every other guest path lives under the rootfs data dir
  // (RootfsManager.dataURL): /etc, /root, /usr, /var, /opt, ...
  // The old code returned these unchanged, so the engine read the iOS
  // host's /etc (or a host /proc that does not exist) — the P2-9
  // mismatch.
  const rel = guestPath.replace(/^\/+/, '');
  if (rel.length === 0) return roots.data;
  return join(roots.data, rel);
}

/** Relative path of `path` under `base`, or null when outside (after resolve). */
function relativeTo(path, base) {
  const resolvedPath = resolve(path);
  const resolvedBase = resolve(base);
  if (resolvedPath === resolvedBase) return '';
  const prefix = resolvedBase.endsWith(sep) ? resolvedBase : resolvedBase + sep;
  if (!resolvedPath.startsWith(prefix)) return null;
  return resolvedPath.slice(prefix.length);
}

/**
 * Whether `path` lies under host `root`. iOS spells the app container
 * two ways: /var/... (Swift / FileManager) and /private/var/...
 * (canonical C++). /var is a symlink to /private/var, so the same host
 * dir must match under either spelling — compare with an optional
 * /private prefix stripped from both sides. A genuine guest path can
 * never match: host roots all carry the container UUID plus
 * `Library/Application Support/`, which no guest path has.
 */
function underHostRoot(path, root) {
  return relativeUnderHostRoot(path, root) !== null;
}

/**
 * Relative path of `path` under host `root`, or null when outside.
 * Same /private-tolerant comparison as underHostRoot: a host path
 * must match under either the /var/... or the /private/var/... spelling
 * (M-5: toGuest used plain relativeTo, so a /var-spelled workspace
 * path missed a /private/var-spelled root and the exec silently ran
 * in the wrong guest directory).
 */
function relativeUnderHostRoot(path, root) {
  const direct = relativeTo(path, root);
  if (direct !== null) return direct;
  const stripPrivate = (value) => value.startsWith('/private/') ? value.slice('/private'.length) : value;
  return relativeTo(stripPrivate(path), stripPrivate(root));
}

/** Join guest path segments with '/' (guest is always POSIX). */
function joinGuest(...parts) {
  // Strip leading/trailing slashes from each segment first: joining
  // '/' and 'etc/passwd' must give '/etc/passwd', not '//etc/passwd'
  // (the old code never passed '/' as a segment, so this was latent).
  const joined = parts
    .map((p) => p.replace(/^\/+|\/+$/g, ''))
    .filter((p) => p !== '')
    .join('/');
  return '/' + joined;
}

// ---------------------------------------------------------------------------
// Loopback service discovery (token file)
// ---------------------------------------------------------------------------

let cachedService = null; // {host, port, token} | null
let cachedServiceFile = null;
let lastMissingCheck = 0;
let waitedForServiceFile = false;

/**
 * Loopback HTTP agent (build 34 fix): NO keep-alive. The loopback
 * service answers every response with `Connection: close`, so pooled
 * sockets are never reused in practice — but the client must not
 * depend on that: a stale or wrong server on a reused port can hand
 * the pool a dead socket, and the next request on it fails with a
 * parse error (HPE_CLOSED_CONNECTION, "Data after `Connection:
 * close`") instead of a clean ECONNREFUSED. One fresh TCP connect
 * per call on 127.0.0.1 costs nothing measurable and removes the
 * whole pooled-socket class.
 */
const loopbackAgent = new HttpAgent({keepAlive: false});

/**
 * True for errors that mean "this connection/response is garbage,
 * not that the service is down": llhttp parse errors (HPE_* — the
 * exact code for the build-33 device failure is
 * HPE_CLOSED_CONNECTION, "Parse Error: Data after `Connection:
 * close`") plus the classic dead-connection codes. Callers retry
 * once with freshly-read service info and drop the cache on these,
 * exactly as they already do for ECONNREFUSED/ECONNRESET.
 */
function isStaleConnectionError(error) {
  if (!error) return false;
  if (error.code === 'ECONNREFUSED' || error.code === 'ECONNRESET') return true;
  return typeof error.code === 'string' && error.code.startsWith('HPE_');
}

/**
 * True only when the TCP connect itself failed (ECONNREFUSED): no
 * bytes were sent, so the request certainly never reached the service
 * and a retry cannot execute the command twice. N-1 (round 2): this
 * is the only transport error the exec retry loops — and the
 * worker→one-shot fallback in spawnIshExec — treat as retryable.
 * Response-phase disconnects (ECONNRESET / HPE_*) are still stale
 * connections for cache invalidation (isStaleConnectionError above),
 * but they must not trigger a retry — the guest command may already
 * have run. Pure predicate on error.code; nothing sets or clears it.
 */
function isConnectFailedError(error) {
  return !!error && error.code === 'ECONNREFUSED';
}
/**
 * True once a worker request has proven this service predates the
 * worker endpoints (HTTP 404 on /ish/worker/run). While set, the
 * spawn shim skips the worker and goes straight to one-shot /ish/exec.
 * Reset by invalidateServiceInfo (a service restart may bring a newer
 * build with the endpoints).
 */
let workerUnsupported = false;

/** Read and parse ish-service.json; returns null when absent/unparsable. */
function readServiceFile(serviceFile) {
  try {
    const parsed = JSON.parse(readFileSync(serviceFile, 'utf8'));
    if (typeof parsed?.token !== 'string' || parsed.token.length === 0) return null;
    if (!Number.isSafeInteger(parsed?.port) || parsed.port <= 0) return null;
    return {host: '127.0.0.1', port: parsed.port, token: parsed.token};
  } catch {
    return null;
  }
}

/**
 * Resolve the loopback service (lazy, cached). First call waits up to 30s
 * for the file to appear (iSH may still be booting); later calls fail fast
 * when it is missing, and re-read once after a connection failure.
 * @param opts.serviceFile override for tests.
 * @returns service info, or null when the bridge is unavailable.
 */
export async function getServiceInfo(opts = {}) {
  const roots = hostRoots();
  const serviceFile = opts.serviceFile ?? roots?.serviceFile ?? null;
  if (!serviceFile) return null;
  if (cachedService && cachedServiceFile === serviceFile) return cachedService;
  const now = Date.now();
  let info = readServiceFile(serviceFile);
  if (!info && !waitedForServiceFile) {
    // First miss: iSH may still be booting; wait up to 30s for the file.
    waitedForServiceFile = true;
    const deadline = Date.now() + SERVICE_FILE_WAIT_MS;
    while (!info && Date.now() < deadline) {
      await new Promise((done) => setTimeout(done, SERVICE_FILE_POLL_MS));
      info = readServiceFile(serviceFile);
    }
  } else if (!info && now - lastMissingCheck < SERVICE_FILE_RETRY_MIN_MS) {
    return null; // Fail fast: already checked recently.
  }
  if (!info) lastMissingCheck = Date.now();
  else {
    cachedService = info;
    cachedServiceFile = serviceFile;
  }
  return info;
}

/**
 * Drop the cached service info (call after a connection failure, then
 * retry once). The retry does a fresh read of ish-service.json instead
 * of failing fast on the 5s window (fix, build 37: the loopback service
 * can restart with a new port/token — e.g. stop/start across a terminal
 * reopen — and the bridge kept dialling the stale cached port/token
 * forever, because only the /ish/exec path invalidated and the WS path
 * never retried).
 * M-4: this deliberately does NOT reset waitedForServiceFile. The 30s
 * first-boot wait is once per process: re-arming it here made every
 * retry against a stopped service wait the full 30s before failing.
 * A retry re-reads the file once and fails fast when it is still
 * missing (lastMissingCheck is reset below for that fresh read).
 */
export function invalidateServiceInfo() {
  cachedService = null;
  cachedServiceFile = null;
  lastMissingCheck = 0;
  // A restart may bring a newer loopback build; re-probe the worker
  // endpoints instead of trusting the old 404 forever.
  workerUnsupported = false;
}

// ---------------------------------------------------------------------------
// /ish/exec client (node:http, chunked NDJSON)
// ---------------------------------------------------------------------------

// R3-N1: entry validation shared by ishExec and ishWorkerExec. Without
// argv, command is required and must be a non-empty string; NUL bytes in
// command, argv elements, env keys/values or cwd would be silently
// truncated by the server's C string handling, so reject before any HTTP
// is sent. The helper guards argv's shape itself (ishWorkerExec takes
// command only, so a malformed argv can only arrive by caller error —
// R4-3: it must still fail as ISH_INVALID_ARGV, not a TypeError).
function assertValidExecInput(opts) {
  if (opts.argv === undefined) {
    if (typeof opts.command !== 'string' || opts.command.length === 0 || opts.command.includes('\0')) {
      throw Object.assign(
        new Error('ish command must be a non-empty string without NUL bytes'),
        {code: 'ISH_INVALID_ARGV'});
    }
  } else if (!Array.isArray(opts.argv) || opts.argv.some((a) => typeof a !== 'string' || a.includes('\0'))) {
    throw Object.assign(
      new Error('ish argv must be an array of strings without NUL bytes'),
      {code: 'ISH_INVALID_ARGV'});
  }
  // R5-1-1: type guards before the NUL checks — a non-string cwd or a
  // non-string env value would otherwise sail through to the server,
  // which treats them as absent (silent wrong-directory / missing-env
  // execution). The guard also closes the native TypeError from
  // Object.entries on a Symbol env. env: null stays allowed (absent).
  if (opts.cwd !== undefined && typeof opts.cwd !== 'string') {
    throw Object.assign(
      new Error('ish cwd must be a string'),
      {code: 'ISH_INVALID_ARGV'});
  }
  // R6-1-1: enumerate env once and reuse the snapshot for both checks
  // below. A throwing getter used to leak its raw error out of
  // Object.values (and, on a second enumeration, out of the NUL check),
  // which spawnIshExec then misclassified as ISH_BRIDGE_UNAVAILABLE.
  // Any enumeration failure is a client-side argument error. A single
  // snapshot also keeps the two checks from judging different values
  // when a stateful getter flips between reads.
  let envEntries = null;
  if (opts.env !== undefined && opts.env !== null
    && typeof opts.env === 'object' && !Array.isArray(opts.env)) {
    try {
      envEntries = Object.entries(opts.env);
    } catch {
      throw Object.assign(
        new Error('ish env must be an object mapping strings to strings'),
        {code: 'ISH_INVALID_ARGV'});
    }
  }
  if (opts.env !== undefined && opts.env !== null
    && (typeof opts.env !== 'object' || Array.isArray(opts.env)
      || envEntries.some(([, v]) => typeof v !== 'string'))) {
    throw Object.assign(
      new Error('ish env must be an object mapping strings to strings'),
      {code: 'ISH_INVALID_ARGV'});
  }
  if (typeof opts.cwd === 'string' && opts.cwd.includes('\0')) {
    throw Object.assign(
      new Error('ish cwd must not contain NUL bytes'),
      {code: 'ISH_INVALID_ARGV'});
  }
  if (envEntries && envEntries.some(([k, v]) => k.includes('\0') || (typeof v === 'string' && v.includes('\0')))) {
    throw Object.assign(
      new Error('ish env keys and values must not contain NUL bytes'),
      {code: 'ISH_INVALID_ARGV'});
  }
  // R6-1-1 (residual): hand the validated snapshot back so callers
  // build the request body from it instead of re-reading opts.env —
  // a second read could throw or flip under a stateful getter.
  return envEntries;
}

/**
 * Run one command in the guest via POST /ish/exec.
 * @param opts.command shell source (required).
 * @param opts.cwd guest cwd (already translated) or undefined.
 * @param opts.env env vars to export in the guest (already sanitised) or undefined.
 * @param opts.stdinData Buffer of stdin bytes or undefined.
 * @param opts.timeoutMs exec timeout (server clamps 1s-15min).
 * @param opts.tty when true, run on a fresh fake PTY (merged stream,
 *   TERM=xterm-256color) instead of host pipes; the terminal frame
 *   echoes {tty: true} so the caller can confirm the exec had a pty.
 *   Default false (pipe path, unchanged). This is the "has pty"
 *   flag of the ENV-02 contract: the bridge sets it, the server
 *   (IShLoopbackService /ish/exec) honors it, and the frame reports
 *   it back. The bridge does NOT decide TERM here — the env/executor
 *   workstream owns the "set TERM only when tty" rule in guestEnv;
 *   this flag is the input it keys on.
 * @param opts.serviceFile override for tests.
 * @param opts.onLine({stream, line}) called per NDJSON output line.
 * @param opts.cwdNonce per-exec nonce (hex) for the session-cwd marker:
 *   the Swift wrapper appends `__DSH_CWD__<nonce>:<cwd>` on stderr
 *   after the command; lines matching exactly this nonce are swallowed
 *   here (never delivered to onLine) and reported via onSessionCwd.
 *   A line with any other nonce-shaped text is ordinary output.
 * @param opts.onSessionCwd(cwd) called with the guest's final cwd
 *   (guest absolute path) when a valid marker line arrives.
 * @param opts.readOnly true when the session policy is read-only: the
 *   server refuses the exec with OHOS_SANDBOX_DENIED instead of
 *   running it on the always-writable workspace mount (H-1).
 * @param opts.signal AbortSignal; aborting closes the connection, which
 *   makes the Swift side cancel the exec and kill the guest process group.
 * @returns {exitCode, durationMs, timedOut?, cancelled?} from the final frame.
 */
export async function ishExec(opts) {
  // B (argv mode): a direct guest exec — argv is sent verbatim, never
  // joined into a shell string. Validate here (the server re-validates
  // and answers 400); an invalid argv fails before any HTTP is sent.
  if (opts.argv !== undefined) {
    if (!Array.isArray(opts.argv) || opts.argv.length === 0
      || opts.argv.some((a) => typeof a !== 'string' || a.length === 0)) {
      throw Object.assign(
        new Error('ish argv must be a non-empty array of non-empty strings'),
        {code: 'ISH_INVALID_ARGV'});
    }
  }
  // N-4 (round 2): the server answers 400 for argv+command and for
  // argv+tty, but without this the failure comes back as
  // ISH_HTTP_ERROR and spawnIshExec reports it as
  // ISH_BRIDGE_UNAVAILABLE ("bridge unavailable") — a client-side
  // argument error misclassified as a dead service. Reject up front,
  // before any HTTP is sent, so the caller sees ISH_INVALID_ARGV.
  if (opts.argv !== undefined && opts.command !== undefined) {
    throw Object.assign(
      new Error('ish argv and command are mutually exclusive'),
      {code: 'ISH_INVALID_ARGV'});
  }
  if (opts.argv !== undefined && opts.tty) {
    throw Object.assign(
      new Error('ish argv cannot be combined with tty'),
      {code: 'ISH_INVALID_ARGV'});
  }
  // R3-N1: without argv command is required; NUL in command/argv/env/cwd
  // fails here, before any HTTP is sent (see assertValidExecInput).
  // R6-1-1 (residual): hand the validated snapshot back so callers
  // build the request body from it instead of re-reading opts.env —
  // a second read could throw or flip under a stateful getter.
  // (Same fix applied to ishExec: it had the identical re-read shape.)
  const validatedEnv = assertValidExecInput(opts);
  const body = JSON.stringify({
    ...(opts.command ? {command: opts.command} : {}),
    ...(opts.argv ? {argv: opts.argv} : {}),
    ...(opts.cwd ? {cwd: opts.cwd} : {}),
    ...(validatedEnv && validatedEnv.length > 0 ? {env: Object.fromEntries(validatedEnv)} : {}),
    ...(opts.stdinData && opts.stdinData.length > 0
      ? {stdinData: Buffer.from(opts.stdinData).toString('base64')} : {}),
    ...(opts.cwdNonce ? {cwdNonce: opts.cwdNonce} : {}),
    ...(opts.tty ? {tty: true} : {}),
    ...(opts.readOnly ? {readOnly: true} : {}),
    timeoutMs: opts.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS,
  });
  // Session-cwd marker filter (ENV-14): the Swift wrapper prints one
  // `__DSH_CWD__<nonce>:<cwd>` line on stderr after the command. It is
  // protocol, not command output: swallow it and report the cwd via
  // onSessionCwd. Only the exact nonce for this exec matches, so a
  // command that prints a look-alike line cannot corrupt the
  // remembered cwd (a wrong-nonce marker is delivered as normal output).
  // H-5: once a line has streamed, the command already ran — a retry
  // would execute a non-idempotent command twice. Same rule as the
  // worker→one-shot fallback in spawnIshExec (sawOutput). The cwd
  // marker counts too: the Swift wrapper prints it after the command
  // finishes, so it proves the command ran.
  let sawOutput = false;
  const execOpts = {...opts, onLine: (frame) => {
    sawOutput = true;
    if (opts.cwdNonce) {
      const marker = parseCwdMarker(frame, opts.cwdNonce);
      if (marker !== null) {
        opts.onSessionCwd?.(marker);
        return;
      }
    }
    opts.onLine?.(frame);
  }};
  // Retry once with a fresh read of ish-service.json (same stale-cache
  // fix as the WS path, build 37): postNdjson invalidates on
  // ECONNREFUSED/ECONNRESET and on llhttp parse errors (HPE_* — a
  // garbled response from a stale/wrong port, build 34), and a 401
  // means the token rotated, so a retry with fresh info can succeed
  // where the cached one failed.
  // ISH_NOT_BOOTED is a real state, not a stale cache — do not retry it.
  let lastError = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) invalidateServiceInfo();
    const service = await getServiceInfo(opts);
    if (!service) throw bridgeUnavailableError(opts);
    try {
      return await postNdjson(service, '/ish/exec', body, execOpts);
    } catch (error) {
      lastError = error;
      if (error?.code === 'ISH_NOT_BOOTED') throw lastError;
      // N-1 (round 2): retry a transport failure only when the connect
      // itself failed (ECONNREFUSED) — the request certainly never
      // reached the service, so the command cannot run twice. A
      // response-phase disconnect (ECONNRESET / HPE_*) must NOT retry:
      // the guest command may already have run (a no-output command's
      // first NDJSON frame may not have arrived yet), and retrying
      // would execute it a second time. Trade-off, stated plainly: a
      // response-phase disconnect no longer auto-recovers; if the
      // caller retries, the command may already have executed once.
      // Closing this window fully needs a server-side idempotency key
      // (Swift work, build round). HTTP errors stay retryable: the
      // server answers every non-200 before running anything, so a
      // retry there never re-executes a command.
      const retryable = isConnectFailedError(error)
        || (error?.code === 'ISH_HTTP_ERROR' && error?.statusCode !== 429);
      if (retryable && attempt === 0 && !sawOutput) continue;
      throw lastError;
    }
  }
  throw lastError;
}

/**
 * POST a JSON body to the loopback service and stream back chunked
 * NDJSON ({stream, line} frames + a terminal frame {exitCode, ...}).
 * Shared by /ish/exec and /ish/worker/run (same framing, same abort
 * semantics). Rejects with ISH_NOT_BOOTED on 503, ISH_HTTP_ERROR (+
 * statusCode) on any other non-200, ISH_NO_FINAL_FRAME when the stream
 * ends without a terminal frame. Aborting opts.signal resolves as
 * {cancelled: true} (the server kills the guest command on disconnect).
 */
function postNdjson(service, path, body, opts) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const settleResolve = (value) => { if (!settled) { settled = true; resolvePromise(value); } };
    const settleReject = (error) => { if (!settled) { settled = true; rejectPromise(error); } };
    const req = httpRequest({
      host: service.host,
      port: service.port,
      agent: loopbackAgent,
      path,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${service.token}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      signal: opts.signal,
    }, (res) => {
      if (res.statusCode === 503) {
        const error = new Error(ISH_NOT_BOOTED);
        error.code = 'ISH_NOT_BOOTED';
        settleReject(error);
        res.resume();
        return;
      }
      if (res.statusCode !== 200) {
        const error = new Error(`ish ${path} failed: HTTP ${res.statusCode}`);
        error.code = 'ISH_HTTP_ERROR';
        error.statusCode = res.statusCode;
        settleReject(error);
        res.resume();
        return;
      }
      // Chunked NDJSON: one JSON object per line; the last line is the
      // terminal frame {exitCode, durationMs, ...}. Lines are split on
      // \n bytes (UTF-8 safe); each complete line is decoded as UTF-8.
      let buffer = Buffer.alloc(0);
      let finalFrame = null;
      const decoder = new StringDecoder('utf8');
      const handleLine = (lineBuffer) => {
        if (lineBuffer.length === 0) return;
        let frame;
        try {
          frame = JSON.parse(decoder.write(lineBuffer));
        } catch {
          return; // Skip a malformed line; the final frame still settles us.
        }
        if (typeof frame?.exitCode === 'number') {
          finalFrame = frame;
          return;
        }
        if (typeof frame?.stream === 'string' && typeof frame?.line === 'string') {
          opts.onLine?.({stream: frame.stream, line: frame.line});
        }
      };
      res.on('data', (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        let index;
        while ((index = buffer.indexOf(0x0a)) >= 0) {
          const line = buffer.subarray(0, index);
          buffer = buffer.subarray(index + 1);
          // The server strips a trailing \r already; tolerate one here too.
          handleLine(line.length > 0 && line[line.length - 1] === 0x0d ? line.subarray(0, -1) : line);
        }
      });
      res.on('end', () => {
        if (buffer.length > 0) handleLine(buffer);
        if (finalFrame) settleResolve(finalFrame);
        else settleReject(Object.assign(new Error('ish exec ended without a final frame'), {code: 'ISH_NO_FINAL_FRAME'}));
      });
      res.on('error', (error) => {
        // Aborted by the caller (kill / DSH timeout / Stop): the socket
        // is torn down after the abort, so a trailing ECONNRESET is a
        // consequence of the cancel, not a real failure.
        if (opts.signal?.aborted) {
          settleResolve({exitCode: null, durationMs: 0, cancelled: true});
          return;
        }
        settleReject(error);
      });
    });
    req.on('error', (error) => {
      // Aborted by the caller: Node 24 surfaces a signal-abort as an
      // 'error' event (AbortError / ABORT_ERR) — the 'abort' event below
      // does not fire for signal-aborts. Treat it as a cancel, not a
      // failure, so the caller sees SIGTERM, not exit code 1.
      if (error?.name === 'AbortError' || error?.code === 'ABORT_ERR') {
        settleResolve({exitCode: null, durationMs: 0, cancelled: true});
        return;
      }
      // Connection failure: the service file may have been rewritten
      // (restart with a new port/token); drop the cache so the next call
      // re-reads it. The caller retries once if it wants to.
      if (isStaleConnectionError(error)) invalidateServiceInfo();
      settleReject(error);
    });
    req.on('abort', () => {
      // Aborted by the caller (kill): the server cancels the exec on
      // disconnect; report it as cancelled, not as an error.
      settleResolve({exitCode: null, durationMs: 0, cancelled: true});
    });
    req.end(body);
  });
}

/**
 * Probe /ish/status. Returns true when the guest is booted and reachable.
 * @param opts.serviceFile override for tests.
 */
export async function ishStatus(opts = {}) {
  const service = await getServiceInfo(opts);
  if (!service) return false;
  return new Promise((resolvePromise) => {
    const req = httpRequest({
      host: service.host,
      port: service.port,
      agent: loopbackAgent,
      path: '/ish/status',
      method: 'GET',
      headers: {'Authorization': `Bearer ${service.token}`},
    }, (res) => {
      res.resume();
      resolvePromise(res.statusCode === 200);
    });
    req.on('error', (error) => {
      // A failed probe may mean the cached port is stale (service
      // restarted with a new port/token): drop the cache so the next
      // call re-reads ish-service.json instead of failing fast on
      // the dead port forever.
      if (isStaleConnectionError(error)) invalidateServiceInfo();
      resolvePromise(false);
    });
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Persistent shell worker client (ENV-04)
// ---------------------------------------------------------------------------
// One long-lived guest /bin/bash per DSH session (ISHWorkerShell,
// Swift-side), so agent execs stop paying a fresh process creation +
// shell start per command. The bridge routes piped execs with a
// session id to POST /ish/worker/run and falls back to one-shot
// /ish/exec when the worker is unavailable (no session id, stdin data,
// tty exec, worker start failure, or an old service that 404s the
// worker endpoints). A fallback only ever happens BEFORE any output
// has streamed — re-running a command that already produced output
// would execute it twice.
//
// Protocol (see IShLoopbackService.buildWorkerCommand): the Swift
// wrapper prints, on stderr, an END marker
// `__DSH_END__<nonce>:<exitCode>:<cwd>` and a jobs snapshot
// (`jobs -l` lines between JOBS_BEGIN/JOBS_END, `jobs -p` pids between
// JOBPIDS_BEGIN/JOBPIDS_END). All protocol lines are swallowed here
// (never delivered to onLine); the END marker updates the session cwd
// memory (same mechanism as ENV-14) and the snapshot updates the
// per-session job table. A line with any other nonce is ordinary
// output. The terminal frame only arrives after the marker AND the
// snapshot, so the job table is current when the run resolves.
//
// Timeouts: the DSH-side deadline (options.signal) is still the
// operative timeout for a model-requested limit, and the server's
// 600 s wall clock is the backstop. Between them sits the Swift
// no-output watchdog: 120 s of silence kills the foreground command
// (5 s grace, then the worker is killed and rebuilt). A command that
// keeps producing output is never killed by it.
//
// Jobs: a command's `&` children are jobs OF THE WORKER SHELL (no
// subshell wrapper), so the agent uses plain bash builtins in the
// worker — `jobs -l` to list, `kill %1` / `kill <pid>` to kill — and
// ishWorkerJobs / ishWorkerKillJob are the programmatic equivalents
// over the same state. ishWorkerJobs runs the no-op command `:` on the
// worker to refresh the snapshot (there is no dedicated loopback
// endpoint: a control channel into the worker's stdin would queue
// behind the running command anyway). Killing a job goes through
// POST /ish/worker/jobs/kill, which refuses any pid that is not a live
// descendant of the worker. Stopping a worker (ishWorkerStop, or the
// service stop) kills its whole process tree, so no background job
// survives its session.
//
// Concurrency: runs for one session are serialized (the worker reads
// one command stream — two runs must never interleave stdin writes).
// Cross-session runs are independent (different workers).

/** Error code when the service predates the worker endpoints (HTTP 404). */
export const ISH_WORKER_UNSUPPORTED = 'ish_worker_unsupported';
/** Error code when a run is refused because the session already has
 * one in flight (HTTP 409, M-10). */
export const ISH_WORKER_BUSY = 'ish_worker_busy';
/** Error code when a job kill names a pid that is not a job of the worker. */
export const ISH_JOB_NOT_FOUND = 'ish_job_not_found';

/** Protocol line prefixes the worker wrapper prints on stderr. */
export const WORKER_END_MARKER_PREFIX = '__DSH_END__';
export const WORKER_JOBS_BEGIN_PREFIX = '__DSH_JOBS_BEGIN__';
export const WORKER_JOBS_END_PREFIX = '__DSH_JOBS_END__';
export const WORKER_JOBPIDS_BEGIN_PREFIX = '__DSH_JOBPIDS_BEGIN__';
export const WORKER_JOBPIDS_END_PREFIX = '__DSH_JOBPIDS_END__';

/**
 * Parse a worker END marker frame: `__DSH_END__<nonce>:<exitCode>:<cwd>`.
 * Returns {exitCode, cwd}, or null when the frame is not a marker for
 * this nonce (same exact-nonce rule as the cwd marker: a command that
 * prints a look-alike line cannot corrupt the run).
 */
export function parseWorkerEndMarker(frame, nonce) {
  if (!nonce || frame?.stream !== 'stderr' || typeof frame?.line !== 'string') return null;
  const prefix = `${WORKER_END_MARKER_PREFIX}${nonce}:`;
  if (!frame.line.startsWith(prefix)) return null;
  const rest = frame.line.slice(prefix.length);
  const colon = rest.indexOf(':');
  if (colon < 0) return null;
  const code = Number(rest.slice(0, colon));
  const cwd = rest.slice(colon + 1);
  if (!Number.isInteger(code) || code < 0 || code > 255) return null;
  if (!cwd.startsWith('/') || /[\0-\x1f\x7f]/.test(cwd)) return null;
  return {exitCode: code, cwd};
}

/**
 * Parse one `jobs -l` line: `[1]+  1234 Running  sleep 600 &`.
 * Returns {job, pid, state, command}, or null. A job notification line
 * (`[1]+ Done sleep 1`, no pid) is NOT a jobs line. State is
 * normalized to 'running' | 'done' | 'stopped' ('Done' / 'Exit 1' /
 * 'Terminated' all read as done — bash drops done jobs from the table
 * once notified, so a missing job is done too).
 */
export function parseJobsLine(line) {
  if (typeof line !== 'string') return null;
  const m = /^\[(\d+)\][+-]?\s+(\d+)\s+([A-Za-z]+(?:\s+\d+)?)\s+(.*)$/.exec(line);
  if (!m) return null;
  const stateWord = m[3].split(/\s+/)[0];
  const state = stateWord === 'Running' ? 'running'
    : stateWord === 'Stopped' ? 'stopped' : 'done';
  return {job: Number(m[1]), pid: Number(m[2]), state, command: m[4]};
}

/**
 * Parse a jobs snapshot (the raw `jobs -l` text between the JOBS_BEGIN
 * / JOBS_END markers) into an array of jobs. Lines that are not jobs
 * lines (notifications, blanks) are ignored.
 */
export function parseJobsSnapshot(text) {
  if (typeof text !== 'string') return [];
  const jobs = [];
  for (const line of text.split('\n')) {
    const job = parseJobsLine(line);
    if (job) jobs.push(job);
  }
  return jobs;
}

/**
 * Per-session worker state (bridge-side mirror of the Swift worker):
 * - knownAlive: a run completed on this worker (so its cwd is known).
 *   Cleared when a run reports workerDied, is aborted, or the worker
 *   is stopped — the next run then resends the cwd (a rebuilt worker
 *   starts in the remembered directory).
 * - cwd: the worker's last known directory (from the last END marker).
 * - jobs: Map pid → {id, pid, job, command, state, startedAt, endedAt?}.
 * - generation: bumped whenever the worker is known dead/rebuilt; a
 *   run that started under an older generation must not update the
 *   state afterwards (it raced with a stop/kill).
 */
const workerSessions = new Map();
/** Per-session promise chain serializing worker operations. */
const workerRunQueues = new Map();

function workerSessionState(sessionId) {
  let state = workerSessions.get(sessionId);
  if (!state) {
    state = {knownAlive: false, cwd: null, jobs: new Map(), generation: 0};
    workerSessions.set(sessionId, state);
  }
  return state;
}

/** Drop all worker state (tests; also bounds the maps). */
export function clearWorkerState() {
  workerSessions.clear();
  workerRunQueues.clear();
}

/** The cached job table for a session (no network call), sorted by pid. */
export function getWorkerJobs(sessionId) {
  const state = workerSessions.get(sessionId);
  if (!state) return [];
  return [...state.jobs.values()].sort((a, b) => a.pid - b.pid);
}

/** Merge a fresh jobs snapshot into the session's job table. */
function updateWorkerJobs(sessionId, jobs) {
  const state = workerSessionState(sessionId);
  const now = Date.now();
  const seen = new Set();
  for (const job of jobs) {
    seen.add(job.pid);
    const prev = state.jobs.get(job.pid);
    if (prev) {
      prev.state = job.state;
      prev.command = job.command;
      prev.job = job.job;
      if (job.state === 'done' && !prev.endedAt) prev.endedAt = now;
      if (job.state !== 'done') delete prev.endedAt;
    } else {
      state.jobs.set(job.pid, {
        id: String(job.pid), pid: job.pid, job: job.job,
        command: job.command, state: job.state, startedAt: now,
        ...(job.state === 'done' ? {endedAt: now} : {}),
      });
    }
  }
  // A job missing from the snapshot has finished (bash drops done jobs
  // from the table once notified).
  for (const [pid, job] of state.jobs) {
    if (!seen.has(pid) && job.state !== 'done') {
      job.state = 'done';
      job.endedAt = now;
    }
  }
}

/**
 * Serialize worker operations per session: the worker reads one command
 * stream, so two runs (or a run and a jobs refresh) for the same session
 * must never interleave stdin writes. Cross-session operations are
 * independent (different workers). A failed operation does not block
 * the queue (the chain continues).
 */
function enqueueWorkerOp(sessionId, fn) {
  const prev = workerRunQueues.get(sessionId) ?? Promise.resolve();
  const next = prev.then(fn, fn);
  workerRunQueues.set(sessionId, next);
  // The queue tail must never surface an unhandled rejection.
  next.catch(() => {});
  return next;
}

/**
 * POST a small JSON body and parse the JSON response. Used by the
 * worker kill/stop endpoints (no NDJSON streaming there). Rejects with
 * ISH_NOT_BOOTED on 503, ISH_HTTP_ERROR (+ statusCode) otherwise.
 */
function postJson(service, path, bodyObj, opts = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const settleResolve = (value) => { if (!settled) { settled = true; resolvePromise(value); } };
    const settleReject = (error) => { if (!settled) { settled = true; rejectPromise(error); } };
    const body = JSON.stringify(bodyObj);
    const req = httpRequest({
      host: service.host,
      port: service.port,
      agent: loopbackAgent,
      path,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${service.token}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      signal: opts.signal,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        if (res.statusCode === 503) {
          const error = new Error(ISH_NOT_BOOTED);
          error.code = 'ISH_NOT_BOOTED';
          settleReject(error);
          return;
        }
        if (res.statusCode !== 200) {
          const error = new Error(`ish ${path} failed: HTTP ${res.statusCode}`);
          error.code = 'ISH_HTTP_ERROR';
          error.statusCode = res.statusCode;
          settleReject(error);
          return;
        }
        try {
          settleResolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch {
          settleReject(Object.assign(new Error(`ish ${path} returned invalid JSON`), {code: 'ISH_BAD_JSON'}));
        }
      });
      res.on('error', (error) => settleReject(error));
    });
    req.on('error', (error) => {
      if (error?.name === 'AbortError' || error?.code === 'ABORT_ERR') {
        settleReject(Object.assign(new Error('ish request aborted'), {code: 'ISH_ABORTED'}));
        return;
      }
      if (isStaleConnectionError(error)) invalidateServiceInfo();
      settleReject(error);
    });
    req.end(body);
  });
}

/**
 * Run one command on the session worker via POST /ish/worker/run.
 * @param opts.command shell source (required).
 * @param opts.sessionId DSH_SESSION_ID (required — the worker key).
 * @param opts.cwd guest cwd (already translated) or undefined. Sent only
 *   when it differs from the worker's last known cwd, or the worker is
 *   not known alive (a rebuilt worker starts in the remembered cwd).
 * @param opts.env env vars for the per-command overlay (already sanitised) or undefined.
 * @param opts.timeoutMs run timeout (server clamps 1s-15min).
 * @param opts.serviceFile override for tests.
 * @param opts.onLine({stream, line}) called per NDJSON output line
 *   (protocol lines — END marker, jobs blocks — are swallowed).
 * @param opts.onSessionCwd(cwd) called with the worker's final cwd
 *   (from the END marker).
 * @param opts.readOnly true when the session policy is read-only: the
 *   server refuses the run with OHOS_SANDBOX_DENIED instead of
 *   running it on the always-writable workspace mount (H-1).
 * @param opts.signal AbortSignal; aborting cancels the HTTP request,
 *   which makes the Swift side kill the current command (never the
 *   worker). An abort that lands while the run is still queued behind
 *   another run resolves as cancelled when its turn comes.
 * @returns {exitCode, durationMs, timedOut?, cancelled?, workerDied?, cwd?}.
 * @throws ISH_WORKER_UNSUPPORTED (code) when the service predates the
 *   worker endpoints (HTTP 404) — the caller falls back to one-shot.
 */
export async function ishWorkerExec(opts) {
  const sessionId = opts.sessionId;
  if (!sessionId) {
    throw Object.assign(new Error('ishWorkerExec requires a sessionId'), {code: 'ISH_WORKER_NO_SESSION'});
  }
  // R3-N1: command is required (no argv mode here); NUL in command/env/cwd
  // fails before the op is queued, so no HTTP is sent (see assertValidExecInput).
  // R6-1-1 (residual): reuse the validated env snapshot for the body
  // below — do not re-read opts.env, which would enumerate a stateful
  // getter a second time.
  const validatedEnv = assertValidExecInput(opts);
  // R5-1-2: the worker endpoint takes command only — a well-formed argv
  // would otherwise be silently ignored while the command runs as a
  // shell string, so reject it instead of dropping it.
  if (opts.argv !== undefined) {
    throw Object.assign(
      new Error('ishWorkerExec takes command only, no argv mode'),
      {code: 'ISH_INVALID_ARGV'});
  }
  const state = workerSessionState(sessionId);
  return enqueueWorkerOp(sessionId, async () => {
    const generation = state.generation;
    if (opts.signal?.aborted) return {exitCode: null, durationMs: 0, cancelled: true};
    const nonce = randomBytes(16).toString('hex');
    const body = JSON.stringify({
      command: opts.command,
      sessionId,
      ...(opts.cwd && (!state.knownAlive || opts.cwd !== state.cwd) ? {cwd: opts.cwd} : {}),
      ...(validatedEnv && validatedEnv.length > 0 ? {env: Object.fromEntries(validatedEnv)} : {}),
      nonce,
      ...(opts.readOnly ? {readOnly: true} : {}),
      timeoutMs: opts.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS,
    });
    // Protocol-line filter: the END marker and the jobs snapshot blocks
    // are worker protocol, not command output — swallow them, update the
    // session state, and report the cwd via onSessionCwd. A line with a
    // different nonce is ordinary output (same rule as the cwd marker).
    let inJobsBlock = false;
    let inJobpidsBlock = false;
    const jobsLines = [];
    // H-5: same rule as ishExec — any streamed frame (including the
    // protocol lines, which the wrapper prints after the command
    // finishes) proves the command ran, so a mid-stream disconnect
    // must not retry.
    let sawOutput = false;
    const execOpts = {...opts, onLine: (frame) => {
      sawOutput = true;
      const end = parseWorkerEndMarker(frame, nonce);
      if (end) {
        if (state.generation === generation) state.cwd = end.cwd;
        opts.onSessionCwd?.(end.cwd);
        return;
      }
      if (frame?.stream === 'stderr' && typeof frame?.line === 'string') {
        const line = frame.line;
        if (line === `${WORKER_JOBS_BEGIN_PREFIX}${nonce}`) { inJobsBlock = true; jobsLines.length = 0; return; }
        if (line === `${WORKER_JOBS_END_PREFIX}${nonce}`) {
          inJobsBlock = false;
          if (state.generation === generation) updateWorkerJobs(sessionId, parseJobsSnapshot(jobsLines.join('\n')));
          return;
        }
        if (inJobsBlock) { jobsLines.push(line); return; }
        if (line === `${WORKER_JOBPIDS_BEGIN_PREFIX}${nonce}`) { inJobpidsBlock = true; return; }
        if (line === `${WORKER_JOBPIDS_END_PREFIX}${nonce}`) { inJobpidsBlock = false; return; }
        if (inJobpidsBlock) return; // pid lines are Swift-side only
      }
      opts.onLine?.(frame);
    }};
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) invalidateServiceInfo();
      const service = await getServiceInfo(opts);
      if (!service) throw bridgeUnavailableError(opts);
      try {
        const result = await postNdjson(service, '/ish/worker/run', body, execOpts);
        // The run resolved: record the worker state (unless a stop
        // bumped the generation while this run was in flight).
        if (state.generation === generation) {
          if (result.workerDied) {
            state.knownAlive = false;
            state.generation += 1;
            const now = Date.now();
            for (const job of state.jobs.values()) {
              if (job.state !== 'done') { job.state = 'done'; job.endedAt = now; }
            }
          } else if (result.cancelled) {
            // The worker is alive, but its cwd is uncertain (the killed
            // command may have cd'd): force the next run to resend it.
            state.knownAlive = false;
          } else {
            state.knownAlive = true;
          }
        }
        return result;
      } catch (error) {
        lastError = error;
        if (error?.code === 'ISH_NOT_BOOTED') throw lastError;
        if (error?.code === 'ISH_HTTP_ERROR' && error?.statusCode === 404) {
          workerUnsupported = true;
          throw Object.assign(
            new Error('ish worker endpoints are not available on this service'),
            {code: ISH_WORKER_UNSUPPORTED});
        }
        if (error?.code === 'ISH_HTTP_ERROR' && error?.statusCode === 409) {
          // M-10: the server already has a run in flight for this
          // session (worker_busy). Do not retry: an immediate retry
          // would hit the same run, and the per-session queue in this
          // bridge already serialises our own runs — a 409 can only
          // come from another client, so surface it and let the
          // caller decide when to retry. (Deliberately not a
          // one-shot fallback: that would run the command concurrently
          // with the in-flight run and break per-session ordering.)
          throw Object.assign(
            new Error(`ish worker busy: session ${sessionId} already has a run in flight`),
            {code: ISH_WORKER_BUSY});
        }
        // N-1 (round 2): same rule as ishExec — only a failed connect
        // (ECONNREFUSED) retries. A response-phase ECONNRESET / HPE_*
        // must not retry: the worker command may already have run
        // without streaming anything yet. HTTP errors stay retryable
        // (the server answers non-200 before running anything) except
        // 429: a throttle is not a pre-run rejection a retry can fix,
        // and re-hitting it immediately just extends the throttle.
        const retryable = isConnectFailedError(error)
          || (error?.code === 'ISH_HTTP_ERROR' && error?.statusCode !== 429);
        if (retryable && attempt === 0 && !sawOutput) continue;
        throw lastError;
      }
    }
    throw lastError;
  });
}

/**
 * List the session worker's background jobs (fresh snapshot): runs the
 * no-op command `:` on the worker and returns the parsed job table.
 * There is no dedicated loopback endpoint for this on purpose — the
 * snapshot is in-band on every run, and a control channel into the
 * worker's stdin would queue behind the running command anyway.
 * @returns [{id, pid, job, command, state, startedAt, endedAt?}] sorted by pid.
 */
export async function ishWorkerJobs(sessionId, opts = {}) {
  await ishWorkerExec({
    command: ':',
    sessionId,
    timeoutMs: opts.timeoutMs ?? 30_000,
    signal: opts.signal,
    serviceFile: opts.serviceFile,
    onLine: () => {},
  });
  return getWorkerJobs(sessionId);
}

/**
 * Kill one background job by pid (POST /ish/worker/jobs/kill). The
 * server refuses any pid that is not a live descendant of the worker.
 * A pure pid operation — it does not go through the per-session run
 * queue, so it works while a foreground command is running.
 * @returns true when the kill was issued.
 * @throws an error with code ISH_JOB_NOT_FOUND when the pid is not a
 *   job of this worker (already finished, or never was one).
 */
export async function ishWorkerKillJob(sessionId, pid, opts = {}) {
  const state = workerSessionState(sessionId);
  const generation = state.generation;
  let lastError = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) invalidateServiceInfo();
    const service = await getServiceInfo(opts);
    if (!service) throw bridgeUnavailableError(opts);
    try {
      const result = await postJson(service, '/ish/worker/jobs/kill', {sessionId, pid}, opts);
      if (result?.killed === true && state.generation === generation) {
        const job = state.jobs.get(pid);
        if (job && job.state !== 'done') { job.state = 'done'; job.endedAt = Date.now(); }
      }
      return result?.killed === true;
    } catch (error) {
      lastError = error;
      if (error?.code === 'ISH_NOT_BOOTED') throw lastError;
      if (error?.code === 'ISH_HTTP_ERROR' && error?.statusCode === 404) {
        // R3-N2 (option b): a 404 after a retried transport error means
        // the job is gone — most plausibly our first kill landed and its
        // response was lost. The caller's question is "is the job dead",
        // so answer true instead of reporting a kill that already
        // happened as not-found. A 404 on the first attempt still
        // throws: the job never existed (or died before we tried).
        // R4-2: mark the local job done too — the retry-after-404 path
        // answers "the job is dead", so the job table must agree with
        // the return value (same generation-guarded update as the
        // success path above).
        if (attempt > 0) {
          if (state.generation === generation) {
            const job = state.jobs.get(pid);
            if (job && job.state !== 'done') { job.state = 'done'; job.endedAt = Date.now(); }
          }
          return true;
        }
        throw Object.assign(
          new Error(`ish job not found: session ${sessionId} pid ${pid}`),
          {code: ISH_JOB_NOT_FOUND});
      }
      const retryable = isStaleConnectionError(error)
        || error?.code === 'ISH_HTTP_ERROR';
      if (retryable && attempt === 0) continue;
      throw lastError;
    }
  }
  throw lastError;
}

/**
 * Stop one session's worker (POST /ish/worker/stop): kills the worker's
 * whole process tree, so no background job survives its session.
 * Local state is cleared regardless of the outcome (a stop is teardown).
 * N-2 (round 2): the whole stop runs through the per-session queue,
 * serialised with runs — a slow stop's `finally` used to run after a
 * concurrent new run had rebuilt the worker and updated the job table,
 * and unconditionally marked the new worker's live jobs done. (A
 * generation guard alone would not close this: a normal new run does
 * not bump `generation` — only a workerDied result does — so the
 * `finally` would still see an unchanged generation and clear anyway.)
 * @returns true when the request was answered.
 */
export async function ishWorkerStop(sessionId, opts = {}) {
  const state = workerSessions.get(sessionId);
  // R3-N3: stop waits behind an in-flight run — enqueueWorkerOp chains
  // onto the previous op with no timeout and no abort signal of its own,
  // so a hung run starves the stop. Deliberately not fixed by pre-clearing
  // state: clearing knownAlive/jobs before the run finishes would
  // reintroduce the round-2 N-2 ordering break (a later run reusing the
  // session while the old one is still in flight). The wait is bounded in
  // practice by the run's own abort signal and server timeout, not by the
  // queue — so this stays a documented trade-off, not a fix.
  return enqueueWorkerOp(sessionId, async () => {
  try {
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) invalidateServiceInfo();
      const service = await getServiceInfo(opts);
      // M-2: a stop is teardown — no service file means there is
      // nothing left to stop, so this is success, not an error.
      if (!service) return true;
      try {
        await postJson(service, '/ish/worker/stop', {sessionId}, opts);
        break;
      } catch (error) {
        lastError = error;
        if (error?.code === 'ISH_NOT_BOOTED') throw lastError;
        const retryable = isStaleConnectionError(error)
          || error?.code === 'ISH_HTTP_ERROR';
        if (retryable && attempt === 0) continue;
        throw lastError;
      }
    }
  } finally {
    // M-2: local state is cleared regardless of the outcome — the old
    // code only reached this block on the success path, so a failed
    // stop left the session marked knownAlive with a stale cwd and
    // jobs still "running".
    if (state) {
      state.knownAlive = false;
      state.generation += 1;
      const now = Date.now();
      for (const job of state.jobs.values()) {
        if (job.state !== 'done') { job.state = 'done'; job.endedAt = now; }
      }
    }
  }
  return true;
  });
}

/** Whether this service is known to predate the worker endpoints (HTTP 404). */
export function isWorkerUnsupported() {
  return workerUnsupported;
}

// ---------------------------------------------------------------------------
// Minimal WebSocket client (RFC 6455 over node:net)
// ---------------------------------------------------------------------------
// The loopback service authenticates the WS upgrade with an Authorization
// header, which the built-in WebSocket client cannot send, so the handshake
// is hand-rolled. Client frames are masked (required by RFC 6455); server
// frames are never masked. Fragmented messages are re-assembled.

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/**
 * Open a WebSocket to the loopback service.
 * @param opts.path e.g. '/ish/pty'.
 * @param opts.serviceFile override for tests.
 * @param opts.onBinary(Buffer) raw binary message.
 * @param opts.onText(string) complete text message.
 * @param opts.onClose({code, reason}) server close / socket end.
 * @param opts.onError(Error) transport error.
 * @returns {sendBinary(Buffer), sendText(string), close(code?), ready}
 *   where ready resolves once the upgrade completes.
 */
export function ishWebSocket(opts) {
  let socket = null;
  let closed = false;
  let handshakeDone = false;
  let handshakeBuffer = Buffer.alloc(0);
  let frameBuffer = Buffer.alloc(0);
  let fragmentOpcode = 0;
  let fragmentPayload = Buffer.alloc(0);
  const listeners = {binary: [], text: [], close: [], error: []};
  const on = (event, fn) => { listeners[event].push(fn); };
  if (opts.onBinary) on('binary', opts.onBinary);
  if (opts.onText) on('text', opts.onText);
  if (opts.onClose) on('close', opts.onClose);
  if (opts.onError) on('error', opts.onError);
  const emit = (event, ...args) => { for (const fn of listeners[event]) { try { fn(...args); } catch {} } };

  // Connect + WS handshake, retrying once with a FRESH read of
  // ish-service.json. Fix (build 37): the loopback service can restart
  // with a new port/token (stop/start across a terminal reopen), and
  // the bridge kept dialling the stale cached port/token forever —
  // the old code never invalidated the cache on a WS failure, so every
  // retry failed the same way (ECONNREFUSED on the dead port, or 401
  // on the rotated token) while the service itself was up.
  const ready = (async () => {
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) invalidateServiceInfo();
      const service = await getServiceInfo(opts);
      if (!service) throw bridgeUnavailableError(opts);
      try {
        await connectOnce(service);
        return;
      } catch (error) {
        lastError = error;
        try { socket?.destroy(); } catch {}
        socket = null;
        handshakeDone = false;
        handshakeBuffer = Buffer.alloc(0);
        // R3-N-1: a 4xx refusal is deterministic (policy denial, bad
        // request) — retrying the identical handshake cannot succeed,
        // so fail immediately instead of spending the second attempt.
        // R4-1: 401 is the exception — it only means the cached token
        // is stale (the service rotates its token on restart), and the
        // retry re-reads the service file, so retry it once.
        if (attempt === 0 && !(error?.statusCode >= 400 && error?.statusCode < 500 && error?.statusCode !== 401)) continue;
        throw lastError;
      }
    }
    throw lastError;
  })();

  async function connectOnce(service) {
    const key = randomBytes(16).toString('base64');
    const expectedAccept = createHash('sha1').update(key + WS_GUID).digest('base64');
    socket = netConnect({host: service.host, port: service.port});
    await new Promise((resolvePromise, rejectPromise) => {
      socket.once('error', rejectPromise);
      socket.once('connect', resolvePromise);
    });
    const handshake = [
      `GET ${opts.path} HTTP/1.1`,
      `Host: ${service.host}:${service.port}`,
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Key: ${key}`,
      'Sec-WebSocket-Version: 13',
      `Authorization: Bearer ${service.token}`,
      '', '',
    ].join('\r\n');
    socket.write(handshake);
    // M-3: the old promise only listened for 'data' and 'error', so a
    // clean server FIN during the upgrade (no data, no error) left
    // `ready` pending forever. Reject on 'close'/'end' too, and cap
    // the whole handshake with a timeout. Listeners are removed on
    // settle so the post-handshake handlers below are the only ones.
    await new Promise((resolvePromise, rejectPromise) => {
      let settled = false;
      const cleanup = () => {
        socket.off('data', onData);
        socket.off('error', onError);
        socket.off('close', onClose);
        socket.off('end', onEnd);
      };
      const fail = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        cleanup();
        rejectPromise(error);
      };
      const done = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        cleanup();
        resolvePromise();
      };
      const onError = (error) => fail(error);
      const onClose = () => fail(Object.assign(
        new Error('ish websocket closed during handshake'),
        {code: 'ISH_WS_CLOSED_DURING_HANDSHAKE'}));
      const onEnd = () => fail(Object.assign(
        new Error('ish websocket ended during handshake'),
        {code: 'ISH_WS_CLOSED_DURING_HANDSHAKE'}));
      const timer = setTimeout(() => fail(Object.assign(
        new Error('ish websocket handshake timed out'),
        {code: 'ISH_WS_HANDSHAKE_TIMEOUT'})), WS_HANDSHAKE_TIMEOUT_MS);
      const onData = (chunk) => {
        handshakeBuffer = Buffer.concat([handshakeBuffer, chunk]);
        const end = handshakeBuffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = handshakeBuffer.subarray(0, end).toString('latin1');
        const rest = handshakeBuffer.subarray(end + 4);
        const statusLine = head.split('\r\n')[0] ?? '';
        if (!statusLine.includes('101')) {
          // R3-N-1: a refusal carries a JSON body, e.g. 403
          // {"error": "OHOS_SANDBOX_DENIED ..."}. Surface its error field
          // so the terminal shows why it was refused instead of a bare
          // status line. The body normally arrives with the headers in
          // one write; a split or empty body just falls back to the
          // status line. statusCode lets the retry loop skip 4xx below.
          const statusCode = Number(/^\S+ (\d{3})/.exec(statusLine)?.[1]);
          let detail = '';
          if (rest.length > 0) {
            try {
              const parsed = JSON.parse(rest.toString('utf8'));
              if (typeof parsed?.error === 'string' && parsed.error) detail = `: ${parsed.error}`;
            } catch {}
          }
          fail(Object.assign(
            new Error(`ish websocket upgrade failed: ${statusLine}${detail}`),
            {code: 'ISH_WS_UPGRADE_FAILED', statusLine,
              ...(Number.isInteger(statusCode) ? {statusCode} : {})}));
          return;
        }
        const accept = /^Sec-WebSocket-Accept:\s*(.+)$/im.exec(head)?.[1]?.trim();
        if (accept !== expectedAccept) {
          fail(Object.assign(new Error('ish websocket accept mismatch'), {code: 'ISH_WS_ACCEPT_MISMATCH'}));
          return;
        }
        handshakeDone = true;
        if (rest.length > 0) feedFrames(rest);
        done();
      };
      socket.on('data', onData);
      socket.once('error', onError);
      socket.once('close', onClose);
      socket.once('end', onEnd);
    });
    socket.on('data', (chunk) => feedFrames(chunk));
    socket.on('error', (error) => { emit('error', error); closeSocket(); });
    socket.on('close', () => closeSocket());
  }

  function feedFrames(chunk) {
    frameBuffer = Buffer.concat([frameBuffer, chunk]);
    for (;;) {
      if (frameBuffer.length < 2) return;
      const b0 = frameBuffer[0];
      const b1 = frameBuffer[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      let length = b1 & 0x7f;
      let headerLen = 2;
      if (length === 126) {
        if (frameBuffer.length < 4) return;
        length = (frameBuffer[2] << 8) | frameBuffer[3];
        headerLen = 4;
      } else if (length === 127) {
        if (frameBuffer.length < 10) return;
        let value = 0n;
        for (let i = 0; i < 8; i++) value = (value << 8n) | BigInt(frameBuffer[2 + i]);
        if (value > BigInt(Number.MAX_SAFE_INTEGER)) { closeSocket(1009, 'message too large'); return; }
        length = Number(value);
        headerLen = 10;
      }
      if (frameBuffer.length < headerLen + length) return;
      const payload = frameBuffer.subarray(headerLen, headerLen + length);
      frameBuffer = frameBuffer.subarray(headerLen + length);
      handleFrame(fin, opcode, Buffer.from(payload));
    }
  }

  function handleFrame(fin, opcode, payload) {
    if (opcode === 0x8) { // Close: echo the code, then close.
      let code = 1000;
      let reason = 'server closed';
      if (payload.length >= 2) {
        code = (payload[0] << 8) | payload[1];
        // The server's close reason (e.g. the 1008 cap message) is
        // UTF-8 after the code; propagate it so the PTY shim can
        // print it instead of a bare code.
        if (payload.length > 2) reason = payload.subarray(2).toString('utf8');
      }
      sendFrame(0x8, payload.subarray(0, 2));
      closeSocket(code, reason);
      return;
    }
    if (opcode === 0x9) { // Ping: reply pong with the same payload.
      sendFrame(0xA, payload);
      return;
    }
    if (opcode === 0xA) return; // Pong: ignore.
    if (opcode !== 0x0 && opcode !== 0x1 && opcode !== 0x2) {
      closeSocket(1002, 'unknown opcode');
      return;
    }
    if (opcode !== 0x0) {
      fragmentOpcode = opcode;
      fragmentPayload = payload;
    } else {
      fragmentPayload = Buffer.concat([fragmentPayload, payload]);
    }
    if (!fin) return;
    const messageOpcode = fragmentOpcode;
    const message = fragmentPayload;
    fragmentPayload = Buffer.alloc(0);
    if (messageOpcode === 0x1) emit('text', message.toString('utf8'));
    else if (messageOpcode === 0x2) emit('binary', message);
  }

  function sendFrame(opcode, payload) {
    if (!socket || socket.destroyed || !handshakeDone) return;
    const mask = randomBytes(4);
    const header = [0x80 | opcode];
    const length = payload.length;
    if (length < 126) header.push(0x80 | length);
    else if (length <= 0xffff) header.push(0x80 | 126, (length >> 8) & 0xff, length & 0xff);
    else {
      header.push(0x80 | 127);
      const value = BigInt(length);
      for (let shift = 56n; shift >= 0n; shift -= 8n) header.push(Number((value >> shift) & 0xffn));
    }
    const masked = Buffer.from(payload);
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4];
    socket.write(Buffer.concat([Buffer.from(header), mask, masked]));
  }

  function closeSocket(code = 1000, reason = '') {
    if (closed) return;
    closed = true;
    try { socket?.destroy(); } catch {}
    emit('close', {code, reason});
  }

  return {
    ready,
    get handshakeDone() { return handshakeDone; },
    sendBinary: (data) => sendFrame(0x2, Buffer.from(data)),
    sendText: (text) => sendFrame(0x1, Buffer.from(text, 'utf8')),
    close: (code = 1000) => {
      if (!closed && handshakeDone) sendFrame(0x8, Buffer.from([(code >> 8) & 0xff, code & 0xff]));
      closeSocket(code, 'client closed');
    },
    on,
  };
}

// ---------------------------------------------------------------------------
// Session cwd memory (ENV-14)
// ---------------------------------------------------------------------------

/**
 * Marker the Swift wrapper prints on stderr after each command:
 * `__DSH_CWD__<nonce>:<guest absolute path>`. The nonce is generated
 * per exec by spawnIshExec and echoed back by the wrapper, so only a
 * marker from this exec can update the remembered cwd.
 */
export const CWD_MARKER_PREFIX = '__DSH_CWD__';

/**
 * Parse a cwd marker frame. Returns the guest cwd, or null when the
 * frame is not a marker for this nonce. The cwd must be an absolute
 * guest path with no control characters; anything else is treated as
 * ordinary output (a command that prints a look-alike line, or a cwd
 * with a newline in it, degrades to "no update" instead of corrupting
 * the remembered cwd).
 */
export function parseCwdMarker(frame, nonce) {
  if (!nonce || frame?.stream !== 'stderr' || typeof frame?.line !== 'string') return null;
  const prefix = `${CWD_MARKER_PREFIX}${nonce}:`;
  if (!frame.line.startsWith(prefix)) return null;
  const cwd = frame.line.slice(prefix.length);
  if (!cwd.startsWith('/') || /[\0-\x1f\x7f]/.test(cwd)) return null;
  return cwd;
}

/**
 * Per-session exec cwd state, keyed by DSH_SESSION_ID:
 * - engineCwd: the last guest cwd the engine asked for (options.cwd
 *   translated). The engine only changes this when the model uses the
 *   working-directory cd tool, so it is the model-visible source of
 *   truth — when it changes, it wins over the remembered cwd.
 * - rememberedCwd: the guest shell's final cwd after the last exec
 *   (from the marker line), i.e. where a bare `cd` inside bash left it.
 *   Used while the engine cwd is unchanged.
 */
const sessionCwdState = new Map();

/**
 * Resolve the guest cwd for one exec (ENV-14).
 * @param sessionId DSH_SESSION_ID, or null when unknown (no memory).
 * @param engineCwdGuest the engine-requested guest cwd (already
 *   translated), or null/undefined when the engine gave none.
 * @returns the guest cwd to send to /ish/exec (or undefined).
 */
export function resolveExecCwd(sessionId, engineCwdGuest) {
  if (!sessionId) return engineCwdGuest ?? undefined;
  const state = sessionCwdState.get(sessionId);
  if (!state) {
    if (engineCwdGuest) sessionCwdState.set(sessionId, {engineCwd: engineCwdGuest, rememberedCwd: null});
    return engineCwdGuest ?? undefined;
  }
  if (engineCwdGuest && state.engineCwd && engineCwdGuest !== state.engineCwd) {
    // The engine moved the session (working-directory cd tool, or a
    // new workdir): the engine is the source of truth; forget the
    // bare-`cd` memory, which belonged to the old directory.
    // (state.engineCwd null means the memory was recorded before any
    // engine cwd was seen — e.g. a direct ishExec call — so there is
    // no "move" to detect and the memory stands.)
    state.engineCwd = engineCwdGuest;
    state.rememberedCwd = null;
    return engineCwdGuest;
  }
  if (engineCwdGuest) state.engineCwd = engineCwdGuest;
  return state.rememberedCwd ?? engineCwdGuest ?? undefined;
}

/** Record the guest's final cwd for a session (from a marker line). */
export function noteExecCwd(sessionId, cwd) {
  if (!sessionId || !cwd) return;
  const state = sessionCwdState.get(sessionId) ?? {engineCwd: null, rememberedCwd: null};
  state.rememberedCwd = cwd;
  sessionCwdState.set(sessionId, state);
}

/** Drop all remembered session cwds (tests; also bounds the map). */
export function clearExecCwdState() {
  sessionCwdState.clear();
}

// ---------------------------------------------------------------------------
// Env sanitising (guest must not inherit host paths)
// ---------------------------------------------------------------------------

/**
 * Build the env to export in the guest. Host filesystem paths (PATH, HOME,
 * TMPDIR, DSH_HOME, ...) are never forwarded: the guest has its own
 * layout. Only DSH_* context vars, locale/terminal hints and an explicit
 * guest PATH/HOME are passed.
 */
/**
 * DSH context vars that are safe to forward (identifiers, not paths).
 * DSH_HOME and any other DSH_* path var are deliberately excluded: the
 * guest has its own layout, and a host path in the guest env would
 * misdirect guest tools.
 */
const GUEST_ENV_DSH_ALLOW = new Set(['DSH_SESSION_ID', 'DSH_SHELL', 'DSH_PTY_SESSION_ID']);

/**
 * Build the env to export in the guest. Host filesystem paths (PATH, HOME,
 * TMPDIR, DSH_HOME, ...) are never forwarded: the guest has its own
 * layout. Only DSH_* context vars, locale/terminal hints and an explicit
 * guest PATH/HOME are passed.
 *
 * @param hostEnv the spawn's env (engine + caller).
 * @param opts.hasPty true when this exec runs with a pty (ENV-12): only
 *   then is TERM forwarded. A piped exec has no tty, so TERM is dropped
 *   entirely — the old code forwarded the engine's TERM=dumb and
 *   defaulted to xterm-256color, both of which lie about the terminal
 *   (and the executor base envp no longer sets TERM for the exec path
 *   either; the PTY path sets it in ISHKernel.executeCommand).
 * @param opts.ptyTerm TERM value for a pty exec when the host env has
 *   none (default 'xterm-256color', matching /etc/profile).
 *
 * ENV-13: PYTHONDONTWRITEBYTECODE=0 is always set (unless the caller
 * explicitly passes a value, which wins) so guest Python writes .pyc
 * files — the old forced =1 made every pip import recompile from
 * source (ENV-03). The kernel patch removes the matching injection;
 * this also neutralises kernels built before that patch, whose
 * sys_execve injection is mode-0 ("only if absent"). GOMAXPROCS /
 * UV_THREADPOOL_SIZE are deliberately NOT set here: the kernel patch
 * deletes their hardcoded values so Go uses runtime.NumCPU and libuv
 * its default. PIP_PROGRESS_BAR stays off via the kernel injection.
 */
export function guestEnv(hostEnv = {}, opts = {}) {
  const hasPty = opts.hasPty === true;
  const env = {};
  // R7-1-1: a throwing env getter used to leak its raw error out of
  // Object.entries (and spawnIshExec then misclassified it as
  // ISH_BRIDGE_UNAVAILABLE). Enumeration failure is a client-side
  // argument error.
  let entries;
  try {
    entries = Object.entries(hostEnv ?? {});
  } catch {
    throw Object.assign(
      new Error('ish env must be an object mapping strings to strings'),
      {code: 'ISH_INVALID_ARGV'});
  }
  for (const [key, value] of entries) {
    if (typeof value !== 'string') continue;
    if (key === 'TERM') {
      // TERM only means something with a tty; without one it is
      // dropped (see opts.hasPty). With one, the host value wins.
      if (hasPty) env[key] = value;
      continue;
    }
    if (GUEST_ENV_DSH_ALLOW.has(key) || key === 'LANG' || key.startsWith('LC_') || key === 'TZ'
      || key === 'PYTHONDONTWRITEBYTECODE') {
      env[key] = value;
    }
  }
  // Guest layout (matches the rootfs /etc/profile): never the host PATH/HOME.
  env.PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
  env.HOME = '/root';
  if (hasPty) env.TERM = env.TERM ?? opts.ptyTerm ?? 'xterm-256color';
  // ENV-13/ENV-03: allow .pyc caching (caller value wins when given).
  env.PYTHONDONTWRITEBYTECODE = env.PYTHONDONTWRITEBYTECODE ?? '0';
  return env;
}

// ---------------------------------------------------------------------------
// Spawn shim (agent `bash` path): childProcess.spawn for "/ish-runner"
// ---------------------------------------------------------------------------

/**
 * Split a confined argv at the first bare "--" (the separator confine()
 * inserts between the runner profile args and the original argv).
 * @returns original argv after "--", or null when there is no separator.
 */
export function splitConfinedArgv(argv) {
  const index = argv.indexOf('--');
  if (index < 0) return null;
  return argv.slice(index + 1);
}

/**
 * Extract the shell command from a confined bash argv.
 * confine() wraps ["bash", "-c", command]; anything else is not a bash
 * call and must fail closed rather than run something unintended.
 */
export function extractBashCommand(argv) {
  const original = splitConfinedArgv(argv);
  if (!original || original.length < 3) return null;
  if (original[0] !== 'bash' || original[1] !== '-c') return null;
  return original[2];
}


// ---------------------------------------------------------------------------
// Spawn shim (agent `bash` path): childProcess.spawn for "/ish-runner"
// ---------------------------------------------------------------------------

/**
 * Run one confined bash command in the guest and present it as a
 * ChildProcess. Shape mirrors pnpm-ios.mjs's spawnPnpmInProcess (the
 * fields dsh-subprocess-local's spawnSubprocess reads): pid, stdin /
 * stdout / stderr, stdio, exitCode, signalCode, killed, spawnfile,
 * spawnargs, once('error' | 'exit'), kill().
 *
 * Stdin: the bash executor writes stdinMode.data and ends the stream
 * immediately after spawn, so the shim collects stdin for up to 25ms
 * (or until it ends) and then POSTs. Input written later is discarded;
 * the guest command sees EOF. This matches the bash tool's non-
 * interactive contract.
 *
 * Timeout: the DSH-side deadline (default 120s, max 600s) is the
 * operative timeout. It reaches the shim as options.signal (plumbed
 * by the patched spawnSubprocess), and aborting it cancels the HTTP
 * request, so the server kills the guest process group and the tool
 * reports the timeout with partial output. The exec's own timeoutMs
 * is DEFAULT_EXEC_TIMEOUT_MS (600s = the bash executor's max), a
 * backstop only — it must never fire first for a DSH-timed command,
 * or the tool would see exitCode -3 with no timeout marker.
 *
 * Kill: child.kill() aborts the HTTP request, as does the caller's
 * AbortSignal (options.signal — the DSH deadline / user Stop). The
 * Swift side cancels the exec on disconnect, which kills the guest
 * process group. Note the managed handle's owner.signal() is a no-op
 * for a synthetic pid (process.kill on the fake group is ESRCH), so
 * the DSH-side terminate() cannot reach the guest directly — the
 * abort-through-disconnect is the kill path, and the server-side
 * timeout is the backstop.
 *
 * PTY exec: options.tty === true runs the command on a fresh fake
 * PTY instead of pipes (ENV-02): stdin is fed chunked + EOT, the
 * stream is merged (stderr arrives as stdout), TERM is
 * xterm-256color. The child reports it as child.ishTty (true when
 * the server's terminal frame echoed {tty: true}). The DSH-side
 * trigger that sets options.tty is outside this file (the bash tool
 * does not pass it today); the plumbing is here so a caller can opt
 * in per command.
 *
 * PTY interface (ENV-12): the piped exec path has no pty, so TERM is
 * not forwarded by default. When a PTY-backed exec calls this shim,
 * pass options.pty === true (and optionally options.ptyTerm, default
 * 'xterm-256color'); the bridge then forwards TERM, and the Swift
 * side still just exports what it is sent. Do not set options.pty
 * for the piped /ish/exec path.
 *
 * Cwd (ENV-14): options.cwd is the engine's workdir (spec.workdir,
 * from the bash executor's config.cwd) and is forwarded via toGuest
 * — the bridge never ignores it. What the bridge adds is memory: a
 * bare `cd` inside the guest shell is invisible to the engine, so
 * the Swift wrapper reports the shell's final cwd in a nonce-tagged
 * marker line and the bridge reuses it for the next exec of the same
 * session while the engine cwd is unchanged (resolveExecCwd). If the
 * engine cwd changes (working-directory cd tool), the engine wins
 * and the memory is forgotten. Without a DSH_SESSION_ID in the env
 * there is no memory (stateless, as before).
 *
 * Persistent worker (ENV-04): a piped exec with a session id runs on
 * the session's long-lived guest /bin/bash (ishWorkerExec) instead of
 * a fresh shell per command — no per-command process creation or shell
 * start. The worker takes no stdin (a command that reads stdin sees
 * /dev/null; stdinData forces the one-shot path), no tty, and is
 * skipped when options.worker === false or the service predates the
 * worker endpoints (then the shim goes straight to one-shot). A
 * worker failure falls back to one-shot only before any output has
 * streamed and only for failures that prove the command never ran;
 * anything else fails closed. child.ishWorker reports which path
 * served the exec (like child.ishTty for the PTY path).
 *
 * Read-only sessions (H-1): options.readOnly === true (from the
 * session policy.mode, via the adapter) is forwarded to both the
 * worker run and the one-shot POST as {readOnly: true}; the server
 * refuses the exec with OHOS_SANDBOX_DENIED instead of running it.
 * The workspace bind mount is always writable, so the denial happens
 * server-side per request — never by remounting.
 *
 * Argv mode (B): when argv is not a bash triplet, it is a direct
 * guest exec (rg/git/node/gh/python3/pip from the adapter) — argv is
 * sent verbatim, no shell is involved, the worker is skipped, and no
 * cwd marker is requested (there is no shell to print one).
 */
export function spawnIshExec(argv, options = {}) {
  const command = extractBashCommand(argv);
  // B (argv mode): a non-bash argv is a direct guest exec, not a shell
  // command — rg/git/node/gh/python3/pip arrive here from the adapter
  // without the /ish-runner wrap. The worker is bash-only, so argv
  // execs always take the one-shot path below.
  const guestArgv = command === null ? argv : null;
  const child = new EventEmitter();
  const stdioOpt = Array.isArray(options.stdio) ? options.stdio : ['pipe', 'pipe', 'pipe'];
  const out = createSink(stdioOpt[1], process.stdout);
  const err = createSink(stdioOpt[2], process.stderr);
  // Stdin: buffer what the caller writes, then hand it to the exec.
  const stdinChunks = [];
  let stdinEnded = false;
  const input = stdioOpt[0] === 'pipe'
    ? new Writable({
        write(chunk, _encoding, done) { stdinChunks.push(Buffer.from(chunk)); done(); },
        final(done) { stdinEnded = true; done(); },
      })
    : null;
  if (input) input.on('error', () => {});

  child.pid = nextSyntheticPid();
  child.stdin = input;
  child.stdout = out.stream;
  child.stderr = err.stream;
  // Whether this exec ran on a PTY (options.tty, confirmed by the
  // server's terminal frame). False until the frame says otherwise.
  child.ishTty = false;
  // Whether this exec ran on the persistent shell worker (ENV-04).
  // False until a worker run serves it (a one-shot fallback leaves it
  // false, so callers can tell which path served the exec).
  child.ishWorker = false;
  // stdio[7] is the subprocess control fd; the shim has no control
  // channel, so stdio is exactly 3 entries and controlPipe() yields
  // undefined (the managed handle works without it).
  child.stdio = [input, out.stream, err.stream];
  child.exitCode = null;
  child.signalCode = null;
  child.killed = false;
  child.spawnfile = guestArgv && guestArgv.length > 0 ? guestArgv[0] : ISH_RUNNER_COMMAND;
  child.spawnargs = argv;

  let settled = false;
  const abortController = new AbortController();
  // Wire the caller's AbortSignal (DSH passes spec.signal via the spawn
  // options — the deadline abort / user Stop — plumbed by the patched
  // spawnSubprocess). Aborting cancels the HTTP request, which makes
  // the Swift side kill the guest process group. Without this, DSH
  // timeout / Stop never reaches the guest: the managed handle's
  // owner.signal() is a no-op for the synthetic pid (ESRCH), so the
  // guest command would run until the server timeout instead.
  const outerSignal = options.signal;
  if (outerSignal) {
    if (outerSignal.aborted) abortController.abort();
    else outerSignal.addEventListener('abort', () => abortController.abort(), {once: true});
  }
  const finish = (code, signal) => {
    if (settled) return;
    settled = true;
    child.exitCode = code;
    child.signalCode = signal;
    child.emit('exit', code, signal);
    for (const stream of [out.stream, err.stream]) {
      if (stream) stream.end();
    }
    const streams = [out.stream, err.stream].filter((s) => s !== null);
    if (streams.length === 0) {
      child.emit('close', code, signal);
      return;
    }
    // T-3: if the consumer already destroyed a stream, its 'close'
    // already fired (or never will again) — count it done now instead
    // of waiting forever for an event that already happened.
    Promise.all(streams.map((s) => new Promise((done) => {
      if (s.closed || s.destroyed) { done(); return; }
      s.once('close', done);
    })))
      .then(() => child.emit('close', code, signal));
  };

  child.kill = (signal) => {
    if (settled) return false;
    child.killed = true;
    abortController.abort();
    finish(null, typeof signal === 'string' ? signal : 'SIGTERM');
    return true;
  };

  // Collect immediately-written stdin, then POST. The bash executor
  // writes its stdin data synchronously after spawn; 25ms covers it
  // without delaying the common (no-stdin) case noticeably.
  const stdinWait = new Promise((done) => {
    if (!input) { done(); return; }
    if (stdinEnded) { done(); return; }
    const timer = setTimeout(done, 25);
    input.once('finish', () => { clearTimeout(timer); done(); });
  });

  void (async () => {
    try {
      await stdinWait;
      if (settled) return; // killed while waiting for stdin
      if (abortController.signal.aborted) { finish(null, 'SIGTERM'); return; } // aborted while waiting for stdin
      const stdinData = stdinChunks.length > 0 ? Buffer.concat(stdinChunks) : undefined;
      // ENV-14: the engine's cwd (spec.workdir) is the only cwd the
      // bridge is given, and it only changes via the working-directory
      // cd tool — a bare `cd` inside the guest shell never reaches it.
      // resolveExecCwd reuses the guest's final cwd from the previous
      // exec while the engine cwd is unchanged (see the marker below).
      // R7-1-1: the DSH_SESSION_ID read is outside guestEnv's
      // enumeration guard, so a throwing getter on that key needs the
      // same ISH_INVALID_ARGV mapping here.
      let sessionId = null;
      try {
        sessionId = typeof options.env?.DSH_SESSION_ID === 'string'
          ? options.env.DSH_SESSION_ID : null;
      } catch {
        throw Object.assign(
          new Error('ish env must be an object mapping strings to strings'),
          {code: 'ISH_INVALID_ARGV'});
      }
      const engineCwd = toGuest(options.cwd ?? process.cwd());
      const guestCwd = resolveExecCwd(sessionId, engineCwd);
      const env = guestEnv(options.env ?? {}, {hasPty: options.pty === true, ptyTerm: options.ptyTerm});
      // One nonce per exec: the Swift wrapper echoes it in the cwd
      // marker, so only this exec's marker can update the memory.
      const cwdNonce = sessionId ? randomBytes(8).toString('hex') : null;
      const emitLine = ({stream, line}) => {
        (stream === 'stderr' ? err : out).write(line + '\n');
      };
      const runOneShot = () => ishExec({
        ...(command !== null ? {command} : {}),
        ...(guestArgv ? {argv: guestArgv} : {}),
        cwd: guestCwd ?? undefined,
        env,
        stdinData,
        // B: the cwd marker is a shell-wrapper feature (ENV-14) — an
        // argv exec has no shell to print it, and it cannot change the
        // session shell's cwd, so no nonce is sent in argv mode.
        ...(cwdNonce && command !== null ? {cwdNonce} : {}),
        onSessionCwd: (cwd) => noteExecCwd(sessionId, cwd),
        tty: options.tty === true,
        ...(options.readOnly ? {readOnly: true} : {}),
        timeoutMs: DEFAULT_EXEC_TIMEOUT_MS,
        signal: abortController.signal,
        onLine: emitLine,
      });
      // ENV-04: route piped execs with a session id to the persistent
      // worker (no per-command shell start). The worker takes no stdin
      // (its stdin is the command channel — a command that reads stdin
      // sees /dev/null instead, see buildWorkerCommand), no tty, and
      // can be opted out of with options.worker === false. A fallback
      // to one-shot happens ONLY before any output has streamed, and
      // only for failures that prove the command never ran (old service
      // 404, not booted, worker start failure, bad request): re-running
      // a command that already produced output — or may have run —
      // would execute it twice, so those fail closed instead.
      let result = null;
      // B: argv execs never take the worker (bash-only); they go
      // one-shot via runOneShot below.
      const useWorker = options.worker !== false && sessionId && !options.tty
        && !stdinData && !workerUnsupported && command !== null;
      if (useWorker) {
        let sawOutput = false;
        try {
          result = await ishWorkerExec({
            command,
            sessionId,
            cwd: guestCwd ?? undefined,
            // The worker has no tty: never forward TERM, even if the
            // caller passed options.pty (that flag belongs to the tty
            // exec path, which never takes the worker).
            env: guestEnv(options.env ?? {}, {hasPty: false}),
            timeoutMs: DEFAULT_EXEC_TIMEOUT_MS,
            signal: abortController.signal,
            onSessionCwd: (cwd) => noteExecCwd(sessionId, cwd),
            ...(options.readOnly ? {readOnly: true} : {}),
            onLine: (frame) => { sawOutput = true; emitLine(frame); },
          });
          child.ishWorker = true;
        } catch (error) {
          const fallBack = !sawOutput && (error?.code === ISH_WORKER_UNSUPPORTED
            || error?.code === 'ISH_NOT_BOOTED' || error?.code === 'ISH_HTTP_ERROR'
            || isConnectFailedError(error));
          if (!fallBack) throw error;
          // Worker unavailable (old service, start failure, or a
          // request the server rejected before running it): one-shot.
          result = null;
        }
      }
      if (result === null) {
        // M-16: the one-shot path goes through the same per-session
        // queue as worker runs, so two overlapping bash calls for one
        // session cannot run concurrently in the guest (cwd memory and
        // output order would interleave). This is safe here: the
        // worker slot above has already been released by the time we
        // get here, so no self-deadlock. Without a session id there is
        // no queue to join — the exec runs unqueued, as before.
        result = sessionId
          ? await enqueueWorkerOp(sessionId, runOneShot)
          : await runOneShot();
      }
      if (settled) return;
      if (result.cancelled) {
        finish(null, 'SIGTERM');
        return;
      }
      // Confirm the PTY from the server side (the frame echoes
      // {tty: true} for a PTY exec); a plain pipe exec reports false.
      child.ishTty = result.tty === true;
      finish(typeof result.exitCode === 'number' ? result.exitCode : 1, null);
    } catch (error) {
      if (settled) return;
      // Fail closed with the runner-failure signature so dsh-bash-sandbox
      // classifies this as SANDBOX_UNAVAILABLE (not a command failure).
      // R7-1-1: preserve ISH_INVALID_ARGV like ISH_NOT_BOOTED, so a
      // throwing env getter is reported as an argument error instead of
      // being rewritten as ISH_BRIDGE_UNAVAILABLE.
      const detail = error?.code === 'ISH_NOT_BOOTED' ? ISH_NOT_BOOTED
        : error?.code === 'ISH_INVALID_ARGV' ? 'ISH_INVALID_ARGV'
        : ISH_BRIDGE_UNAVAILABLE;
      err.write(`${detail}: ${error?.message ?? error}\n`);
      finish(1, null);
    }
  })();

  process.nextTick(() => child.emit('spawn'));
  return child;
}

/** PassThrough sink for one stdio slot (mirrors pnpm-ios.mjs createSink). */
function createSink(mode, inherited) {
  if (mode === 'pipe' || mode === undefined) {
    const stream = new PassThrough();
    return {stream, write: (text) => { stream.write(text); }};
  }
  if (mode === 'ignore' || mode === null) return {stream: null, write: () => {}};
  return {stream: null, write: (text) => { inherited.write(text); }};
}

/**
 * Install the childProcess.spawn patch (pnpm-ios.mjs technique). Only the
 * "/ish-runner" sentinel is intercepted; every other spawn goes to the
 * real spawn unchanged. Returns the previous spawn for tests.
 */
export function installSpawnPatch() {
  const realSpawn = childProcess.spawn;
  childProcess.spawn = function spawn(file, args, options) {
    if (file === ISH_RUNNER_COMMAND) {
      return spawnIshExec(Array.isArray(args) ? args : [], options ?? {});
    }
    return realSpawn.apply(this, arguments);
  };
  // Modules that already imported `spawn` (e.g. execa) must see the patch.
  syncBuiltinESMExports();
  return realSpawn;
}

// ---------------------------------------------------------------------------
// PTY shim (interactive terminal): node-pty-compatible Terminal over WS
// ---------------------------------------------------------------------------

/**
 * A node-pty-compatible Terminal backed by WS /ish/pty. The interface
 * dsh-subprocess-local's LocalTerminalHandle needs: pid, onData(cb) /
 * onExit(cb) returning {dispose()}, write(string), resize(cols, rows),
 * pause(), resume(), kill(signal).
 *
 * Bytes are forwarded transparently (no line buffering, no escape
 * mangling) so the DSH headless xterm can answer DSR/CPR itself. Inbound
 * WS binary frames are decoded incrementally (StringDecoder) so a
 * multi-byte UTF-8 character split across frames is not corrupted.
 *
 * Only one PTY session can exist at a time (single shared _consoleTTY
 * Swift-side); a second open is refused with close 1008, which surfaces
 * here as an onExit with an explanatory line on the output stream.
 * (Stage 5.3: MULTI-SESSION — the kernel routes each socket to its own
 * PTY session, so any number of IshPtyTerminal instances up to the
 * kernel cap (8) can be live at once; close 1008 now only fires at the
 * cap, and the server's reason is printed. Each instance owns its WS
 * connection, its decoder, its pause buffer and its exit state — no
 * shared mutable state between instances.)
 */
export class IshPtyTerminal {
  constructor(file, args, options = {}) {
    this._file = file;
    this._args = Array.isArray(args) ? args : [];
    this._options = options;
    this._pid = nextSyntheticPid();
    this._cols = options.cols ?? 80;
    this._rows = options.rows ?? 24;
    // N-2 (H-1 residual): a read-only terminal upgrade carries
    // ?readOnly=1 — a GET upgrade has no body, so the flag rides the
    // query and handlePTYUpgrade refuses before spawning the shell.
    this._readOnly = options.readOnly === true;
    this._dataListeners = [];
    this._exitListeners = [];
    this._decoder = new StringDecoder('utf8');
    this._paused = false;
    this._pausedBuffers = [];
    this._exited = false;
    this._ws = null;
    // Input written before the WS handshake completes (M-6): queued
    // and flushed in order once `ready` resolves, instead of being
    // silently dropped by sendFrame's handshakeDone check. Bounded
    // (PTY_PENDING_MAX_BYTES) so a handshake that never completes
    // cannot grow it without bound; excess input is dropped.
    this._pendingFrames = [];
    this._pendingBytes = 0;
    // N-3 (round 2): true once _open has flushed the queued frames.
    // write() queues while this is false, so input arriving in the
    // tick where the handshake completes cannot overtake the queued
    // frames. Set by _open only, never cleared (the terminal is
    // single-use; after _exit, write() returns early on _exited).
    this._flushed = false;
    // Kernel session id, learned from the server's session hello
    // ({"type":"session","sessionId":"..."}) right after the upgrade.
    // Null until the hello arrives (older servers never send it).
    // Diagnostics only — routing is by socket, the client never has
    // to send the id anywhere.
    this.sessionId = null;
    this._ready = this._open();
  }

  get pid() { return this._pid; }
  get cols() { return this._cols; }
  get rows() { return this._rows; }

  onData(listener) {
    this._dataListeners.push(listener);
    return {dispose: () => {
      const i = this._dataListeners.indexOf(listener);
      if (i >= 0) this._dataListeners.splice(i, 1);
    }};
  }

  onExit(listener) {
    this._exitListeners.push(listener);
    return {dispose: () => {
      const i = this._exitListeners.indexOf(listener);
      if (i >= 0) this._exitListeners.splice(i, 1);
    }};
  }

  write(data) {
    if (this._exited) return;
    const bytes = Buffer.from(String(data), 'utf8');
    // M-6: queue input that arrives before the handshake completes;
    // sendFrame would silently drop it. Flushed in order by _open
    // once `ready` resolves.
    // N-3 (round 2): also queue while the flush itself has not run
    // yet — handshakeDone is set in the socket 'data' handler, but
    // _open's flush runs in a later microtask, and a write in between
    // (e.g. from an onData listener answering a frame piggybacked on
    // the 101 response) would otherwise overtake the queued frames.
    if (!this._ws?.handshakeDone || !this._flushed) {
      if (this._pendingBytes + bytes.length <= PTY_PENDING_MAX_BYTES) {
        this._pendingFrames.push(bytes);
        this._pendingBytes += bytes.length;
      }
      return;
    }
    this._ws.sendBinary(bytes);
  }

  resize(cols, rows) {
    this._cols = cols;
    this._rows = rows;
    if (this._exited) return;
    // M-6: a resize before the handshake is not lost — _open sends
    // the latest size right after `ready` resolves, so there is
    // nothing to queue; only send immediately once upgraded.
    if (this._ws?.handshakeDone) {
      this._ws.sendText(JSON.stringify({type: 'resize', cols, rows}));
    }
  }

  pause() {
    this._paused = true;
  }

  resume() {
    if (!this._paused) return;
    this._paused = false;
    const buffered = this._pausedBuffers;
    this._pausedBuffers = [];
    for (const text of buffered) this._emitData(text);
  }

  kill(_signal) {
    this._close('client kill');
  }

  /** Resolve once the WS upgrade completes (or rejects on failure). */
  get ready() { return this._ready; }

  async _open() {
    const ws = ishWebSocket({
      path: this._readOnly ? '/ish/pty?readOnly=1' : '/ish/pty',
      onBinary: (data) => {
        const text = this._decoder.write(data);
        if (text) this._emitData(text);
      },
      onText: (text) => {
        // Session hello ({"type":"session","sessionId":"..."}), sent
        // by the server right after the upgrade. Stored for
        // diagnostics; anything else is ignored (the server sends no
        // other text messages).
        try {
          const msg = JSON.parse(text);
          if (msg?.type === 'session' && typeof msg.sessionId === 'string') {
            this.sessionId = msg.sessionId;
          }
        } catch {}
      },
      onClose: ({code, reason}) => {
        if (this._exited) return;
        if (code === 1008) {
          // Session cap (stage 5.3): the server's reason names it
          // ("too many pty sessions are active (max 8)").
          this._emitData(`ish: terminal refused (close 1008${reason ? `: ${reason}` : ''})\r\n`);
        } else if (code === 1011) {
          this._emitData(`ish: the guest shell failed to start (close 1011)\r\n`);
        }
        this._exit({exitCode: null, signal: null});
      },
      onError: (error) => {
        if (this._exited) return;
        this._emitData(`ish: terminal transport failed: ${error?.message ?? error}\r\n`);
        this._exit({exitCode: null, signal: null});
      },
    });
    this._ws = ws;
    try {
      await ws.ready;
    } catch (error) {
      if (!this._exited) {
        const detail = error?.code === 'ISH_NOT_BOOTED' ? ISH_NOT_BOOTED : ISH_BRIDGE_UNAVAILABLE;
        this._emitData(`ish: ${detail}: ${error?.message ?? error}\r\n`);
        this._exit({exitCode: null, signal: null});
      }
      return;
    }
    // M-6: flush input queued during the handshake, in order, before
    // the initial resize.
    for (const bytes of this._pendingFrames) ws.sendBinary(bytes);
    this._pendingFrames = [];
    this._pendingBytes = 0;
    // N-3 (round 2): mark the flush done only after the queued frames
    // have been sent — write() queues while this is false (see above).
    this._flushed = true;
    // Shell is up. Size it. No default cd: the shell starts in its
    // own default directory; the user cds where they want. (The old
    // code sent `cd -- '<session cwd>'` as the first input, which
    // echoed in the scrollback and forced every terminal into
    // /home/workspace.)
    ws.sendText(JSON.stringify({type: 'resize', cols: this._cols, rows: this._rows}));
  }

  _emitData(text) {
    if (this._paused) {
      this._pausedBuffers.push(text);
      return;
    }
    for (const listener of [...this._dataListeners]) listener(text);
  }

  _exit(outcome) {
    if (this._exited) return;
    this._exited = true;
    // M-6: the handshake failed (or the terminal was killed) — queued
    // pre-handshake input will never be delivered; drop it.
    this._pendingFrames = [];
    this._pendingBytes = 0;
    const tail = this._decoder.end();
    if (tail) this._emitData(tail);
    for (const listener of [...this._exitListeners]) listener(outcome);
  }

  _close(reason) {
    if (this._exited) return;
    try { this._ws?.sendText(JSON.stringify({type: 'close'})); } catch {}
    try { this._ws?.close(1000); } catch {}
    this._exit({exitCode: null, signal: null});
    void reason;
  }
}

/** node-pty.spawn-shaped entry point for the PTY shim. */
export function ishPtySpawn(file, args, options) {
  return new IshPtyTerminal(file, args, options);
}

// ---------------------------------------------------------------------------
// dsh.go.direct hook (spawn-layer path translation, zz-direct-runtime.diff)
// ---------------------------------------------------------------------------

/**
 * The direct-engine hook object. Every method is optional-chained by its
 * callers, so a missing hook is safe; installing it only changes the
 * paths DSH resolves and spawns.
 *
 * - executable(): "/bin/sh" (and bare "sh") is the guest shell, not a
 *   host file; rewrite it to the "/ish-pty" sentinel so terminal shell
 *   resolution succeeds (the patched resolveExecutable accepts the
 *   sentinel). Everything else passes through unchanged.
 * - command(): no rewrite; the spawn layer already receives the sentinel
 *   (terminal) or the confined runner argv (bash), both handled by the
 *   patches in ish-sandbox-backend.diff.
 * - toHost()/toGuest(): workspace + guest-rootfs translation (see
 *   above). Guest /tmp, /etc, /root etc. map under the rootfs data
 *   dir; /proc, /sys and /dev throw (kernel-virtual, shell-only).
 * - requiresProot(): false — iSH is not proot, nothing needs it.
 * - containsExecutionPath(): true — host paths stay reachable to the
 *   host-side fs tools (the guest only matters for execution); returning
 *   false would make fs-local refuse ordinary host files.
 * - prepareDirectory(): mkdir -p on the host, return the path.
 */
export function createDirectHook() {
  return {
    toHost: (path) => toHost(path),
    toGuest: (path) => toGuest(path),
    executable: (command) => {
      if (command === '/bin/sh' || command === 'sh') return ISH_PTY_COMMAND;
      return command;
    },
    command: (_file, _args, _options) => undefined,
    requiresProot: (_path) => false,
    containsExecutionPath: (_path) => true,
    prepareDirectory: async (cwd) => {
      const {mkdir} = await import('node:fs/promises');
      await mkdir(cwd, {recursive: true});
      return cwd;
    },
  };
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

/**
 * Install the iSH bridge into the engine worker. Call before runCli (the
 * same place engine-worker.mjs installs the pnpm in-process shim). Never
 * throws: if the loopback service is not up yet, the shims are still
 * installed and fail closed per-call (the first call waits up to 10s for
 * ish-service.json, then reports the backend unavailable).
 */
export function installIshBridge() {
  globalThis[DSH_DIRECT_SYMBOL] = createDirectHook();
  globalThis[ISH_PTY_SYMBOL] = {spawn: ishPtySpawn};
  installSpawnPatch();
}
