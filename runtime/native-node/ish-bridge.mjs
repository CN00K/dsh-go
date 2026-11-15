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
import {request as httpRequest} from 'node:http';
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
/** Guest shell the loopback service spawns for /ish/pty (hardcoded Swift-side). */
export const GUEST_SHELL = '/bin/sh';

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

/** Default /ish/exec timeoutMs. Matches the bash-sandbox config (60s). */
export const DEFAULT_EXEC_TIMEOUT_MS = 60_000;
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
 * Host roots, derived from the supervisor's environment (supervisor.mjs):
 * HOME=<root>/home, TMPDIR=<root>/tmp. The token file lives at
 * <root>/ish-service.json (Application Support/NativeNode/ish-service.json).
 */
function hostRoots() {
  const home = process.env.HOME;
  if (!home) return null;
  return {
    home,
    workspace: join(home, 'workspace'),
    tmp: join(home, '..', 'tmp'),
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
  const relWorkspace = relativeTo(resolved, roots.workspace);
  if (relWorkspace !== null) return joinGuest(GUEST_WORKSPACE, relWorkspace);
  const relTmp = relativeTo(resolved, roots.tmp);
  if (relTmp !== null) return joinGuest(GUEST_TMP, relTmp);
  return null;
}

/**
 * Translate a guest absolute path to its host equivalent.
 * @param guestPath guest absolute path.
 * @returns host path; untranslatable paths are returned unchanged (the
 *   callers fall back to the input when the hook is absent, so this
 *   preserves the no-hook behaviour).
 */
export function toHost(guestPath) {
  const roots = hostRoots();
  if (!roots || typeof guestPath !== 'string' || guestPath.length === 0) return guestPath;
  const relWorkspace = relativeTo(guestPath, GUEST_WORKSPACE);
  if (relWorkspace !== null) return join(roots.workspace, relWorkspace);
  const relTmp = relativeTo(guestPath, GUEST_TMP);
  if (relTmp !== null) return join(roots.tmp, relTmp);
  return guestPath;
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

/** Join guest path segments with '/' (guest is always POSIX). */
function joinGuest(...parts) {
  const joined = parts.filter((p) => p !== '').join('/');
  return joined.startsWith('/') ? joined : '/' + joined;
}

// ---------------------------------------------------------------------------
// Loopback service discovery (token file)
// ---------------------------------------------------------------------------

let cachedService = null; // {host, port, token} | null
let cachedServiceFile = null;
let lastMissingCheck = 0;
let waitedForServiceFile = false;

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
 * retry once). Also resets the wait state so the retry does a fresh
 * read of ish-service.json instead of failing fast on the 5s window
 * (fix, build 37: the loopback service can restart with a new
 * port/token — e.g. stop/start across a terminal reopen — and the
 * bridge kept dialling the stale cached port/token forever, because
 * only the /ish/exec path invalidated and the WS path never retried).
 */
export function invalidateServiceInfo() {
  cachedService = null;
  cachedServiceFile = null;
  waitedForServiceFile = false;
  lastMissingCheck = 0;
}

// ---------------------------------------------------------------------------
// /ish/exec client (node:http, chunked NDJSON)
// ---------------------------------------------------------------------------

/**
 * Run one command in the guest via POST /ish/exec.
 * @param opts.command shell source (required).
 * @param opts.cwd guest cwd (already translated) or undefined.
 * @param opts.env env vars to export in the guest (already sanitised) or undefined.
 * @param opts.stdinData Buffer of stdin bytes or undefined.
 * @param opts.timeoutMs exec timeout (server clamps 1s-15min).
 * @param opts.serviceFile override for tests.
 * @param opts.onLine({stream, line}) called per NDJSON output line.
 * @param opts.signal AbortSignal; aborting closes the connection, which
 *   makes the Swift side cancel the exec and kill the guest process group.
 * @returns {exitCode, durationMs, timedOut?, cancelled?} from the final frame.
 */
export async function ishExec(opts) {
  const body = JSON.stringify({
    command: opts.command,
    ...(opts.cwd ? {cwd: opts.cwd} : {}),
    ...(opts.env && Object.keys(opts.env).length > 0 ? {env: opts.env} : {}),
    ...(opts.stdinData && opts.stdinData.length > 0
      ? {stdinData: Buffer.from(opts.stdinData).toString('base64')} : {}),
    timeoutMs: opts.timeoutMs ?? DEFAULT_EXEC_TIMEOUT_MS,
  });
  // Retry once with a fresh read of ish-service.json (same stale-cache
  // fix as the WS path, build 37): postExec invalidates on
  // ECONNREFUSED/ECONNRESET, and a 401 means the token rotated, so a
  // retry with fresh info can succeed where the cached one failed.
  // ISH_NOT_BOOTED is a real state, not a stale cache — do not retry it.
  let lastError = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) invalidateServiceInfo();
    const service = await getServiceInfo(opts);
    if (!service) throw bridgeUnavailableError(opts);
    try {
      return await postExec(service, body, opts);
    } catch (error) {
      lastError = error;
      if (error?.code === 'ISH_NOT_BOOTED') throw lastError;
      const retryable = error?.code === 'ECONNREFUSED' || error?.code === 'ECONNRESET'
        || error?.code === 'ISH_HTTP_ERROR';
      if (retryable && attempt === 0) continue;
      throw lastError;
    }
  }
  throw lastError;
}

function postExec(service, body, opts) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const settleResolve = (value) => { if (!settled) { settled = true; resolvePromise(value); } };
    const settleReject = (error) => { if (!settled) { settled = true; rejectPromise(error); } };
    const req = httpRequest({
      host: service.host,
      port: service.port,
      path: '/ish/exec',
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
        const error = new Error(`ish exec failed: HTTP ${res.statusCode}`);
        error.code = 'ISH_HTTP_ERROR';
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
      res.on('error', (error) => settleReject(error));
    });
    req.on('error', (error) => {
      // Connection failure: the service file may have been rewritten
      // (restart with a new port/token); drop the cache so the next call
      // re-reads it. The caller retries once if it wants to.
      if (error?.code === 'ECONNREFUSED' || error?.code === 'ECONNRESET') invalidateServiceInfo();
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
      path: '/ish/status',
      method: 'GET',
      headers: {'Authorization': `Bearer ${service.token}`},
    }, (res) => {
      res.resume();
      resolvePromise(res.statusCode === 200);
    });
    req.on('error', () => resolvePromise(false));
    req.end();
  });
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
        if (attempt === 0) continue;
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
    await new Promise((resolvePromise, rejectPromise) => {
      const onData = (chunk) => {
        handshakeBuffer = Buffer.concat([handshakeBuffer, chunk]);
        const end = handshakeBuffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = handshakeBuffer.subarray(0, end).toString('latin1');
        const rest = handshakeBuffer.subarray(end + 4);
        socket.off('data', onData);
        const statusLine = head.split('\r\n')[0] ?? '';
        if (!statusLine.includes('101')) {
          rejectPromise(Object.assign(
            new Error(`ish websocket upgrade failed: ${statusLine}`),
            {code: 'ISH_WS_UPGRADE_FAILED', statusLine}));
          return;
        }
        const accept = /^Sec-WebSocket-Accept:\s*(.+)$/im.exec(head)?.[1]?.trim();
        if (accept !== expectedAccept) {
          rejectPromise(Object.assign(new Error('ish websocket accept mismatch'), {code: 'ISH_WS_ACCEPT_MISMATCH'}));
          return;
        }
        handshakeDone = true;
        if (rest.length > 0) feedFrames(rest);
        resolvePromise();
      };
      socket.on('data', onData);
      socket.once('error', rejectPromise);
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
      if (payload.length >= 2) code = (payload[0] << 8) | payload[1];
      sendFrame(0x8, payload.subarray(0, 2));
      closeSocket(code, 'server closed');
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

export function guestEnv(hostEnv = {}) {
  const env = {};
  for (const [key, value] of Object.entries(hostEnv ?? {})) {
    if (typeof value !== 'string') continue;
    if (GUEST_ENV_DSH_ALLOW.has(key) || key === 'TERM' || key === 'LANG' || key.startsWith('LC_') || key === 'TZ') {
      env[key] = value;
    }
  }
  // Guest layout (matches the rootfs /etc/profile): never the host PATH/HOME.
  env.PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
  env.HOME = '/root';
  env.TERM = env.TERM ?? 'xterm-256color';
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
 * Timeout: the DSH timeout is not visible to spawn(), so the exec uses
 * DEFAULT_EXEC_TIMEOUT_MS (60s, the bash-sandbox config). The server
 * kills the guest process group at that point and returns exitCode -3.
 * A future improvement is to plumb spec.timeoutMs through (needs a DSH
 * patch); until then, commands longer than 60s are cut off at 60s.
 *
 * Kill: aborts the HTTP request. The Swift side cancels the exec on
 * disconnect, which kills the guest process group. Note the managed
 * handle's owner.signal() is a no-op for a synthetic pid (process.kill
 * on the fake group is ESRCH), so the DSH-side terminate() cannot reach
 * the guest directly — the abort-through-disconnect is the kill path,
 * and the server-side timeout is the backstop.
 */
export function spawnIshExec(argv, options = {}) {
  const command = extractBashCommand(argv);
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
  // stdio[7] is the subprocess control fd; the shim has no control
  // channel, so stdio is exactly 3 entries and controlPipe() yields
  // undefined (the managed handle works without it).
  child.stdio = [input, out.stream, err.stream];
  child.exitCode = null;
  child.signalCode = null;
  child.killed = false;
  child.spawnfile = ISH_RUNNER_COMMAND;
  child.spawnargs = argv;

  let settled = false;
  let abortController = null;
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
    Promise.all(streams.map((s) => new Promise((done) => s.once('close', done))))
      .then(() => child.emit('close', code, signal));
  };

  child.kill = (signal) => {
    if (settled) return false;
    child.killed = true;
    abortController?.abort();
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
      const stdinData = stdinChunks.length > 0 ? Buffer.concat(stdinChunks) : undefined;
      const guestCwd = toGuest(options.cwd ?? process.cwd());
      abortController = new AbortController();
      const result = await ishExec({
        command,
        cwd: guestCwd ?? undefined,
        env: guestEnv(options.env ?? {}),
        stdinData,
        timeoutMs: DEFAULT_EXEC_TIMEOUT_MS,
        signal: abortController.signal,
        onLine: ({stream, line}) => {
          (stream === 'stderr' ? err : out).write(line + '\n');
        },
      });
      if (settled) return;
      if (result.cancelled) {
        finish(null, 'SIGTERM');
        return;
      }
      finish(typeof result.exitCode === 'number' ? result.exitCode : 1, null);
    } catch (error) {
      if (settled) return;
      // Fail closed with the runner-failure signature so dsh-bash-sandbox
      // classifies this as SANDBOX_UNAVAILABLE (not a command failure).
      const detail = error?.code === 'ISH_NOT_BOOTED' ? ISH_NOT_BOOTED : ISH_BRIDGE_UNAVAILABLE;
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
 */
export class IshPtyTerminal {
  constructor(file, args, options = {}) {
    this._file = file;
    this._args = Array.isArray(args) ? args : [];
    this._options = options;
    this._pid = nextSyntheticPid();
    this._cols = options.cols ?? 80;
    this._rows = options.rows ?? 24;
    this._dataListeners = [];
    this._exitListeners = [];
    this._decoder = new StringDecoder('utf8');
    this._paused = false;
    this._pausedBuffers = [];
    this._exited = false;
    this._ws = null;
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
    this._ws?.sendBinary(Buffer.from(String(data), 'utf8'));
  }

  resize(cols, rows) {
    this._cols = cols;
    this._rows = rows;
    if (this._exited) return;
    this._ws?.sendText(JSON.stringify({type: 'resize', cols, rows}));
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
      path: '/ish/pty',
      onBinary: (data) => {
        const text = this._decoder.write(data);
        if (text) this._emitData(text);
      },
      onText: () => {}, // The service sends no text messages to the client.
      onClose: ({code, reason}) => {
        if (this._exited) return;
        if (code === 1008) {
          this._emitData(`ish: another terminal session is already active (close 1008)\r\n`);
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
 * - toHost()/toGuest(): workspace/tmp translation (see above).
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
