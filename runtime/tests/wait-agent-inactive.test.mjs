// P4 (60z): wait_agent distinguishes "no teammate exists" (no-active-peer)
// from "teammates exist but all are inactive" (all-peers-inactive).
import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const { apply } = await import(pathToFileURL(join(
  prefix, 'node_modules/@deepseek-ai/dsh-experimental-tool-agent-team/lib/index.js')));

const WAITED = { timedOut: false, woke: true };

function setup(members) {
  const definitions = new Map();
  const agent = { id: 'lead', ctx: null };
  const scopedCtx = {
    systemPrompt: {
      getSectionOrder: () => 0,
      getContextOrder: () => 0,
      section: () => () => {},
      context: () => () => {},
    },
    tools: {
      register: (definition) => {
        definitions.set(definition.name, definition);
        return () => definitions.delete(definition.name);
      },
    },
  };
  agent.ctx = scopedCtx;
  let waitCalls = 0;
  const ctx = {
    agents: { list: () => [agent] },
    agentTeams: {
      tryMembership: (a) => (a === agent ? { role: 'lead', name: 'lead' } : undefined),
      membership: () => ({ role: 'lead', name: 'lead' }),
      listMembers: () => members,
      waitForChange: async () => {
        waitCalls++;
        return WAITED;
      },
    },
    on: () => () => {},
    effect: () => () => {},
  };
  apply(ctx, {});
  const waitAgent = definitions.get('wait_agent');
  assert.ok(waitAgent, 'wait_agent registered by apply()');
  const exec = { agent, signal: new AbortController().signal };
  return { waitAgent, exec, waitCalls: () => waitCalls };
}

test('P4: no teammate at all still returns no-active-peer', async () => {
  const { waitAgent, exec, waitCalls } = setup([{ id: 'lead', status: 'inactive' }]);
  const result = await waitAgent.execute({}, exec);
  assert.deepEqual(result, {
    timedOut: false,
    noProgress: {
      reason: 'no-active-peer',
      message: 'No other Team member is running or provisioning. wait_agent cannot make progress or wake inactive teammates. Re-list with list_agents and team_task_list, then use send_message to wake each required inactive teammate before waiting again.',
    },
  });
  assert.equal(waitCalls(), 0, 'shortcut must not enter waitForChange');
});

test('P4: teammates exist but all inactive returns all-peers-inactive, not no-active-peer', async () => {
  const { waitAgent, exec, waitCalls } = setup([
    { id: 'lead', status: 'inactive' },
    { id: 'smoke-teammate', status: 'inactive' },
  ]);
  const result = await waitAgent.execute({}, exec);
  assert.equal(result.timedOut, false);
  assert.equal(result.noProgress.reason, 'all-peers-inactive');
  assert.match(result.noProgress.message, /may just have finished/);
  assert.match(result.noProgress.message, /inbox/);
  assert.equal(waitCalls(), 0, 'shortcut must not enter waitForChange');
});

test('P4: a running teammate still enters the wait', async () => {
  const { waitAgent, exec, waitCalls } = setup([
    { id: 'lead', status: 'inactive' },
    { id: 'smoke-teammate', status: 'running' },
  ]);
  assert.equal(await waitAgent.execute({}, exec), WAITED);
  assert.equal(waitCalls(), 1);
});

test('P4: a provisioning teammate still enters the wait', async () => {
  const { waitAgent, exec, waitCalls } = setup([
    { id: 'lead', status: 'inactive' },
    { id: 'smoke-teammate', status: 'provisioning' },
  ]);
  assert.equal(await waitAgent.execute({}, exec), WAITED);
  assert.equal(waitCalls(), 1);
});

test('P4: an illegal timeout still skips the pre-check, as before', async () => {
  const { waitAgent, exec, waitCalls } = setup([
    { id: 'lead', status: 'inactive' },
    { id: 'smoke-teammate', status: 'inactive' },
  ]);
  assert.equal(await waitAgent.execute({ timeout_ms: 5 }, exec), WAITED);
  assert.equal(waitCalls(), 1);
});

test('P4: the output schema admits both reasons', () => {
  const { waitAgent } = setup([{ id: 'lead', status: 'inactive' }]);
  const reason = waitAgent.output.schema.properties.noProgress.properties.reason;
  assert.deepEqual(reason.enum, ['no-active-peer', 'all-peers-inactive']);
});
