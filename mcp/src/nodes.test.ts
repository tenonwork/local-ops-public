// Tests for the node summary tools (tools/nodes.ts and the summary input of create_project / create_component in
// tools/planner.ts): call-time detection of migration 0035 (absent: the tool refuses and sends nothing else), the
// named-notation calls carrying p_summary, and summary validation refused before any query. No database: tools run on
// a real McpServer over an in-memory transport, against a fake pool that answers detection and the ops functions from
// fixed rows.
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
import { NODES_MISSING } from './tools/nodes.ts';

interface Statement { text: string; values?: unknown[] }
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const detect = (sig: string) => `SELECT to_regprocedure('${sig}') IS NOT NULL AS present`;
const DETECT = {
  set_node_summary: detect('ops.set_node_summary(ltree,text,uuid)'),
  create_project: detect('ops.create_project(ltree,text,text,jsonb,text)'),
  create_component: detect('ops.create_component(ltree,text,text,text,text,jsonb,text)'),
};
const CALL = {
  set_node_summary: 'SELECT * FROM ops.set_node_summary(p_node_path => $1::public.ltree, p_summary => $2, p_session => $3)',
  create_project: `SELECT * FROM ops.create_project(p_parent_path => $1::public.ltree, p_key => $2, p_name => $3, p_params => $4::jsonb,
         p_summary => $5)`,
  create_component: `SELECT * FROM ops.create_component(p_parent_path => $1::public.ltree, p_key => $2, p_kind => $3, p_repo_ref => $4,
         p_verify_cmd => $5, p_params => $6::jsonb, p_summary => $7)`,
};
const ROW = { node_path: 'global.p', summary: 's', summary_updated_at: '2026-10-20T00:00:00.000Z', summary_session_id: SESSION };

// Each tool with a valid call (summary 's') and the values its ops call binds.
const tools = [
  { name: 'set_node_summary' as const, args: { node_path: 'global.p', segment_id: SESSION },
    values: (summary: string) => ['global.p', summary, SESSION] },
  { name: 'create_project' as const, args: { parent_path: 'global', key: 'k', name: 'n' },
    values: (summary: string) => ['global', 'k', 'n', '{}', summary] },
  { name: 'create_component' as const, args: { parent_path: 'global.p', key: 'k', kind: 'service', repo_ref: 'r' },
    values: (summary: string) => ['global.p', 'k', 'service', 'r', null, '{}', summary] },
];

function fakePool(present: boolean) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text.startsWith('SELECT to_regprocedure(')) return { rows: [{ present }] };
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
  const client = new Client({ name: 'nodes-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  return { client, call, statements, close: async () => { await client.close(); await server.close(); } };
}

for (const t of tools) {
  test(`0035 absent: ${t.name} refuses after detection alone`, async () => {
    const c = await connect(false);
    try {
      const r = await c.call(t.name, { ...t.args, summary: 's' });
      assert.equal(r.isError, true);
      assert.equal(r.text, NODES_MISSING);
      assert.deepEqual(c.statements.map((s) => s.text), [DETECT[t.name]], 'only the detection query ran');
    } finally {
      await c.close();
    }
  });

  test(`0035 present: ${t.name} detects, then calls its ops function in named notation with p_summary`, async () => {
    const c = await connect(true);
    try {
      const r = await c.call(t.name, { ...t.args, summary: 's' });
      assert.equal(r.isError, false, r.text);
      assert.deepEqual(JSON.parse(r.text), ROW);
      assert.deepEqual(c.statements, [{ text: DETECT[t.name], values: undefined },
        { text: CALL[t.name], values: t.values('s') }]);

      const long = 'x'.repeat(200);
      const max = await c.call(t.name, { ...t.args, summary: long });
      assert.equal(max.isError, false, `200 characters accepted: ${max.text}`);
      assert.deepEqual(c.statements.at(-1)?.values, t.values(long));
    } finally {
      await c.close();
    }
  });

  test(`${t.name}: summary missing, empty, blank, 201 characters or two lines is refused before any query`, async () => {
    const c = await connect(true);
    try {
      const refusals: [Record<string, unknown>, RegExp][] = [
        [{}, /summary/],
        [{ summary: '' }, /must not be blank/],
        [{ summary: '  ' }, /must not be blank/],
        [{ summary: 'x'.repeat(201) }, /summary/],
        [{ summary: 'one\ntwo' }, /must be one line/],
        [{ summary: 'one\rtwo' }, /must be one line/],
      ];
      for (const [extra, message] of refusals) {
        const r = await c.call(t.name, { ...t.args, ...extra });
        assert.equal(r.isError, true, `${JSON.stringify(extra)}: ${r.text}`);
        assert.match(r.text, new RegExp(`^MCP error -32602: Input validation error: Invalid arguments for tool ${t.name}`));
        assert.match(r.text, message);
      }
      assert.equal(c.statements.length, 0, 'no statement at all');
    } finally {
      await c.close();
    }
  });
}

test('tools/list: set_node_summary is a planner tool with segment_id required; summary required on all three; none on the executor', async () => {
  const c = await connect(true);
  try {
    const { tools: listed } = await c.client.listTools();
    const t = listed.find((x) => x.name === 'set_node_summary');
    assert.ok(t, 'planner registers set_node_summary');
    assert.equal(t.description, "Set a node's one-line summary (ops.set_node_summary): non-empty, one line, at most 200 "
      + 'characters; stamps summary_updated_at and the session. segment_id (the session id) is required: a full UUID or '
      + '8-character id prefix. Returns node_path, summary, summary_updated_at, summary_session_id. Needs migration 0035.');
    const schema = t.inputSchema as { properties: Record<string, unknown>; required?: string[] };
    assert.deepEqual(Object.keys(schema.properties).sort(), ['node_path', 'segment_id', 'summary']);
    assert.deepEqual([...(schema.required ?? [])].sort(), ['node_path', 'segment_id', 'summary']);
    for (const name of ['create_project', 'create_component']) {
      const s = listed.find((x) => x.name === name);
      assert.ok(s, `planner registers ${name}`);
      assert.ok(s.inputSchema.required?.includes('summary'), `${name}.summary required`);
      assert.match(s.description ?? '', / summary \(required\): the node's one-line description\. Needs migration 0035\.$/);
      const p = (s.inputSchema.properties as Record<string, { maxLength?: number }>).summary;
      assert.equal(p.maxLength, 200);
    }
  } finally {
    await c.close();
  }
  const e = await connect(true, registerExecutor);
  try {
    const { tools: listed } = await e.client.listTools();
    for (const name of ['set_node_summary', 'create_project', 'create_component']) {
      assert.equal(listed.some((x) => x.name === name), false, `executor does not register ${name}`);
    }
  } finally {
    await e.close();
  }
});
