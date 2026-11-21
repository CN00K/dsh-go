/**
 * Tests for the read-only /dsh-profiles alias (#6).
 *
 * Run: node --test runtime/tests/ios-profiles-alias.test.mjs
 *
 * The alias exposes the host $DSH_HOME/profiles tree read-only to the
 * guest worker filesystem and the iOS file tools, so profile/log paths
 * (e.g. plugin-manager logs) are readable without a full guest root
 * mount. Writes stay refused even in danger-full-access.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const PORT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const GUEST_SPECIALIZE_PY = join(PORT_ROOT, 'tooling/ios/guest-specialization.py');

const fakeRoot = mkdtempSync(join(tmpdir(), 'ios-profiles-alias-'));
const fakeHome = join(fakeRoot, 'home');
const profilesRoot = join(fakeHome, '.dsh', 'profiles');
const logFile = join(profilesRoot, 'web', '.plugin-manager', 'logs', 'run1', 'ohos.log');
mkdirSync(dirname(logFile), { recursive: true });
writeFileSync(logFile, 'plugin log line\n');
const work = join(fakeRoot, 'workspace');
mkdirSync(work, { recursive: true });
const tmpRoot = join(fakeRoot, 'tmp');
mkdirSync(tmpRoot, { recursive: true });
process.env.DSH_HOME = join(fakeHome, '.dsh');
test.after(() => rmSync(fakeRoot, { recursive: true, force: true }));

const { createFilesystem, profileReadOnlyAliases } = await import('../ios/guest/virtual-filesystem.mjs');
const { guestFilePath } = await import('../ios/guest/file-paths.mjs');

test('profileReadOnlyAliases derives the root from DSH_HOME, or takes an explicit root', () => {
  assert.deepEqual(profileReadOnlyAliases(), [{ mountPoint: '/dsh-profiles', root: profilesRoot, readOnly: true }]);
  assert.deepEqual(profileReadOnlyAliases('/elsewhere/profiles'),
    [{ mountPoint: '/dsh-profiles', root: '/elsewhere/profiles', readOnly: true }]);
  const saved = process.env.DSH_HOME;
  delete process.env.DSH_HOME;
  try {
    assert.deepEqual(profileReadOnlyAliases(), []);
  } finally {
    process.env.DSH_HOME = saved;
  }
});

test('profile/log paths read through the alias; writes are refused even in danger-full-access', async () => {
  const { fs, seal } = createFilesystem([work], { mode: 'danger-full-access' }, profileReadOnlyAliases());
  seal();
  assert.equal(await fs.readFile('/dsh-profiles/web/.plugin-manager/logs/run1/ohos.log', 'utf8'), 'plugin log line\n');
  assert.equal(await fs.exists('/dsh-profiles/web/.plugin-manager/logs/run1/ohos.log'), true);
  for (const attempt of [
    async () => fs.writeFile('/dsh-profiles/web/new.txt', 'x'),
    async () => fs.appendFile('/dsh-profiles/web/.plugin-manager/logs/run1/ohos.log', 'x'),
    async () => fs.mkdir('/dsh-profiles/web/newdir'),
    async () => fs.rm('/dsh-profiles/web/.plugin-manager/logs/run1/ohos.log'),
    async () => fs.symlink('/dsh-profiles/web/new.txt', '/dsh-profiles/web/link.txt'),
  ]) {
    await assert.rejects(attempt, error => {
      assert.equal(error.code, 'EACCES');
      assert.match(error.message, /只读别名/);
      return true;
    });
  }
  // Paths outside the alias are unaffected: workspace writes still work.
  await fs.writeFile(join(work, 'hello.txt'), 'hi');
  assert.equal(await fs.readFile(join(work, 'hello.txt'), 'utf8'), 'hi');
  assert.equal(await fs.exists('/etc/passwd'), false);
});

test('guestFilePath maps /dsh-profiles to the host profiles tree and refuses parent traversal', () => {
  const options = { iosGuestWorkspaceRoot: work };
  assert.equal(guestFilePath('/dsh-profiles/web/.plugin-manager/logs/run1/ohos.log', options, undefined, {}, tmpRoot), logFile);
  assert.equal(guestFilePath('/dsh-profiles', options, undefined, {}, tmpRoot), profilesRoot);
  assert.throws(() => guestFilePath('/dsh-profiles/../etc/passwd', options, undefined, {}, tmpRoot),
    error => error.code === 'FS_SANDBOX_DENIED');
  // Without an iOS guest session root the alias does not apply.
  assert.equal(guestFilePath('/dsh-profiles/web/x.log', {}, undefined, {}, tmpRoot), '/dsh-profiles/web/x.log');
  // The existing workspace alias is unaffected.
  assert.equal(guestFilePath('/workspace/hello.txt', options, undefined, {}, tmpRoot), join(work, 'hello.txt'));
});

/**
 * Run the real guest-specialization specialize() on one repo file and
 * return the specialized text. The script itself enforces every
 * anchor's count == 1, so a drifted input fails here instead of
 * silently shipping without the alias.
 */
function specializeFile(relPath) {
  const script = [
    'import importlib.util, sys',
    "spec = importlib.util.spec_from_file_location('guest_specialization', sys.argv[1])",
    'mod = importlib.util.module_from_spec(spec)',
    'spec.loader.exec_module(mod)',
    "data = open(sys.argv[2], 'rb').read()",
    'out = mod.specialize(sys.argv[4], data)',
    "open(sys.argv[3], 'wb').write(out)",
  ].join('\n');
  const tmp = mkdtempSync(join(tmpdir(), 'ios-profiles-alias-spec-'));
  const outPath = join(tmp, 'out.js');
  try {
    execFileSync('python3', ['-c', script, GUEST_SPECIALIZE_PY, join(PORT_ROOT, relPath), outPath, relPath], { stdio: 'pipe' });
    return readFileSync(outPath, 'utf8');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

test('guest-specialization mounts the profile alias in the worker and passes its root via workerData', () => {
  const worker = specializeFile('runtime/ohos/process/worker.mjs');
  assert.ok(worker.includes('...profileReadOnlyAliases(workerData.iosGuestProfilesRoot)'),
    'the worker filesystem must mount the profile alias rows');
  const runtime = specializeFile('runtime/ohos/process/runtime.mjs');
  assert.ok(runtime.includes("iosGuestProfilesRoot: process.env.DSH_HOME ? join(process.env.DSH_HOME, 'profiles') : undefined"),
    'the runtime must pass the profiles root via workerData (the worker env scrubs DSH_*)');
});
