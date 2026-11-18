import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundaryCoordinator } from '../../ohos/lifecycle/coordinator.mjs';

// M-1: a transient checkpoint, session-read or journal-append failure must
// fail only this call so the scheduler can retry it. Only a failed durable
// identity check (ERR_OHOS_LIFECYCLE_IDENTITY / SEQUENCE) or confirmed
// journal damage (CORRUPT / POISONED) may poison the shared boundary.
const transientIo = () => Object.assign(new Error('transient journal EIO'), { code: 'EIO' });
const corruptErr = () => Object.assign(new Error('journal corrupt'), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
const foreground = { version: 1, engineGeneration: 1, ownerGeneration: 1, revision: 1, grantGeneration: 0,
  nowMs: 100, deadlineMs: 0, drainAtMs: 0, phase: 0, available: 1, foreground: 1, clockFailed: 0 };

function setup(t, { flushSession, readEvents } = {}) {
  const records = [];
  let appendFailures = 0;
  let fatalFailures = 0;
  let flushFailures = 0;
  let appendCalls = 0;
  const journal = {
    records,
    get appendCalls() { return appendCalls; },
    failAppend(times) { appendFailures = times; },
    failAppendFatal(times) { fatalFailures = times; },
    failFlush(times) { flushFailures = times; },
    async append(body) {
      appendCalls++;
      if (appendFailures > 0) { appendFailures--; throw transientIo(); }
      if (fatalFailures > 0) { fatalFailures--; throw corruptErr(); }
      const row = { body }; records.push(row); return row;
    },
    async flush() { if (flushFailures > 0) { flushFailures--; throw transientIo(); } },
    async close() {},
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

// R3-1: a failed #pause() leaves the boundary paused but the pause record
// unpersisted. The next native refresh (desired stays false, target already
// false, so no transition fires) retries #pause() once; the record lands and
// the marker clears, so a later refresh does not re-record.
test('transient journal append failure during pause is retried by the next native refresh; the pause record lands', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  assert.equal(f.c.status().paused, true);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), []);
  await f.c.observeHost({});
  assert.equal(f.c.status().paused, true);
  assert.equal(f.c.status().confirmedPause, true);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
  await f.c.observeHost({});
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
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

// R4-N-1: a fatal #pause() failure poisons the boundary, so the retry
// marker must not be set — otherwise the 250ms poller retries a poisoned
// journal forever. A gate waiter keeps the timer alive (observeHost is not
// the driver: it #check()s first and throws BLOCKED once #fault is set).
test('a fatal journal failure during pause does not arm the retry marker; the poller stops retrying', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  f.journal.failAppendFatal(10);
  // Park a gate waiter before the fatal retry: gate() re-checks #check only
  // when its race resolves, so the waiter stays and the timer keeps firing.
  const waiter = f.c.gate('session-A', undefined);
  waiter.catch(() => {});
  await new Promise(r => setTimeout(r, 700));
  assert.equal(f.c.status().blocked, true);
  // Exactly 2 appends: the transient failure plus the one fatal retry.
  // Pre-fix the marker was re-set on the fatal failure and each 250ms
  // refresh retried, growing the count (1 -> 4 in the audit probe).
  assert.equal(f.journal.appendCalls, 2);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), []);
});

// R4-N-2: the pause record lands before flush(), so a flush failure must
// not arm the retry marker — the retry would append a duplicate pause
// record. The record is already on disk without the fsync.
test('a flush failure after the pause record landed does not retry or duplicate the pause record', async t => {
  const f = setup(t);
  f.journal.failFlush(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.equal(f.c.status().blocked, false);
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
  await f.c.observeHost({});
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
  await f.c.observeHost({});
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
});

// R4-N-2 (stale marker): the marker was set by an earlier record failure,
// then the retry's record lands but its flush() fails. The marker must be
// cleared when the record lands, or the next refresh would retry and
// duplicate the record. This is the case (b)-alone would miss: its catch
// guard never clears a marker set by the earlier failure.
test('a stale retry marker is cleared when the retry record lands even if its flush fails', async t => {
  const f = setup(t);
  f.journal.failAppend(1);
  await assert.rejects(f.c.pause(), { code: 'EIO' });
  assert.deepEqual(f.journal.records.map(row => row.body.kind), []);
  f.journal.failFlush(1);
  await assert.rejects(f.c.observeHost({}), { code: 'EIO' });
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
  await f.c.observeHost({});
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['pause']);
});
