// Integration test for the status-line usage reader against the rehearsal database (migration 0038): main's send path,
// with the client injected as one connection inside a transaction that is always rolled back, records a reading (row
// visible in ops.usage_snapshots), an identical second reading returns recorded false, and the printed line carries
// the percentages. Runs as the URL's role.
// Skipped unless LOCAL_OPS_REHEARSAL_URL is set; refuses the production database local_ops; skips with a
// diagnostic when ops.record_usage is absent.
//
//   LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { main, parseInput, send, type StatusClient } from './statusline.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';
const skip = url === '' && 'LOCAL_OPS_REHEARSAL_URL not set';

test('rehearsal: the status line records a changed reading once through ops.record_usage', { skip }, async (t) => {
  assert.notEqual(new URL(url).pathname, '/local_ops', 'integration tests refuse the production database local_ops');
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  await db.query('BEGIN');
  // connect and end are no-ops: the transaction owns the connection
  const client = (): StatusClient => ({
    connect: async () => undefined,
    query: (text: string, values?: unknown[]) => db.query(text, values),
    end: async () => undefined,
  });
  try {
    const present = (await db.query(
      "SELECT to_regprocedure('ops.record_usage(text,text,numeric,timestamptz,numeric,timestamptz)') IS NOT NULL AS present"))
      .rows[0].present;
    if (present !== true) {
      t.skip('ops.record_usage is absent in rehearsal (migration 0038 not applied)');
      return;
    }

    // a pair distinct from any stored snapshot: percentages with two decimals, resets from the database clock
    const now = (await db.query('SELECT extract(epoch FROM now())::bigint AS s')).rows[0].s as string;
    const fiveAt = Number(now) + 2 * 3600;
    const sevenAt = Number(now) + 3 * 86400;
    const session = `it-statusline-${process.pid}`;
    const stdin = JSON.stringify({ session_id: session, rate_limits: {
      five_hour: { used_percentage: 37.25, resets_at: fiveAt }, seven_day: { used_percentage: 12.5, resets_at: sevenAt } } });
    const dir = await mkdtemp(join(tmpdir(), 'statusline-it-'));
    const out: string[] = [];
    const before = Number((await db.query('SELECT count(*) AS n FROM ops.usage_snapshots')).rows[0].n);

    const line = await main({ stdin: async () => stdin, cacheDir: dir, client, write: (l) => out.push(l),
      warn: (m) => assert.fail(`warned: ${m}`) });
    assert.deepEqual(out, [line]);
    assert.match(line, /^5h 37% → \d\d:\d\d · 7d 13%/);
    const rows = (await db.query(
      `SELECT client, session_ref, five_hour_pct::text, seven_day_pct::text, five_hour_resets_at = to_timestamp($1) AS at
         FROM ops.usage_snapshots ORDER BY id DESC LIMIT 1`, [fiveAt])).rows;
    assert.deepEqual(rows, [{ client: 'statusline', session_ref: session, five_hour_pct: '37.25', seven_day_pct: '12.50',
      at: true }]);
    assert.equal(Number((await db.query('SELECT count(*) AS n FROM ops.usage_snapshots')).rows[0].n), before + 1);

    // the same reading sent again (cache bypassed) is not stored
    const again = (await db.query(
      `SELECT ops.record_usage(p_client => 'statusline', p_session_ref => $1, p_five_hour_pct => 37.25,
                               p_five_hour_resets_at => to_timestamp($2), p_seven_day_pct => 12.5,
                               p_seven_day_resets_at => to_timestamp($3)) AS r`, [session, fiveAt, sevenAt])).rows[0].r;
    assert.deepEqual(again, { recorded: false });
    const cache = await send(client(), parseInput(stdin)!, null);
    assert.equal(cache.fiveHourPct, 37.25);
    assert.equal(Number((await db.query('SELECT count(*) AS n FROM ops.usage_snapshots')).rows[0].n), before + 1);
  } finally {
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
