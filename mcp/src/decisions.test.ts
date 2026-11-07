// Tests for the decision reader tool (tools/decisions.ts): call-time detection of migration 0034 (absent: the tool
// refuses and sends nothing else), the named-notation call with its default and given limit, and input validation
// refused before any query. No database: tools run on a real McpServer over an in-memory transport, against a fake
// pool that answers detection and the ops function from fixed rows.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerPlanner } from './tools/planner.ts';
import { registerExecutor } from './tools/executor.ts';
import { DECISIONS_MISSING } from './tools/decisions.ts';

interface Statement { text: string; values?: unknown[] }
const DETECT_TEXT = "SELECT to_regprocedure('ops.get_decisions(ltree,integer)') IS NOT NULL AS present";
const CALL_TEXT = 'SELECT * FROM ops.get_decisions(p_node_path => $1::public.ltree, p_limit => $2)';
const ROW = { id: 'dddddddd-1111-4111-8111-111111111111', id8: 'dddddddd', gist: 'g.', node_path: 'global.p', distance: 0,
  occurred_at: '2026-10-20T00:00:00.000Z' };

function fakePool(present: boolean) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text === DETECT_TEXT) return { rows: [{ present }] };
    return { rows: [ROW] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(present: boolean, register = registerPlanner) {
  const { pool, statements } = fakePool(present);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  register(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'decisions-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  return { client, call, statements, close: async () => { await client.close(); await server.close(); } };
}

test('0034 absent: get_decisions refuses after detection alone', async () => {
  const c = await connect(false);
  try {
    const r = await c.call('get_decisions', { node_path: 'global.p' });
    assert.equal(r.isError, true);
    assert.equal(r.text, DECISIONS_MISSING);
    assert.deepEqual(c.statements.map((s) => s.text), [DETECT_TEXT], 'only the detection query ran');
  } finally {
    await c.close();
  }
});

test('0034 present: get_decisions detects, then calls ops.get_decisions in named notation (limit default 50)', async () => {
  const c = await connect(true);
  try {
    const r = await c.call('get_decisions', { node_path: 'global.p' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), [ROW]);
    assert.deepEqual(c.statements, [{ text: DETECT_TEXT, values: undefined }, { text: CALL_TEXT, values: ['global.p', 50] }]);

    const given = await c.call('get_decisions', { node_path: 'global.p.core', limit: 7 });
    assert.equal(given.isError, false, given.text);
    assert.deepEqual(c.statements.slice(2), [{ text: DETECT_TEXT, values: undefined },
      { text: CALL_TEXT, values: ['global.p.core', 7] }]);
  } finally {
    await c.close();
  }
});

test('get_decisions: limit 0, 201, 1.5 and a malformed node_path are refused before any query', async () => {
  const c = await connect(true);
  try {
    const refusals: [Record<string, unknown>, RegExp][] = [
      [{ node_path: 'global.p', limit: 0 }, /limit/],
      [{ node_path: 'global.p', limit: 201 }, /limit/],
      [{ node_path: 'global.p', limit: 1.5 }, /limit/],
      [{ node_path: 'Global' }, /node_path/],
      [{}, /node_path/],
    ];
    for (const [args, message] of refusals) {
      const r = await c.call('get_decisions', args);
      assert.equal(r.isError, true, `${JSON.stringify(args)}: ${r.text}`);
      assert.match(r.text, /^MCP error -32602: Input validation error: Invalid arguments for tool get_decisions/);
      assert.match(r.text, message);
    }
    assert.equal(c.statements.length, 0, 'no statement at all');
  } finally {
    await c.close();
  }
});

test('tools/list: get_decisions is a planner tool with its description, node_path required, no segment_id; not on the executor', async () => {
  const c = await connect(true);
  try {
    const { tools: listed } = await c.client.listTools();
    const t = listed.find((x) => x.name === 'get_decisions');
    assert.ok(t, 'planner registers get_decisions');
    assert.equal(t.description, 'Current decisions at node_path and its ancestors, nearest first, as one-line gists with '
      + 'ids (ops.get_decisions): id, id8, gist, node_path, distance (0 = this node), occurred_at. limit 1-200, default 50. '
      + 'Read full text by id with query. Needs migration 0034.');
    const schema = t.inputSchema as { properties: Record<string, { type?: string; minimum?: number; maximum?: number }>;
      required?: string[] };
    assert.deepEqual(Object.keys(schema.properties).sort(), ['limit', 'node_path']);
    assert.deepEqual(schema.required, ['node_path']);
    assert.equal(schema.properties.limit.type, 'integer');
    assert.equal(schema.properties.limit.minimum, 1);
    assert.equal(schema.properties.limit.maximum, 200);
  } finally {
    await c.close();
  }
  const e = await connect(true, registerExecutor);
  try {
    const { tools: listed } = await e.client.listTools();
    assert.equal(listed.some((x) => x.name === 'get_decisions'), false, 'executor does not register get_decisions');
  } finally {
    await e.close();
  }
});
