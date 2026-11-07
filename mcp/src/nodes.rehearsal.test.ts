// Integration test for the node summary tools against the rehearsal database (migration 0035): create_project and
// create_component store their summaries (stamped, no session); set_node_summary overwrites a summary and stamps the
// session; an unknown node comes back as a validation error with the database's message. On a project and component
// the test creates under global, on one connection inside a transaction that is always rolled back; tool statements
// run under savepoints, as in docs.rehearsal.test.ts, and as the URL's role.
// Skipped unless LOCAL_OPS_REHEARSAL_URL is set; refuses the production database local_ops.
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

test('rehearsal: create_project / create_component store summaries; set_node_summary overwrites and stamps; unknown node', { skip }, async () => {
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
  const client = new Client({ name: 'nodes-it', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Json) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const ok = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text);
  };
  const node = async (path: string) => (await db.query(
    `SELECT summary, summary_updated_at IS NOT NULL AS stamped, summary_session_id
       FROM ops.nodes WHERE path OPERATOR(public.=) $1::public.ltree`, [path])).rows[0];
  try {
    const present = (await db.query(
      "SELECT to_regprocedure('ops.set_node_summary(ltree,text,uuid)') IS NOT NULL AS present")).rows[0].present;
    assert.equal(present, true, 'rehearsal has ops.set_node_summary (0035)');

    const hex = randomBytes(4).toString('hex');
    const projectPath = `global.it-node-${hex}`;
    const corePath = `${projectPath}.core`;
    await ok('create_project', { parent_path: 'global', key: `it-node-${hex}`, name: 'nodes integration',
      summary: `project ${hex}` });
    await ok('create_component', { parent_path: projectPath, key: 'core', kind: 'service', repo_ref: 'it',
      verify_cmd: 'true', summary: `component ${hex}` });
    assert.deepEqual(await node(projectPath), { summary: `project ${hex}`, stamped: true, summary_session_id: null });
    assert.deepEqual(await node(corePath), { summary: `component ${hex}`, stamped: true, summary_session_id: null });

    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const set = await ok('set_node_summary', { node_path: corePath, summary: `rewritten ${hex}`,
      segment_id: session_id.slice(0, 8) });
    assert.equal(set.node_path, corePath);
    assert.equal(set.summary, `rewritten ${hex}`);
    assert.equal(set.summary_session_id, session_id);
    assert.ok(set.summary_updated_at, 'summary_updated_at returned');
    assert.deepEqual(await node(corePath), { summary: `rewritten ${hex}`, stamped: true, summary_session_id: session_id });

    const unknown = await call('set_node_summary', { node_path: `${projectPath}.nope`, summary: 's', segment_id: session_id });
    assert.equal(unknown.isError, true, unknown.text);
    assert.equal(unknown.text, `Validation error (P0001): unknown node ${projectPath}.nope`);
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
