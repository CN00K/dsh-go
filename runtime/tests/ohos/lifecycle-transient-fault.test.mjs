import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';

// M-1: a transient checkpoint, session-read or journal-append failure must
// fail only this call so the scheduler can retry it. Only a failed durable
// identity check (ERR_OHOS_LIFECYCLE_IDENTITY / SEQUENCE) or confirmed
// journal damage (CORRUPT / POISONED) may poison the shared boundary.
const transientIo = () => Object.assign(new Error('transient journal EIO'), { code: 'EIO' });
const foreground = { version: 1, engineGeneration: 1, ownerGeneration: 1, revision: 1, grantGeneration: 0,
  nowMs: 100, deadlineMs: 0, drainAtMs: 0, phase: 0, available: 1, foreground: 1, clockFailed: 0 };

function setup(t, { flushSession, readEvents } = {}) {
  const records = [];
  let appendFailures = 0;
  const journal = {
    records,
    failAppend(times) { appendFailures = times; },
    async append(body) {
      if (appendFailures > 0) { appendFailures--; throw transientIo(); }
      const row = { body }; records.push(row); return row;
    },
    async flush() {}, async close() {},
  };
  const c = new BoundaryCoordinator({ journal, bootId: 'transient-fault',
    flushSession: flushSession ?? (async () => true),
    readEvents: readEvents ?? (async (id, offset = 0) => [{ type: 'tool/call', seq: offset,
      data: { callId: `call-${offset}`, name: 'effect', turn: 1, step: 1 } }]),
    readHost: () => ({ ...foreground }), revalidateTransport: async () => {} });
  t.after(async () => {
    // A prepared call leaves a pending entry until its outcome is committed;
    // settle it first or close() waits on it forever.
    c.failedGroup('session-A', [0, 1]);
    await c.close();
  });
  const meta = { session: { id: 'session-A' }, block: { id: 'call-0', name: 'effect' },
    turn: 1, step: 1, callSeq: 0, signal: undefined };
  return { c, journal, meta };
}

test('transient flushSession failure in prepared does not poison the boundary; retry succeeds', async t => {
  let flushFailures = 1;
  const f = setup(t, { flushSession: async () => {
    if (flushFailures-- > 0) throw new Error('transient session io');
    return true;
  } });
  await assert.rejects(f.c.prepared(f.meta), /transient session io/);
  assert.equal(f.c.status().blocked, false);
  await f.c.prepared(f.meta);
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().calls.length, 1);
  assert.equal(f.c.status().calls[0].phase, 'prepared');
});

test('transient journal append failure in prepared does not poison the boundary; retry succeeds', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.prepared(f.meta), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  await f.c.prepared(f.meta);
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().calls.length, 1);
});

test('an identity mismatch in prepared still poisons the boundary', async t => {
  const f = setup(t, { readEvents: async () => [{ type: 'tool/call', seq: 0,
    data: { callId: 'someone-else', name: 'effect', turn: 1, step: 1 } }] });
  await assert.rejects(f.c.prepared(f.meta), { code: 'ERR_OHOS_LIFECYCLE_IDENTITY' });
  assert.equal(f.c.status().blocked, true);
  await assert.rejects(f.c.prepared(f.meta), { code: 'ERR_OHOS_LIFECYCLE_BLOCKED' });
});

test('transient flushSession failure in committed does not poison the boundary', async t => {
  let flushFailures = 0;
  const f = setup(t, { flushSession: async () => {
    if (flushFailures-- > 0) throw new Error('transient commit io');
    return true;
  } });
  await f.c.prepared(f.meta);
  flushFailures = 1;
  await assert.rejects(f.c.committed(f.meta), /transient commit io/);
  assert.equal(f.c.status().blocked, false);
  // A fresh call still dispatches: the boundary is not poisoned.
  const next = { ...f.meta, callSeq: 1, block: { id: 'call-1', name: 'effect' } };
  await f.c.prepared(next);
  assert.equal(f.c.status().calls.length, 2);
});

test('transient journal append failure during pause does not poison the boundary; retry pauses', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  await f.c.pause();
  assert.equal(f.c.status().paused, true);
  assert.equal(f.c.status().blocked, false);
});

test('transient journal append failure during resume does not poison the boundary; retry resumes', async t => {
  const f = setup(t);
  await f.c.pause();
  f.journal.failAppend(1);
  await assert.rejects(f.c.resume(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().paused, true);
  await f.c.resume();
  assert.equal(f.c.status().paused, false);
  assert.equal(f.c.status().blocked, false);
});

// N-2: the H-2 reset only covered the transport branch. A transient #record
// failure inside #resume() must reset the admission target the same way, or
// the next native refresh would skip the retry (desired === target) and the
// gate would stay closed until an explicit resume(). observeHost must also
// not keep rethrowing the stale failed control.
test('transient journal append failure during resume is retried by the next native refresh; observeHost does not rethrow the stale error', async t => {
  const f = setup(t);
  await f.c.pause();
  f.journal.failAppend(1);
  await assert.rejects(f.c.resume(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().paused, true);
  await f.c.observeHost({});
  assert.equal(f.c.status().paused, false);
  assert.equal(f.c.admit('session-A'), true);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause', 'resume']);
});

// N-3: the gate is built before the pause record is attempted, so a failed
// #record still leaves the boundary paused — the budget clock must stop too,
// or tool budgets would keep charging while the interface reports paused.
test('transient journal append failure during pause still stops the budget clock', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().paused, true);
  assert.equal(f.c.status().confirmedPause, true);
  await f.c.pause();
  assert.equal(f.c.status().paused, true);
  assert.equal(f.c.status().confirmedPause, true);
});

// N-6: a flushSession that throws is transient (covered above); one that
// returns non-true means no durable flush listener is registered at all —
// a persistent configuration failure no retry can fix — so it poisons.
test('a missing durable flush listener in prepared poisons the boundary', async t => {
  const f = setup(t, { flushSession: async () => false });
  await assert.rejects(f.c.prepared(f.meta), { code: 'ERR_OHOS_LIFECYCLE_NO_CHECKPOINT' });
  assert.equal(f.c.status().blocked, true);
  await assert.rejects(f.c.prepared(f.meta), { code: 'ERR_OHOS_LIFECYCLE_BLOCKED' });
});

test('a missing durable flush listener in committed poisons the boundary', async t => {
  let flushes = 0;
  const f = setup(t, { flushSession: async () => ++flushes === 1 });
  await f.c.prepared(f.meta);
  await assert.rejects(f.c.committed(f.meta), { code: 'ERR_OHOS_LIFECYCLE_NO_CHECKPOINT' });
  assert.equal(f.c.status().blocked, true);
  const next = { ...f.meta, callSeq: 1, block: { id: 'call-1', name: 'effect' } };
  await assert.rejects(f.c.prepared(next), { code: 'ERR_OHOS_LIFECYCLE_BLOCKED' });
});
