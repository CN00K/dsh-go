import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(join(resolve(process.env.DSH_PREFIX), 'package.json'));
const hmrUrl = pathToFileURL(require.resolve('@deepseek-ai/dsh-hmr')).href;
const { detectPollingNeeded } = await import(hmrUrl);

let root;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-hmr-polling-probe-test-'));
});
after(async () => {
  await rm(root, { recursive: true, force: true });
});

async function freshDir(name) {
  const dir = join(root, name);
  await mkdir(dir);
  return dir;
}

// Fake fs.watch: only the event the probe listens for is emulated. The
// probe's mkdtemp/writeFile/rm still use the real fs; only the watcher is
// mocked, via the watchImpl parameter (the default is the real fs.watch).
function fakeWatch(mode) {
  return () => {
    const handlers = new Map();
    const watcher = {
      once(event, fn) { handlers.set(event, fn); return watcher; },
      close() {},
    };
    if (mode === 'change' || mode === 'rename' || mode === 'error') {
      setImmediate(() => handlers.get(mode)?.());
    }
    return watcher;
  };
}

test('Q2: mocked fs.watch with no event needs polling', { timeout: 10000 }, async () => {
  const dir = await freshDir('silent');
  assert.equal(await detectPollingNeeded(dir, fakeWatch('silent')), true);
});

test('Q2: mocked fs.watch with a change event needs no polling', async () => {
  const dir = await freshDir('change');
  assert.equal(await detectPollingNeeded(dir, fakeWatch('change')), false);
});

test('Q2: mocked fs.watch with a rename event needs no polling', async () => {
  const dir = await freshDir('rename');
  assert.equal(await detectPollingNeeded(dir, fakeWatch('rename')), false);
});

test('Q2: mocked fs.watch with an error needs no polling', async () => {
  const dir = await freshDir('error');
  assert.equal(await detectPollingNeeded(dir, fakeWatch('error')), false);
});

test('Q2: real fs.watch on this host delivers the event, so no polling', async () => {
  const dir = await freshDir('real');
  assert.equal(await detectPollingNeeded(dir), false);
});

test('Q2: probe failure is treated as no polling', async () => {
  const file = join(root, 'not-a-dir');
  await writeFile(file, 'x');
  assert.equal(await detectPollingNeeded(file, fakeWatch('silent')), false);
});

test('Q2: probe result is cached per directory', { timeout: 10000 }, async () => {
  const dir = await freshDir('cached');
  assert.equal(await detectPollingNeeded(dir, fakeWatch('silent')), true);
  // A later call for the same directory reuses the first probe instead of
  // re-probing: even a watch that would deliver an event still reports
  // polling needed.
  assert.equal(await detectPollingNeeded(dir, fakeWatch('change')), true);
});
