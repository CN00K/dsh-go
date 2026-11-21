/**
 * Unit test for ish-adapter.mjs T-2: a throwing installIshBridge() must
 * not escape ishSpawnFor / ishSpawnTerminalFor.
 *
 * Run: node --test runtime/ios/process/ish-adapter-install-failure.test.mjs
 *
 * This file is separate from ish-adapter.test.mjs on purpose: the
 * module.register() hooks below redirect the adapter's ish-bridge
 * import to a throwing stub for the whole test process, so no test in
 * this file may use the real bridge.
 */
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { register } from 'node:module';

register('./ish-adapter-install-failure-hooks.mjs', import.meta.url);

const fakeRoot = mkdtempSync(join(tmpdir(), 'ish-adapter-install-failure-'));

function spec() {
  return {
    cwd: join(fakeRoot, 'workspace'),
    stdio: { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' },
    env: {},
  };
}

test('T-2: a throwing bridge install falls back to the virtual shell (once logged)', async () => {
  const { ishSpawnFor, ishSpawnTerminalFor } = await import('./ish-adapter.mjs');
  const errors = [];
  const originalError = console.error;
  console.error = (...args) => { errors.push(args.join(' ')); };
  try {
    const options = { temporaryRoot: fakeRoot, onSpillFailure: () => {}, policy: undefined };
    assert.equal(ishSpawnFor(['bash', '-c', 'echo hi'], spec(), options), undefined);
    // A second call retries the install (partial state is not kept) and
    // still falls back instead of throwing.
    assert.equal(ishSpawnFor(['bash', '-c', 'echo hi'], spec(), options), undefined);
    // The terminal entry no longer returns a silent undefined: the
    // bridge failure is a visible declined result carrying the cause.
    assert.deepEqual(ishSpawnTerminalFor({ argv: ['bash'], cols: 80, rows: 24 }),
      { declined: 'bridge', detail: 'injected ish-bridge install failure' });
  } finally {
    console.error = originalError;
  }
  assert.equal(errors.length, 1, `expected one install-failure line, got ${errors.length}`);
  assert.match(errors[0], /installIshBridge failed/);
});
