/**
 * Tests for the iOS-specialized VirtualSubprocessRuntime (M-12, M-15).
 *
 * Run: node --test runtime/tests/ios-specialized-runtime.test.mjs
 *
 * The tree's runtime/ohos/process/runtime.mjs is the specialization
 * INPUT: it has no ishSpawnFor call. The real source of truth is
 * tooling/ios/specialize-runtime.py, so this file builds the
 * specialized copy with that script's own diagnostics_for_ios()
 * (which also enforces every anchor's count == 1) and imports the
 * result from a temp tree that mirrors the repo layout, so the
 * copy's relative imports resolve. Execs run against a mock
 * loopback server on 127.0.0.1, mirroring ish-bridge.test.mjs.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { pathToFileURL } from 'node:url';

const TOKEN = 'test-token-123';
const PORT_ROOT = resolve(dirname(new URL(import.meta.url).pathname), '../..');
const TREE_RUNTIME = join(PORT_ROOT, 'runtime/ohos/process/runtime.mjs');
const SPECIALIZE_PY = join(PORT_ROOT, 'tooling/ios/specialize-runtime.py');

const fakeRoot = mkdtempSync(join(tmpdir(), 'ios-specialized-runtime-'));
const fakeHome = join(fakeRoot, 'root');
mkdirSync(join(fakeHome, 'workspace'), { recursive: true });
process.env.HOME = fakeHome;
process.env.TMPDIR = join(fakeRoot, 'host-tmp');
mkdirSync(process.env.TMPDIR, { recursive: true });
delete process.env.DSH_SESSION_ID;
/** Canonical service-file path the bridge reads (HOME/../ish-service.json). */
const canonicalServiceFile = join(fakeRoot, 'ish-service.json');

/**
 * Build the specialized runtime.mjs with the real specialize script
 * and lay it out in a temp tree mirroring the repo, so its relative
 * imports (./commands.mjs, ../../ios/process/ish-adapter.mjs, ...)
 * resolve. Returns the imported VirtualSubprocessRuntime class.
 */
async function loadSpecializedRuntime() {
  const tmp = mkdtempSync(join(tmpdir(), 'ios-specialized-tree-'));
  const processDir = join(tmp, 'runtime/ohos/process');
  mkdirSync(processDir, { recursive: true });
  mkdirSync(join(tmp, 'runtime/ios'), { recursive: true });
  const script = [
    'import importlib.util, sys',
    "spec = importlib.util.spec_from_file_location('specialize_runtime', sys.argv[1])",
    'mod = importlib.util.module_from_spec(spec)',
    'spec.loader.exec_module(mod)',
    "data = open(sys.argv[2], 'rb').read()",
    "out = mod.diagnostics_for_ios('runtime/ohos/process/runtime.mjs', data)",
    "open(sys.argv[3], 'wb').write(out)",
  ].join('\n');
  const outPath = join(processDir, 'runtime.mjs');
  execFileSync('python3', ['-c', script, SPECIALIZE_PY, TREE_RUNTIME, outPath], { stdio: 'pipe' });
  const realProcessDir = join(PORT_ROOT, 'runtime/ohos/process');
  for (const entry of readdirSync(realProcessDir)) {
    if (entry === 'runtime.mjs') continue;
    symlinkSync(join(realProcessDir, entry), join(processDir, entry));
  }
  symlinkSync(join(PORT_ROOT, 'runtime/ios/process'), join(tmp, 'runtime/ios/process'));
  symlinkSync(join(PORT_ROOT, 'node_modules'), join(tmp, 'node_modules'));
  const { VirtualSubprocessRuntime } = await import(pathToFileURL(outPath).href);
  return { VirtualSubprocessRuntime, tmp };
}

function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

/**
 * Mock loopback server. Each /ish/exec POST waits for the test to
 * release it, so the exec stays in flight while the test inspects
 * runtime.live. Other paths 404 (no worker endpoints).
 */
async function startHoldingServer() {
  let requests = 0;
  const waiters = [];
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', async () => {
      if (req.url !== '/ish/exec') {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'not_found' }));
        return;
      }
      requests++;
      const gate = deferred();
      waiters.push(gate);
      const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      await gate.promise;
      res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
      res.write(JSON.stringify({ stream: 'stdout', line: 'hi' }) + '\n');
      res.write(JSON.stringify({ exitCode: 0, durationMs: 5 }) + '\n');
      res.end();
      return parsed;
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const port = server.address().port;
  writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
  return {
    requests: () => requests,
    received: async () => {
      for (;;) {
        if (requests > 0) return;
        await new Promise((done) => setTimeout(done, 5));
      }
    },
    releaseAll: () => { for (const gate of waiters.splice(0)) gate.resolve(); },
    close: () => new Promise((done) => server.close(done)),
  };
}

async function fixture(t) {
  const { VirtualSubprocessRuntime } = await loadSpecializedRuntime();
  const work = join(fakeHome, 'workspace');
  const temporaryRoot = join(fakeRoot, 'host-tmp');
  mkdirSync(temporaryRoot, { recursive: true });
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  const server = await startHoldingServer();
  t.after(async () => {
    server.releaseAll();
    await runtime.dispose().catch(() => {});
    await server.close();
  });
  const spawn = (argv, options = {}) => runtime.spawn({
    argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, ...options,
  });
  return { runtime, server, spawn, work };
}

test('M-12: an iSH bash handle is in live while running and leaves it on settle', { timeout: 15000 }, async (t) => {
  const { runtime, server, spawn } = await fixture(t);
  const handle = spawn(['bash', '-c', 'echo hi']);
  await server.received();
  assert.equal(runtime.live.has(handle), true, 'live must contain the running iSH handle');
  assert.equal(runtime.live.size, 1);
  // lifecycle/index.mjs:141 reads backend.live.size for hasActiveWork:
  // size 1 here is exactly what keeps the engine from looking idle.
  server.releaseAll();
  const outcome = await handle.done;
  assert.deepEqual(outcome, { exitCode: 0, signal: null });
  assert.equal(runtime.live.has(handle), false, 'live must drop the handle once done settles');
  assert.equal(runtime.live.size, 0);
});

test('M-12: dispose() terminates a running iSH bash handle', { timeout: 15000 }, async (t) => {
  const { runtime, server, spawn } = await fixture(t);
  const handle = spawn(['bash', '-c', 'echo hi']);
  await server.received();
  assert.equal(runtime.live.size, 1);
  const disposing = runtime.dispose();
  const outcome = await handle.done;
  assert.deepEqual(outcome, { exitCode: null, signal: 'SIGTERM' });
  await disposing;
  assert.equal(runtime.live.size, 0);
});

test('M-15: a logical cwd falls back to the virtual path and fails explicitly', { timeout: 15000 }, async (t) => {
  const { runtime, server, spawn } = await fixture(t);
  const logicalCwd = '/workspaces/12345678-1234-1234-1234-123456789012';
  const handle = spawn(['bash', '-c', 'echo hi'], { cwd: logicalCwd });
  await assert.rejects(handle.done, (error) => {
    assert.equal(error.code, 'ERR_WORKSPACE_CONFINEMENT_REQUIRED');
    return true;
  });
  assert.equal(server.requests(), 0, 'the declined spawn must never reach the guest');
  assert.equal(runtime.live.size, 0);
});
