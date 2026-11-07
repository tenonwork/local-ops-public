// Integration test for open_session's node overview against the rehearsal database (migration 0036): open_session at a
// fixture project returns the session id and the node's overview (first line NODE <path> (, the CONTEXT, CHILDREN,
// NEXT STEP and BACKLOG headers in order, within the default 4000 characters), with no overview_error. On a project
// the test creates under global, on one connection inside a transaction that is always rolled back; tool statements
// run under savepoints, as in nodes.rehearsal.test.ts, and as the URL's role.
// Skipped unless LOCAL_OPS_REHEARSAL_URL is set; refuses the production database local_ops; skips with a
// diagnostic when ops.node_overview is absent.
//
//   LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerPlanner } from './tools/planner.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';
const skip = url === '' && 'LOCAL_OPS_REHEARSAL_URL not set';
type Json = Record<string, any>;

test('rehearsal: open_session returns the opened node\'s overview beside the session id', { skip }, async (t) => {
  assert.notEqual(new URL(url).pathname, '/local_ops', 'integration tests refuse the production database local_ops');
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  await db.query('BEGIN');
  let n = 0;
  const guarded = async (text: string, values?: unknown[]) => {
    const sp = `t${n++}`;
    await db.query(`SAVEPOINT ${sp}`);
    try {
      const r = await db.query(text, values);
      await db.query(`RELEASE SAVEPOINT ${sp}`);
      return r;
    } catch (err) {
      await db.query(`ROLLBACK TO SAVEPOINT ${sp}`);
      throw err;
    }
  };
  const txClient = {
    query: (text: string, values?: unknown[]) =>
      text === 'BEGIN' ? db.query('SAVEPOINT tx')
        : text === 'COMMIT' ? db.query('RELEASE SAVEPOINT tx')
        : text === 'ROLLBACK' ? db.query('ROLLBACK TO SAVEPOINT tx')
        : db.query(text, values),
    release() {},
  };
  const pool = { query: guarded, connect: async () => txClient } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'overview-it', version: '1.0.0' });
  await client.connect(b);
  const ok = async (name: string, args: Json) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    const text = r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n');
    assert.equal(r.isError === true, false, `${name}: ${text}`);
    return JSON.parse(text);
  };
  try {
    const present = (await db.query(
      "SELECT to_regprocedure('ops.node_overview(ltree,integer)') IS NOT NULL AS present")).rows[0].present;
    if (present !== true) {
      t.skip('ops.node_overview(ltree,integer) is absent in rehearsal (migration 0036 not applied)');
      return;
    }

    const hex = randomBytes(4).toString('hex');
    const projectPath = `global.it-overview-${hex}`;
    await ok('create_project', { parent_path: 'global', key: `it-overview-${hex}`, name: 'overview integration',
      summary: `project ${hex}` });

    const r = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    assert.match(r.session_id, /^[0-9a-f-]{36}$/);
    assert.equal('overview_error' in r, false, `no overview_error: ${r.overview_error}`);
    const overview = r.overview as string;
    assert.equal(typeof overview, 'string');
    assert.ok(overview.split('\n')[0].startsWith(`NODE ${projectPath} (`), overview);
    let at = -1;
    for (const header of ['CONTEXT', 'CHILDREN', 'NEXT STEP', 'BACKLOG']) {
      const i = overview.split('\n').findIndex((line, k) => k > at && line.startsWith(header));
      assert.ok(i > at, `${header} follows the previous header:\n${overview}`);
      at = i;
    }
    assert.ok(overview.length <= 4000, `length ${overview.length}`);
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
