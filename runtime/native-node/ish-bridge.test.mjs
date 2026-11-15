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
  ISH_PTY_COMMAND,
  ISH_RUNNER_COMMAND,
  extractBashCommand,
  getServiceInfo,
  guestEnv,
  invalidateServiceInfo,
  ishExec,
  ishPtySpawn,
  ishWebSocket,
  spawnIshExec,
  splitConfinedArgv,
  toGuest,
  toHost,
} from './ish-bridge.mjs';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const TOKEN = 'test-token-123';

// Fake HOME so path translation has a stable root. HOME is <root>/home,
// so the service file lives at <root>/ish-service.json (one level up).
import {mkdirSync} from 'node:fs';
const fakeRoot = mkdtempSync(join(tmpdir(), 'ish-bridge-test-'));
const fakeHome = join(fakeRoot, 'home');
mkdirSync(fakeHome, {recursive: true});
process.env.HOME = fakeHome;
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

test('toGuest maps the workspace and tmp, rejects everything else', () => {
  assert.equal(toGuest(join(fakeHome, 'workspace', 'a.txt')), '/home/workspace/a.txt');
  assert.equal(toGuest(join(fakeHome, 'workspace')), '/home/workspace');
  assert.equal(toGuest(join(fakeRoot, 'tmp', 'x')), '/tmp/x');
  // ".." escape out of the workspace is rejected (resolve normalises it).
  assert.equal(toGuest(join(fakeHome, 'workspace', '..', 'secret.txt')), null);
  assert.equal(toGuest(join(fakeHome, 'workspace', '..', '..', 'etc', 'passwd')), null);
  // Absolute paths outside the shared dirs are rejected.
  assert.equal(toGuest('/etc/passwd'), null);
  assert.equal(toGuest('/var/mobile/secret'), null);
  assert.equal(toGuest(''), null);
});

test('toHost is the inverse of toGuest for shared dirs', () => {
  assert.equal(toHost('/home/workspace/a.txt'), join(fakeHome, 'workspace', 'a.txt'));
  assert.equal(toHost('/home/workspace'), join(fakeHome, 'workspace'));
  assert.equal(toHost('/tmp/x'), join(fakeRoot, 'tmp', 'x'));
  // Guest-only paths have no host equivalent; returned unchanged (the
  // callers fall back to the input when the hook is absent).
  assert.equal(toHost('/etc/passwd'), '/etc/passwd');
  assert.equal(toHost('/root/.profile'), '/root/.profile');
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
  assert.equal(env.TERM, 'xterm-256color');
  assert.equal(env.LANG, 'en_US.UTF-8');
  assert.equal(env.TMPDIR, undefined);
  assert.equal(env.DSH_HOME, undefined);
  assert.equal(env.FOO, undefined);
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
async function startMockWsServer({closeCode = null} = {}) {
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
      // Refuse with a close frame (like the 1008 second-session refusal).
      const payload = Buffer.from([(closeCode >> 8) & 0xff, closeCode & 0xff]);
      socket.write(Buffer.from([0x88, payload.length, ...payload]));
      socket.end();
      return;
    }
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
