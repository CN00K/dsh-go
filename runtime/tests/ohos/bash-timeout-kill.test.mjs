import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const require = createRequire(join(resolve(process.env.DSH_PREFIX), 'package.json'));
const load = name => import(pathToFileURL(require.resolve(`@deepseek-ai/${name}`)));
const { NativeToolExecutor } = await load('dsh-tool-executor-native');
const [{ Context }, { SystemPrompt }, { ToolRuntime }, { SessionProjectionRegistry }, { LocalFileSystem }, { WorkingDirectoryService }, { ShellEnvRegistry }, { ApprovalService }, { LocalBashExecutor }, toolBash] = await Promise.all([
  'cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-session-projection', 'dsh-fs-local', 'dsh-working-directory', 'dsh-shell-env', 'dsh-user-approval', 'dsh-bash-local', 'dsh-tool-bash',
].map(load));
let root, work, temp, ctx, id = 0;
before(async () => {
  root = await mkdtemp(join(tmpdir(), 'ohos-bash-timeout-kill-test-'));
  [work, temp] = ['work', 'temp'].map(part => join(root, part));
  await Promise.all([work, temp].map(path => mkdir(path)));
  ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolRuntime, {});
  ctx.tools.setExecutor(new NativeToolExecutor(ctx));
  await ctx.plugin(SessionProjectionRegistry);
  // Jobs first: tool-bash registers its jobs-backed tool once the jobs
  // service is present (cordis inject resolves immediately here).
  await ctx.plugin((await load('dsh-session')).default);
  await ctx.plugin((await load('dsh-agent')).default);
  await ctx.plugin((await load('dsh-jobs-local')).default);
  ctx.jobs.attachController('bash-timeout-kill-fixture');
  await ctx.plugin(LocalFileSystem, { cwd: work });
  await ctx.plugin(WorkingDirectoryService, { defaultDirectory: work });
  await ctx.plugin(ShellEnvRegistry, { dshHome: temp });
  await ctx.plugin(ApprovalService, { policy: 'ask' });
  // Local (unsandboxed) bash executor: the ohos sandbox executor needs
  // the just-bash build product, which is not present on this host.
  // LocalBashExecutor injects the subprocess service, so the host
  // LocalSubprocessRuntime goes first.
  await ctx.plugin((await load('dsh-subprocess-local')).default);
  await ctx.plugin(LocalBashExecutor, { cwd: work, timeoutMs: 4000, maxTimeoutMs: 5000, maxOutputBytes: 65536, maxSpillBytes: 1048576, graceMs: 200 });
  // Default config: promoteOnTimeout true (the shipped behaviour).
  await ctx.plugin(toolBash, { enableRunInBackground: true, promoteOnTimeout: true });
});
after(async () => {
  await ctx?.fiber.dispose();
  await rm(root, { recursive: true, force: true });
});
async function ownerAgent() {
  let ownerCtx;
  const fiber = ctx.plugin({ inject: ['agents'], apply(child) { ownerCtx = child; } });
  await fiber;
  const name = `bash-timeout-kill-${++id}`;
  const session = ctx.sessions.create(name);
  const agent = { id: session.id, session, ctx: ownerCtx, status: 'idle', inject() {} };
  await ownerCtx.agents.register(agent);
  return agent;
}
const execute = async (owner, command, args = {}) => (await ctx.tools.execute({
  calls: [{ id: `call-${++id}`, name: 'bash',
    arguments: JSON.stringify({ description: 'Q1 timeout kill', command, ...args }) }],
  agent: owner, signal: new AbortController().signal,
})).results[0].result;

test('Q1: foreground bash timeout kills the job instead of promoting it', { timeout: 15000 }, async () => {
  const owner = await ownerAgent();
  const result = await execute(owner, 'echo partial; sleep 30', { timeoutMs: 500 });
  assert.equal(result.isError, false, JSON.stringify(result));
  assert.equal(result.value.kind, 'foreground');
  assert.equal(result.value.timedOut, true);
  assert.equal(result.value.exitCode, null);
  assert.equal(result.value.jobId, undefined);
  assert.match(result.value.stdout.text, /partial/);
  assert.equal(ctx.jobs.hasActiveJobs(), false, 'no job may stay alive after the timeout kill');
});

test('Q1: explicit run_in_background still returns a background job', { timeout: 15000 }, async () => {
  const owner = await ownerAgent();
  const result = await execute(owner, 'sleep 30', { run_in_background: true });
  assert.equal(result.isError, false, JSON.stringify(result));
  assert.equal(result.value.kind, 'background');
  assert.equal(typeof result.value.jobId, 'string');
  assert.equal(ctx.jobs.hasActiveJobs(), true);
  ctx.jobs.kill(result.value.jobId, owner.id, 'test cleanup');
  await ctx.jobs.wait(result.value.jobId, 5000, owner.id);
  assert.equal(ctx.jobs.hasActiveJobs(), false);
});
