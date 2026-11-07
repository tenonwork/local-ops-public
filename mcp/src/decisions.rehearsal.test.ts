// Integration test for the decision reader tool against the rehearsal database (migration 0034): get_decisions at a
// child node returns its decisions at distance 0 before its parent's at distance 1, leaves out a superseded decision,
// honours limit, and an unknown node comes back as a validation error with the database's message. On a project and
// component the test creates under global, on one connection inside a transaction that is always rolled back; tool
// statements run under savepoints, as in docs.rehearsal.test.ts, and as the URL's role.
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

test('rehearsal: get_decisions nearest first, superseded left out, limit, unknown node', { skip }, async () => {
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
  const client = new Client({ name: 'decisions-it', version: '1.0.0' });
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
  try {
    const present = (await db.query(
      "SELECT to_regprocedure('ops.get_decisions(ltree,integer)') IS NOT NULL AS present")).rows[0].present;
    assert.equal(present, true, 'rehearsal has ops.get_decisions (0034)');

    // Parent global.it-dec-<hex>, child <parent>.core.
    const hex = randomBytes(4).toString('hex');
    const parentPath = `global.it-dec-${hex}`;
    const childPath = `${parentPath}.core`;
    await ok('create_project', { parent_path: 'global', key: `it-dec-${hex}`, name: 'decisions integration', summary: 'it' });
    await ok('create_component', { parent_path: parentPath, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const { session_id } = await ok('open_session', { node_path: parentPath, kind: 'planning' });

    const decide = async (node_path: string, decision: string, supersedes?: string) =>
      (await ok('log_decision', { node_path, decision, segment_id: session_id, ...(supersedes ? { supersedes } : {}) })).id as string;
    const old = await decide(parentPath, `parent old ${hex}. More.`);
    const parent = await decide(parentPath, `parent new ${hex}. More.`, old);
    const child1 = await decide(childPath, `child one ${hex}`);
    const child2 = await decide(childPath, `child two ${hex}`);

    const got = await ok('get_decisions', { node_path: childPath, limit: 200 }) as Json[];
    assert.deepEqual(new Set(got.slice(0, 2).map((r) => r.id)), new Set([child1, child2]), 'child rows first');
    assert.deepEqual(got.slice(0, 2).map((r) => r.distance), [0, 0]);
    assert.deepEqual(got.slice(0, 2).map((r) => r.node_path), [childPath, childPath]);
    assert.equal(got[2].id, parent, 'then the parent row');
    assert.equal(got[2].distance, 1);
    assert.equal(got[2].gist, `parent new ${hex}.`);
    assert.equal(got[2].id8, parent.slice(0, 8));
    assert.equal(got.some((r) => r.id === old), false, 'superseded decision left out');
    assert.ok(got.slice(3).every((r) => r.distance >= 2), 'ancestors beyond the parent come after it');

    const one = await ok('get_decisions', { node_path: childPath, limit: 1 }) as Json[];
    assert.equal(one.length, 1);
    assert.equal(one[0].distance, 0);

    const unknown = await call('get_decisions', { node_path: `${parentPath}.nope` });
    assert.equal(unknown.isError, true, unknown.text);
    assert.equal(unknown.text, `Validation error (P0001): unknown node ${parentPath}.nope`);
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
