/**
 * Unit tests for ish-bridge.mjs (Stage 3).
 *
 * Run: node --test runtime/native-node/ish-bridge.test.mjs
 * (Also run on Codemagic by the ios-unsigned / ios-stage2-verify workflows.)
 *
 * Pure-function tests (path translation, argv parsing, env sanitising)
 * need no service. Client tests spin up mock loopback servers on
 * 127.0.0.1 (ephemeral ports) and point the bridge at them via a fake
 * ish-service.json, so they exercise the real HTTP/WS code paths without
 * a device. The mock servers implement the contract in
 * app/ios/Runner/IShLoopbackService.swift: Bearer auth, Content-Length
 * bodies, chunked NDJSON for /ish/exec, RFC 6455 for /ish/pty.
 */
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {
  DEFAULT_EXEC_TIMEOUT_MS,
  ISH_JOB_NOT_FOUND,
  ISH_PTY_COMMAND,
  ISH_RUNNER_COMMAND,
  ISH_WORKER_UNSUPPORTED,
  WORKER_END_MARKER_PREFIX,
  WORKER_JOBPIDS_BEGIN_PREFIX,
  WORKER_JOBPIDS_END_PREFIX,
  WORKER_JOBS_BEGIN_PREFIX,
  WORKER_JOBS_END_PREFIX,
  clearExecCwdState,
  clearWorkerState,
  extractBashCommand,
  getServiceInfo,
  getWorkerJobs,
  guestEnv,
  invalidateServiceInfo,
  ishExec,
  ishPtySpawn,
  ishWebSocket,
  ishWorkerExec,
  ishWorkerJobs,
  ishWorkerKillJob,
  ishWorkerStop,
  isWorkerUnsupported,
  noteExecCwd,
  parseCwdMarker,
  parseJobsLine,
  parseJobsSnapshot,
  parseWorkerEndMarker,
  resolveExecCwd,
  spawnIshExec,
  splitConfinedArgv,
  toGuest,
  toHost,
} from './ish-bridge.mjs';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const TOKEN = 'test-token-123';

// Fake HOME so path translation has a stable root. 1.1.1 layout:
// HOME is <guestRoot>/root (host_core sets it; no supervisor), so the
// service file lives at <guestRoot>/ish-service.json (one level up)
// and the rootfs data dir is three levels up (see fakeData below).
// TMPDIR is the host-only temp dir (host_core: <cache>/ohos-process).
import {mkdirSync} from 'node:fs';
const fakeRoot = mkdtempSync(join(tmpdir(), 'ish-bridge-test-'));
const fakeHome = join(fakeRoot, 'root');
mkdirSync(fakeHome, {recursive: true});
process.env.HOME = fakeHome;
process.env.TMPDIR = join(fakeRoot, 'host-tmp');
/** Canonical service-file path the bridge reads (HOME/../ish-service.json). */
const canonicalServiceFile = join(fakeRoot, 'ish-service.json');

/** Write a fake ish-service.json pointing at `port`; returns its path. */
function writeServiceFile(port) {
  const file = join(fakeHome, `ish-service-${port}.json`);
  writeFileSync(file, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
  return file;
}

/** Start a mock loopback server; `handler` receives (req, res, body). */
async function startMockServer(handler) {
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => handler(req, res, Buffer.concat(chunks)));
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const port = server.address().port;
  return {server, port, close: () => new Promise((done) => server.close(done))};
}

function bearerOk(req) {
  return req.headers.authorization === `Bearer ${TOKEN}`;
}

// ---------------------------------------------------------------------------
// Path translation (design §3.5)
// ---------------------------------------------------------------------------

/** Guest rootfs data dir under the fake HOME (mirrors hostRoots() in the bridge):
 * HOME is one level deeper than in 1.0.x (<guestRoot>/root vs <root>/home),
 * so the climb is three levels: <guestRoot>/root -> ../../.. -> <AppSupport>/iSH/rootfs/data. */
const fakeData = join(fakeHome, '..', '..', '..', 'iSH', 'rootfs', 'data');

test('toGuest maps the workspace and the rootfs data dir, rejects everything else', () => {
  assert.equal(toGuest(join(fakeHome, 'workspace', 'a.txt')), '/home/workspace/a.txt');
  assert.equal(toGuest(join(fakeHome, 'workspace')), '/home/workspace');
  // Guest /tmp lives under the rootfs data dir, not under <root>/tmp
  // (that is the host-only TMPDIR — the old mapping claimed host temp
  // files were guest /tmp files).
  assert.equal(toGuest(join(fakeData, 'tmp', 'x')), '/tmp/x');
  assert.equal(toGuest(join(fakeData, 'etc', 'passwd')), '/etc/passwd');
  assert.equal(toGuest(fakeData), '/');
  // Host-only tmp is no longer guest /tmp.
  assert.equal(toGuest(join(fakeRoot, 'tmp', 'x')), null);
  // ".." escape out of the workspace is rejected (resolve normalises it).
  assert.equal(toGuest(join(fakeHome, 'workspace', '..', 'secret.txt')), null);
  assert.equal(toGuest(join(fakeHome, 'workspace', '..', '..', 'etc', 'passwd')), null);
  // Absolute paths outside the shared dirs are rejected.
  assert.equal(toGuest('/etc/passwd'), null);
  assert.equal(toGuest('/var/mobile/secret'), null);
  assert.equal(toGuest(''), null);
});

test('toHost maps guest paths into the rootfs data dir', () => {
  assert.equal(toHost('/home/workspace/a.txt'), join(fakeHome, 'workspace', 'a.txt'));
  assert.equal(toHost('/home/workspace'), join(fakeHome, 'workspace'));
  assert.equal(toHost('/tmp/x'), join(fakeData, 'tmp', 'x'));
  assert.equal(toHost('/tmp'), join(fakeData, 'tmp'));
  // A path under the host-only TMPDIR is already a host path: pass through.
  assert.equal(toHost(join(fakeRoot, 'host-tmp', 'x')), join(fakeRoot, 'host-tmp', 'x'));
  // Every other guest path lives under the rootfs data dir (P2-9:
  // the old code returned these unchanged, so the engine read the
  // iOS host's /etc).
  assert.equal(toHost('/etc/passwd'), join(fakeData, 'etc', 'passwd'));
  assert.equal(toHost('/root/.profile'), join(fakeData, 'root', '.profile'));
  assert.equal(toHost('/'), fakeData);
  // Relative paths are left alone (resolved by the caller).
  assert.equal(toHost('relative/path'), 'relative/path');
  // Host paths already under a host root pass through unchanged.
  assert.equal(toHost(join(fakeHome, 'workspace', 'a.txt')), join(fakeHome, 'workspace', 'a.txt'));
  assert.equal(toHost(join(fakeData, 'etc', 'passwd')), join(fakeData, 'etc', 'passwd'));
});

test('toHost throws for kernel-virtual guest paths', () => {
  // /proc, /sys and /dev have no file in the rootfs; the shell is the
  // only way to read them. The error must say so (P2-9 hint).
  assert.throws(() => toHost('/proc/version'), /shell instead/);
  assert.throws(() => toHost('/proc/self/fd/0'), /shell instead/);
  assert.throws(() => toHost('/proc'), /shell instead/);
  assert.throws(() => toHost('/sys/kernel/hostname'), /shell instead/);
  assert.throws(() => toHost('/dev/null'), /shell instead/);
  // Prefix lookalikes are not virtual.
  assert.equal(toHost('/procx/x'), join(fakeData, 'procx', 'x'));
  assert.equal(toHost('/devices'), join(fakeData, 'devices'));
});

// ---------------------------------------------------------------------------
// Confined argv parsing
// ---------------------------------------------------------------------------

test('splitConfinedArgv finds the first bare -- separator', () => {
  const argv = ['/ish-runner', '--ro-bind', '/', '/', '--dev', '/dev',
    '--unshare-pid', '--proc', '/proc', '--die-with-parent',
    '--tmpfs', '/tmp', '--bind', '/w', '/w', '--',
    'bash', '-c', 'echo hi'];
  assert.deepEqual(splitConfinedArgv(argv), ['bash', '-c', 'echo hi']);
  assert.equal(splitConfinedArgv(['bash', '-c', 'x']), null);
  // A "--" inside the command string is not an argv element, so the
  // first bare "--" is always the separator confine() inserted.
  assert.deepEqual(splitConfinedArgv(['/ish-runner', '--', 'bash', '-c', 'echo -- hi']), ['bash', '-c', 'echo -- hi']);
});

test('extractBashCommand only accepts ["bash", "-c", command]', () => {
  assert.equal(
    extractBashCommand(['/ish-runner', '--ro-bind', '/', '/', '--', 'bash', '-c', 'ls -la']),
    'ls -la');
  assert.equal(extractBashCommand(['/ish-runner', '--', 'bash', 'ls']), null);
  assert.equal(extractBashCommand(['/ish-runner', '--', 'sh', '-c', 'ls']), null);
  assert.equal(extractBashCommand(['/ish-runner']), null);
  assert.equal(extractBashCommand(['/ish-runner', '--', 'bash', '-c']), null);
});

// ---------------------------------------------------------------------------
// Env sanitising
// ---------------------------------------------------------------------------

test('guestEnv never forwards host paths', () => {
  // Piped exec (no pty): TERM is dropped entirely (ENV-12) — the old
  // test asserted the xterm-256color default here; that default now
  // only applies to pty execs (see the hasPty test below).
  const env = guestEnv({
    PATH: '/usr/local/bin:/bin',
    HOME: '/var/mobile/Containers/Data/Application/UUID',
    TMPDIR: '/var/mobile/tmp',
    DSH_HOME: '/var/mobile/.dsh',
    DSH_SESSION_ID: 'sess-1',
    DSH_SHELL: '1',
    TERM: 'xterm-256color',
    LANG: 'en_US.UTF-8',
    FOO: 'bar',
  });
  assert.equal(env.PATH, '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin');
  assert.equal(env.HOME, '/root');
  assert.equal(env.DSH_SESSION_ID, 'sess-1');
  assert.equal(env.DSH_SHELL, '1');
  assert.equal(env.TERM, undefined);
  assert.equal(env.LANG, 'en_US.UTF-8');
  assert.equal(env.TMPDIR, undefined);
  assert.equal(env.DSH_HOME, undefined);
  assert.equal(env.FOO, undefined);
  // ENV-13: .pyc caching is enabled unless the caller says otherwise.
  assert.equal(env.PYTHONDONTWRITEBYTECODE, '0');
});

test('guestEnv forwards TERM only with a pty (ENV-12)', () => {
  // The engine's model-friendly TERM=dumb must not reach a piped exec.
  assert.equal(guestEnv({TERM: 'dumb'}).TERM, undefined);
  // No host TERM and no pty: no TERM is invented either.
  assert.equal(guestEnv({}).TERM, undefined);
  // With a pty: the host value wins; without one the profile default
  // (xterm-256color) applies, overridable via ptyTerm.
  assert.equal(guestEnv({TERM: 'xterm-256color'}, {hasPty: true}).TERM, 'xterm-256color');
  assert.equal(guestEnv({}, {hasPty: true}).TERM, 'xterm-256color');
  assert.equal(guestEnv({}, {hasPty: true, ptyTerm: 'screen-256color'}).TERM, 'screen-256color');
});

test('guestEnv honours an explicit PYTHONDONTWRITEBYTECODE (ENV-13)', () => {
  assert.equal(guestEnv({PYTHONDONTWRITEBYTECODE: '1'}).PYTHONDONTWRITEBYTECODE, '1');
  assert.equal(guestEnv({PYTHONDONTWRITEBYTECODE: '0'}).PYTHONDONTWRITEBYTECODE, '0');
});

// ---------------------------------------------------------------------------
// Session cwd memory (ENV-14)
// ---------------------------------------------------------------------------

test('parseCwdMarker only accepts the exact nonce and a clean path', () => {
  const frame = (line) => ({stream: 'stderr', line});
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:/tmp/foo'), 'abc123'), '/tmp/foo');
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:/tmp/foo'), 'deadbeef'), null);
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:relative'), 'abc123'), null);
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:/tmp/a\nb'), 'abc123'), null);
  assert.equal(parseCwdMarker({stream: 'stdout', line: '__DSH_CWD__abc123:/tmp'}, 'abc123'), null);
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:'), 'abc123'), null);
  assert.equal(parseCwdMarker(frame('plain output'), 'abc123'), null);
  assert.equal(parseCwdMarker(frame('__DSH_CWD__abc123:/tmp'), null), null);
});

test('resolveExecCwd reuses the remembered cwd until the engine moves', () => {
  clearExecCwdState();
  const sess = 'sess-cwd-1';
  // No memory yet: the engine cwd passes through.
  assert.equal(resolveExecCwd(sess, '/home/workspace'), '/home/workspace');
  // A bare `cd /tmp` in the guest is remembered; the next exec reuses it
  // while the engine keeps asking for the same directory.
  noteExecCwd(sess, '/tmp');
  assert.equal(resolveExecCwd(sess, '/home/workspace'), '/tmp');
  assert.equal(resolveExecCwd(sess, '/home/workspace'), '/tmp');
  // The model uses the working-directory cd tool: the engine cwd
  // changes, the engine wins, and the old memory is forgotten.
  assert.equal(resolveExecCwd(sess, '/home/workspace/sub'), '/home/workspace/sub');
  assert.equal(resolveExecCwd(sess, '/home/workspace/sub'), '/home/workspace/sub');
  // No session id: stateless, as before.
  assert.equal(resolveExecCwd(null, '/home/workspace'), '/home/workspace');
  assert.equal(resolveExecCwd(null, undefined), undefined);
  // Memory recorded before any engine cwd was seen (direct ishExec
  // use) is not discarded as an engine "move" — there is no move.
  noteExecCwd('sess-cwd-2', '/tmp/early');
  assert.equal(resolveExecCwd('sess-cwd-2', '/home/workspace'), '/tmp/early');
  clearExecCwdState();
});

// ---------------------------------------------------------------------------
// /ish/exec client against a mock server
// ---------------------------------------------------------------------------

test('ishExec streams NDJSON lines and returns the final frame', async () => {
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.equal(req.url, '/ish/exec');
    assert.equal(req.method, 'POST');
    assert.ok(bearerOk(req), 'Bearer auth required');
    const parsed = JSON.parse(body.toString('utf8'));
    assert.equal(parsed.command, 'echo hi && echo err 1>&2');
    assert.equal(parsed.cwd, '/home/workspace');
    assert.equal(parsed.env.FOO, 'bar');
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'hi'}) + '\n');
    res.write(JSON.stringify({stream: 'stderr', line: 'err'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 12}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    const lines = [];
    const result = await ishExec({
      command: 'echo hi && echo err 1>&2',
      cwd: '/home/workspace',
      env: {FOO: 'bar'},
      serviceFile: writeServiceFile(port),
      onLine: (frame) => lines.push(frame),
    });
    assert.deepEqual(result, {exitCode: 0, durationMs: 12});
    assert.deepEqual(lines, [
      {stream: 'stdout', line: 'hi'},
      {stream: 'stderr', line: 'err'},
    ]);
  } finally {
    await close();
  }
});

test('ishExec swallows the exact-nonce cwd marker and reports the cwd (ENV-14)', async () => {
  const nonce = '0123456789abcdef';
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    assert.equal(parsed.cwdNonce, nonce);
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'hello'}) + '\n');
    // The Swift wrapper's marker: swallowed, never shown to the caller.
    res.write(JSON.stringify({stream: 'stderr', line: `__DSH_CWD__${nonce}:/tmp/work`}) + '\n');
    // A look-alike with a different nonce is ordinary output.
    res.write(JSON.stringify({stream: 'stderr', line: '__DSH_CWD__ffffffffffffffff:/etc'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 3}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    const lines = [];
    const cwds = [];
    const result = await ishExec({
      command: 'cd /tmp/work',
      cwd: '/home/workspace',
      cwdNonce: nonce,
      serviceFile: writeServiceFile(port),
      onLine: (frame) => lines.push(frame),
      onSessionCwd: (cwd) => cwds.push(cwd),
    });
    assert.deepEqual(result, {exitCode: 0, durationMs: 3});
    assert.deepEqual(cwds, ['/tmp/work']);
    assert.deepEqual(lines, [
      {stream: 'stdout', line: 'hello'},
      {stream: 'stderr', line: '__DSH_CWD__ffffffffffffffff:/etc'},
    ]);
  } finally {
    await close();
  }
});

test('ishExec surfaces ish_not_booted (503) as a typed error', async () => {
  const {server, port, close} = await startMockServer((_req, res) => {
    res.writeHead(503, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'ish_not_booted'}));
  });
  try {
    invalidateServiceInfo();
    await assert.rejects(
      ishExec({command: 'ls', serviceFile: writeServiceFile(port)}),
      (error) => error.code === 'ISH_NOT_BOOTED');
  } finally {
    await close();
  }
});

test('ishExec rejects unauthenticated requests (401)', async () => {
  const {server, port, close} = await startMockServer((req, res) => {
    if (!bearerOk(req)) {
      res.writeHead(401, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: 'unauthorized'}));
      return;
    }
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.end(JSON.stringify({exitCode: 0, durationMs: 1}) + '\n');
  });
  try {
    invalidateServiceInfo();
    // Wrong token file: the server must reject it.
    const badFile = join(fakeHome, 'ish-service-bad.json');
    writeFileSync(badFile, JSON.stringify({host: '127.0.0.1', port, token: 'wrong'}));
    await assert.rejects(
      ishExec({command: 'ls', serviceFile: badFile}),
      (error) => error.code === 'ISH_HTTP_ERROR');
  } finally {
    await close();
  }
});

test('getServiceInfo waits for the file on first miss, then fails fast', async () => {
  invalidateServiceInfo();
  const missing = join(fakeHome, 'ish-service-never.json');
  const start = Date.now();
  const first = await getServiceInfo({serviceFile: missing});
  const firstMs = Date.now() - start;
  assert.equal(first, null);
  assert.ok(firstMs >= 29000 && firstMs < 35000, `first wait should be ~30s, was ${firstMs}ms`);
  const secondStart = Date.now();
  const second = await getServiceInfo({serviceFile: missing});
  assert.equal(second, null);
  assert.ok(Date.now() - secondStart < 1000, 'second miss must fail fast');
});

test('bridge unavailable error names the missing service file', async () => {
  invalidateServiceInfo();
  // The one 30 s wait was already spent by the getServiceInfo test
  // above, so this miss fails fast.
  await assert.rejects(
    ishExec({command: 'echo hi', serviceFile: join(fakeHome, 'ish-service-never.json')}),
    (error) => {
      assert.equal(error.code, 'ISH_BRIDGE_UNAVAILABLE');
      assert.match(error.message, /ish-service\.json not found at /);
      assert.ok(error.message.includes(join(fakeHome, 'ish-service-never.json')));
      return true;
    });
});

// ---------------------------------------------------------------------------
// WS client against a mock server (hand-rolled RFC 6455 on both sides)
// ---------------------------------------------------------------------------

/** Minimal mock WS server: validates the upgrade + Authorization, then echoes. */
async function startMockWsServer({closeCode = null, closeReason = null, sessionHello = false, onSocket = null} = {}) {
  const server = createServer();
  const sockets = new Set();
  server.on('upgrade', (req, socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    if (!bearerOk(req)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return;
    }
    const key = req.headers['sec-websocket-key'];
    if (!key || req.headers['sec-websocket-version'] !== '13') {
      socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(key + WS_GUID).digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
    if (closeCode !== null) {
      // Refuse with a close frame (like the 1008 session-cap refusal);
      // an optional reason follows the 2-byte code, as the real server sends.
      const reasonBytes = closeReason ? Buffer.from(closeReason, 'utf8') : Buffer.alloc(0);
      const payload = Buffer.concat([
        Buffer.from([(closeCode >> 8) & 0xff, closeCode & 0xff]), reasonBytes]);
      socket.write(Buffer.from([0x88, payload.length, ...payload]));
      socket.end();
      return;
    }
    if (sessionHello) {
      // Session hello, like the real server sends right after the upgrade.
      const hello = JSON.stringify({type: 'session', sessionId: `mock-session-${sockets.size}`});
      const payload = Buffer.from(hello, 'utf8');
      socket.write(Buffer.concat([Buffer.from([0x81, payload.length]), payload]));
    }
    if (onSocket) onSocket(socket);
    let buffer = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        if (buffer.length < 2) return;
        const b1 = buffer[1];
        let length = b1 & 0x7f;
        let headerLen = 2;
        if (length === 126) {
          if (buffer.length < 4) return;
          length = (buffer[2] << 8) | buffer[3];
          headerLen = 4;
        }
        const masked = (b1 & 0x80) !== 0;
        if (masked) headerLen += 4;
        if (buffer.length < headerLen + length) return;
        const opcode = buffer[0] & 0x0f;
        let payload = Buffer.from(buffer.subarray(headerLen, headerLen + length));
        if (masked) {
          const mask = buffer.subarray(headerLen - 4, headerLen);
          for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
        }
        buffer = buffer.subarray(headerLen + length);
        if (opcode === 0x8) { socket.end(); return; } // close
        if (opcode === 0x9) { // ping -> pong
          socket.write(Buffer.from([0x8a, payload.length, ...payload]));
          continue;
        }
        if (opcode === 0x2) { // binary echo (unmasked server frame)
          const header = payload.length < 126
            ? Buffer.from([0x82, payload.length])
            : Buffer.from([0x82, 126, (payload.length >> 8) & 0xff, payload.length & 0xff]);
          socket.write(Buffer.concat([header, payload]));
        }
        // Text frames are control frames; the mock just records them.
      }
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const port = server.address().port;
  return {server, port, close: () => new Promise((done) => {
    for (const s of sockets) s.destroy();
    server.close(done);
  })};
}

test('ishWebSocket retries once with a fresh service file after a stale cache (build 37)', async () => {
  const {server, port, close} = await startMockWsServer();
  try {
    invalidateServiceInfo();
    // Prime the cache with a dead port: the loopback service restarted
    // with a new port after the bridge cached the old one.
    const serviceFile = join(fakeHome, 'ish-service-retry.json');
    writeFileSync(serviceFile, JSON.stringify({host: '127.0.0.1', port: 1, token: TOKEN}));
    const cached = await getServiceInfo({serviceFile});
    assert.equal(cached.port, 1);
    // The service restarts: the file now points at the live server.
    writeFileSync(serviceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    const received = [];
    const ws = ishWebSocket({
      path: '/ish/pty',
      serviceFile,
      onBinary: (data) => received.push(data.toString('utf8')),
    });
    await ws.ready;
    ws.sendBinary(Buffer.from('retry ok\n', 'utf8'));
    await new Promise((done) => setTimeout(done, 200));
    assert.deepEqual(received, ['retry ok\n']);
    ws.close();
  } finally {
    await close();
  }
});

test('ishWebSocket handshakes with Bearer auth and echoes binary frames', async () => {
  const {server, port, close} = await startMockWsServer();
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    const received = [];
    const ws = ishWebSocket({
      path: '/ish/pty',
      serviceFile,
      onBinary: (data) => received.push(data.toString('utf8')),
    });
    await ws.ready;
    ws.sendBinary(Buffer.from('echo hi\n', 'utf8'));
    await new Promise((done) => setTimeout(done, 200));
    assert.deepEqual(received, ['echo hi\n']);
    ws.close();
  } finally {
    await close();
  }
});

test('ishWebSocket reports a 1008 refusal as a close event', async () => {
  const {server, port, close} = await startMockWsServer({closeCode: 1008});
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    const closes = [];
    const ws = ishWebSocket({
      path: '/ish/pty',
      serviceFile,
      onClose: (info) => closes.push(info),
    });
    await ws.ready;
    await new Promise((done) => setTimeout(done, 200));
    assert.equal(closes.length, 1);
    assert.equal(closes[0].code, 1008);
  } finally {
    await close();
  }
});

// ---------------------------------------------------------------------------
// spawn shim against a mock /ish/exec server
// ---------------------------------------------------------------------------

test('spawnIshExec returns a ChildProcess-shaped handle with streamed output', async () => {
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    // The old service has no worker endpoints: an unknown path 404s, and
    // spawnIshExec falls back to one-shot (this is what the test exercises).
    if (req.url !== '/ish/exec') {
      res.writeHead(404, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: 'not_found'}));
      return;
    }
    const parsed = JSON.parse(body.toString('utf8'));
    assert.equal(parsed.command, 'echo hi');
    assert.equal(parsed.cwd, '/home/workspace');
    assert.equal(parsed.env.PATH, '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin');
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'hi'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 5}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    // Point the bridge at the mock service file via HOME-relative lookup:
    // spawnIshExec uses getServiceInfo() without an override, so install
    // the mock as the canonical service file for this test.
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const argv = [ISH_RUNNER_COMMAND, '--ro-bind', '/', '/', '--', 'bash', '-c', 'echo hi'];
    const child = spawnIshExec(argv, {cwd: join(fakeHome, 'workspace'), env: {}});
    assert.ok(typeof child.pid === 'number' && child.pid > 0);
    assert.equal(child.spawnfile, ISH_RUNNER_COMMAND);
    let stdout = '';
    child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
    const outcome = await new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
    assert.deepEqual(outcome, {code: 0, signal: null});
    assert.equal(stdout, 'hi\n');
  } finally {
    await close();
  }
});

test('spawnIshExec remembers a bare cd across execs of one session (ENV-14)', async () => {
  clearExecCwdState();
  const seenCwds = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    // The old service has no worker endpoints: an unknown path 404s, and
    // spawnIshExec falls back to one-shot (this is what the test exercises).
    if (req.url !== '/ish/exec') {
      res.writeHead(404, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: 'not_found'}));
      return;
    }
    const parsed = JSON.parse(body.toString('utf8'));
    seenCwds.push(parsed.cwd);
    // The Swift wrapper sends the cwd nonce; emulate its marker line.
    assert.equal(typeof parsed.cwdNonce, 'string');
    assert.match(parsed.cwdNonce, /^[0-9a-f]{16}$/);
    // No TERM on a piped exec (ENV-12), .pyc caching on (ENV-13).
    assert.equal(parsed.env.TERM, undefined);
    assert.equal(parsed.env.PYTHONDONTWRITEBYTECODE, '0');
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'ok'}) + '\n');
    res.write(JSON.stringify({stream: 'stderr', line: `__DSH_CWD__${parsed.cwdNonce}:/tmp`}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 5}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const opts = {cwd: join(fakeHome, 'workspace'), env: {DSH_SESSION_ID: 'sess-cwd-e2e'}};
    const run = async (command) => {
      const child = spawnIshExec([ISH_RUNNER_COMMAND, '--', 'bash', '-c', command], opts);
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
      child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });
      const outcome = await new Promise((done) => child.once('exit', (code) => done(code)));
      return {outcome, stdout, stderr};
    };
    // First exec: engine cwd; the marker reports the shell ended in /tmp.
    const first = await run('cd /tmp && pwd');
    assert.equal(first.outcome, 0);
    assert.equal(first.stdout, 'ok\n');
    assert.equal(first.stderr, '', 'the cwd marker must never reach tool output');
    // Second exec, same session, same engine cwd: the bridge reuses /tmp.
    const second = await run('pwd');
    assert.equal(second.outcome, 0);
    assert.deepEqual(seenCwds, ['/home/workspace', '/tmp']);
    // A different session starts fresh (no cross-session leakage).
    const other = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'pwd'],
      {cwd: join(fakeHome, 'workspace'), env: {DSH_SESSION_ID: 'sess-other'}});
    let otherOut = '';
    other.stdout.on('data', (c) => { otherOut += c.toString('utf8'); });
    await new Promise((done) => other.once('exit', done));
    assert.equal(otherOut, 'ok\n');
    assert.deepEqual(seenCwds, ['/home/workspace', '/tmp', '/home/workspace']);
  } finally {
    clearExecCwdState();
    await close();
  }
});

test('spawnIshExec fails closed when the bridge is down', async () => {
  invalidateServiceInfo();
  // The getServiceInfo test above already did the one ~30s wait for a
  // missing file, so this miss fails fast. Remove the canonical file
  // first: the previous test installed a mock server's port there, and
  // a stale-but-parseable file would fail with ECONNREFUSED instead of
  // exercising the file-not-found path.
  rmSync(canonicalServiceFile, {force: true});
  const child = spawnIshExec(
    [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'echo hi'],
    {cwd: join(fakeHome, 'workspace'), env: {}});
  let stderr = '';
  child.stderr.on('data', (c) => { stderr += c.toString('utf8'); });
  const outcome = await new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
  assert.deepEqual(outcome, {code: 1, signal: null});
  assert.match(stderr, /ish bridge unavailable/);
  // The runner-failure line still names the file that was checked, so a
  // device log tells a missing boot from a wrong path.
  assert.match(stderr, /ish-service\.json not found at /);
});

test('spawnIshExec posts the 600s backstop timeout (never before the DSH deadline)', async () => {
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    const parsed = JSON.parse(body.toString('utf8'));
    assert.equal(parsed.timeoutMs, DEFAULT_EXEC_TIMEOUT_MS);
    assert.equal(parsed.timeoutMs, 600_000);
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({exitCode: 0, durationMs: 5}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const child = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'echo hi'],
      {cwd: join(fakeHome, 'workspace'), env: {}});
    const outcome = await new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
    assert.deepEqual(outcome, {code: 0, signal: null});
  } finally {
    await close();
  }
});

test('spawnIshExec aborts the request when the caller signal aborts (DSH timeout / Stop)', async () => {
  let requestClosed = false;
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    // Never send the final frame: the command "runs" until aborted.
    req.on('close', () => { requestClosed = true; });
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'partial'}) + '\n');
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const outer = new AbortController();
    const child = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'sleep 300'],
      {cwd: join(fakeHome, 'workspace'), env: {}, signal: outer.signal});
    let stdout = '';
    child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
    const outcomePromise = new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
    // Abort after the POST is in flight, like the DSH deadline / user Stop.
    setTimeout(() => outer.abort(), 150);
    const outcome = await outcomePromise;
    assert.deepEqual(outcome, {code: null, signal: 'SIGTERM'});
    assert.equal(stdout, 'partial\n');
    // Give the socket a moment to tear down server-side.
    await new Promise((done) => setTimeout(done, 50));
    assert.equal(requestClosed, true);
  } finally {
    await close();
  }
});

// ---------------------------------------------------------------------------
// PTY shim against a mock WS server
// ---------------------------------------------------------------------------

test('ishPtySpawn forwards input and output as raw bytes', async () => {
  const {server, port, close} = await startMockWsServer();
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const term = ishPtySpawn(ISH_PTY_COMMAND, ['-i'], {
      cols: 80, rows: 24, cwd: join(fakeHome, 'workspace'), env: {},
    });
    assert.ok(typeof term.pid === 'number' && term.pid > 0);
    const received = [];
    term.onData((data) => received.push(data));
    await term.ready;
    // No default cd on open: the shell starts in its own default
    // directory (the mock echoes nothing back).
    await new Promise((done) => setTimeout(done, 200));
    assert.ok(!received.join('').includes("cd -- '/home/workspace'"), `unexpected cd in ${JSON.stringify(received)}`);
    received.length = 0;
    term.write('ls\n');
    await new Promise((done) => setTimeout(done, 200));
    assert.deepEqual(received, ['ls\n']);
    term.resize(120, 40);
    assert.equal(term.cols, 120);
    assert.equal(term.rows, 40);
    const exit = await new Promise((done) => {
      term.onExit((outcome) => done(outcome));
      term.kill('SIGTERM');
    });
    assert.deepEqual(exit, {exitCode: null, signal: null});
  } finally {
    await close();
  }
});

// ---------------------------------------------------------------------------
// PTY exec (stage 5.3, ENV-02) + multi-session PTY shim
// ---------------------------------------------------------------------------

test('ishExec sends tty:true and returns the server tty:true frame', async () => {
  let sawBody = null;
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    sawBody = JSON.parse(body.toString('utf8'));
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'tty'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 3, tty: true}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    const lines = [];
    const result = await ishExec({
      command: '[ -t 1 ] && echo tty', tty: true,
      serviceFile: writeServiceFile(port),
      onLine: (frame) => lines.push(frame),
    });
    assert.equal(sawBody.tty, true);
    assert.deepEqual(result, {exitCode: 0, durationMs: 3, tty: true});
    assert.deepEqual(lines, [{stream: 'stdout', line: 'tty'}]);
  } finally {
    await close();
  }
});

test('ishExec omits tty when not requested (pipe path unchanged)', async () => {
  let sawBody = null;
  const {server, port, close} = await startMockServer((req, res, body) => {
    sawBody = JSON.parse(body.toString('utf8'));
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({exitCode: 0, durationMs: 3}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    const result = await ishExec({command: 'echo hi', serviceFile: writeServiceFile(port)});
    assert.ok(!('tty' in sawBody));
    assert.deepEqual(result, {exitCode: 0, durationMs: 3});
  } finally {
    await close();
  }
});

test('spawnIshExec passes options.tty through and sets child.ishTty', async () => {
  let sawBody = null;
  const {server, port, close} = await startMockServer((req, res, body) => {
    sawBody = JSON.parse(body.toString('utf8'));
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'tty'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 3, tty: true}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const child = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', '[ -t 1 ] && echo tty'],
      {cwd: join(fakeHome, 'workspace'), env: {}, tty: true});
    assert.equal(child.ishTty, false); // not confirmed until the frame arrives
    const outcome = await new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
    assert.deepEqual(outcome, {code: 0, signal: null});
    assert.equal(sawBody.tty, true);
    assert.equal(child.ishTty, true);
  } finally {
    await close();
  }
});

test('spawnIshExec leaves child.ishTty false for a plain exec', async () => {
  let sawBody = null;
  const {server, port, close} = await startMockServer((req, res, body) => {
    sawBody = JSON.parse(body.toString('utf8'));
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({exitCode: 0, durationMs: 3}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const child = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'echo hi'],
      {cwd: join(fakeHome, 'workspace'), env: {}});
    const outcome = await new Promise((done) => child.once('exit', (code, signal) => done({code, signal})));
    assert.deepEqual(outcome, {code: 0, signal: null});
    assert.ok(!('tty' in sawBody));
    assert.equal(child.ishTty, false);
  } finally {
    await close();
  }
});

test('ishWebSocket propagates the server close reason (1008 cap message)', async () => {
  const {server, port, close} = await startMockWsServer({
    closeCode: 1008, closeReason: 'too many pty sessions are active (max 8)',
  });
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    const closes = [];
    const ws = ishWebSocket({
      path: '/ish/pty',
      serviceFile,
      onClose: (info) => closes.push(info),
    });
    await ws.ready;
    await new Promise((done) => setTimeout(done, 200));
    assert.equal(closes.length, 1);
    assert.equal(closes[0].code, 1008);
    assert.match(closes[0].reason, /too many pty sessions are active \(max 8\)/);
  } finally {
    await close();
  }
});

/** Send one unmasked binary frame on a mock server socket. */
function mockSendBinary(socket, text) {
  const payload = Buffer.from(text, 'utf8');
  socket.write(Buffer.concat([Buffer.from([0x82, payload.length]), payload]));
}

test('two IshPtyTerminal instances keep separate streams and record sessionIds', async () => {
  const sockets = [];
  const {server, port, close} = await startMockWsServer({
    sessionHello: true,
    onSocket: (socket) => sockets.push(socket),
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const termA = ishPtySpawn(ISH_PTY_COMMAND, ['-i'], {
      cols: 80, rows: 24, cwd: join(fakeHome, 'workspace'), env: {},
    });
    const termB = ishPtySpawn(ISH_PTY_COMMAND, ['-i'], {
      cols: 80, rows: 24, cwd: join(fakeHome, 'workspace'), env: {},
    });
    const outA = [];
    const outB = [];
    termA.onData((data) => outA.push(data));
    termB.onData((data) => outB.push(data));
    await Promise.all([termA.ready, termB.ready]);
    // The session hello arrives right after the upgrade; give it a
    // moment to be parsed before asserting.
    await new Promise((done) => setTimeout(done, 200));
    assert.ok(termA.sessionId && termA.sessionId.startsWith('mock-session-'), `A sessionId: ${termA.sessionId}`);
    assert.ok(termB.sessionId && termB.sessionId.startsWith('mock-session-'), `B sessionId: ${termB.sessionId}`);
    assert.notEqual(termA.sessionId, termB.sessionId);
    assert.equal(sockets.length, 2);
    // Distinct bytes pushed to each socket arrive only on that terminal.
    mockSendBinary(sockets[0], 'A-only');
    mockSendBinary(sockets[1], 'B-only');
    await new Promise((done) => setTimeout(done, 200));
    assert.equal(outA.join(''), 'A-only');
    assert.equal(outB.join(''), 'B-only');
    // Closing A does not affect B's stream.
    const exitA = await new Promise((done) => {
      termA.onExit((outcome) => done(outcome));
      termA.kill('SIGTERM');
    });
    assert.deepEqual(exitA, {exitCode: null, signal: null});
    mockSendBinary(sockets[1], 'B-still-alive');
    await new Promise((done) => setTimeout(done, 200));
    assert.equal(outA.join(''), 'A-only');
    assert.equal(outB.join(''), 'B-onlyB-still-alive');
    const exitB = await new Promise((done) => {
      termB.onExit((outcome) => done(outcome));
      termB.kill('SIGTERM');
    });
    assert.deepEqual(exitB, {exitCode: null, signal: null});
  } finally {
    await close();
  }
});

// ---------------------------------------------------------------------------
// Persistent shell worker (ENV-04)
// ---------------------------------------------------------------------------

/** Reply to a /ish/worker/run request like the Swift WorkerSession does. */
function mockWorkerRunResponse(res, {nonce, exitCode = 0, cwd = '/home/workspace', jobsText = '', jobPids = [], stdoutLines = []}) {
  res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
  for (const line of stdoutLines) {
    res.write(JSON.stringify({stream: 'stdout', line}) + '\n');
  }
  res.write(JSON.stringify({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:${exitCode}:${cwd}`}) + '\n');
  res.write(JSON.stringify({stream: 'stderr', line: `${WORKER_JOBS_BEGIN_PREFIX}${nonce}`}) + '\n');
  for (const line of jobsText.split('\n').filter(Boolean)) {
    res.write(JSON.stringify({stream: 'stderr', line}) + '\n');
  }
  res.write(JSON.stringify({stream: 'stderr', line: `${WORKER_JOBS_END_PREFIX}${nonce}`}) + '\n');
  res.write(JSON.stringify({stream: 'stderr', line: `${WORKER_JOBPIDS_BEGIN_PREFIX}${nonce}`}) + '\n');
  for (const pid of jobPids) {
    res.write(JSON.stringify({stream: 'stderr', line: String(pid)}) + '\n');
  }
  res.write(JSON.stringify({stream: 'stderr', line: `${WORKER_JOBPIDS_END_PREFIX}${nonce}`}) + '\n');
  res.write(JSON.stringify({exitCode, durationMs: 4}) + '\n');
  res.end();
}

test('parseWorkerEndMarker only accepts the exact nonce and a clean result', () => {
  const nonce = '0123456789abcdef0123456789abcdef';
  assert.deepEqual(
    parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:3:/tmp/work`}, nonce),
    {exitCode: 3, cwd: '/tmp/work'});
  // Wrong nonce, wrong stream, bad exit code, relative cwd: all ordinary output.
  assert.equal(parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}ffffffffffffffffffffffffffffffff:0:/tmp`}, nonce), null);
  assert.equal(parseWorkerEndMarker({stream: 'stdout', line: `${WORKER_END_MARKER_PREFIX}${nonce}:0:/tmp`}, nonce), null);
  assert.equal(parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:x:/tmp`}, nonce), null);
  assert.equal(parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:0:tmp`}, nonce), null);
  assert.equal(parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:256:/tmp`}, nonce), null);
  assert.equal(parseWorkerEndMarker({stream: 'stderr', line: `${WORKER_END_MARKER_PREFIX}${nonce}:0:/tmp`}, null), null);
});

test('parseJobsLine reads jobs -l, ignores notifications and garbage', () => {
  assert.deepEqual(parseJobsLine('[1]+  1234 Running                 sleep 600 &'),
    {job: 1, pid: 1234, state: 'running', command: 'sleep 600 &'});
  assert.deepEqual(parseJobsLine('[2]-  5678 Done                    sleep 1'),
    {job: 2, pid: 5678, state: 'done', command: 'sleep 1'});
  assert.deepEqual(parseJobsLine('[1]+  99 Exit 1                   false'),
    {job: 1, pid: 99, state: 'done', command: 'false'});
  assert.deepEqual(parseJobsLine('[3]  4242 Stopped                 cat'),
    {job: 3, pid: 4242, state: 'stopped', command: 'cat'});
  // Notification lines have no pid: not jobs lines.
  assert.equal(parseJobsLine('[1]+ Done                    sleep 1'), null);
  assert.equal(parseJobsLine('[1]+ Terminated              sleep 600 &'), null);
  assert.equal(parseJobsLine(''), null);
  assert.equal(parseJobsLine('hello'), null);
  assert.equal(parseJobsLine(null), null);
});

test('parseJobsSnapshot collects only the jobs lines', () => {
  const jobs = parseJobsSnapshot('[1]+  1234 Running                 sleep 600 &\n[2]-  5678 Done                    sleep 1\n[1]+ Done                    sleep 1\n');
  assert.deepEqual(jobs, [
    {job: 1, pid: 1234, state: 'running', command: 'sleep 600 &'},
    {job: 2, pid: 5678, state: 'done', command: 'sleep 1'},
  ]);
  assert.deepEqual(parseJobsSnapshot(''), []);
  assert.deepEqual(parseJobsSnapshot(null), []);
});

test('ishWorkerExec streams output, swallows the protocol lines, and updates the job table', async () => {
  clearWorkerState();
  const sessionId = 'sess-worker-1';
  const requests = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.equal(req.url, '/ish/worker/run');
    assert.ok(bearerOk(req));
    const parsed = JSON.parse(body.toString('utf8'));
    requests.push(parsed);
    assert.equal(parsed.sessionId, sessionId);
    assert.match(parsed.nonce, /^[0-9a-f]{32}$/, 'a 128-bit nonce per run');
    // No TERM on a worker run (no tty, ENV-12) — when env is sent.
    if (parsed.env) {
      assert.equal(parsed.env.TERM, undefined);
      assert.equal(parsed.env.PYTHONDONTWRITEBYTECODE, '0');
    }
    mockWorkerRunResponse(res, {
      nonce: parsed.nonce,
      exitCode: 0,
      cwd: '/tmp',
      jobsText: '[1]+  1234 Running                 sleep 600 &',
      jobPids: [1234],
      stdoutLines: ['hi'],
    });
  });
  try {
    invalidateServiceInfo();
    const lines = [];
    const cwds = [];
    const result = await ishWorkerExec({
      command: 'sleep 600 & echo hi',
      sessionId,
      cwd: '/home/workspace',
      env: guestEnv({DSH_SESSION_ID: sessionId}, {hasPty: false}),
      serviceFile: writeServiceFile(port),
      onLine: (frame) => lines.push(frame),
      onSessionCwd: (cwd) => cwds.push(cwd),
    });
    assert.deepEqual(result, {exitCode: 0, durationMs: 4});
    // Only the command output reaches the caller: marker + jobs blocks are swallowed.
    assert.deepEqual(lines, [{stream: 'stdout', line: 'hi'}]);
    assert.deepEqual(cwds, ['/tmp']);
    assert.equal(requests[0].cwd, '/home/workspace', 'first run sends the cwd (worker not known alive)');
    // The job table learned the background job from the snapshot.
    assert.deepEqual(getWorkerJobs(sessionId).map((j) => ({pid: j.pid, state: j.state, command: j.command})), [
      {pid: 1234, state: 'running', command: 'sleep 600 &'},
    ]);
    // Second run: the worker is known alive in /tmp, so no cwd is sent.
    const second = await ishWorkerExec({
      command: 'pwd', sessionId, cwd: '/tmp',
      serviceFile: writeServiceFile(port), onLine: () => {},
    });
    assert.equal(second.exitCode, 0);
    assert.equal(requests[1].cwd, undefined, 'steady-state runs send no cwd (the worker already is there)');
  } finally {
    clearWorkerState();
    await close();
  }
});

test('ishWorkerExec maps a 404 to ISH_WORKER_UNSUPPORTED (old service)', async () => {
  clearWorkerState();
  const {server, port, close} = await startMockServer((_req, res) => {
    res.writeHead(404, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'not_found'}));
  });
  try {
    invalidateServiceInfo();
    await assert.rejects(
      ishWorkerExec({command: 'ls', sessionId: 'sess-worker-404', serviceFile: writeServiceFile(port)}),
      (error) => error.code === ISH_WORKER_UNSUPPORTED);
    assert.equal(isWorkerUnsupported(), true);
  } finally {
    clearWorkerState();
    await close();
  }
});

test('ishWorkerExec reports a dead worker and the next run resends the cwd', async () => {
  clearWorkerState();
  const sessionId = 'sess-worker-died';
  const requests = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    requests.push(parsed);
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    // The shell exited (e.g. the command was `exit 3`): no marker, no
    // snapshot — the terminal frame carries the shell's exit code.
    res.write(JSON.stringify({stream: 'stderr', line: 'bye'}) + '\n');
    res.write(JSON.stringify({exitCode: 3, durationMs: 2, workerDied: true}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    const first = await ishWorkerExec({
      command: 'exit 3', sessionId, cwd: '/home/workspace',
      serviceFile: writeServiceFile(port), onLine: () => {},
    });
    assert.deepEqual(first, {exitCode: 3, durationMs: 2, workerDied: true});
    assert.equal(requests[0].cwd, '/home/workspace');
    // The next run rebuilds the worker and resends the remembered cwd.
    const second = await ishWorkerExec({
      command: 'pwd', sessionId, cwd: '/home/workspace',
      serviceFile: writeServiceFile(port), onLine: () => {},
    });
    assert.equal(second.exitCode, 3);
    assert.equal(requests[1].cwd, '/home/workspace', 'a rebuilt worker starts in the remembered cwd');
  } finally {
    clearWorkerState();
    await close();
  }
});

test('spawnIshExec routes a piped exec with a session id to the worker', async () => {
  clearExecCwdState();
  clearWorkerState();
  const sessionId = 'sess-spawn-worker';
  const requests = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    assert.ok(bearerOk(req));
    const parsed = JSON.parse(body.toString('utf8'));
    requests.push({url: req.url, parsed});
    if (req.url === '/ish/worker/run') {
      mockWorkerRunResponse(res, {nonce: parsed.nonce, cwd: '/tmp', stdoutLines: ['ok']});
      return;
    }
    res.writeHead(404, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'not_found'}));
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const run = async (command) => {
      const child = spawnIshExec(
        [ISH_RUNNER_COMMAND, '--', 'bash', '-c', command],
        {cwd: join(fakeHome, 'workspace'), env: {DSH_SESSION_ID: sessionId}});
      let stdout = '';
      child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
      const outcome = await new Promise((done) => child.once('exit', (code) => done(code)));
      return {outcome, stdout, child};
    };
    const first = await run('cd /tmp && pwd');
    assert.equal(first.outcome, 0);
    assert.equal(first.stdout, 'ok\n');
    assert.equal(first.child.ishWorker, true);
    assert.equal(first.child.ishTty, false);
    assert.equal(requests[0].url, '/ish/worker/run');
    assert.equal(requests[0].parsed.sessionId, sessionId);
    // Second exec reuses the worker (and the remembered cwd).
    const second = await run('pwd');
    assert.equal(second.outcome, 0);
    assert.equal(second.child.ishWorker, true);
    assert.equal(requests.length, 2);
    assert.equal(requests[1].url, '/ish/worker/run');
    assert.equal(requests[1].parsed.cwd, undefined);
  } finally {
    clearExecCwdState();
    clearWorkerState();
    await close();
  }
});

test('spawnIshExec falls back to one-shot when the service has no worker endpoints', async () => {
  clearExecCwdState();
  clearWorkerState();
  const sessionId = 'sess-spawn-fallback';
  const requests = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    requests.push(req.url);
    if (req.url === '/ish/worker/run') {
      res.writeHead(404, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: 'not_found'}));
      return;
    }
    assert.equal(req.url, '/ish/exec');
    assert.match(parsed.cwdNonce, /^[0-9a-f]{16}$/);
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'oneshot'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 5}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const run = async (command) => {
      const child = spawnIshExec(
        [ISH_RUNNER_COMMAND, '--', 'bash', '-c', command],
        {cwd: join(fakeHome, 'workspace'), env: {DSH_SESSION_ID: sessionId}});
      let stdout = '';
      child.stdout.on('data', (c) => { stdout += c.toString('utf8'); });
      const outcome = await new Promise((done) => child.once('exit', (code) => done(code)));
      return {outcome, stdout, child};
    };
    const first = await run('echo hi');
    assert.equal(first.outcome, 0);
    assert.equal(first.stdout, 'oneshot\n');
    assert.equal(first.child.ishWorker, false, 'the fallback exec is one-shot, not a worker run');
    assert.deepEqual(requests, ['/ish/worker/run', '/ish/exec']);
    // The 404 is remembered: the second exec skips the worker entirely.
    const second = await run('echo hi');
    assert.equal(second.outcome, 0);
    assert.equal(second.child.ishWorker, false);
    assert.deepEqual(requests, ['/ish/worker/run', '/ish/exec', '/ish/exec']);
    assert.equal(isWorkerUnsupported(), true);
  } finally {
    clearExecCwdState();
    clearWorkerState();
    await close();
  }
});

test('spawnIshExec skips the worker for stdin data, tty execs, and worker:false', async () => {
  clearExecCwdState();
  clearWorkerState();
  const urls = [];
  const {server, port, close} = await startMockServer((req, res) => {
    urls.push(req.url);
    res.writeHead(200, {'Content-Type': 'application/x-ndjson'});
    res.write(JSON.stringify({stream: 'stdout', line: 'ok'}) + '\n');
    res.write(JSON.stringify({exitCode: 0, durationMs: 5}) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({host: '127.0.0.1', port, token: TOKEN}));
    invalidateServiceInfo();
    const sessionOpts = {cwd: join(fakeHome, 'workspace'), env: {DSH_SESSION_ID: 'sess-skip-worker'}};
    const run = async (command, opts) => {
      const child = spawnIshExec([ISH_RUNNER_COMMAND, '--', 'bash', '-c', command], opts);
      const outcome = await new Promise((done) => child.once('exit', (code) => done(code)));
      return {outcome, child};
    };
    // stdin data: the worker's stdin is the command channel.
    const withStdin = spawnIshExec(
      [ISH_RUNNER_COMMAND, '--', 'bash', '-c', 'cat'], sessionOpts);
    withStdin.stdin.end('hello\n');
    await new Promise((done) => withStdin.once('exit', done));
    assert.equal(withStdin.ishWorker, false);
    // tty exec: the PTY path is one-shot by design.
    const tty = await run('ls', {...sessionOpts, tty: true});
    assert.equal(tty.child.ishWorker, false);
    // Explicit opt-out.
    const opted = await run('ls', {...sessionOpts, worker: false});
    assert.equal(opted.child.ishWorker, false);
    // No session id: stateless, like the cwd memory.
    const noSession = await run('ls', {cwd: join(fakeHome, 'workspace'), env: {}});
    assert.equal(noSession.child.ishWorker, false);
    assert.ok(urls.every((u) => u === '/ish/exec'), `all one-shot, got ${urls.join(',')}`);
  } finally {
    clearExecCwdState();
    clearWorkerState();
    await close();
  }
});

test('ishWorkerJobs refreshes the table and ishWorkerKillJob marks the job done', async () => {
  clearWorkerState();
  const sessionId = 'sess-jobs';
  let jobsText = '[1]+  1234 Running                 sleep 600 &';
  const kills = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    if (req.url === '/ish/worker/run') {
      assert.equal(parsed.command, ':');
      mockWorkerRunResponse(res, {nonce: parsed.nonce, jobsText, jobPids: [1234]});
      return;
    }
    if (req.url === '/ish/worker/jobs/kill') {
      assert.equal(parsed.sessionId, sessionId);
      kills.push(parsed.pid);
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({killed: true, pid: parsed.pid}));
      return;
    }
    res.writeHead(404, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'not_found'}));
  });
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    const jobs = await ishWorkerJobs(sessionId, {serviceFile});
    assert.deepEqual(jobs.map((j) => ({pid: j.pid, state: j.state})), [{pid: 1234, state: 'running'}]);
    assert.equal(await ishWorkerKillJob(sessionId, 1234, {serviceFile}), true);
    assert.deepEqual(kills, [1234]);
    assert.deepEqual(getWorkerJobs(sessionId).map((j) => ({pid: j.pid, state: j.state})),
      [{pid: 1234, state: 'done'}]);
    // The next snapshot no longer lists the job: it stays done.
    jobsText = '';
    const jobs2 = await ishWorkerJobs(sessionId, {serviceFile});
    assert.deepEqual(jobs2.map((j) => ({pid: j.pid, state: j.state})),
      [{pid: 1234, state: 'done'}]);
  } finally {
    clearWorkerState();
    await close();
  }
});

test('ishWorkerKillJob surfaces a 404 as ISH_JOB_NOT_FOUND', async () => {
  clearWorkerState();
  const {server, port, close} = await startMockServer((_req, res) => {
    res.writeHead(404, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'job_not_found'}));
  });
  try {
    invalidateServiceInfo();
    await assert.rejects(
      ishWorkerKillJob('sess-jobs-404', 9999, {serviceFile: writeServiceFile(port)}),
      (error) => error.code === ISH_JOB_NOT_FOUND);
  } finally {
    clearWorkerState();
    await close();
  }
});

test('ishWorkerStop clears the worker state (jobs are done)', async () => {
  clearWorkerState();
  const sessionId = 'sess-stop';
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    if (req.url === '/ish/worker/run') {
      mockWorkerRunResponse(res, {
        nonce: parsed.nonce,
        jobsText: '[1]+  1234 Running                 sleep 600 &',
        jobPids: [1234],
      });
      return;
    }
    if (req.url === '/ish/worker/stop') {
      assert.equal(parsed.sessionId, sessionId);
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({stopped: true}));
      return;
    }
    res.writeHead(404, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({error: 'not_found'}));
  });
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    await ishWorkerExec({command: 'sleep 600 &', sessionId, serviceFile, onLine: () => {}});
    assert.equal(getWorkerJobs(sessionId).length, 1);
    assert.equal(await ishWorkerStop(sessionId, {serviceFile}), true);
    assert.deepEqual(getWorkerJobs(sessionId).map((j) => j.state), ['done']);
    // The next run resends the cwd (the worker is not known alive).
    let nextCwd = 'unset';
    const {server: server2, port: port2, close: close2} = await startMockServer((req, res, body) => {
      const parsed = JSON.parse(body.toString('utf8'));
      nextCwd = parsed.cwd ?? null;
      mockWorkerRunResponse(res, {nonce: parsed.nonce});
    });
    try {
      await ishWorkerExec({command: 'pwd', sessionId, cwd: '/home/workspace', serviceFile: writeServiceFile(port2), onLine: () => {}});
      assert.equal(nextCwd, '/home/workspace');
    } finally {
      await close2();
    }
  } finally {
    clearWorkerState();
    await close();
  }
});

test('worker runs of one session serialize (no interleaved stdin writes)', async () => {
  clearWorkerState();
  clearExecCwdState();
  const sessionId = 'sess-serial';
  const arrivals = [];
  const {server, port, close} = await startMockServer((req, res, body) => {
    const parsed = JSON.parse(body.toString('utf8'));
    arrivals.push({command: parsed.command, at: Date.now()});
    // Hold the first run open for 150 ms; the second request must not
    // arrive until the first has been answered.
    setTimeout(() => {
      mockWorkerRunResponse(res, {nonce: parsed.nonce, stdoutLines: [parsed.command]});
    }, parsed.command === 'first' ? 150 : 0);
  });
  try {
    invalidateServiceInfo();
    const serviceFile = writeServiceFile(port);
    const outs = [];
    const p1 = ishWorkerExec({command: 'first', sessionId, serviceFile, onLine: (f) => outs.push(f.line)});
    const p2 = ishWorkerExec({command: 'second', sessionId, serviceFile, onLine: (f) => outs.push(f.line)});
    const [r1, r2] = await Promise.all([p1, p2]);
    assert.equal(r1.exitCode, 0);
    assert.equal(r2.exitCode, 0);
    assert.equal(arrivals.length, 2);
    assert.ok(arrivals[1].at - arrivals[0].at >= 140,
      `second run started ${arrivals[1].at - arrivals[0].at}ms after the first (must wait for it)`);
    assert.deepEqual(outs, ['first', 'second']);
  } finally {
    clearWorkerState();
    clearExecCwdState();
    await close();
  }
});
