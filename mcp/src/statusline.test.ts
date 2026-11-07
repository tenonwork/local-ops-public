// Unit tests for the status-line usage reader (statusline.ts); no database: main runs with a fake client and a
// temporary cache directory.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { cachePath, changed, formatLine, main, parseInput, type Cache, type StatusClient } from './statusline.ts';

const FIVE_AT = 1_800_000_000;   // epoch seconds
const SEVEN_AT = 1_800_500_000;
const hhmm = (s: number) => {
  const d = new Date(s * 1000);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
};
const input = (five?: number, seven?: number, session = 'sess-1') => JSON.stringify({
  session_id: session,
  model: { id: 'x' },
  rate_limits: {
    ...(five === undefined ? {} : { five_hour: { used_percentage: five, resets_at: FIVE_AT } }),
    ...(seven === undefined ? {} : { seven_day: { used_percentage: seven, resets_at: SEVEN_AT } }),
  },
});

test('parseInput: full, partial, absent and malformed input', () => {
  const full = parseInput(input(42.4, 18));
  assert.deepEqual(full, { sessionId: 'sess-1', fiveHour: { pct: 42.4, resetsAt: new Date(FIVE_AT * 1000) },
    sevenDay: { pct: 18, resetsAt: new Date(SEVEN_AT * 1000) } });
  assert.deepEqual(parseInput(input(undefined, 18)), { sessionId: 'sess-1',
    sevenDay: { pct: 18, resetsAt: new Date(SEVEN_AT * 1000) } });
  assert.deepEqual(parseInput(JSON.stringify({ session_id: 's' })), { sessionId: 's' });
  assert.deepEqual(parseInput('{}'), { sessionId: '' });
  assert.deepEqual(parseInput(JSON.stringify({ session_id: 's',
    rate_limits: { five_hour: { used_percentage: '4' , resets_at: FIVE_AT }, seven_day: { used_percentage: 3 } } })),
  { sessionId: 's' });
  assert.equal(parseInput('not json'), null);
  assert.equal(parseInput(''), null);
  assert.equal(parseInput('[1]'), null);
  assert.equal(parseInput('null'), null);
});

test('formatLine: each case', () => {
  const window: Cache = { fiveHourPct: null, fiveHourResetsAt: null, sevenDayPct: null, sevenDayResetsAt: null,
    window: 'W056' };
  assert.equal(formatLine(parseInput(input(42.4, 18.6)), null), `5h 42% → ${hhmm(FIVE_AT)} · 7d 19%`);
  assert.equal(formatLine(parseInput(input(42.4, 18.6)), window), `5h 42% → ${hhmm(FIVE_AT)} · 7d 19% · W056`);
  assert.equal(formatLine(parseInput(input(undefined, 18)), null), '5h – · 7d 18%');
  assert.equal(formatLine(parseInput(input(7, undefined)), null), `5h 7% → ${hhmm(FIVE_AT)} · 7d –`);
  assert.equal(formatLine(parseInput(JSON.stringify({ session_id: 's' })), null), 'usage –');
  assert.equal(formatLine(null, null), 'usage –');
  assert.equal(formatLine(null, window), 'usage – · W056');
});

test('changed: compares the four values', () => {
  const r = parseInput(input(42, 18))!;
  const same: Cache = { fiveHourPct: 42, fiveHourResetsAt: FIVE_AT, sevenDayPct: 18, sevenDayResetsAt: SEVEN_AT,
    window: 'W001' };
  assert.equal(changed(r, null), true);
  assert.equal(changed(r, same), false);
  assert.equal(changed(r, { ...same, fiveHourPct: 43 }), true);
  assert.equal(changed(r, { ...same, fiveHourResetsAt: FIVE_AT + 1 }), true);
  assert.equal(changed(r, { ...same, sevenDayPct: 17 }), true);
  assert.equal(changed(r, { ...same, sevenDayResetsAt: null }), true);
  assert.equal(changed(parseInput(input(42, undefined))!, same), true);
});

test('cachePath: sanitises the session id', () => {
  assert.equal(cachePath('/d', 'a/b:c..d'), join('/d', 'claude-statusline-a_b_c__d.json'));
  assert.equal(cachePath('/d', ''), join('/d', 'claude-statusline-unknown.json'));
});

interface Fake { client: () => StatusClient; calls: unknown[][]; ended: number }
function fake(answer: (values: unknown[]) => unknown = () => ({ recorded: true, id: 1,
  tick: { state: 'ok', directive: null, line: 'ok W056 · 4h00 left' } })): Fake {
  const f: Fake = { calls: [], ended: 0, client: () => ({
    connect: async () => undefined,
    query: async (_text: string, values: unknown[] = []) => {
      f.calls.push(values);
      return { rows: [{ r: answer(values) }] };
    },
    end: async () => { f.ended++; },
  }) };
  return f;
}

async function run(stdin: string, cacheDir: string, client: () => StatusClient, extra: { timeoutMs?: number } = {}) {
  const out: string[] = [];
  const err: string[] = [];
  const line = await main({ stdin: async () => stdin, cacheDir, client, write: (l) => out.push(l),
    warn: (m) => err.push(m), ...extra });
  return { line, out, err };
}

test('main: sends once, identical run sends nothing, changed pct sends again', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'statusline-test-'));
  const f = fake();
  const a = await run(input(42, 18), dir, f.client);
  assert.deepEqual(a.out, [`5h 42% → ${hhmm(FIVE_AT)} · 7d 18% · W056`]);
  assert.deepEqual(a.err, []);
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0], ['statusline', 'sess-1', 42, new Date(FIVE_AT * 1000).toISOString(), 18,
    new Date(SEVEN_AT * 1000).toISOString()]);
  assert.equal(f.ended, 1);
  assert.deepEqual(JSON.parse(await readFile(cachePath(dir, 'sess-1'), 'utf8')),
    { fiveHourPct: 42, fiveHourResetsAt: FIVE_AT, sevenDayPct: 18, sevenDayResetsAt: SEVEN_AT, window: 'W056' });

  const b = await run(input(42, 18), dir, f.client);
  assert.deepEqual(b.out, a.out);
  assert.equal(f.calls.length, 1, 'identical reading is not sent');

  const c = await run(input(43, 18), dir, fake(() => ({ recorded: true, id: 2, tick: null })).client);
  assert.deepEqual(c.out, [`5h 43% → ${hhmm(FIVE_AT)} · 7d 18% · W056`], 'label kept without a tick line');
  const d = fake();
  await run(input(44, 18), dir, d.client);
  assert.equal(d.calls.length, 1, 'changed pct sends again');
});

test('main: no rate_limits or unparseable stdin prints the line and sends nothing', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'statusline-test-'));
  const f = fake();
  assert.deepEqual((await run(JSON.stringify({ session_id: 's' }), dir, f.client)).out, ['usage –']);
  assert.deepEqual((await run('garbage', dir, f.client)).out, ['usage –']);
  assert.equal(f.calls.length, 0);
  assert.deepEqual(await readdir(dir), []);
});

test('main: a throwing client still prints the line, warns once and writes no cache', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'statusline-test-'));
  let ended = 0;
  const throwing = () => ({
    connect: async () => { throw new Error('connection refused'); },
    query: async () => ({ rows: [] }),
    end: async () => { ended++; },
  });
  const r = await run(input(42, 18), dir, throwing);
  assert.deepEqual(r.out, [`5h 42% → ${hhmm(FIVE_AT)} · 7d 18%`]);
  assert.deepEqual(r.err, ['connection refused']);
  assert.equal(ended, 1, 'client ended');
  assert.deepEqual(await readdir(dir), [], 'no cache without a returned call');

  const factoryThrows = await run(input(42, 18), dir, () => { throw new Error('boom'); });
  assert.equal(factoryThrows.out.length, 1);
  assert.deepEqual(await readdir(dir), []);
});

test('main: a hung connect hits the overall timeout, prints the line and writes no cache', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'statusline-test-'));
  const hung = () => ({
    connect: () => new Promise<never>(() => undefined),
    query: async () => ({ rows: [] }),
    end: async () => undefined,
  });
  const started = Date.now();
  const r = await run(input(42, 18), dir, hung, { timeoutMs: 50 });
  assert.ok(Date.now() - started < 1000);
  assert.deepEqual(r.out, [`5h 42% → ${hhmm(FIVE_AT)} · 7d 18%`]);
  assert.deepEqual(r.err, ['timed out']);
  assert.deepEqual(await readdir(dir), []);
});

test('main: recorded false still writes the cache', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'statusline-test-'));
  await run(input(42, 18), dir, fake(() => ({ recorded: false })).client);
  assert.equal((await readCache(dir)).fiveHourPct, 42);
});

async function readCache(dir: string): Promise<Cache> {
  return JSON.parse(await readFile(cachePath(dir, 'sess-1'), 'utf8')) as Cache;
}
