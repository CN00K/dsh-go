// Worker-thread probe for the wave-3 plugin fixes: this worker IS the
// engine thread shape (a worker_threads Worker, as on device), with the
// platform faked to openharmony and the iSH bridge symbol installed before
// the engine boots. It inspects and installs a ["linux"] bundle from a
// relative file: spec, then reports the outcomes to the parent test.
import { parentPort, workerData } from 'node:worker_threads';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile, writeFile } from 'node:fs/promises';

Object.defineProperty(process, 'platform', { value: 'openharmony' });
globalThis[Symbol.for('dsh.ish.pty')] = { spawn: () => { throw new Error('no pty in test'); } };

const { createPluginBackend } = await import(pathToFileURL(join(workerData.prefix, 'runtime/ohos/plugins/backend.mjs')));
globalThis[Symbol.for('dsh.go.ohos.plugins')] = createPluginBackend();

const { boot, PluginPackages } = await import(pathToFileURL(join(workerData.prefix, 'node_modules/@deepseek-ai/dsh-app-boot/lib/index.js')));
const { dir, home, prefix } = workerData;
const main = join(dir, 'cordis.yml');
const rows = [{ insert: [{ id: 'manager', name: pathToFileURL(join(prefix, 'node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js')).href }] }];
await writeFile(join(dir, 'cordis.yml'), '[]\n');
await writeFile(join(dir, 'cordis.patch.yml'), JSON.stringify(rows));

const ctx = await boot('dsh', main, rows, async (c) => {
  await c.plugin(PluginPackages);
  c.provide('profileContext', {
    dir, home, installAnchor: join(prefix, 'node_modules/@deepseek-ai/dsh/package.json'),
    patchPath: join(dir, 'cordis.patch.yml'),
    overlays: [], startedBundles: [], telemetryDisabledEnv: '1',
  });
});
try {
  const inspected = await ctx.pluginManager.inspect('file:./localbundle');
  const installed = await ctx.pluginManager.installBundle('file:./localbundle');
  const manifest = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
  parentPort.postMessage({
    inspected,
    installed: {
      application: installed.application, bundle: installed.bundle,
      stage: installed.stage, error: installed.error ?? null,
    },
    dependency: manifest.dependencies?.['local-test-bundle'] ?? null,
  });
} finally {
  await ctx.fiber.dispose();
}
