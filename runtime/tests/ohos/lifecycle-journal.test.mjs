import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { openBoundaryJournal, snapshot } from '../../ohos/lifecycle/journal.mjs';

const binding = process._linkedBinding('dsh_ohos_publication');
const body = (kind, extra = {}) => ({ kind, bootId: 'boot-A', sessionId: 'session-A', callSeq: 3, callId: 'same', turn: 1, step: 1, ...extra });
async function fixture(t, options = {}) {
  const root = await fs.mkdtemp(join(tmpdir(), 'dsh-lifecycle-log-'));
  const directory = join(root, 'private');
  const journals = [];
  t.after(async () => {
    for (const journal of journals) await journal.close();
    await fs.rm(root, { recursive: true, force: true });
  });
  const open = async overrides => {
    const journal = await openBoundaryJournal({ directory, lockExclusive: binding.lockExclusive, ...options, ...overrides });
    journals.push(journal); return journal;
  };
  return { root, directory, open, journal: await open() };
}

test('real file sync precedes resolved records; one native flock rejects another writer', async t => {
  const observed = [];
  const f = await fixture(t, { onStage(stage, row) { observed.push([stage, row.body?.kind]); } });
  await f.journal.append(body('prepared'));
  await f.journal.append(body('dispatch'));
  assert.deepEqual(observed.filter(row => row[0] === 'record-durable').map(row => row[1]), ['prepared', 'dispatch']);
  assert.deepEqual(f.journal.records.map(row => row.seq), [0, 1, 2]);
  assert.equal((await fs.stat(join(f.directory, 'boundary.jsonl'))).mode & 0o777, 0o600);
  await assert.rejects(f.open(), error => ['EAGAIN', 'EWOULDBLOCK'].includes(error.code));
  await f.journal.close();
  const again = await f.open();
  assert.equal(again.corruption, null);
  assert.equal(again.records.at(-1).body.kind, 'dispatch');
});

test('outcomes reference synced exact JSON bytes; identical concurrent results share verified content', async t => {
  const f = await fixture(t);
  const result = { content: [{ type: 'text', text: '中文\u0000完整结果' }], isError: false };
  const [a, b] = await Promise.all([
    f.journal.appendResult(body('returned'), result),
    f.journal.appendResult(body('outcome'), result),
  ]);
  assert.deepEqual(a.body.result, b.body.result);
  assert.deepEqual(await f.journal.readResult(b.body.result), result);
  assert.deepEqual(await fs.readdir(join(f.directory, 'results')), [b.body.result.sha256 + '.json']);
  assert.equal((await fs.stat(join(f.directory, b.body.result.path))).mode & 0o777, 0o600);
});

for (const damage of ['tail', 'checksum', 'sequence', 'empty']) test(`real ${damage} corruption preserves prefix and refuses new dispatch`, async t => {
  const f = await fixture(t);
  await f.journal.append(body('prepared')); await f.journal.append(body('dispatch'));
  await f.journal.close();
  const path = join(f.directory, 'boundary.jsonl');
  const bytes = await fs.readFile(path);
  if (damage === 'tail') await fs.writeFile(path, bytes.subarray(0, -7));
  if (damage === 'empty') await fs.writeFile(path, '');
  if (damage === 'checksum') await fs.writeFile(path, bytes.toString().replace('session-A', 'session-X'));
  if (damage === 'sequence') {
    const rows = bytes.toString().trimEnd().split('\n'); rows.splice(1, 1); await fs.writeFile(path, rows.join('\n') + '\n');
  }
  const damaged = await fs.readFile(path);
  const again = await f.open();
  assert(again.corruption);
  await assert.rejects(again.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
  assert.deepEqual(await fs.readFile(path), damaged, 'no truncation or silent repair');
});

test('missing or changed result is explicit unknown evidence, never an empty success', async t => {
  const f = await fixture(t);
  const row = await f.journal.appendResult(body('outcome'), { content: [{ type: 'text', text: 'saved' }] });
  const path = join(f.directory, row.body.result.path);
  await fs.writeFile(path, 'changed');
  await assert.rejects(f.journal.readResult(row.body.result), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
  await fs.unlink(path);
  await assert.rejects(f.journal.readResult(row.body.result), { code: 'ERR_OHOS_LIFECYCLE_CORRUPT' });
});

test('a real partial append failure poisons later requests and leaves a nonempty corrupt tail', async t => {
  let armed = false;
  const f = await fixture(t, { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).endsWith('boundary.jsonl')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'write') return async (bytes, offset, length, position) => {
        if (!armed) return target.write(bytes, offset, length, position);
        await target.write(bytes, offset, Math.min(9, length), position);
        throw Object.assign(new Error('real short append then EIO'), { code: 'EIO' });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } });
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'EIO' });
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_POISONED' });
  await f.journal.close();
  const again = await f.open({ fs });
  assert.equal(again.corruption.reason, 'incomplete-tail');
  assert.equal(again.records.at(-1).body.kind, 'prepared');
});

// M-1: failures proven to have written nothing to the log must not poison
// it. Only a failure at or after the write phase (a partial write, a failed
// sync) or confirmed corruption may poison; the next append must still work.
test('a rejected before-record observer leaves the log intact and does not poison later appends', async t => {
  let armed = false;
  const f = await fixture(t, { onStage(stage) {
    if (armed && stage === 'before-record') { armed = false; throw new Error('transient observer'); }
  } });
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.append(body('dispatch')), /transient observer/);
  assert.equal(f.journal.failed, false);
  await f.journal.append(body('dispatch'));
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'prepared', 'dispatch']);
});

test('an oversized record is rejected without poisoning later appends', async t => {
  const f = await fixture(t);
  await f.journal.append(body('prepared'));
  await assert.rejects(f.journal.append({ ...body('dispatch'), note: 'x'.repeat(2 * 1024 * 1024) }), /exceeds 1 MiB/);
  assert.equal(f.journal.failed, false);
  await f.journal.append(body('dispatch'));
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'prepared', 'dispatch']);
});

test('a transient result-file failure does not poison later appends', async t => {
  let armed = false;
  const f = await fixture(t, { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).includes('/results/')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'write') return async (bytes, offset, length, position) => {
        if (!armed) return target.write(bytes, offset, length, position);
        armed = false;
        throw Object.assign(new Error('transient result EIO'), { code: 'EIO' });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } });
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.appendResult(body('returned'), { content: 'first' }), { code: 'EIO' });
  assert.equal(f.journal.failed, false);
  await f.journal.appendResult(body('outcome'), { content: 'second' });
  assert.equal(f.journal.records.at(-1).body.kind, 'outcome');
});

// N-1: the M-1 test above only retries with different bytes (a different
// result file). A retry with the same bytes hits the same result file, so a
// half-written remnant from the failed write must be removed first —
// otherwise the retry reads the remnant as corruption and poisons the journal.
test('a partial result-file write is removed so a same-bytes retry succeeds instead of poisoning', async t => {
  let armed = false;
  const f = await fixture(t, { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).includes('/results/')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'write') return async (bytes, offset, length, position) => {
        if (!armed) return target.write(bytes, offset, length, position);
        armed = false;
        await target.write(bytes, offset, Math.min(5, length), position);
        throw Object.assign(new Error('partial result write then EIO'), { code: 'EIO' });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } });
  const result = { content: [{ type: 'text', text: 'same bytes' }] };
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.appendResult(body('returned'), result), { code: 'EIO' });
  assert.equal(f.journal.failed, false);
  const retry = await f.journal.appendResult(body('outcome'), result);
  assert.equal(f.journal.failed, false);
  assert.deepEqual(await f.journal.readResult(retry.body.result), result);
  assert.deepEqual(await fs.readdir(join(f.directory, 'results')), [retry.body.result.sha256 + '.json']);
  // The failed first attempt never wrote its 'returned' record (resultFile
  // runs before the log append), so only the retry's 'outcome' follows.
  assert.deepEqual(f.journal.records.map(row => row.body.kind), ['header', 'prepared', 'outcome']);
});

// N-4: a full journal is persistent, not transient — no append can ever
// succeed again without explicit maintenance — so hitting the 64 MiB limit
// poisons the journal and status reports blocked, instead of every append
// failing while the boundary still looks healthy. The log is faked near
// full through the file handle's stat (writing a real 64 MiB log per test
// would be far too slow); a single oversized record still must not poison.
test('a full 64 MiB journal poisons later appends instead of reporting healthy', async t => {
  let armed = false;
  const f = await fixture(t, { fs: { ...fs, async open(path, ...args) {
    const handle = await fs.open(path, ...args);
    if (!String(path).endsWith('boundary.jsonl')) return handle;
    return new Proxy(handle, { get(target, key) {
      if (key === 'stat' && armed) return async () => {
        const info = await target.stat();
        return Object.assign(Object.create(Object.getPrototypeOf(info)), info, { size: 64 * 1024 * 1024 - 10 });
      };
      const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
    } });
  } } });
  await f.journal.append(body('prepared')); armed = true;
  await assert.rejects(f.journal.append(body('dispatch')), /exceeds 64 MiB/);
  assert.equal(f.journal.failed, true);
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_POISONED' });
});

test('closing seals admission before waiting; late append cannot race a closed fd', async t => {
  const reached = Promise.withResolvers(), release = Promise.withResolvers();
  const f = await fixture(t, { async onStage(stage) {
    if (stage === 'before-record') { reached.resolve(); await release.promise; }
  } });
  const pending = f.journal.append(body('prepared'));
  await reached.promise;
  const closing = f.journal.close();
  await assert.rejects(f.journal.append(body('dispatch')), { code: 'ERR_OHOS_LIFECYCLE_CLOSED' });
  release.resolve(); await pending; await closing;
  const again = await f.open({ onStage() {} });
  assert.equal(again.records.at(-1).body.kind, 'prepared');
});

test('snapshot rejects getter/cycle/exotic/sparse data and copies exact JSON without mutation', () => {
  const value = { ['__proto__']: { preserved: true }, list: ['中文', null, 2, false] };
  const copy = snapshot(value);
  assert.deepEqual(copy, value); assert.notEqual(copy.list, value.list);
  let reads = 0; const getter = { get secret() { reads++; return 'must not read'; } };
  const cycle = {}; cycle.self = cycle;
  for (const bad of [getter, cycle, new Date(), { missing: undefined }, [,,], -0, NaN]) assert.throws(() => snapshot(bad));
  assert.equal(reads, 0);
});
