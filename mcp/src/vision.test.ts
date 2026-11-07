// Tests for the vision tools (tools/vision.ts) and the vision inputs of create_dispatch / log_decision /
// add_backlog_item: call-time detection of migration 0032 (absent: vision tools refuse and send nothing else, the
// three writers send today's statements; present: the writer and ops.vision_link run in one transaction), and
// prefix resolution of link refs by kind. No database: tools run on a real McpServer over an in-memory transport,
// against a fake pool that answers detection, prefix lookups and the ops functions from fixed rows.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerPlanner } from './tools/planner.ts';
import { VISION_MISSING } from './tools/vision.ts';

const BACKLOG = 'aaaaaaaa-1111-4111-8111-111111111111';
const DISPATCH = 'bbbbbbbb-1111-4111-8111-111111111111';
const DECISION = 'dddddddd-1111-4111-8111-111111111111';
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const NEW = 'f0f0f0f0-1111-4111-8111-111111111111';

const tables: Record<string, string[]> = {
  backlog_items: [BACKLOG], dispatches: [DISPATCH], decisions: [DECISION], sessions: [SESSION],
};

interface Statement { text: string; values?: unknown[] }
const LOOKUP = /FROM ops\.(\w+) WHERE id::text LIKE \$1 \|\| '%' LIMIT 2/;
const DETECT = /^SELECT to_reg(procedure|class)\('[^']+'\) IS NOT NULL AS present$/;
const TX = /^(BEGIN|COMMIT|ROLLBACK)$/;

// present: what detection answers. linkError: raised by ops.vision_link.
function fakePool(present: boolean, linkError?: Error) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (DETECT.test(text)) return { rows: [{ present }] };
    const lookup = LOOKUP.exec(text);
    if (lookup) {
      const hits = tables[lookup[1]].filter((id) => id.startsWith(String(values?.[0])));
      return { rows: hits.slice(0, 2).map((id) => ({ id, n: String(hits.length) })) };
    }
    if (text.includes('ops.vision_link(') && linkError) throw linkError;
    if (text.includes('ops.vision_link(')) return { rows: [{ r: { linked: 1, updated: 0 } }] };
    return { rows: [{ id: NEW, n: 0, r: {}, changed: true, source: 'kind:task' }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(present: boolean, linkError?: Error) {
  const { pool, statements } = fakePool(present, linkError);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'vision-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  // Statements other than detection.
  const sent = () => statements.filter((s) => !DETECT.test(s.text));
  return { client, call, statements, sent, close: async () => { await client.close(); await server.close(); } };
}

const visionCalls: [string, Record<string, unknown>][] = [
  ['vision_upsert', { items: [{ key: 'a' }], segment_id: SESSION }],
  ['vision_link', { links: [{ item_key: 'a', kind: 'decision', ref: DECISION, relation: 'defines' }], segment_id: SESSION }],
  ['vision_unlink', { links: [{ item_key: 'a', kind: 'decision', ref: DECISION }], segment_id: SESSION }],
  ['vision_set_status', { key: 'a', status: 'designed', reason: 'r', segment_id: SESSION }],
  ['vision_true_close', { key: 'a', evidence: 'e', segment_id: SESSION }],
  ['vision_check', {}],
  ['vision_status', {}],
  ['vision_status', { under: 'a' }],
];

for (const [name, args] of visionCalls) {
  test(`0032 absent: ${name} ${JSON.stringify(args).slice(0, 40)} refuses after detection alone`, async () => {
    const c = await connect(false);
    try {
      const r = await c.call(name, args);
      assert.equal(r.isError, true);
      assert.equal(r.text, VISION_MISSING);
      assert.equal(c.statements.length, 1, 'only the detection query ran');
      assert.match(c.statements[0].text, DETECT);
    } finally {
      await c.close();
    }
  });
}

test('0032 present: each vision tool calls its ops function or view', async () => {
  const c = await connect(true);
  try {
    const fns = ['ops.vision_upsert(', 'ops.vision_link(', 'ops.vision_unlink(', 'ops.vision_set_status(',
      'ops.vision_true_close(', 'ops.vision_check()', 'FROM ops.vision_status ORDER BY key', 'WITH RECURSIVE'];
    for (const [i, [name, args]] of visionCalls.entries()) {
      const before = c.statements.length;
      const r = await c.call(name, args);
      assert.equal(r.isError, false, `${name}: ${r.text}`);
      const after = c.statements.slice(before);
      assert.match(after[0].text, DETECT, `${name} detects first`);
      assert.ok(after.slice(1).some((s) => !DETECT.test(s.text) && s.text.includes(fns[i])), `${name} sent ${fns[i]}`);
    }
    const session = c.sent().find((s) => s.text.includes('ops.vision_set_status('));
    assert.deepEqual(session?.values, ['a', 'designed', 'r', SESSION, null]);
  } finally {
    await c.close();
  }
});

const base = { node_path: 'global.p.core', dispatch_type: 'repair', title: 't', prompt: 'p', segment_id: SESSION };
const writers: [string, Record<string, unknown>, Record<string, unknown>][] = [
  ['create_dispatch', base, { vision_item: 'a' }],
  ['create_dispatch', base, { vision_none_reason: 'n' }],
  ['log_decision', { node_path: 'global.p', decision: 'd', segment_id: SESSION }, { vision_item: 'a', vision_relation: 'defines' }],
  ['add_backlog_item', { node_path: 'global.p', title: 't', kind: 'task' },
    { vision_item: 'a', vision_role: 'blocks', segment_id: SESSION }],
];

for (const [name, args, vision] of writers) {
  test(`0032 absent: ${name} with ${Object.keys(vision).join(', ')} sends today's statements, no transaction`, async () => {
    const plain = await connect(false);
    const linked = await connect(false);
    try {
      const p = await plain.call(name, args);
      const l = await linked.call(name, { ...args, ...vision });
      assert.equal(p.isError, false, p.text);
      assert.equal(l.isError, false, l.text);
      assert.deepEqual(linked.sent(), plain.sent(), 'same statements as a call without vision inputs');
      assert.equal(l.text, p.text, 'same result');
      assert.ok(linked.sent().every((s) => !TX.test(s.text) && !s.text.includes('ops.vision_')));
      assert.ok(linked.sent().some((s) => s.text.includes(`ops.${name}(`)));
    } finally {
      await plain.close();
      await linked.close();
    }
  });
}

test('0032 present: create_dispatch without a vision input or with both is refused before any statement', async () => {
  const c = await connect(true);
  try {
    for (const extra of [{}, { vision_item: 'a', vision_none_reason: 'n' }]) {
      const before = c.statements.length;
      const r = await c.call('create_dispatch', { ...base, ...extra });
      assert.equal(r.isError, true);
      assert.equal(r.text, 'MCP error -32602: Input validation error: Invalid arguments for tool create_dispatch: '
        + 'exactly one of vision_item and vision_none_reason is required');
      const after = c.statements.slice(before);
      assert.equal(after.length, 1, 'only detection');
      assert.match(after[0].text, DETECT);
    }
    const blank = await c.call('create_dispatch', { ...base, vision_none_reason: '  ' });
    assert.equal(blank.isError, true, 'a blank none reason is a schema error');
    assert.match(blank.text, /must not be blank/);
  } finally {
    await c.close();
  }
});

for (const [name, args, vision] of writers) {
  test(`0032 present: ${name} with ${Object.keys(vision).join(', ')} writes then links inside BEGIN..COMMIT`, async () => {
    const c = await connect(true);
    try {
      const r = await c.call(name, { ...args, ...vision });
      assert.equal(r.isError, false, r.text);
      const seq = c.sent().filter((s) => TX.test(s.text) || s.text.includes('ops.'));
      assert.deepEqual(seq.map((s) => (TX.test(s.text) ? s.text : s.text.match(/ops\.\w+\(/)?.[0])),
        ['BEGIN', `ops.${name}(`, 'ops.vision_link(', 'COMMIT']);
      const link = seq[2];
      const kind = { create_dispatch: 'dispatch', log_decision: 'decision', add_backlog_item: 'backlog' }[name];
      const expected: Record<string, unknown> = { kind, ref: NEW };
      if ('vision_item' in vision) expected.item_key = vision.vision_item;
      if ('vision_none_reason' in vision) expected.none_reason = vision.vision_none_reason;
      if ('vision_relation' in vision) expected.relation = vision.vision_relation;
      if ('vision_role' in vision) expected.role = vision.vision_role;
      assert.deepEqual(JSON.parse(link.values?.[0] as string), [expected]);
      assert.equal(link.values?.[1], SESSION, 'the same session');
      assert.equal(JSON.parse(r.text).id, NEW, 'the result is the written row');
    } finally {
      await c.close();
    }
  });
}

test('0032 present: a refused vision_link rolls back the write and surfaces the database message', async () => {
  const refusal = new pg.DatabaseError('vision_link element 1: vision item nope does not exist', 0, 'error');
  refusal.code = '23514';
  const c = await connect(true, refusal);
  try {
    const r = await c.call('create_dispatch', { ...base, vision_item: 'nope' });
    assert.equal(r.isError, true);
    assert.equal(r.text, `Validation error (23514): ${refusal.message}`);
    const tx = c.sent().filter((s) => TX.test(s.text)).map((s) => s.text);
    assert.deepEqual(tx, ['BEGIN', 'ROLLBACK']);
  } finally {
    await c.close();
  }
});

test('log_decision / add_backlog_item: vision inputs come in pairs; add_backlog_item needs segment_id with them', async () => {
  for (const present of [false, true]) {
    const c = await connect(present);
    try {
      const refusals: [string, Record<string, unknown>, string][] = [
        ['log_decision', { ...writers[2][1], vision_item: 'a' }, 'vision_item and vision_relation are given together or not at all'],
        ['log_decision', { ...writers[2][1], vision_relation: 'defines' }, 'vision_item and vision_relation are given together or not at all'],
        ['add_backlog_item', { ...writers[3][1], vision_role: 'blocks' }, 'vision_item and vision_role are given together or not at all'],
        ['add_backlog_item', { ...writers[3][1], vision_item: 'a', vision_role: 'blocks' }, 'segment_id is required with vision_item'],
      ];
      for (const [name, args, message] of refusals) {
        const before = c.statements.length;
        const r = await c.call(name, args);
        assert.equal(r.text, `MCP error -32602: Input validation error: Invalid arguments for tool ${name}: ${message}`);
        assert.equal(c.statements.length, before, 'nothing sent');
      }
    } finally {
      await c.close();
    }
  }
});

const refs: [string, string, string][] = [['decision', DECISION, 'decisions'], ['backlog', BACKLOG, 'backlog_items'],
  ['dispatch', DISPATCH, 'dispatches']];

for (const name of ['vision_link', 'vision_unlink']) {
  test(`${name}: each ref resolves by its kind's table; an unmatched prefix is refused before the ops call`, async () => {
    const c = await connect(true);
    try {
      const links = refs.map(([kind, id]) => ({ item_key: 'a', kind, ref: id.slice(0, 8).toUpperCase() }));
      const r = await c.call(name, { links, segment_id: SESSION });
      assert.equal(r.isError, false, r.text);
      const lookups = c.statements.filter((s) => LOOKUP.test(s.text));
      assert.deepEqual(lookups.map((s) => [LOOKUP.exec(s.text)?.[1], s.values?.[0]]),
        refs.map(([, id, table]) => [table, id.slice(0, 8)]));
      const op = c.sent().find((s) => s.text.includes(`ops.${name}(`));
      assert.deepEqual(JSON.parse(op?.values?.[0] as string).map((l: { ref: string }) => l.ref), refs.map(([, id]) => id));

      const before = c.sent().filter((s) => s.text.includes(`ops.${name}(`)).length;
      const bad = await c.call(name, { links: [{ item_key: 'a', kind: 'decision', ref: BACKLOG.slice(0, 8) }], segment_id: SESSION });
      assert.equal(bad.text, `MCP error -32602: Input validation error: Invalid arguments for tool ${name}: `
        + 'links[0].ref: prefix aaaaaaaa matched 0 rows in decisions');
      assert.equal(c.sent().filter((s) => s.text.includes(`ops.${name}(`)).length, before, 'nothing sent');
    } finally {
      await c.close();
    }
  });
}

test('tools/list: vision tools take no node_path and no top-level *_key input; true close names the operator yes', async () => {
  const c = await connect(true);
  try {
    const { tools: listed } = await c.client.listTools();
    const vision = listed.filter((x) => x.name.startsWith('vision_'));
    assert.deepEqual(vision.map((x) => x.name).sort(), ['vision_check', 'vision_link', 'vision_set_status', 'vision_status',
      'vision_true_close', 'vision_unlink', 'vision_upsert']);
    for (const t of vision) {
      const props = Object.keys(t.inputSchema.properties ?? {});
      assert.ok(!props.includes('node_path'), t.name);
      assert.deepEqual(props.filter((p) => p.endsWith('_key')), [], t.name);
    }
    assert.match(listed.find((x) => x.name === 'vision_true_close')?.description ?? '', /operator's explicit yes/);
  } finally {
    await c.close();
  }
});
