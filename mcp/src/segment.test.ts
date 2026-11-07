// Tests for segment_id, the session input of record_gate / create_dispatch / log_decision / close_session (and
// formerly adopt_orphans, now not registered); the retired alias session_id (stripped by the computer-link bridge) is
// refused. No database:
// tools run on a real McpServer over an in-memory transport, against a fake pool that records every statement.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { contactFor, installPassiveTick } from './tick.ts';
import { registerPlanner } from './tools/planner.ts';

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';
const NOW = '2026-10-09T00:00:00Z';

interface Statement { text: string; values?: unknown[] }

function fakePool() {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text.includes('ops.tick(')) return { rows: [{ t: { state: 'ok', line: 'ok', directive: null } }] };
    if (/ops\.((write|approve|retire)_doc|set_node_summary)\(/.test(text)) return { rows: [{ present: true, r: {} }] };
    return { rows: [{ id: 'x', n: 0, counts: { decisions: 0, dispatches: 0 } }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(passiveTick = false) {
  const { pool, statements } = fakePool();
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  if (passiveTick) installPassiveTick(server, pool, () => contactFor(server.server.getClientVersion()), 'planner');
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'segment-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  return { client, call, statements, close: async () => { await client.close(); await server.close(); } };
}

// Each tool with the rest of a valid call, the ops function it calls, and the bind position of the session.
const tools = [
  { name: 'record_gate', fn: 'ops.record_gate(', pos: 3, required: false,
    args: { gate_key: 'g', result: 'pass' } },
  { name: 'create_dispatch', fn: 'ops.create_dispatch(', pos: 6, required: true,
    args: { node_path: 'global.p.core', dispatch_type: 'repair', title: 't', prompt: 'p' } },
  { name: 'log_decision', fn: 'ops.log_decision(', pos: 7, required: true,
    args: { node_path: 'global.p', decision: 'd' } },
  { name: 'close_session', fn: 'ops.close_session(', pos: 0, required: true,
    args: { summary: 's', next_step: 'n', decisions: [] } },
  { name: 'write_doc', fn: 'ops.write_doc(p_', pos: 9, required: true,
    args: { node_path: 'global.p', doc_key: 'D', doc_type: 'manual', title: 't', content: 'c', basis: 'review' } },
  { name: 'approve_doc', fn: 'ops.approve_doc(p_', pos: 3, required: true,
    args: { node_path: 'global.p', doc_key: 'D', content_sha256: 'a'.repeat(64) } },
  { name: 'retire_doc', fn: 'ops.retire_doc(p_', pos: 3, required: true,
    args: { node_path: 'global.p', doc_key: 'D', reason: 'r' } },
  { name: 'set_node_summary', fn: 'ops.set_node_summary(p_', pos: 2, required: true,
    args: { node_path: 'global.p', summary: 's' } },
];

// adopt_orphans took a required segment_id until the tool was removed (ops.adopt_orphans dropped in 0023).
test('adopt_orphans: not registered; a call with segment_id or session_id reaches no database', async () => {
  const c = await connect();
  try {
    for (const args of [{ segment_id: A }, { session_id: A }]) {
      const r = await c.call('adopt_orphans', { from: NOW, to: NOW, ...args });
      assert.equal(r.isError, true);
      assert.equal(r.text, 'MCP error -32602: Tool adopt_orphans not found');
    }
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

for (const t of tools) {
  test(`${t.name}: segment_id reaches the database; the retired session_id is refused`, async () => {
    const c = await connect();
    try {
      const r = await c.call(t.name, { ...t.args, segment_id: A });
      assert.equal(r.isError, false, `${t.name}: ${r.text}`);
      const s = c.statements.filter((x) => x.text.includes(t.fn)).at(-1);
      assert.ok(s, `${t.name} called ${t.fn}`);
      assert.equal(s.values?.[t.pos], A);

      const before = c.statements.length;
      for (const args of [{ session_id: A }, { segment_id: A, session_id: A }, { segment_id: A, session_id: B }]) {
        const refused = await c.call(t.name, { ...t.args, ...args });
        assert.equal(refused.isError, true, `${t.name} ${JSON.stringify(args)}: ${refused.text}`);
        assert.match(refused.text, /session_id is no longer accepted; send the session id as segment_id/);
      }
      assert.equal(c.statements.length, before, 'a refused call reaches no database');

      const neither = await c.call(t.name, t.args);
      if (t.required) {
        assert.equal(neither.isError, true);
        assert.match(neither.text, /segment_id is required/);
        assert.equal(c.statements.length, before, 'a refused call reaches no database');
      } else {
        assert.equal(neither.isError, false, `${t.name}: ${neither.text}`);
        assert.equal(c.statements.at(-1)?.values?.[t.pos], null);
      }
    } finally {
      await c.close();
    }
  });
}

test('tools/list: segment_id is advertised, required exactly where the tool needs a session; session_id is not listed', async () => {
  const c = await connect();
  try {
    const { tools: listed } = await c.client.listTools();
    for (const t of tools) {
      const schema = listed.find((x) => x.name === t.name)?.inputSchema as
        { properties: Record<string, unknown>; required?: string[] };
      assert.ok(schema.properties.segment_id, `${t.name} has segment_id`);
      assert.ok(!('session_id' in schema.properties), `${t.name} does not list session_id`);
      assert.equal((schema.required ?? []).includes('segment_id'), t.required, `${t.name}: segment_id required = ${t.required}`);
    }
    const requiring = listed.filter((x) => (x.inputSchema.required ?? []).includes('segment_id')).map((x) => x.name).sort();
    assert.deepEqual(requiring, ['approve_doc', 'close_session', 'create_dispatch', 'log_decision', 'retire_doc',
      'set_node_summary', 'vision_link', 'vision_set_status', 'vision_true_close', 'vision_unlink', 'vision_upsert', 'write_doc']);
    assert.equal(listed.find((x) => x.name === 'adopt_orphans'), undefined, 'adopt_orphans is not registered');
    assert.ok(listed.every((x) => !('session_id' in (x.inputSchema.properties ?? {}))), 'no tool lists session_id');
  } finally {
    await c.close();
  }
});

test('call log names segment_id as an argument key', async () => {
  const lines: string[] = [];
  const write = process.stderr.write.bind(process.stderr);
  process.stderr.write = ((chunk: string | Uint8Array) => { lines.push(String(chunk)); return true; }) as typeof process.stderr.write;
  const c = await connect(true);
  try {
    await c.call('close_session', { segment_id: A, summary: 's', next_step: 'n', decisions: [] });
  } finally {
    process.stderr.write = write;
    await c.close();
  }
  const line = lines.find((l) => l.includes('tool=close_session'));
  assert.ok(line, 'close_session was logged');
  assert.match(line, /args=\[[^\]]*\bsegment_id\b/);
});

test('decision items accept supersedes and pass it to the decisions JSON unchanged', async () => {
  const c = await connect();
  try {
    const decisions = [{ decision: 'new', supersedes: B }, { decision: 'plain' }];
    const closed = await c.call('close_session', { segment_id: A, summary: 's', next_step: 'n', decisions });
    assert.equal(closed.isError, false, closed.text);
    const close = c.statements.filter((x) => x.text.includes('ops.close_session(')).at(-1);
    assert.deepEqual(JSON.parse(close?.values?.[3] as string), decisions);

    const rebuilt = await c.call('reconstruct_session', {
      node_path: 'global.p', kind: 'planning', occurred_at: NOW, closed_at: NOW, summary: 's', next_step: 'n', decisions,
    });
    assert.equal(rebuilt.isError, false, rebuilt.text);
    const rclose = c.statements.filter((x) => x.text.includes('ops.close_session(')).at(-1);
    assert.deepEqual(JSON.parse(rclose?.values?.[3] as string), decisions);

    const before = c.statements.length;
    const bad = await c.call('close_session', {
      segment_id: A, summary: 's', next_step: 'n', decisions: [{ decision: 'x', supersedes: 'not-a-uuid' }],
    });
    assert.equal(bad.isError, true, 'supersedes must be a uuid');
    assert.equal(c.statements.length, before, 'a refused call reaches no database');
  } finally {
    await c.close();
  }
});
