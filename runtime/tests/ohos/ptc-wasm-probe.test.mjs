import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createContext, Script } from 'node:vm';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(join(resolve(process.env.DSH_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const ptcLib = join(resolve(process.env.DSH_PREFIX),
  'node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib');

test('P1: importing dsh-ptc-runtime-node logs the host WebAssembly probe', async () => {
  const lines = [];
  const origLog = console.log;
  console.log = (...args) => { lines.push(args.map(String).join(' ')); };
  try {
    await load('dsh-ptc-runtime-node');
  } finally {
    console.log = origLog;
  }
  const probe = lines.find((line) => line.includes('[ptc-wasm-probe] host-load'));
  assert.ok(probe, `host-load probe missing in: ${lines.join('\n')}`);
  assert.match(probe, /WebAssembly=object/, 'host Node has WebAssembly');
});

test('P1: vm context without WebAssembly gains a working one from the host injection', () => {
  // Build a context the way createScriptContext does, strip WebAssembly from
  // it to simulate a realm that lacks it, then apply the injection the patch
  // adds to process.js / persistent-process.js (same statements, same guard).
  // The real createScriptContext cannot be imported directly: process.js and
  // persistent-process.js are worker entry points that run their main on
  // import. The source assertion below ties this behaviour to the real code.
  const globals = Object.create(null);
  const context = createContext(globals);
  const realm = new Script('globalThis').runInContext(context);
  new Script('delete globalThis.WebAssembly').runInContext(context);
  assert.equal(new Script('typeof WebAssembly').runInContext(context), 'undefined');
  assert.equal(Object.hasOwn(realm, 'WebAssembly'), false);
  if (!Object.hasOwn(realm, 'WebAssembly') && typeof WebAssembly !== 'undefined') {
    Object.defineProperty(globals, 'WebAssembly',
      Object.getOwnPropertyDescriptor(globalThis, 'WebAssembly'));
  }
  assert.equal(new Script('typeof WebAssembly').runInContext(context), 'object');
  assert.equal(
    new Script('new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0])) instanceof WebAssembly.Module')
      .runInContext(context),
    true);
});

test('P1: injection does not replace a context that already has WebAssembly', () => {
  const globals = Object.create(null);
  const context = createContext(globals);
  const realm = new Script('globalThis').runInContext(context);
  const before = new Script('WebAssembly').runInContext(context);
  assert.equal(typeof before, 'object');
  if (!Object.hasOwn(realm, 'WebAssembly') && typeof WebAssembly !== 'undefined') {
    Object.defineProperty(globals, 'WebAssembly',
      Object.getOwnPropertyDescriptor(globalThis, 'WebAssembly'));
  }
  const after = new Script('WebAssembly').runInContext(context);
  assert.equal(after, before, 'context keeps its own WebAssembly intrinsic');
});

test('P1: the probe and injection are present in the patched engine files', () => {
  const index = readFileSync(join(ptcLib, 'index.js'), 'utf8');
  assert.ok(index.includes('[ptc-wasm-probe] host-load'), 'index.js: host-load probe');
  assert.ok(index.includes('[ptc-wasm-probe] stripTypes mode='),
    'index.js: stripTypes probe');
  const injection = 'if (!Object.hasOwn(realm, "WebAssembly") && typeof WebAssembly !== "undefined") '
    + 'Object.defineProperty(globals, "WebAssembly", '
    + 'Object.getOwnPropertyDescriptor(globalThis, "WebAssembly"));';
  for (const file of ['process.js', 'persistent-process.js']) {
    const src = readFileSync(join(ptcLib, file), 'utf8');
    assert.ok(src.includes('[ptc-wasm-probe] createScriptContext'),
      `${file}: context probe`);
    assert.ok(src.includes(injection), `${file}: injection`);
  }
});

test('P1: --jitless removes WebAssembly and breaks stripTypeScriptTypes', () => {
  // Pins the diagnosis: NodeMobile runs --jitless, which is what makes the
  // host report undefined at every probe level on device. Same Node version
  // as NodeMobile (24.22.1) reproduces ERR_WEBASSEMBLY_NOT_SUPPORTED here.
  const probe = 'const out = [typeof WebAssembly];'
    + ' try { const { stripTypeScriptTypes } = require("node:module");'
    + ' stripTypeScriptTypes("const x: number = 1;"); out.push("strip-ok"); }'
    + ' catch (error) { out.push("strip-fail:" + (error.code || error.name)); }'
    + ' console.log(JSON.stringify(out));';
  const run = spawnSync(process.execPath, ['--jitless', '-e', probe],
    { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  const [wasm, strip] = JSON.parse(run.stdout.trim());
  assert.equal(wasm, 'undefined', '--jitless must remove the WebAssembly global');
  assert.equal(strip, 'strip-fail:ERR_WEBASSEMBLY_NOT_SUPPORTED');
});
