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
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const TOKEN = 'test-token-123';
const PORT_ROOT = resolve(dirname(new URL(import.meta.url).pathname), '../..');
const TREE_RUNTIME = join(PORT_ROOT, 'runtime/ohos/process/runtime.mjs');
const SPECIALIZE_PY = join(PORT_ROOT, 'tooling/ios/specialize-runtime.py');
// N-2 caller file: the one stock terminal caller the iOS
// specialization attaches the resolved policy in (see
// tooling/ios/specialize-runtime.py DIAGNOSTIC_EDITS). The other
// caller, the terminal controller behind the user's own terminal,
// is deliberately left stock: it carries no policy (R4-1).
const TERMINAL_BASH_FILE = 'node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js';
const TERMINAL_CONTROLLER_FILE = 'node_modules/@deepseek-ai/dsh-api-terminal-controller/lib/index.js';

const fakeRoot = mkdtempSync(join(tmpdir(), 'ios-specialized-runtime-'));
const fakeHome = join(fakeRoot, 'root');
mkdirSync(join(fakeHome, 'workspace'), { recursive: true });
process.env.HOME = fakeHome;
process.env.TMPDIR = join(fakeRoot, 'host-tmp');
mkdirSync(process.env.TMPDIR, { recursive: true });
delete process.env.DSH_SESSION_ID;
/** Canonical service-file path the bridge reads (HOME/../ish-service.json). */
const canonicalServiceFile = join(fakeRoot, 'ish-service.json');
test.after(() => rmSync(fakeRoot, { recursive: true, force: true }));

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
    // Node resolves a symlinked file's relative imports against its
    // real path, so a symlinked command-router.mjs would import the
    // UNSPECIALIZED tree runtime.mjs (no ishSpawnFor) instead of this
    // tree's specialized copy. Copy it as a real file, as the composed
    // runtime tree does in production.
    if (entry === 'command-router.mjs') {
      copyFileSync(join(realProcessDir, entry), join(processDir, entry));
      continue;
    }
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
  const urls = [];
  let lastBody = null;
  const waiters = [];
  const server = createServer((req, res) => {
    urls.push(req.url);
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
      lastBody = parsed;
      await gate.promise;
      res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
      res.write(JSON.stringify({ stream: 'stdout', line: 'hi' }) + '\n');
      res.write(JSON.stringify({ exitCode: 0, durationMs: 5 }) + '\n');
      res.end();
      return parsed;
    });
  });
  // A WS upgrade (GET /ish/pty) never reaches the 'request' handler:
  // record its URL here and refuse it, so a terminal handshake fails
  // fast instead of hanging.
  server.on('upgrade', (req, socket) => {
    urls.push(req.url);
    socket.write('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    socket.end();
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const port = server.address().port;
  writeFileSync(canonicalServiceFile, JSON.stringify({ host: '127.0.0.1', port, token: TOKEN }));
  return {
    requests: () => requests,
    urls: () => [...urls],
    lastBody: () => lastBody,
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
  const { VirtualSubprocessRuntime, tmp } = await loadSpecializedRuntime();
  const work = join(fakeHome, 'workspace');
  const temporaryRoot = join(fakeRoot, 'host-tmp');
  mkdirSync(temporaryRoot, { recursive: true });
  const runtime = new VirtualSubprocessRuntime({ workspaceRoots: [work], temporaryRoot });
  const server = await startHoldingServer();
  t.after(async () => {
    server.releaseAll();
    await runtime.dispose().catch(() => {});
    await server.close();
    rmSync(tmp, { recursive: true, force: true });
  });
  const spawn = (argv, options = {}) => runtime.spawn({
    argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, ...options,
  });
  return { runtime, server, spawn, work };
}

/**
 * A CommandRouter over the specialized runtime, with a Linux backend
 * that behaves as iOS's does (disabled): any spawn that reaches it
 * settles as exit 127, and resolveExecutable throws. A test that
 * reaches the mock loopback therefore proves the command was not
 * claimed by the Linux slot.
 */
async function routerFixture(t) {
  const { tmp } = await loadSpecializedRuntime();
  const { CommandRouter } = await import(pathToFileURL(join(tmp, 'runtime/ohos/process/command-router.mjs')).href);
  const work = join(fakeHome, 'workspace');
  const temporaryRoot = join(fakeRoot, 'host-tmp');
  mkdirSync(temporaryRoot, { recursive: true });
  const disabledLinux = {
    capabilities: Object.freeze({ confinement: Object.freeze(['read-only', 'workspace-write']), stdin: 'stream', pty: false }),
    commands: [],
    live: new Set(),
    prepare: (argv) => [...argv],
    spawn: () => ({ done: Promise.resolve({ exitCode: 127, signal: null }), started: Promise.resolve(), terminate: () => {}, waitForExit: async () => true, start: () => {} }),
    resolveExecutable: async () => { throw Object.assign(new Error('gh 在 App 内 Linux 环境中运行；Linux 环境未开启'), { code: 'ERR_OHOS_LINUX_DISABLED' }); },
    dispose: async () => {},
  };
  const router = new CommandRouter({ workspaceRoots: [work], temporaryRoot }, { linux: () => disabledLinux });
  const server = await startHoldingServer();
  t.after(async () => {
    server.releaseAll();
    await router.dispose().catch(() => {});
    await server.close();
    rmSync(tmp, { recursive: true, force: true });
  });
  const spawn = (argv, options = {}) => router.spawn({
    argv, cwd: work, graceMs: 200,
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' }, ...options,
  });
  return { router, server, spawn, work };
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

test('N-1: a direct gh spawn via CommandRouter reaches the guest, not the disabled Linux slot', { timeout: 15000 }, async (t) => {
  const { server, spawn } = await routerFixture(t);
  const handle = spawn(['gh', '--version']);
  await server.received();
  server.releaseAll();
  const outcome = await handle.done;
  assert.deepEqual(outcome, { exitCode: 0, signal: null });
  assert.equal(server.requests(), 1, 'gh must reach the mock loopback exactly once');
  assert.deepEqual(server.lastBody().argv, ['gh', '--version']);
  assert.equal('command' in server.lastBody(), false, 'a CLI argv goes verbatim, with no shell command');
});

test('N-1: a direct python3 spawn via CommandRouter reaches the guest, not the disabled Linux slot', { timeout: 15000 }, async (t) => {
  const { server, spawn } = await routerFixture(t);
  const handle = spawn(['python3', '--version']);
  await server.received();
  server.releaseAll();
  const outcome = await handle.done;
  assert.deepEqual(outcome, { exitCode: 0, signal: null });
  assert.equal(server.requests(), 1, 'python3 must reach the mock loopback exactly once');
  assert.deepEqual(server.lastBody().argv, ['python3', '--version']);
});

test('N-1: resolveExecutable returns the bare guest CLI name instead of asking disabled Linux', { timeout: 15000 }, async (t) => {
  const { router } = await routerFixture(t);
  for (const name of ['gh', 'python3', 'pip', 'pip3']) {
    assert.equal(await router.resolveExecutable(name), name, `${name} must resolve to its bare name`);
  }
  assert.equal(await router.resolveExecutable('rg'), '/dsh-go/ohos/bin/rg', 'rg keeps its virtual resolution');
  assert.equal(await router.resolveExecutable('git'), '/dsh-go/ohos/bin/git', 'git keeps its virtual resolution');
});

test('N-2: a read-only policy marks the terminal upgrade readOnly; no policy leaves it unmarked', { timeout: 15000 }, async (t) => {
  const { runtime, server } = await fixture(t);
  const terminalSpec = (policy) => ({ argv: ['bash'], cols: 80, rows: 24, ...(policy ? { policy } : {}) });
  // The mock server refuses the upgrade with 400, so each terminal
  // exits at the handshake: done settles without a guest shell.
  const readOnlyTerminal = await runtime.spawnTerminal(terminalSpec({ mode: 'read-only' }));
  await readOnlyTerminal.done;
  const plainTerminal = await runtime.spawnTerminal(terminalSpec());
  await plainTerminal.done;
  assert.ok(server.urls().includes('/ish/pty?readOnly=1'),
    `read-only upgrade must carry the flag; saw ${JSON.stringify(server.urls())}`);
  assert.ok(server.urls().includes('/ish/pty'),
    `a terminal without a policy must upgrade plainly; saw ${JSON.stringify(server.urls())}`);
  assert.ok(server.urls().filter((url) => url.includes('?')).every((url) => url === '/ish/pty?readOnly=1'),
    `no other query form may appear; saw ${JSON.stringify(server.urls())}`);
});

/**
 * Run the real specialize script's diagnostics_for_ios() on one
 * composed-tree file and return the specialized text. The script
 * itself enforces every anchor's count == 1, so a drifted upstream
 * file fails here instead of silently shipping unpatched.
 */
function specializeFile(relPath) {
  const script = [
    'import importlib.util, sys',
    "spec = importlib.util.spec_from_file_location('specialize_runtime', sys.argv[1])",
    'mod = importlib.util.module_from_spec(spec)',
    'spec.loader.exec_module(mod)',
    "data = open(sys.argv[2], 'rb').read()",
    'out = mod.diagnostics_for_ios(sys.argv[4], data)',
    "open(sys.argv[3], 'wb').write(out)",
  ].join('\n');
  const tmp = mkdtempSync(join(tmpdir(), 'ios-specialized-file-'));
  const outPath = join(tmp, 'out.js');
  try {
    execFileSync('python3', ['-c', script, SPECIALIZE_PY, join(PORT_ROOT, relPath), outPath, relPath], { stdio: 'pipe' });
    return readFileSync(outPath, 'utf8');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

/**
 * Import a specialized caller module from a temp mirror of the repo
 * layout: the specialized file sits at <mirror>/caller/<relPath>, so
 * its bare imports resolve through <mirror>/node_modules (symlinked
 * to the repo's), exactly like the composed runtime tree's layout.
 * The mirror's own node_modules holds only the specialized caller
 * packages; every other bare import falls through to the repo tree.
 */
async function loadSpecializedCaller(t, relPath) {
  const text = specializeFile(relPath);
  const mirror = mkdtempSync(join(tmpdir(), 'ios-specialized-caller-'));
  const dest = join(mirror, 'caller', relPath);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, text);
  symlinkSync(join(PORT_ROOT, 'node_modules'), join(mirror, 'node_modules'));
  t.after(() => rmSync(mirror, { recursive: true, force: true }));
  return import(pathToFileURL(dest).href);
}

// N-2 caller: the specialization itself must attach the policy —
// the stock callers do not, and the anchor's count == 1 is enforced
// by diagnostics_for_ios, so these tests also guard anchor drift.
test('N-2 caller: terminal-bash specialization attaches policy to the spawnTerminal spec', () => {
  const original = readFileSync(join(PORT_ROOT, TERMINAL_BASH_FILE), 'utf8');
  const text = specializeFile(TERMINAL_BASH_FILE);
  assert.ok(text.includes('\t\t\targv,\n\t\t\tpolicy,\n\t\t\tcwd: spec.cwd'),
    'specialized spawnTerminal spec must carry the resolved policy');
  assert.ok(!original.includes('\t\t\targv,\n\t\t\tpolicy,\n'),
    'the stock caller must not attach policy (the test is sensitive to the edit)');
});

// N-2 caller (R4-1): the controller is deliberately NOT specialized:
// the user's own terminal must open without an agent sandbox policy
// (create() promises a shell "without Agent sandbox or approval
// restrictions"). The specialization must carry no edit for it, and
// the stock spawn must neither fetch the policy for the spec nor put
// one in it.
test('N-2 caller: terminal-controller specialization leaves the manual terminal unpolicied', () => {
  // No string match on the .py source: a double-quoted key is equally
  // valid Python and diagnostics_for_ios would run it. Ask the real
  // function instead — it raises KeyError exactly when
  // DIAGNOSTIC_EDITS carries no entry for the controller, whatever
  // the key's quote style.
  assert.throws(() => specializeFile(TERMINAL_CONTROLLER_FILE), /KeyError: 'node_modules\/@deepseek-ai\/dsh-api-terminal-controller\/lib\/index\.js'/,
    'diagnostics_for_ios must have no edit for the terminal controller (the manual terminal stays exempt)');
  const stock = readFileSync(join(PORT_ROOT, TERMINAL_CONTROLLER_FILE), 'utf8');
  assert.ok(stock.includes('const { subprocess, workingDirectory } = this.execution(agent);'),
    'stock spawn must destructure only subprocess and workingDirectory');
  assert.ok(!stock.includes('sandboxPolicy, workingDirectory } = this.execution(agent)'),
    'stock spawn must not fetch sandboxPolicy for the spec');
  assert.ok(!stock.includes('argv: [shell.path, ...shell.args],\n\t\t\t\tpolicy,'),
    'stock spawnTerminal spec must not carry a policy');
});

// N-2 caller: drive the specialized BashTerminalBackend with stubbed
// ctx and a capturing spawnTerminal, and assert the resolved policy
// reaches the spec. The backend's own spawnTerminal is injected, so
// no subprocess or guest is involved.
test('N-2 caller: BashTerminalBackend.spawn puts the resolved policy in the spec', { timeout: 15000 }, async (t) => {
  const { BashTerminalBackend } = await loadSpecializedCaller(t, TERMINAL_BASH_FILE);
  const session = { id: 'sess-n2', header: { cwd: '/tmp' } };
  const owner = { id: 'owner-n2', session, ctx: { on: () => {} } };
  const resolved = { mode: 'read-only', workspaceRoot: '/tmp', sessionId: 'sess-n2' };
  const ctx = {
    terminals: {},
    sandboxPolicy: {
      resolve: (request) => {
        assert.equal(request.session, session, 'policy must resolve for the spec owner session');
        return resolved;
      },
    },
    workingDirectory: { ensure: async () => '/tmp' },
    get: (name) => (name === 'sandbox' ? { confine: async (argv) => ({ argv }) } : undefined),
  };
  const config = {
    backendType: 'bash', shellPath: '/bin/bash', shellArgs: [],
    rows: 24, cols: 80, shellDialect: 'bash', disposeGraceMs: 200, timeoutMs: 5000,
  };
  let captured = null;
  const spawnTerminal = async (spec) => { captured = spec; return { pid: 7 }; };
  const createSession = () => ({ initialize: async () => {} });
  const backend = new BashTerminalBackend(ctx, config, spawnTerminal, createSession);
  const spawned = await backend.spawn({ owner, sessionId: 'pty-n2', cwd: '/tmp' });
  assert.ok(spawned, 'spawn must return the created session');
  assert.equal(captured.policy, resolved, 'the resolved policy must travel in the spec');
  assert.equal(captured.policy.mode, 'read-only');
  assert.deepEqual(captured.argv, ['/bin/bash']);
});

// N-2 caller (R4-1): drive the STOCK TerminalController.spawn with a
// fake `this` (execution/config only) and stubbed providers, and
// assert the spec carries NO policy: the manual terminal opens
// unpolicied even though the sandboxPolicy provider exists. spawn()
// itself builds a BrowserTerminal around the stubbed handle, so the
// handle carries an ended output stream and an already-settled done.
test('N-2 caller: TerminalController.spawn puts no policy in the spec', { timeout: 15000 }, async () => {
  const { TerminalController } = await import(pathToFileURL(join(PORT_ROOT, TERMINAL_CONTROLLER_FILE)).href);
  const session = { id: 'sess-n2-ctl', header: { cwd: '/tmp' } };
  let captured = null;
  const providers = {
    subprocess: {
      resolveExecutable: async (path) => path,
      spawnTerminal: async (spec) => {
        captured = spec;
        return { pid: 7, output: Readable.from([]), done: Promise.resolve({ exitCode: 0, signal: null }) };
      },
    },
    // Present but never resolved: stock spawn destructures only
    // subprocess and workingDirectory, so resolve() must not run.
    sandboxPolicy: {
      resolve: () => { throw new Error('stock controller spawn must not resolve a policy'); },
    },
    workingDirectory: { ensure: async () => '/tmp' },
  };
  const agent = { id: 'agent-n2', session, ctx: { get: (name) => providers[name] } };
  const fakeThis = {
    execution: (a) => ({
      subprocess: a.ctx.get('subprocess'),
      sandboxPolicy: a.ctx.get('sandboxPolicy'),
      workingDirectory: a.ctx.get('workingDirectory'),
    }),
    config: {
      shell: { path: '/bin/bash', args: [], name: 'bash' },
      disposeGraceMs: 200, scrollback: 100, maxBufferedBytes: 4096,
    },
  };
  const terminal = await TerminalController.prototype.spawn.call(
    fakeThis, agent, {}, { id: 't-n2', cols: 80, rows: 24 }, new AbortController().signal);
  assert.ok(terminal, 'spawn must return the created terminal');
  assert.equal('policy' in captured, false, 'the manual terminal spec must carry no policy');
  assert.deepEqual(captured.argv, ['/bin/bash']);
});

// N-2 caller (R4-3): the stock spawn destructures { subprocess,
// workingDirectory } from execution(), so pin the REAL execution()
// provider shape: it returns exactly the three providers the
// controller relies on, and throws when one is missing. The stubbed
// execution() in the behavior test above cannot catch an upstream
// change to this return shape.
test('N-2 caller: TerminalController execution() returns the providers spawn destructures', async () => {
  const { TerminalController } = await import(pathToFileURL(join(PORT_ROOT, TERMINAL_CONTROLLER_FILE)).href);
  const providers = {
    subprocess: { resolveExecutable: async (path) => path },
    sandboxPolicy: { resolve: () => ({ mode: 'read-only' }) },
    workingDirectory: { ensure: async () => '/tmp' },
  };
  const agent = { id: 'agent-n2-exec', ctx: { get: (name) => providers[name] } };
  const returned = TerminalController.prototype.execution.call({}, agent);
  assert.deepEqual(Object.keys(returned).sort(), ['sandboxPolicy', 'subprocess', 'workingDirectory']);
  assert.equal(returned.subprocess, providers.subprocess);
  assert.equal(returned.sandboxPolicy, providers.sandboxPolicy);
  assert.equal(returned.workingDirectory, providers.workingDirectory);
  for (const missing of ['subprocess', 'sandboxPolicy', 'workingDirectory']) {
    const partial = { ...providers, [missing]: undefined };
    const partialAgent = { id: 'agent-n2-exec', ctx: { get: (name) => partial[name] } };
    assert.throws(() => TerminalController.prototype.execution.call({}, partialAgent),
      /requires (subprocess and sandbox policy|a working-directory) provider/);
  }
});

// N-2 caller (R4-2): lib/types/index.js is a second, unpatched copy
// of the controller bundled into lib/index.js. After the R4-1 revert
// the two copies behave the same (neither attaches a policy), so
// there is nothing to mirror — mirroring would re-create the
// exemption break in the copy, and deleting the file at compose time
// would need new machinery for a file nothing loads. Instead this
// test pins the copy as dead code: no export maps to it and no
// module in the tree imports it, so a future loader change cannot
// silently route terminals through the stale copy.
test('N-2 caller: no module resolves the duplicate controller copy lib/types/index.js', () => {
  const packageDir = join(PORT_ROOT, 'node_modules/@deepseek-ai/dsh-api-terminal-controller');
  assert.ok(existsSync(join(packageDir, 'lib/types/index.js')),
    'the duplicate copy must exist for this test to mean anything');
  const pkg = JSON.parse(readFileSync(join(packageDir, 'package.json'), 'utf8'));
  const targets = [];
  const collect = (node) => {
    if (typeof node === 'string') targets.push(node);
    else if (node && typeof node === 'object') Object.values(node).forEach(collect);
  };
  collect(pkg.exports);
  assert.ok(targets.length > 0, 'the controller package must declare exports');
  assert.ok(!targets.some((target) => target.endsWith('lib/types/index.js')),
    `no export may map to the duplicate copy; saw ${JSON.stringify(targets)}`);
  assert.equal(pkg.exports['./types'].default, './lib/types/types.js',
    'the ./types export must stay the empty stub, not the duplicate implementation');
  assert.equal(readFileSync(join(packageDir, 'lib/types/types.js'), 'utf8').split('\n')[0], 'export {};',
    'the ./types target must be a stub with no implementation');
  // The only in-package mention of the duplicate is the bundler's
  // //#region marker in lib/index.js (a comment, not an import).
  const bundled = readFileSync(join(packageDir, 'lib/index.js'), 'utf8');
  const mentions = bundled.split('\n').filter((line) => line.includes('lib/types/index.js'));
  assert.deepEqual(mentions, ['//#region lib/types/index.js']);
  // No file outside node_modules may deep-import the duplicate; this
  // test file itself names the path, so it is excluded from the walk.
  // The installed packages get a second pass: a future upstream
  // package deep-importing the duplicate would land in node_modules,
  // and only code files (.js/.mjs/.cjs) can resolve it. The
  // controller package itself holds no such reference (its only
  // mention is the bundler's //#region comment, without the
  // terminal-controller/ prefix), so nothing is excluded there.
  const hits = [];
  const walk = (dir, skipNodeModules, pattern) => {
    let scanned = 0;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === '.git' || (skipNodeModules && entry.name === 'node_modules')) continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) scanned += walk(path, skipNodeModules, pattern);
      else if (entry.isFile() && path !== fileURLToPath(import.meta.url)
        && pattern.test(entry.name)) {
        scanned++;
        if (readFileSync(path, 'utf8').includes('terminal-controller/lib/types/index.js')) hits.push(path);
      }
    }
    return scanned;
  };
  walk(PORT_ROOT, true, /\.(mjs|js|cjs|json|ya?ml|py|md)$/);
  const scannedSecondPass = walk(join(PORT_ROOT, 'node_modules'), false, /\.(mjs|js|cjs)$/);
  assert.ok(scannedSecondPass > 1000, 'the node_modules pass must actually scan installed modules');
  assert.deepEqual(hits, [], 'no repo or installed-module file may reference the duplicate controller copy');
});
