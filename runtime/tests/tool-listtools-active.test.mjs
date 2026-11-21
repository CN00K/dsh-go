// P3 (59z): Tool.listTools annotates each schema with its owner fiber's
// activation state (active/phase/missing). The model-facing schemas()
// projection itself gains no new field.
//
// Reachability, verified against Cordis (not assumed): a fiber that fails
// unloads its effects, so its tools vanish from the registry entirely —
// listTools never shows a failed owner's tool. And a pending fiber's
// context cannot resolve `tools` at all (Cordis refuses required-service
// access in an inactive context), so no real register() call can ever carry
// a pending fiber. The annotation therefore reports the truth for every
// live registration (active), and the pending/missing computation below is
// exercised by inserting the exact record register() would have stored,
// against a genuine pending fiber.
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';

const prefix = resolve(process.env.DSH_PREFIX);
const require = createRequire(join(prefix, 'package.json'));
const load = (name) => import(require.resolve('@deepseek-ai/' + name));
const [{ Context }, { SystemPrompt }, { ToolsService, defineTool }, { CordisInspectRegistryService }] = await Promise.all([
  load('cordis'), load('dsh-system-prompt'), load('dsh-tools'), load('dsh-cordis-host-runner'),
]);
const ctx = new Context();
await ctx.plugin(SystemPrompt, {});
await ctx.plugin(ToolsService);
new CordisInspectRegistryService(ctx, 1000);
await ctx.plugin(await load('dsh-tool-cordis/host'));
await ctx.plugin(await load('dsh-tool-cordis'));
const signal = new AbortController().signal;
const query = (provider, method, input) =>
  ctx.cordisInspect.query('host', provider, method, input, undefined, signal);

const tool = (name) => defineTool({
  name,
  description: name,
  parameters: {},
  output: {
    schema: { type: 'object', additionalProperties: false, properties: { ok: { type: 'boolean' } } },
    render: () => [{ type: 'text', text: 'ok' }],
  },
  execute: async () => ({ ok: true }),
});

// A normal plugin: fiber active, tool registered from its own context. This
// locks the key assumption: register() captures the registering plugin's
// fiber via the traceable use-site `this.ctx` — had it captured the root or
// service fiber, the annotation could not distinguish owners at all.
await ctx.plugin({
  name: 'fake-active',
  inject: ['tools'],
  apply(pluginCtx) {
    pluginCtx.tools.register(tool('fake_active_tool'));
  },
});

// A plugin whose inject can never be satisfied: fiber stays pending and its
// apply never runs.
const pending = ctx.plugin({
  name: 'fake-pending',
  inject: ['missing-service-xyz'],
  apply() {
    throw new Error('fake-pending apply must never run');
  },
});
assert.equal(pending.state, 0, 'fake-pending fiber must be pending');
const toolsService = ctx.tools[Symbol.for('cordis.original')];
const undoPendingInsert = toolsService.layers.global.tools.insert('fake_pending_tool', {
  definition: tool('fake_pending_tool'),
  when: undefined,
  fiber: pending.ctx.fiber,
});
after(async () => {
  undoPendingInsert();
  await ctx.fiber.dispose();
});

const byName = (tools) => new Map(tools.map((schema) => [schema.name, schema]));

test('P3: listTools marks the active plugin tool active', async () => {
  const { tools } = await query('Tool', 'listTools');
  const active = byName(tools).get('fake_active_tool');
  assert.ok(active, 'fake_active_tool listed');
  assert.equal(active.active, true);
  assert.equal(active.phase, 'active');
  assert.equal('missing' in active, false);
  // The built-in inspect tools come from an active fiber too.
  const map = byName(tools);
  for (const name of ['cordis_inspect_list', 'cordis_inspect_query']) {
    assert.equal(map.get(name).active, true, `${name} active`);
    assert.equal(map.get(name).phase, 'active', `${name} phase`);
  }
});

test('P3: listTools marks the pending-fiber tool inactive with its missing service', async () => {
  const { tools } = await query('Tool', 'listTools');
  const pendingTool = byName(tools).get('fake_pending_tool');
  assert.ok(pendingTool, 'fake_pending_tool listed');
  assert.equal(pendingTool.active, false);
  assert.equal(pendingTool.phase, 'pending');
  assert.deepEqual(pendingTool.missing, ['missing-service-xyz']);
});

test('P3: schemas() itself gains no activation field', () => {
  for (const schema of ctx.tools.schemas()) {
    assert.equal('active' in schema, false, `${schema.name} leaked active into schemas()`);
    assert.equal('phase' in schema, false, `${schema.name} leaked phase into schemas()`);
    assert.equal('missing' in schema, false, `${schema.name} leaked missing into schemas()`);
  }
});
