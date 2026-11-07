// Integration test for the tick tools against the rehearsal database. Every statement runs on one
// connection inside a transaction that is always rolled back, so no rows are left behind.
// Skipped unless LOCAL_OPS_REHEARSAL_URL is set; refuses the production database local_ops.
//
//   LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { contactFor, installPassiveTick } from './tick.ts';
import { registerTick, registerWindowLink } from './tools/window.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';

test('rehearsal: need_cal -> new + CAL_CREATE -> link -> no directive', { skip: url === '' && 'LOCAL_OPS_REHEARSAL_URL not set' }, async () => {
  assert.notEqual(new URL(url).pathname, '/local_ops', 'integration tests refuse the production database local_ops');
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  await db.query('BEGIN');
  try {
    // Rehearsal is restored from production, which may hold a live window. End it at now() inside this
    // transaction (shrinking a span can create no overlap); the rollback restores it.
    await db.query('UPDATE ops.windows SET resets_at = now() WHERE now() >= started_at AND now() < resets_at');
    const live = await db.query('SELECT count(*)::int AS n FROM ops.window_state WHERE live');
    assert.equal(live.rows[0].n, 0, 'precondition: no live window in rehearsal');

    // The whole server shares the one transaction-holding connection.
    const pool = { query: db.query.bind(db), connect: async () => ({ query: db.query.bind(db), release() {} }) };
    const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
    const contact = () => contactFor(server.server.getClientVersion());
    installPassiveTick(server, pool as unknown as pg.Pool, contact);
    registerTick(server, pool as unknown as pg.Pool, contact);
    registerWindowLink(server, pool as unknown as pg.Pool);
    const [a, b] = InMemoryTransport.createLinkedPair();
    await server.connect(a);
    const client = new Client({ name: 'claude-ai', version: '1.0.0' });
    await client.connect(b);
    const call = async (name: string, args: Record<string, unknown> = {}) => {
      const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
      const text = r.content.map((c) => (c.type === 'text' ? c.text : ''));
      assert.notEqual(r.isError, true, text.join('\n'));
      return text;
    };
    const tickJson = async (args: Record<string, unknown> = {}) => {
      const [line, json] = await call('tick', args);
      const t = JSON.parse(json);
      assert.equal(line, t.line);
      return t;
    };

    const t1 = await tickJson();
    assert.equal(t1.state, 'need_cal');
    assert.equal(t1.directive, 'LIST_CAL');

    const t2 = await tickJson({ calendar: [] });
    assert.equal(t2.state, 'new');
    assert.equal(t2.directive, 'CAL_CREATE');
    assert.equal(t2.window.start_source, 'inferred');

    const [linked] = await call('window_link_event', { number: t2.window.number, event_id: 'it-f30aa2d7' });
    assert.equal(JSON.parse(linked).calendar_event_id, 'it-f30aa2d7');

    const t3 = await tickJson();
    assert.equal(t3.directive, null);
    assert.equal(t3.window.calendar_event_id, 'it-f30aa2d7');

    // Only rows this transaction wrote: ticks.at defaults to now(), the transaction start.
    const recorded = await db.query('SELECT source::text, client, state FROM ops.ticks WHERE at = now() ORDER BY id DESC LIMIT 3');
    assert.deepEqual(recorded.rows.map((r) => [r.source, r.client]),
      [['chat', 'claude-ai'], ['chat', 'claude-ai'], ['chat', 'claude-ai']]);

    await client.close();
    await server.close();
  } finally {
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
