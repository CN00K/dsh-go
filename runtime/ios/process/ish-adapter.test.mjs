/**
 * Unit tests for ish-adapter.mjs (M-15 grant/logical-cwd decline).
 *
 * Run: node --test runtime/ios/process/ish-adapter.test.mjs
 *
 * The positive-path tests spin up a mock loopback server on 127.0.0.1
 * (ephemeral port) and point the bridge at it via a fake
 * ish-service.json, mirroring ish-bridge.test.mjs. The decline tests
 * need no server: ishSpawnFor must return undefined before any HTTP.
 */
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { ishSpawnFor } from './ish-adapter.mjs';
import { ISH_RUNNER_COMMAND, invalidateServiceInfo } from './ish-bridge.mjs';

const TOKEN = 'test-token-123';

const fakeRoot = mkdtempSync(join(tmpdir(), 'ish-adapter-test-'));
const fakeHome = join(fakeRoot, 'root');
mkdirSync(fakeHome, { recursive: true });
mkdirSync(join(fakeHome, 'workspace'), { recursive: true });
process.env.HOME = fakeHome;
process.env.TMPDIR = join(fakeRoot, 'host-tmp');
delete process.env.DSH_SESSION_ID;
/** Canonical service-file path the bridge reads (HOME/../ish-service.json). */
const canonicalServiceFile = join(fakeRoot, 'ish-service.json');

const GRANT_ID = '12345678-1234-1234-1234-123456789012';
const LOGICAL_CWD = `/workspaces/${GRANT_ID}`;
const WORKSPACE_CWD = join(fakeHome, 'workspace');

function spec(cwd) {
  return {
    cwd,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' },
    env: {},
  };
}

function opts(policy) {
  return { temporaryRoot: join(fakeRoot, 'host-tmp'), onSpillFailure: () => {}, policy };
}

function collect(stream) {
  const chunks = [];
  stream.on('data', (c) => chunks.push(Buffer.from(c)));
  return () => Buffer.concat(chunks).toString('utf8');
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
  return { server, port, close: () => new Promise((done) => server.close(done)) };
}

function replyOk(res) {
  res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
  res.write(JSON.stringify({ stream: 'stdout', line: 'hi' }) + '\n');
  res.write(JSON.stringify({ exitCode: 0, durationMs: 5 }) + '\n');
  res.end();
}

// M-15 decline tests run first: they must decline before ensureBridge()
// installs anything, so the bridge symbols stay unset here.
test('M-15: ishSpawnFor declines a logical workspace cwd (no guest run)', () => {
  const handle = ishSpawnFor(['bash', '-c', 'echo hi'], spec(LOGICAL_CWD), opts(undefined));
  assert.equal(handle, undefined);
  assert.equal(globalThis[Symbol.for('dsh.ish.pty')], undefined,
    'a declined spawn must not install the bridge');
});

test('M-15: ishSpawnFor declines the bare /workspaces root too', () => {
  assert.equal(ishSpawnFor(['bash', '-c', 'echo hi'], spec('/workspaces'), opts(undefined)), undefined);
});

test('M-15: ishSpawnFor declines when the policy carries a grant', () => {
  const policy = { mode: 'workspace-write', workspaceRoot: LOGICAL_CWD,
    grant: { mountPoint: LOGICAL_CWD } };
  assert.equal(ishSpawnFor(['bash', '-c', 'echo hi'], spec(WORKSPACE_CWD), opts(policy)), undefined);
});

test('M-15: a normal workspace cwd still goes to the guest', async () => {
  let requests = 0;
  const { server, port, close } = await startMockServer((req, res, body) => {
    assert.equal(req.headers.authorization, `Bearer ${TOKEN}`);
    if (req.url !== '/ish/exec') {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'not_found' }));
      return;
    }
    requests++;
    const parsed = JSON.parse(body.toString('utf8'));
    assert.equal(parsed.command, 'echo hi');
    assert.equal(parsed.cwd, '/home/workspace');
    replyOk(res);
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
    invalidateServiceInfo();
    const handle = ishSpawnFor(['bash', '-c', 'echo hi'], spec(WORKSPACE_CWD), opts(undefined));
    assert.notEqual(handle, undefined);
    const stdout = collect(handle.stdout);
    const outcome = await handle.done;
    assert.deepEqual(outcome, { exitCode: 0, signal: null });
    assert.equal(stdout(), 'hi\n');
    assert.equal(requests, 1);
  } finally {
    await close();
  }
});

test('M-15: a non-logical lookalike cwd is not declined', async () => {
  let requests = 0;
  const { server, port, close } = await startMockServer((req, res) => {
    if (req.url !== '/ish/exec') {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'not_found' }));
      return;
    }
    requests++;
    replyOk(res);
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
    invalidateServiceInfo();
    // '/workspaces-evil' is not a logical path (isLogicalWorkspacePath
    // only matches '/workspaces' and '/workspaces/...').
    const handle = ishSpawnFor(['bash', '-c', 'echo hi'], spec('/workspaces-evil'), opts(undefined));
    assert.notEqual(handle, undefined);
    await handle.done;
    assert.equal(requests, 1);
  } finally {
    await close();
  }
});

// ---------------------------------------------------------------------------
// Route B (2026-11-18): agent rg/git/node/gh/python3/pip via a direct
// argv exec. `node` is only routed when the caller says this is the
// agent-facing (non-concurrent) runtime — pluginNode spawns `node` for
// engine plugin scripts and must stay virtual.
// ---------------------------------------------------------------------------

test('B: ishSpawnFor routes agent rg to the guest as argv', async () => {
  let seenBody = null;
  const { server, port, close } = await startMockServer((req, res, body) => {
    assert.equal(req.url, '/ish/exec');
    seenBody = JSON.parse(body.toString('utf8'));
    replyOk(res);
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
    invalidateServiceInfo();
    const handle = ishSpawnFor(['rg', '--json', 'x'], spec(WORKSPACE_CWD),
      { ...opts(undefined), concurrent: false });
    assert.notEqual(handle, undefined);
    const outcome = await handle.done;
    assert.deepEqual(outcome, { exitCode: 0, signal: null });
    assert.deepEqual(seenBody.argv, ['rg', '--json', 'x']);
    assert.equal('command' in seenBody, false);
  } finally {
    await close();
  }
});

test('B: ishSpawnFor routes node only when explicitly non-concurrent', async () => {
  // concurrent:true (pluginNode) and unset both stay virtual; only an
  // explicit concurrent:false (the agent runtime) routes node.
  assert.equal(ishSpawnFor(['node', '-e', '1'], spec(WORKSPACE_CWD),
    { ...opts(undefined), concurrent: true }), undefined);
  assert.equal(ishSpawnFor(['node', '-e', '1'], spec(WORKSPACE_CWD),
    opts(undefined)), undefined);
  let seenBody = null;
  const { server, port, close } = await startMockServer((req, res, body) => {
    seenBody = JSON.parse(body.toString('utf8'));
    replyOk(res);
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
    invalidateServiceInfo();
    const handle = ishSpawnFor(['node', '-e', '1'], spec(WORKSPACE_CWD),
      { ...opts(undefined), concurrent: false });
    assert.notEqual(handle, undefined);
    await handle.done;
    assert.deepEqual(seenBody.argv, ['node', '-e', '1']);
  } finally {
    await close();
  }
});

test('B: ishSpawnFor declines a path argv, sh, and unknown commands', () => {
  assert.equal(ishSpawnFor(['/usr/bin/rg', 'x'], spec(WORKSPACE_CWD),
    { ...opts(undefined), concurrent: false }), undefined);
  assert.equal(ishSpawnFor(['sh', '-c', 'echo hi'], spec(WORKSPACE_CWD),
    { ...opts(undefined), concurrent: false }), undefined);
  assert.equal(ishSpawnFor(['ffmpeg', '-version'], spec(WORKSPACE_CWD),
    { ...opts(undefined), concurrent: false }), undefined);
  assert.notEqual(ishSpawnFor(['rg'], spec(WORKSPACE_CWD),
    { ...opts(undefined), concurrent: false }), undefined,
    'a bare rg with no pattern still routes (argv validation is the server\'s job)');
});

test('B: ishSpawnFor forwards readOnly on the argv path and the denial flows', async () => {
  let seenBody = null;
  const { server, port, close } = await startMockServer((req, res, body) => {
    seenBody = JSON.parse(body.toString('utf8'));
    // Mimic sendReadOnlyDenied: 200 + NDJSON denial line + exitCode 1.
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
    res.write(JSON.stringify({ stream: 'stderr', line: 'EACCES: OHOS_SANDBOX_DENIED: 当前调用是 read-only，不能修改文件' }) + '\n');
    res.write(JSON.stringify({ exitCode: 1, durationMs: 0 }) + '\n');
    res.end();
  });
  try {
    invalidateServiceInfo();
    writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
    invalidateServiceInfo();
    const policy = { mode: 'read-only' };
    const handle = ishSpawnFor(['git', 'status'], spec(WORKSPACE_CWD),
      { ...opts(policy), concurrent: false });
    assert.notEqual(handle, undefined);
    const stderr = collect(handle.stderr);
    const outcome = await handle.done;
    assert.deepEqual(outcome, { exitCode: 1, signal: null });
    assert.equal(seenBody.readOnly, true);
    assert.deepEqual(seenBody.argv, ['git', 'status']);
    assert.ok(stderr().includes('OHOS_SANDBOX_DENIED'), `denial missing: ${JSON.stringify(stderr())}`);
  } finally {
    await close();
  }
});
