// Tests for planner id inputs: a full UUID passes through without a lookup; an 8-hex prefix resolves against the
// input's own table to exactly one row before the ops function is called. Also node path inputs: named-notation
// ltree calls, node lookup and subtree checks. No database: tools run on a real McpServer over an in-memory
// transport, against a fake pool that answers prefix and node lookups from fixed rows.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { readFile } from 'node:fs/promises';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerExecutor } from './tools/executor.ts';
import { registerPlanner } from './tools/planner.ts';

const BACKLOG = 'aaaaaaaa-1111-4111-8111-111111111111';
const DISPATCH = 'bbbbbbbb-1111-4111-8111-111111111111';
const TWIN_1 = 'cccccccc-1111-4111-8111-111111111111';
const TWIN_2 = 'cccccccc-2222-4222-8222-222222222222';
const DECISION = 'dddddddd-1111-4111-8111-111111111111';
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const NIL = '00000000-0000-0000-0000-000000000000';
const MAX = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const NOW = '2026-10-09T00:00:00Z';
const NODE = '99999999-1111-4111-8111-111111111111';
const UNKNOWN_NODE = 'global.nope';
const OUTSIDE = TWIN_2;

const tables: Record<string, string[]> = {
  backlog_items: [BACKLOG],
  dispatches: [DISPATCH, TWIN_1, TWIN_2],
  decisions: [DECISION],
  sessions: [SESSION],
};

interface Statement { text: string; values?: unknown[] }
const LOOKUP = /FROM ops\.(\w+) WHERE id::text LIKE \$1 \|\| '%' LIMIT 2/;

function fakePool() {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    const lookup = LOOKUP.exec(text);
    if (lookup) {
      const hits = tables[lookup[1]].filter((id) => id.startsWith(String(values?.[0])));
      return { rows: hits.slice(0, 2).map((id) => ({ id, n: String(hits.length) })) };
    }
    // Node lookup (list_queue / list_backlog / mark_reviewed): every path but UNKNOWN_NODE exists.
    // get_pending: one implementation-class dispatch carrying one context ref.
    if (text.includes('ops.get_pending(')) {
      return { rows: [{ id: DISPATCH, dispatch_type: 'repair', context_refs: ['DOC'] }] };
    }
    if (text.includes('FROM ops.nodes WHERE path')) {
      return { rows: values?.[0] === UNKNOWN_NODE ? [] : [{ id: NODE }] };
    }
    // mark_reviewed's subtree membership check: every id but OUTSIDE is under the node.
    if (text.includes('d.id = ANY($2::uuid[])')) {
      return { rows: (values?.[1] as string[]).filter((id) => id !== OUTSIDE).map((id) => ({ id })) };
    }
    // Migration 0035 is present (create_project / create_component detection).
    if (/to_regprocedure\('ops\.create_(project|component)\(/.test(text)) return { rows: [{ present: true }] };
    return { rows: [{ id: 'x', n: 0, text: 'doc', counts: { decisions: 0, dispatches: 0 } }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(register: (s: McpServer, p: pg.Pool) => void = registerPlanner) {
  const { pool, statements } = fakePool();
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  register(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'idprefix-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const lookups = () => statements.filter((s) => LOOKUP.test(s.text));
  const opCall = (fn: string) => statements.filter((s) => s.text.includes(fn)).at(-1);
  return { client, call, statements, lookups, opCall, close: async () => { await client.close(); await server.close(); } };
}

// Each prefix-accepting input: the call (with the id or prefix placed by put), the table it resolves against,
// the ops function, and where the resolved id lands in that function's bind values.
const inputs: {
  input: string; tool: string; table: string; full: string; fn: string;
  put: (v: string) => Record<string, unknown>; bound: (values: unknown[]) => unknown;
}[] = [
  { input: 'update_backlog_item.id', tool: 'update_backlog_item', table: 'backlog_items', full: BACKLOG,
    fn: 'ops.update_backlog_item(', put: (v) => ({ id: v, status: 'done' }), bound: (x) => x[0] },
  { input: 'cancel_dispatch.id', tool: 'cancel_dispatch', table: 'dispatches', full: DISPATCH,
    fn: 'ops.cancel_dispatch(', put: (v) => ({ id: v, reason: 'r' }), bound: (x) => x[0] },
  { input: 'record_gate.dispatch_id', tool: 'record_gate', table: 'dispatches', full: DISPATCH,
    fn: 'ops.record_gate(', put: (v) => ({ gate_key: 'g', result: 'pass', dispatch_id: v }), bound: (x) => x[2] },
  { input: 'add_backlog_item.source_dispatch_id', tool: 'add_backlog_item', table: 'dispatches', full: DISPATCH,
    fn: 'ops.add_backlog_item(', put: (v) => ({ node_path: 'global.p', title: 't', kind: 'task', source_dispatch_id: v }),
    bound: (x) => x[4] },
  { input: 'log_decision.supersedes', tool: 'log_decision', table: 'decisions', full: DECISION,
    fn: 'ops.log_decision(', put: (v) => ({ node_path: 'global.p', decision: 'd', segment_id: SESSION, supersedes: v }),
    bound: (x) => x[6] },
  { input: 'close_session.decisions[0].supersedes', tool: 'close_session', table: 'decisions', full: DECISION,
    fn: 'ops.close_session(',
    put: (v) => ({ segment_id: SESSION, summary: 's', next_step: 'n', decisions: [{ decision: 'd', supersedes: v }] }),
    bound: (x) => JSON.parse(x[3] as string)[0].supersedes },
  { input: 'reconstruct_session.decisions[0].supersedes', tool: 'reconstruct_session', table: 'decisions', full: DECISION,
    fn: 'ops.close_session(',
    put: (v) => ({ node_path: 'global.p', kind: 'planning', occurred_at: NOW, closed_at: NOW, summary: 's', next_step: 'n',
      decisions: [{ decision: 'd', supersedes: v }] }),
    bound: (x) => JSON.parse(x[3] as string)[0].supersedes },
  { input: 'record_gate.segment_id', tool: 'record_gate', table: 'sessions', full: SESSION,
    fn: 'ops.record_gate(', put: (v) => ({ gate_key: 'g', result: 'pass', segment_id: v }), bound: (x) => x[3] },
  { input: 'create_dispatch.segment_id', tool: 'create_dispatch', table: 'sessions', full: SESSION,
    fn: 'ops.create_dispatch(',
    put: (v) => ({ node_path: 'global.p.core', dispatch_type: 'repair', title: 't', prompt: 'p', segment_id: v }),
    bound: (x) => x[6] },
  { input: 'log_decision.segment_id', tool: 'log_decision', table: 'sessions', full: SESSION,
    fn: 'ops.log_decision(', put: (v) => ({ node_path: 'global.p', decision: 'd', segment_id: v }), bound: (x) => x[7] },
  { input: 'close_session.segment_id', tool: 'close_session', table: 'sessions', full: SESSION,
    fn: 'ops.close_session(', put: (v) => ({ segment_id: v, summary: 's', next_step: 'n', decisions: [] }),
    bound: (x) => x[0] },
];

for (const t of inputs) {
  test(`${t.input}: full UUID passes through, prefix resolves in ${t.table}, unmatched prefix is refused`, async () => {
    const c = await connect();
    try {
      const full = await c.call(t.tool, t.put(t.full));
      assert.equal(full.isError, false, full.text);
      assert.equal(c.lookups().length, 0, 'a full UUID needs no lookup');
      assert.equal(t.bound(c.opCall(t.fn)?.values ?? []), t.full);

      const prefix = t.full.slice(0, 8);
      const resolved = await c.call(t.tool, t.put(prefix.toUpperCase()));
      assert.equal(resolved.isError, false, resolved.text);
      const [lookup] = c.lookups();
      assert.match(lookup.text, new RegExp(`FROM ops\\.${t.table} `), 'resolved against its own table');
      assert.deepEqual(lookup.values, [prefix], 'the prefix is bound lower-cased');
      assert.equal(t.bound(c.opCall(t.fn)?.values ?? []), t.full, 'the ops function gets the full UUID');

      const before = c.statements.filter((s) => s.text.includes(t.fn)).length;
      const missing = await c.call(t.tool, t.put('12345678'));
      assert.equal(missing.isError, true);
      assert.equal(missing.text,
        `MCP error -32602: Input validation error: Invalid arguments for tool ${t.tool}: ${t.input.slice(t.tool.length + 1)}: prefix 12345678 matched 0 rows in ${t.table}`);
      assert.equal(c.statements.filter((s) => s.text.includes(t.fn)).length, before, 'nothing sent to the ops function');
    } finally {
      await c.close();
    }
  });
}

// adopt_orphans.segment_id was a prefix input until the tool was removed (ops.adopt_orphans dropped in 0023).
test('adopt_orphans.segment_id: the tool is not registered; a full UUID or a prefix reaches no database', async () => {
  const c = await connect();
  try {
    const { tools: listed } = await c.client.listTools();
    assert.equal(listed.find((x) => x.name === 'adopt_orphans'), undefined, 'adopt_orphans is not listed');
    for (const segment_id of [SESSION, SESSION.slice(0, 8)]) {
      const r = await c.call('adopt_orphans', { segment_id, from: NOW, to: NOW });
      assert.equal(r.isError, true);
      assert.equal(r.text, 'MCP error -32602: Tool adopt_orphans not found');
    }
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

test('probe ids (all-zeros, all-f) pass through unchanged with no lookup', async () => {
  const c = await connect();
  try {
    for (const id of [NIL, MAX]) {
      const r = await c.call('cancel_dispatch', { id, reason: 'r' });
      assert.equal(r.isError, false, r.text);
      assert.equal(JSON.parse(r.text).id, id);
      assert.equal(c.opCall('ops.cancel_dispatch(')?.values?.[0], id);
    }
    assert.equal(c.lookups().length, 0);
  } finally {
    await c.close();
  }
});

test('a prefix matching several rows is refused with the match count', async () => {
  const c = await connect();
  try {
    const r = await c.call('cancel_dispatch', { id: 'cccccccc', reason: 'r' });
    assert.equal(r.isError, true);
    assert.equal(r.text, 'MCP error -32602: Input validation error: Invalid arguments for tool cancel_dispatch: id: prefix cccccccc matched 2 rows in dispatches');
    assert.equal(c.opCall('ops.cancel_dispatch('), undefined, 'nothing sent to the ops function');
  } finally {
    await c.close();
  }
});

test('a prefix resolves only against its own table', async () => {
  const c = await connect();
  try {
    // aaaaaaaa is a backlog item, not a dispatch.
    const r = await c.call('cancel_dispatch', { id: BACKLOG.slice(0, 8), reason: 'r' });
    assert.equal(r.text, 'MCP error -32602: Input validation error: Invalid arguments for tool cancel_dispatch: id: prefix aaaaaaaa matched 0 rows in dispatches');
  } finally {
    await c.close();
  }
});

test('partial, padded and wrong-length ids are schema errors and reach no database', async () => {
  const c = await connect();
  try {
    for (const id of ['f609e169-0000', 'f609e169-0000-0000-0000-000000000000', 'bbbbbbb', 'bbbbbbbbb', 'bbbbbbbg', '']) {
      const r = await c.call('cancel_dispatch', { id, reason: 'r' });
      assert.equal(r.isError, true, `${JSON.stringify(id)} accepted`);
      assert.match(r.text, /Input validation error: Invalid arguments for tool cancel_dispatch/);
      assert.match(r.text, /expected a full UUID or 8-character id prefix/);
    }
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

test('outputs carry the resolved full UUID in their id / session fields', async () => {
  const c = await connect();
  try {
    const cancelled = await c.call('cancel_dispatch', { id: 'bbbbbbbb', reason: 'r' });
    assert.deepEqual(JSON.parse(cancelled.text), { id: DISPATCH, status: 'cancelled' });
    const closed = await c.call('close_session', { segment_id: 'EEEEEEEE', summary: 's', next_step: 'n', decisions: [] });
    assert.equal(JSON.parse(closed.text).session_id, SESSION);
    const adopted = await c.call('adopt_orphans', { segment_id: 'eeeeeeee', from: NOW, to: NOW });
    assert.equal(adopted.text, 'MCP error -32602: Tool adopt_orphans not found', 'adopt_orphans is not registered');
  } finally {
    await c.close();
  }
});

test('mark_reviewed resolves a mix of full ids and prefixes, de-duplicated after resolution', async () => {
  const c = await connect();
  try {
    const r = await c.call('mark_reviewed', { node_path: 'global.p', ids: [DISPATCH, 'BBBBBBBB', TWIN_1, NIL] });
    assert.equal(r.isError, false, r.text);
    assert.equal(c.lookups().length, 1, 'only the prefix is looked up');
    assert.deepEqual(c.opCall('ops.mark_reviewed(')?.values?.[0], [DISPATCH, TWIN_1, NIL]);
    assert.equal(JSON.parse(r.text).requested, 3);

    const bad = await c.call('mark_reviewed', { node_path: 'global.p', ids: [DISPATCH, 'cccccccc'] });
    assert.equal(bad.text, 'MCP error -32602: Input validation error: Invalid arguments for tool mark_reviewed: ids[1]: prefix cccccccc matched 2 rows in dispatches');
  } finally {
    await c.close();
  }
});

test('tools/list: every prefix-accepting input says so', async () => {
  const c = await connect();
  try {
    const { tools: listed } = await c.client.listTools();
    const prop = (tool: string, name: string) =>
      (listed.find((x) => x.name === tool)?.inputSchema.properties ?? {})[name] as { description?: string; items?: { description?: string } };
    const fields: [string, string][] = [
      ['update_backlog_item', 'id'], ['cancel_dispatch', 'id'], ['record_gate', 'dispatch_id'], ['record_gate', 'segment_id'],
      ['add_backlog_item', 'source_dispatch_id'], ['log_decision', 'supersedes'], ['log_decision', 'segment_id'],
      ['create_dispatch', 'segment_id'], ['close_session', 'segment_id'],
      ['write_doc', 'segment_id'], ['approve_doc', 'segment_id'], ['retire_doc', 'segment_id'],
    ];
    for (const [tool, name] of fields) {
      assert.equal(prop(tool, name)?.description, 'full UUID or 8-character id prefix', `${tool}.${name}`);
    }
    assert.equal(prop('mark_reviewed', 'ids')?.items?.description, 'full UUID or 8-character id prefix');
    assert.equal(prop('write_doc', 'decision_ids')?.items?.description, 'full UUID or 8-character id prefix');
    assert.equal(prop('write_doc', 'dispatch_ids')?.items?.description, 'full UUID or 8-character id prefix');
    for (const tool of ['update_backlog_item', 'cancel_dispatch', 'record_gate', 'add_backlog_item', 'log_decision',
      'create_dispatch', 'close_session', 'mark_reviewed', 'reconstruct_session']) {
      assert.match(listed.find((x) => x.name === tool)?.description ?? '', /full UUID or 8-character id prefix/, tool);
    }
    assert.equal(listed.find((x) => x.name === 'adopt_orphans'), undefined, 'adopt_orphans is not registered');
  } finally {
    await c.close();
  }
});

// query and record_gate are planner-only (fdca7d0f): the executor neither lists nor runs them.
test('executor: query and record_gate are not registered; calling them reaches no database', async () => {
  const c = await connect(registerExecutor);
  try {
    const { tools: listed } = await c.client.listTools();
    for (const name of ['query', 'record_gate']) {
      assert.equal(listed.find((x) => x.name === name), undefined, `${name} is not listed`);
    }
    const q = await c.call('query', { sql: 'SELECT 1' });
    assert.equal(q.isError, true);
    assert.equal(q.text, 'MCP error -32602: Tool query not found');
    const g = await c.call('record_gate', { gate_key: 'g', result: 'pass', dispatch_id: DISPATCH, segment_id: SESSION });
    assert.equal(g.isError, true);
    assert.equal(g.text, 'MCP error -32602: Tool record_gate not found');
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

// Node-keyed tools: the path goes first, in named notation, cast to public.ltree (a convention that keeps each call
// explicit; the project-keyed overloads it once disambiguated from were dropped in 0021).
const nodeCalls: { tool: string; args: Record<string, unknown>; fn: string; param: string; executor?: boolean }[] = [
  { tool: 'open_session', args: { node_path: 'global.p', kind: 'planning' }, fn: 'ops.open_session(', param: 'p_node_path' },
  { tool: 'reconstruct_session', fn: 'ops.open_session(', param: 'p_node_path',
    args: { node_path: 'global.p.core', kind: 'execution', occurred_at: NOW, closed_at: NOW, summary: 's', next_step: 'n' } },
  { tool: 'get_unreviewed_reports', args: { node_path: 'global.p' }, fn: 'ops.get_unreviewed_reports(', param: 'p_node_path' },
  { tool: 'resolve_context', args: { node_path: 'global.p.core', ref: 'DOC' }, fn: 'ops.resolve_context(', param: 'p_node_path' },
  { tool: 'create_dispatch', fn: 'ops.create_dispatch(', param: 'p_node_path',
    args: { node_path: 'global.p.core', dispatch_type: 'repair', title: 't', prompt: 'p', segment_id: SESSION } },
  { tool: 'log_decision', args: { node_path: 'global.p', decision: 'd', segment_id: SESSION }, fn: 'ops.log_decision(',
    param: 'p_node_path' },
  { tool: 'add_backlog_item', args: { node_path: 'global.p.core', title: 't', kind: 'task' }, fn: 'ops.add_backlog_item(',
    param: 'p_node_path' },
  { tool: 'create_project', args: { parent_path: 'global', key: 'k', name: 'n', summary: 'it' }, fn: 'ops.create_project(',
    param: 'p_parent_path' },
  { tool: 'create_component', args: { parent_path: 'global.p', key: 'k', kind: 'service', repo_ref: 'r', summary: 'it' },
    fn: 'ops.create_component(', param: 'p_parent_path' },
  { tool: 'get_pending', args: { node_path: 'global.p.core' }, fn: 'ops.get_pending(', param: 'p_node_path', executor: true },
  { tool: 'resolve_context', args: { node_path: 'global.p.core', ref: 'DOC' }, fn: 'ops.resolve_context(',
    param: 'p_node_path', executor: true },
];

for (const t of nodeCalls) {
  test(`${t.executor ? 'executor' : 'planner'} ${t.tool}: ${t.fn.slice(0, -1)} gets the path as ${t.param} => $1::public.ltree`, async () => {
    const c = await connect(t.executor ? registerExecutor : registerPlanner);
    try {
      const r = await c.call(t.tool, t.args);
      assert.equal(r.isError, false, r.text);
      const s = c.opCall(t.fn);
      assert.ok(s, `${t.tool} called ${t.fn}`);
      assert.match(s.text, new RegExp(`${t.fn.replace('(', '\\(')}\\s*${t.param} => \\$1::public\\.ltree`));
      assert.equal(s.values?.[0], t.args.node_path ?? t.args.parent_path);
    } finally {
      await c.close();
    }
  });
}

test("executor: get_pending reads the caps of the path's depth-2 project; claim_dispatch resolves refs at that path", async () => {
  const c = await connect(registerExecutor);
  try {
    const pending = await c.call('get_pending', { node_path: 'global.p.core' });
    assert.equal(pending.isError, false, pending.text);
    const caps = c.statements.find((s) => s.text.includes('FROM ops.projects p JOIN ops.nodes n'));
    assert.ok(caps, 'caps read through the project node');
    assert.match(caps.text, /public\.subpath\(\$1::public\.ltree, 0, least\(2, public\.nlevel\(\$1::public\.ltree\)\)\)/);
    assert.deepEqual(caps.values, ['global.p.core']);
    assert.deepEqual(JSON.parse(pending.text).caps, { implementation_max: 3, investigation_max: 1 }, 'no project: protocol defaults');

    const claimed = await c.call('claim_dispatch', { id: DISPATCH });
    assert.equal(claimed.isError, false, claimed.text);
    const resolve = c.opCall('ops.resolve_context(');
    assert.match(resolve?.text ?? '', /ops\.resolve_context\(p_node_path => \$1::public\.ltree, p_ref => \$2\)/);
    assert.deepEqual(resolve?.values, ['global.p.core', 'DOC']);
  } finally {
    await c.close();
  }
});

// get_pending by id on its own server and pool: ops.get_pending returns pending (an investigation at the head, then
// implementation rows), dispatch_types gives each class, and the cap is high enough that earlier claims never reach it.
const BY_ID_INV = 'a1a1a1a1-cccc-4ccc-8ccc-a1a1a1a1a1a1';
const BY_ID_IMPL_1 = 'b2b2b2b2-cccc-4ccc-8ccc-b2b2b2b2b2b2';
const BY_ID_IMPL_2 = 'c3c3c3c3-cccc-4ccc-8ccc-c3c3c3c3c3c3';

async function pendingHarness(pending: { id: string; dispatch_type: string }[]) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text.includes('ops.get_pending(')) return { rows: pending.map((r) => ({ ...r, context_refs: [] })) };
    if (text.includes("key = 'batch_defaults'")) return { rows: [{ value: { implementation_max: 100, investigation_max: 1 } }] };
    if (text.includes('SELECT type, commit_policy FROM ops.dispatch_types')) {
      return { rows: [{ type: 'investigation', commit_policy: 'none' }, { type: 'repair', commit_policy: 'local' }] };
    }
    return { rows: [] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerExecutor(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'pending-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  return { call, statements, close: async () => { await client.close(); await server.close(); } };
}

const QUEUE = [
  { id: BY_ID_INV, dispatch_type: 'investigation' },
  { id: BY_ID_IMPL_1, dispatch_type: 'repair' },
  { id: BY_ID_IMPL_2, dispatch_type: 'repair' },
];

test('executor get_pending: without id the head batch is unchanged (the investigation only)', async () => {
  const c = await pendingHarness(QUEUE);
  try {
    const r = await c.call('get_pending', { node_path: 'global.p.core' });
    assert.equal(r.isError, false, r.text);
    const out = JSON.parse(r.text);
    assert.deepEqual(Object.keys(out), ['batch_class', 'caps', 'claimed_this_process', 'run_class', 'pending_total',
      'returned', 'remaining_pending', 'rows']);
    assert.equal(out.batch_class, 'investigation');
    assert.deepEqual(out.rows.map((x: { id: string }) => x.id), [BY_ID_INV]);
    assert.equal(out.pending_total, 3);
    assert.equal(out.remaining_pending, 2);
  } finally {
    await c.close();
  }
});

test('executor get_pending: an id8 behind the head batch returns that row only, and claim_dispatch takes it', async () => {
  const c = await pendingHarness(QUEUE);
  try {
    const r = await c.call('get_pending', { node_path: 'global.p.core', id: BY_ID_IMPL_2.slice(0, 8).toUpperCase() });
    assert.equal(r.isError, false, r.text);
    const out = JSON.parse(r.text);
    assert.deepEqual(Object.keys(out), ['batch_class', 'caps', 'claimed_this_process', 'run_class', 'pending_total',
      'returned', 'remaining_pending', 'rows', 'selected_by_id']);
    assert.equal(out.batch_class, 'implementation');
    assert.deepEqual(out.rows.map((x: { id: string }) => x.id), [BY_ID_IMPL_2]);
    assert.equal(out.returned, 1);
    assert.equal(out.pending_total, 3);
    assert.equal(out.remaining_pending, 2);
    assert.equal(out.selected_by_id, true);

    const claimed = await c.call('claim_dispatch', { id: BY_ID_IMPL_2 });
    assert.equal(claimed.isError, false, claimed.text);
    assert.deepEqual(c.statements.find((s) => s.text.includes('ops.claim_dispatch('))?.values?.[0], BY_ID_IMPL_2);
  } finally {
    await c.close();
  }
});

test('executor get_pending: a full UUID selects the same way', async () => {
  const c = await pendingHarness(QUEUE);
  try {
    const out = JSON.parse((await c.call('get_pending', { node_path: 'global.p.core', id: BY_ID_IMPL_2 })).text);
    assert.equal(out.batch_class, 'implementation');
    assert.deepEqual(out.rows.map((x: { id: string }) => x.id), [BY_ID_IMPL_2]);
    assert.equal(out.returned, 1);
    assert.equal(out.remaining_pending, 2);
    assert.equal(out.selected_by_id, true);
  } finally {
    await c.close();
  }
});

test('executor get_pending: an unknown id8 returns no rows with a note, not an error; nothing is cached', async () => {
  const c = await pendingHarness(QUEUE);
  try {
    const r = await c.call('get_pending', { node_path: 'global.p.core', id: 'd4d4d4d4' });
    assert.equal(r.isError, false, r.text);
    const out = JSON.parse(r.text);
    assert.equal(out.batch_class, null);
    assert.deepEqual(out.rows, []);
    assert.equal(out.returned, 0);
    assert.equal(out.selected_by_id, true);
    assert.equal(out.note, 'no pending dispatch at global.p.core matches d4d4d4d4');
    const claim = await c.call('claim_dispatch', { id: 'd4d4d4d4-cccc-4ccc-8ccc-d4d4d4d4d4d4' });
    assert.equal(claim.text, 'dispatch d4d4d4d4-cccc-4ccc-8ccc-d4d4d4d4d4d4 was not returned by get_pending in this process');
  } finally {
    await c.close();
  }
});

test('executor get_pending: a prefix shared by two pending rows is refused with the count', async () => {
  const c = await pendingHarness([
    { id: 'e5e5e5e5-1111-4111-8111-111111111111', dispatch_type: 'repair' },
    { id: 'e5e5e5e5-2222-4222-8222-222222222222', dispatch_type: 'repair' },
  ]);
  try {
    const r = await c.call('get_pending', { node_path: 'global.p.core', id: 'e5e5e5e5' });
    assert.equal(r.isError, true);
    assert.equal(r.text, 'id prefix e5e5e5e5 matches 2 pending dispatches at global.p.core; pass the full id');
  } finally {
    await c.close();
  }
});

test('executor get_pending: a malformed id is a schema error and reaches no database', async () => {
  const c = await pendingHarness(QUEUE);
  try {
    for (const id of ['b2b2b2b', 'zzzzzzzz', 'b2b2b2b2c', ' b2b2b2b2']) {
      const r = await c.call('get_pending', { node_path: 'global.p.core', id });
      assert.equal(r.isError, true, `${JSON.stringify(id)} accepted`);
      assert.match(r.text, /Input validation error: Invalid arguments for tool get_pending/);
    }
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

test('list_queue / list_backlog / mark_reviewed: an unknown node_path is refused before any other statement', async () => {
  const c = await connect();
  try {
    for (const [tool, args] of [['list_queue', {}], ['list_backlog', {}], ['mark_reviewed', { ids: [DISPATCH] }]] as const) {
      const before = c.statements.length;
      const r = await c.call(tool, { node_path: UNKNOWN_NODE, ...args });
      assert.equal(r.isError, true, `${tool}: ${r.text}`);
      assert.equal(r.text, `unknown node ${UNKNOWN_NODE}`);
      const after = c.statements.slice(before).filter((s) => !/^(BEGIN|COMMIT|ROLLBACK)$/.test(s.text));
      assert.equal(after.length, 1, `${tool}: only the node lookup ran`);
      assert.match(after[0].text, /FROM ops\.nodes WHERE path OPERATOR\(public\.=\) \$1::public\.ltree/);
    }
  } finally {
    await c.close();
  }
});

test('list_queue / list_backlog scope to the node subtree; mark_reviewed refuses an id outside it', async () => {
  const c = await connect();
  try {
    for (const tool of ['list_queue', 'list_backlog']) {
      const r = await c.call(tool, { node_path: 'global.p' });
      assert.equal(r.isError, false, r.text);
      const s = c.statements.at(-1);
      assert.match(s?.text ?? '', /\.path OPERATOR\(public\.<@\) root\.path/, `${tool} filters on the subtree`);
      assert.equal(s?.values?.[0], NODE, `${tool} binds the looked-up node`);
    }

    const r = await c.call('mark_reviewed', { node_path: 'global.p', ids: [DISPATCH, OUTSIDE] });
    assert.equal(r.isError, true);
    assert.equal(r.text, `not dispatches under node global.p: ${OUTSIDE}`);
    assert.equal(c.opCall('ops.mark_reviewed('), undefined, 'nothing sent to the ops function');
  } finally {
    await c.close();
  }
});

test('tools/list: no tool takes a *_key node input; node_path / parent_path are required paths', async () => {
  const pathTools: Record<string, string[]> = {
    planner: ['open_session', 'get_unreviewed_reports', 'mark_reviewed', 'list_queue', 'list_backlog', 'create_dispatch',
      'log_decision', 'add_backlog_item', 'reconstruct_session', 'resolve_context', 'approve_doc', 'retire_doc', 'write_doc',
      'get_decisions', 'set_node_summary'],
    executor: ['get_pending', 'resolve_context'],
  };
  for (const role of ['planner', 'executor'] as const) {
    const c = await connect(role === 'planner' ? registerPlanner : registerExecutor);
    try {
      const { tools: listed } = await c.client.listTools();
      const keyed = listed.flatMap((x) => Object.keys(x.inputSchema.properties ?? {}).filter((p) => p.endsWith('_key')));
      assert.deepEqual([...new Set(keyed)].sort(), role === 'planner' ? ['doc_key', 'gate_key'] : [],
        role === 'planner' ? "planner: only record_gate's gate_key and the docs tools' doc_key end in _key" : 'executor: no input ends in _key');
      const parented = role === 'planner' ? ['create_component', 'create_project'] : [];
      for (const [name, prop] of [...pathTools[role].map((n) => [n, 'node_path']), ...parented.map((n) => [n, 'parent_path'])]) {
        const schema = listed.find((x) => x.name === name)?.inputSchema as
          { properties: Record<string, { pattern?: string; description?: string }>; required?: string[] };
        assert.ok(schema, `${role} ${name} registered`);
        assert.ok(schema.required?.includes(prop), `${name}.${prop} required`);
        assert.equal(schema.properties[prop].pattern, '^[a-z0-9][a-z0-9_-]*(\\.[a-z0-9][a-z0-9_-]*)*$');
        assert.equal(schema.properties[prop].description, 'node path such as global.local-ops.core');
      }
      const withPath = listed.filter((x) => 'node_path' in (x.inputSchema.properties ?? {})).map((x) => x.name).sort();
      assert.deepEqual(withPath, [...pathTools[role]].sort(), `${role}: exactly these tools take node_path`);
    } finally {
      await c.close();
    }
  }
});

test('a malformed node path is a schema error and reaches no database', async () => {
  const c = await connect();
  try {
    for (const node_path of ['', 'Global', 'global..p', '.global', 'global.', 'global/p', '-global']) {
      const r = await c.call('list_queue', { node_path });
      assert.equal(r.isError, true, `${JSON.stringify(node_path)} accepted`);
      assert.match(r.text, /Input validation error: Invalid arguments for tool list_queue/);
    }
    assert.equal(c.statements.length, 0);
  } finally {
    await c.close();
  }
});

// claim_dispatch on its own server and pool: get_pending returns id (with a cap high enough that earlier claims in
// this process never reach it), and ops.claim_dispatch either succeeds or raises claimError.
async function claimHarness(clientName: string, id: string, claimError?: Error) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text.includes('ops.get_pending(')) return { rows: [{ id, dispatch_type: 'repair', context_refs: [] }] };
    if (text.includes("key = 'batch_defaults'")) return { rows: [{ value: { implementation_max: 100, investigation_max: 1 } }] };
    if (text.includes('ops.claim_dispatch(') && claimError) throw claimError;
    return { rows: [] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerExecutor(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: clientName, version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  return { call, statements, close: async () => { await client.close(); await server.close(); } };
}

const CLAIMED_BY = (name: string) => new RegExp(`^${name}:${process.pid}:\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$`);

for (const [clientName, prefix, id] of [
  ['claim-test-client', 'claim-test-client', '11111111-aaaa-4aaa-8aaa-111111111111'],
  ['  ', 'unknown', '22222222-aaaa-4aaa-8aaa-222222222222'],
] as const) {
  test(`executor claim_dispatch: claimed_by is ${prefix}:<pid>:<server start> for clientInfo.name ${JSON.stringify(clientName)}`, async () => {
    const c = await claimHarness(clientName, id);
    try {
      assert.equal((await c.call('get_pending', { node_path: 'global.p.core' })).isError, false);
      const r = await c.call('claim_dispatch', { id });
      assert.equal(r.isError, false, r.text);
      const claim = c.statements.find((s) => s.text.includes('ops.claim_dispatch('));
      const passed = claim?.values?.[1] as string;
      assert.deepEqual(claim?.values, [id, passed]);
      assert.match(passed, CLAIMED_BY(prefix));
      const out = JSON.parse(r.text);
      assert.equal(out.claimed_by, passed, 'claimed_by is what ops.claim_dispatch got');
      assert.equal(out.dispatch.claimed_by, passed, 'dispatch.claimed_by is what ops.claim_dispatch got');
    } finally {
      await c.close();
    }
  });
}

// LOCAL_OPS_AUTORUN=1 (set by mcp/autorun.mcp.json for watcher launches) prefixes 'autorun:'; unset or '0' leaves
// claimed_by unchanged.
for (const [value, id] of [
  ['1', '44444444-aaaa-4aaa-8aaa-444444444444'],
  [undefined, '55555555-aaaa-4aaa-8aaa-555555555555'],
  ['0', '66666666-aaaa-4aaa-8aaa-666666666666'],
] as const) {
  test(`executor claim_dispatch: LOCAL_OPS_AUTORUN=${value ?? '(unset)'} gives claimed_by ${value === '1' ? 'autorun:' : ''}<name>:<pid>:<server start>`, async () => {
    const saved = process.env.LOCAL_OPS_AUTORUN;
    const c = await claimHarness('claim-test-client', id);
    try {
      if (value === undefined) delete process.env.LOCAL_OPS_AUTORUN; else process.env.LOCAL_OPS_AUTORUN = value;
      assert.equal((await c.call('get_pending', { node_path: 'global.p.core' })).isError, false);
      const r = await c.call('claim_dispatch', { id });
      assert.equal(r.isError, false, r.text);
      const passed = c.statements.find((s) => s.text.includes('ops.claim_dispatch('))?.values?.[1] as string;
      assert.match(passed, CLAIMED_BY(value === '1' ? 'autorun:claim-test-client' : 'claim-test-client'));
      assert.equal(JSON.parse(r.text).claimed_by, passed);
    } finally {
      if (saved === undefined) delete process.env.LOCAL_OPS_AUTORUN; else process.env.LOCAL_OPS_AUTORUN = saved;
      await c.close();
    }
  });
}

test('mcp/autorun.mcp.json: exactly one server, local_ops, the executor with LOCAL_OPS_AUTORUN=1', async () => {
  const cfg = JSON.parse(await readFile(new URL('../autorun.mcp.json', import.meta.url), 'utf8'));
  assert.deepEqual(Object.keys(cfg.mcpServers), ['local_ops']);
  assert.deepEqual(cfg.mcpServers.local_ops,
    { command: 'node', args: ['mcp/src/server.ts', '--role', 'executor'], env: { LOCAL_OPS_AUTORUN: '1' } });
});

test('executor claim_dispatch: a 23514 refusal is a clear error and uses no batch slot; other errors pass through', async () => {
  const refusal = new pg.DatabaseError(
    'promote dispatch 33333333-aaaa-4aaa-8aaa-333333333333 has no current prod_apply_approved pass recorded after its creation; it stays pending',
    0, 'error');
  refusal.code = '23514';
  const id = '33333333-aaaa-4aaa-8aaa-333333333333';
  const c = await claimHarness('claim-test-client', id, refusal);
  try {
    const before = JSON.parse((await c.call('get_pending', { node_path: 'global.p.core' })).text).claimed_this_process;
    const r = await c.call('claim_dispatch', { id });
    assert.equal(r.isError, true);
    assert.equal(r.text, `the database refused the claim of dispatch ${id}: nothing was claimed and no batch slot was used `
      + `(${before}/100 claims this run). Validation error (23514): ${refusal.message}`);
    const after = JSON.parse((await c.call('get_pending', { node_path: 'global.p.core' })).text).claimed_this_process;
    assert.equal(after, before, 'claim count unchanged');
    const done = await c.call('complete_dispatch', { id, result: 'r', report: 'r' });
    assert.equal(done.text, `dispatch ${id} was not claimed by this process`);
  } finally {
    await c.close();
  }

  const other = new pg.DatabaseError(`dispatch ${id} is not pending`, 0, 'error');
  other.code = 'P0001';
  const o = await claimHarness('claim-test-client', id, other);
  try {
    await o.call('get_pending', { node_path: 'global.p.core' });
    const r = await o.call('claim_dispatch', { id });
    assert.equal(r.isError, true);
    assert.equal(r.text, `Postgres error P0001: dispatch ${id} is not pending`, 'unchanged');
  } finally {
    await o.close();
  }
});
