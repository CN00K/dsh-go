// ENV-07 / ENV-10 regression tests (dsh-go): the time-context fallback zone
// is pinned to the user's zone, the device clientTimeZone wins over it, and
// the bash tool description names the iSH guest boundary only on iOS.
//
// Run from the repo root against an installed, patched DSH prefix:
//   DSH_PREFIX=<prefix> node --test runtime/tests/time-zone-fallback.test.mjs
// (same harness as time-zone-dedup.test.mjs; the prefix must have the
// zzzzzzzz-time-zone-fallback and zzzzzzzz-sandbox-source-boundary patches
// applied, plus zzzzzzz-time-zone-dedup for the shared fixture behaviour.)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const base = join(resolve(process.env.DSH_PREFIX), 'node_modules/@deepseek-ai');
const load = name => import(pathToFileURL(join(base, name, 'lib/index.js')));
const { Context } = await load('cordis');
const { createUserMessage } = await load('dsh-llm');
const { agentEvents } = await load('dsh-agent');
let serial = 0;
function message(zone, source = {}) {
  return createUserMessage({ content: [{ type: 'text', text: 'fixture' }], source: { kind: 'user', rpcId: `fixture-${++serial}`, ...(zone === undefined ? {} : { clientTimeZone: zone }), ...source } });
}
async function fixture(t, timeZone) {
  const ctx = new Context();
  t.after(() => ctx.fiber.dispose());
  for (const name of ['dsh-session', 'dsh-session-projection', 'dsh-agent', 'dsh-llm', 'dsh-tools', 'dsh-system-prompt']) {
    await ctx.plugin((await load(name)).default);
  }
  await ctx.plugin((await load('dsh-agent-loop')).AgentLoop, { agents: [] });
  await ctx.plugin(await load('dsh-time-context'), { timeZone, refreshIntervalMs: 0 });
  const { agent } = await ctx.agents.create({ sessionId: `fixture-${++serial}` });
  return { agent, async run(messages, turn = 1) {
    return agentEvents(ctx, agent).waterfall('agent/pre-step', { messages, turn, step: 1, signal: new AbortController().signal }, () => Promise.resolve({ kind: 'enter', messages }));
  } };
}
const header = result => result.messages.at(-1).content[0].text.split('\n')[0];
const policy = result => result.messages.at(-1).content[0].text.split('\n')[1];
// `...T00:16:50+08:00[Asia/Shanghai]` -> offset + label; the ENV-10 failure
// was an offset that did not belong to the label zone.
function parseTimestamp(line) {
  const match = /T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2})\[(.+)\]$/.exec(line);
  assert.ok(match, `unexpected timestamp header: ${line}`);
  return { offset: match[1], zone: match[2] };
}
test('pinned Asia/Shanghai fallback renders a self-consistent +08:00 header with no client zone', async t => {
  const f = await fixture(t, 'Asia/Shanghai');
  const observed = await f.run([message(undefined)]);
  assert.deepEqual(parseTimestamp(header(observed)), { offset: '+08:00', zone: 'Asia/Shanghai' });
  assert.equal(policy(observed), 'Browser time zone for this request: unavailable. Ask the user to clarify otherwise-unqualified dates and times.');
});
test('device clientTimeZone wins over the fallback', async t => {
  const f = await fixture(t, 'UTC');
  const observed = await f.run([message('Asia/Shanghai')]);
  assert.deepEqual(parseTimestamp(header(observed)), { offset: '+08:00', zone: 'Asia/Shanghai' });
  assert.equal(policy(observed), 'Browser time zone for this request: Asia/Shanghai. Interpret otherwise-unqualified dates and times in this zone.');
});
test('installed standard preset pins the Asia/Shanghai fallback', () => {
  const preset = readFileSync(join(base, 'dsh-web-app/presets/standard.patch.yml'), 'utf-8');
  const row = preset.indexOf("- id: time-context");
  assert.ok(row >= 0, 'standard preset has no time-context row');
  const block = preset.slice(row, preset.indexOf('- id: tool-bash', row));
  assert.match(block, /timeZone: 'Asia\/Shanghai'/);
});
test('bash description names the guest boundary only on the iOS guest backend', async () => {
  const mod = await load('dsh-tool-bash');
  const describe = async () => {
    const seen = [];
    const ctx = { shell: {}, systemPrompt: { section: () => {}, getSectionOrder: () => 0 }, tools: { register: (def) => { seen.push(def); return () => {}; } }, get: () => undefined };
    await mod.apply(ctx, { enableRunInBackground: false });
    assert.equal(seen.length, 1);
    return seen[0].description;
  };
  const plain = await describe();
  assert.ok(plain.startsWith('Execute a bash command'));
  assert.ok(!plain.includes('iSH Linux guest'), 'non-guest hosts must not see the iOS boundary note');
  globalThis[Symbol.for('dsh.ish.pty')] = { spawn: () => {} };
  try {
    const guest = await describe();
    assert.ok(guest.includes('iSH Linux guest'));
    assert.ok(guest.includes('Runner.app/NativeNode'));
    assert.ok(guest.includes('outside the guest'));
  } finally {
    delete globalThis[Symbol.for('dsh.ish.pty')];
  }
});
