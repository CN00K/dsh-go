import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';

const prefix = resolve(process.env.DSH_PREFIX);
const base = join(prefix, 'node_modules/@deepseek-ai');
const { boot, PluginPackages } = await import(pathToFileURL(join(base, 'dsh-app-boot/lib/index.js')));
const { parseInstallSpec } = await import(pathToFileURL(join(base, 'dsh-plugin-manager/lib/index.js')));
const { createPluginBackend } = await import(pathToFileURL(join(prefix, 'runtime/ohos/plugins/backend.mjs')));
const { localDirectoryPath } = await import(pathToFileURL(join(prefix, 'runtime/ohos/plugins/registry.mjs')));

const ISH = Symbol.for('dsh.ish.pty');
const BACKEND = Symbol.for('dsh.go.ohos.plugins');
const manager = join(base, 'dsh-plugin-manager/lib/index.js');

function profileContext(dir, home) {
  return {
    dir, home, installAnchor: join(base, 'dsh/package.json'),
    patchPath: join(dir, 'cordis.patch.yml'),
    overlays: [], startedBundles: [], telemetryDisabledEnv: '1',
  };
}

async function bootProfile(t, dir, home, fileRows, mountRows = fileRows) {
  let ctx;
  t.after(async () => { await ctx?.fiber.dispose(); });
  await writeFile(join(dir, 'cordis.yml'), '[]\n');
  await writeFile(join(dir, 'cordis.patch.yml'), JSON.stringify(fileRows));
  // The real launcher mounts the composed set (bundle layers, then the
  // profile patch); the file itself only holds the profile layer.
  ctx = await boot('dsh', join(dir, 'cordis.yml'), mountRows, async (c) => {
    await c.plugin(PluginPackages);
    c.provide('profileContext', profileContext(dir, home));
  });
  assert.ok(ctx.pluginManager);
  return ctx;
}

async function writeLocalBundle(dir, { platforms } = {}) {
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'package.json'), JSON.stringify({
    name: 'local-test-bundle',
    version: '1.0.0',
    type: 'module',
    exports: { '.': './index.mjs', './package.json': './package.json' },
    dsh: { bundle: { patch: './cordis.patch.yml', ...(platforms ? { platforms } : {}) } },
  }));
  await writeFile(join(dir, 'index.mjs'), 'export function apply() {}\n');
  await writeFile(join(dir, 'cordis.patch.yml'), JSON.stringify([
    { insert: [{ id: 'lb-0', name: 'local-test-bundle' }] },
  ]));
}

// Fixture with the bundle already installed (profile node_modules +
// dependencies + bundles list), so listPlugins/listBundles can be read
// without going through installBundle.
async function installedFixture(t, { nestedInclude = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'ish-host-installed-'));
  t.after(async () => { await rm(root, { recursive: true, force: true }); });
  const home = join(root, 'home'), dir = join(home, 'profiles/web');
  const pkg = join(dir, 'node_modules/local-test-bundle');
  const failing = join(dir, 'node_modules/local-failing-plugin');
  await mkdir(join(pkg), { recursive: true });
  await mkdir(join(failing), { recursive: true });
  await writeFile(join(pkg, 'package.json'), JSON.stringify({
    name: 'local-test-bundle',
    version: '1.0.0',
    type: 'module',
    exports: { '.': './index.mjs', './package.json': './package.json' },
    dsh: { bundle: { patch: './cordis.patch.yml', platforms: ['linux'] } },
  }));
  await writeFile(join(pkg, 'index.mjs'), 'export function apply() {}\n');
  const bundlePatch = [{ insert: [
    { id: 'good-0', name: 'local-test-bundle' },
    { id: 'bad-0', name: 'local-failing-plugin' },
  ] }];
  await writeFile(join(pkg, 'cordis.patch.yml'), JSON.stringify(bundlePatch));
  await writeFile(join(failing, 'package.json'), JSON.stringify({
    name: 'local-failing-plugin',
    version: '1.0.0',
    type: 'module',
    exports: { '.': './index.mjs', './package.json': './package.json' },
  }));
  await writeFile(join(failing, 'index.mjs'), "export function apply() { throw new Error('fiber-boom'); }\n");
  await writeFile(join(dir, 'package.json'), JSON.stringify({
    name: 'fixture-profile',
    dependencies: { 'local-test-bundle': 'file:' + pkg },
    dsh: { profile: { bundles: ['local-test-bundle'] } },
  }));
  const nestedPatch = join(dir, 'nested.patch.yml');
  const fileRows = [{ insert: [{ id: 'manager', name: pathToFileURL(manager).href }] }];
  if (nestedInclude) {
    // A nested include's file holds a plain entry list, not patch ops.
    await writeFile(nestedPatch, JSON.stringify([
      { id: 'nested-p0', name: 'local-test-bundle', disabled: true },
    ]));
    fileRows[0].insert.push({
      id: 'nested', name: 'cordis:include',
      config: { path: pathToFileURL(nestedPatch).href },
    });
  }
  const ctx = await bootProfile(t, dir, home, fileRows, [...bundlePatch, ...fileRows]);
  return { ctx, dir, home, root };
}

// Fixture with the bundle NOT installed: a local bundle directory inside
// the profile dir, so installBundle('file:./localbundle') can install it.
async function installFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'ish-host-install-'));
  t.after(async () => { await rm(root, { recursive: true, force: true }); });
  const home = join(root, 'home'), dir = join(home, 'profiles/web');
  await mkdir(dir, { recursive: true });
  await writeLocalBundle(join(dir, 'localbundle'), { platforms: ['linux'] });
  await writeFile(join(dir, 'package.json'), JSON.stringify({
    name: 'fixture-profile', dependencies: {},
    dsh: { profile: { bundles: [] } },
  }));
  const rows = [{ insert: [{ id: 'manager', name: pathToFileURL(manager).href }] }];
  const ctx = await bootProfile(t, dir, home, rows);
  return { ctx, dir, home, root };
}

function withSymbols(t, { ish = false, backend = false } = {}) {
  const prevIsh = globalThis[ISH];
  const prevBackend = globalThis[BACKEND];
  if (ish) globalThis[ISH] = { spawn: () => { throw new Error('no pty in test'); } };
  if (backend) globalThis[BACKEND] = createPluginBackend();
  t.after(() => {
    if (prevIsh === undefined) delete globalThis[ISH];
    else globalThis[ISH] = prevIsh;
    if (prevBackend === undefined) delete globalThis[BACKEND];
    else globalThis[BACKEND] = prevBackend;
  });
}

test('parseInstallSpec resolves file: relative paths against the profile directory', () => {
  assert.deepEqual(parseInstallSpec('file:./dir', '/prof'), { kind: 'path', spec: 'file:./dir', path: '/prof/dir' });
  assert.deepEqual(parseInstallSpec('file:../up', '/prof/sub'), { kind: 'path', spec: 'file:../up', path: '/prof/up' });
  assert.deepEqual(parseInstallSpec('link:./dir', '/prof'), { kind: 'path', spec: 'link:./dir', path: '/prof/dir' });
  assert.deepEqual(parseInstallSpec('file:~/x', '/prof'), { kind: 'path', spec: 'file:~/x', path: join(homedir(), 'x') });
  assert.deepEqual(parseInstallSpec('file:/abs/dir', '/prof'), { kind: 'path', spec: 'file:/abs/dir', path: '/abs/dir' });
  assert.deepEqual(parseInstallSpec('pkg@1.2.3', '/prof'), { kind: 'registry', spec: 'pkg@1.2.3', name: 'pkg', range: '1.2.3' });
  assert.throws(() => parseInstallSpec('file:./dir'), /a local path must be absolute/);
  assert.throws(() => parseInstallSpec('./dir', '/prof'), /a local path must be absolute/);
});

test('localDirectoryPath and backend.accepts resolve relative specs against a base', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'ish-host-paths-'));
  t.after(async () => { await rm(dir, { recursive: true, force: true }); });
  await mkdir(join(dir, 'localbundle'));
  assert.equal(localDirectoryPath('file:./localbundle', dir), join(dir, 'localbundle'));
  assert.equal(localDirectoryPath('/abs/dir'), '/abs/dir');
  assert.equal(localDirectoryPath('file:./localbundle'), null);
  assert.equal(localDirectoryPath('some-pkg'), null);
  const backend = createPluginBackend();
  assert.equal(backend.accepts('file:./localbundle', dir), true);
  assert.equal(backend.accepts('file:./localbundle'), false);
  assert.equal(backend.accepts(join(dir, 'localbundle')), true);
  assert.equal(backend.accepts('some-pkg@1.0.0'), true);
  assert.equal(backend.accepts('file:./missing', dir), false);
});

test('inspect refuses without a backend when the iSH bridge is installed', async (t) => {
  const { ctx } = await installedFixture(t);
  withSymbols(t, { ish: true });
  const refused = await ctx.pluginManager.inspect('file:./localbundle');
  assert.equal(refused.status, 'refused');
  assert.equal(refused.problem, 'unknown');
  assert.match(refused.reason, /本机不支持安装/);
});

test('inspect resolves file:./dir against the profile without the bridge symbol', async (t) => {
  const { ctx } = await installFixture(t);
  assert.equal(globalThis[ISH], undefined);
  const found = await ctx.pluginManager.inspect('file:./localbundle');
  assert.equal(found.status, 'accepted');
  assert.equal(found.kind, 'path');
  assert.equal(found.name, 'local-test-bundle');
  assert.equal(found.bundle, true);
  assert.equal((await ctx.pluginManager.inspect('file:./nope')).status, 'refused');
  assert.equal((await ctx.pluginManager.inspect('file:./nope')).problem, 'not-a-package');
});

test('installBundle installs file:./dir through the backend', async (t) => {
  const { ctx, dir } = await installFixture(t);
  // Same device shape as the worker test, on the main thread: the engine
  // reports openharmony and the bridge is installed, so the probe returns
  // the backend the preload created.
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  t.after(() => Object.defineProperty(process, 'platform', { value: 'linux' }));
  withSymbols(t, { ish: true, backend: true });
  const result = await ctx.pluginManager.installBundle('file:./localbundle');
  assert.equal(result.application === 'failed' ? JSON.stringify(result.error) : '', '');
  assert.equal(result.bundle, 'local-test-bundle');
  assert.equal(result.stage, 'enable');
  const manifest = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
  assert.equal(manifest.dependencies['local-test-bundle'], '1.0.0');
  const bundles = await ctx.pluginManager.listBundles();
  const installed = bundles.find((b) => b.name === 'local-test-bundle');
  assert.ok(installed);
  assert.equal(installed.error, undefined);
  assert.equal(installed.rows.length, 1);
  assert.equal(installed.rows[0].rowId, 'lb-0');
});

test('listPlugins drops the root include row but keeps real plugins', async (t) => {
  const { ctx } = await installedFixture(t);
  const rows = await ctx.pluginManager.listPlugins();
  assert.equal(rows.some((row) => row.moduleName === 'cordis:include'), false);
  assert.equal(rows.some((row) => row.entryId === 'include'), false);
  assert.ok(rows.some((row) => row.patchId === 'good-0'));
  assert.ok(rows.some((row) => row.patchId === 'bad-0'));
  assert.equal(rows.find((row) => row.entryId.endsWith('manager')).readOnlyReason, 'management-required');
  // change() folds a management refusal into a failed result, not a throw.
  const denied = await ctx.pluginManager.setPluginEnabled('include', true);
  assert.equal(denied.application, 'failed');
  assert.equal(denied.error.code, 'unknown-plugin');
});

test('listPlugins drops nested include rows but keeps the plugins under them', async (t) => {
  const { ctx } = await installedFixture(t, { nestedInclude: true });
  const rows = await ctx.pluginManager.listPlugins();
  assert.equal(rows.some((row) => row.moduleName === 'cordis:include'), false);
  assert.ok(rows.some((row) => row.entryId.endsWith('nested-p0')));
  assert.ok(rows.some((row) => row.patchId === 'good-0'));
});

test('declaredRows projects the live fiber phase and the failure diagnostic', async (t) => {
  const { ctx } = await installedFixture(t);
  const bundles = await ctx.pluginManager.listBundles();
  const bundle = bundles.find((b) => b.name === 'local-test-bundle');
  assert.ok(bundle);
  assert.equal(bundle.error, undefined);
  assert.equal(bundle.rows.length, 2);
  const good = bundle.rows.find((row) => row.rowId === 'good-0');
  const bad = bundle.rows.find((row) => row.rowId === 'bad-0');
  assert.equal(good.fiberPhase, 'active');
  assert.equal(good.diagnostic, undefined);
  assert.equal(bad.fiberPhase, 'failed');
  assert.equal(typeof bad.diagnostic, 'string');
  assert.match(bad.diagnostic, /fiber-boom/);
  // The inventory's enabled flag and the declared row's fiber phase agree
  // in the sense P3 fixes: the failing row is enabled but not running.
  const inventory = await ctx.pluginManager.listPlugins();
  const badLive = inventory.find((row) => row.patchId === 'bad-0');
  assert.equal(badLive.enabled, true);
  assert.equal(badLive.fiberPhase, 'failed');
});

test('worker thread: openharmony platform + iSH bridge installs a ["linux"] bundle from file:./dir', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'ish-host-worker-'));
  t.after(async () => { await rm(root, { recursive: true, force: true }); });
  const home = join(root, 'home'), dir = join(home, 'profiles/web');
  await mkdir(dir, { recursive: true });
  await writeLocalBundle(join(dir, 'localbundle'), { platforms: ['linux'] });
  await writeFile(join(dir, 'package.json'), JSON.stringify({
    name: 'fixture-profile', dependencies: {},
    dsh: { profile: { bundles: [] } },
  }));
  const worker = new Worker(
    new URL('./fixtures/plugin-ish-host-worker.mjs', import.meta.url),
    { workerData: { prefix, dir, home } },
  );
  t.after(() => worker.terminate());
  const result = await new Promise((resolvePromise, rejectPromise) => {
    worker.once('message', resolvePromise);
    worker.once('error', rejectPromise);
    worker.once('exit', (code) => {
      if (code !== 0) rejectPromise(new Error(`worker exited with ${code}`));
    });
  });
  assert.equal(result.inspected.status, 'accepted');
  assert.equal(result.inspected.kind, 'path');
  assert.equal(result.inspected.name, 'local-test-bundle');
  assert.equal(result.installed.application === 'failed' ? JSON.stringify(result.installed.error) : '', '');
  assert.equal(result.installed.bundle, 'local-test-bundle');
  assert.equal(result.dependency, '1.0.0');
});
