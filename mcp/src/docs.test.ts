// Tests for the context-document tools (tools/docs.ts): call-time detection of migration 0033 (absent: each tool
// refuses and sends nothing else), prefix resolution of decision_ids / dispatch_ids / segment_id before the ops call,
// and input validation refused before any query. No database: tools run on a real McpServer over an in-memory
// transport, against a fake pool that answers detection, prefix lookups and the ops functions from fixed rows.
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
import { DOCS_MISSING } from './tools/docs.ts';

const DISPATCH = 'bbbbbbbb-1111-4111-8111-111111111111';
const DECISION = 'dddddddd-1111-4111-8111-111111111111';
const DECISION_2 = 'd0d0d0d0-1111-4111-8111-111111111111';
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const SHA = 'a'.repeat(64);

const tables: Record<string, string[]> = { dispatches: [DISPATCH], decisions: [DECISION, DECISION_2], sessions: [SESSION] };

interface Statement { text: string; values?: unknown[] }
const LOOKUP = /FROM ops\.(\w+) WHERE id::text LIKE \$1 \|\| '%' LIMIT 2/;
const DETECT = /^SELECT to_regprocedure\('[^']+'\) IS NOT NULL AS present$/;

function fakePool(present: boolean) {
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
    return { rows: [{ r: { id: 'doc' } }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(present: boolean) {
  const { pool, statements } = fakePool(present);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'docs-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const op = (name: string) => statements.find((s) => !DETECT.test(s.text) && s.text.includes(`ops.${name}(`));
  return { client, call, statements, op, close: async () => { await client.close(); await server.close(); } };
}

const where = { node_path: 'global.p', doc_key: 'GUIDE', segment_id: SESSION };
const docCalls: [string, Record<string, unknown>, string][] = [
  ['write_doc', { ...where, doc_type: 'manual', title: 't', content: 'c', basis: 'review' },
    'ops.write_doc(ltree,text,text,text,text,text,text,uuid[],uuid[],uuid)'],
  ['approve_doc', { ...where, content_sha256: SHA }, 'ops.approve_doc(ltree,text,text,uuid)'],
  ['retire_doc', { ...where, reason: 'r' }, 'ops.retire_doc(ltree,text,text,uuid)'],
];

for (const [name, args, signature] of docCalls) {
  test(`0033 absent: ${name} refuses after detection alone`, async () => {
    const c = await connect(false);
    try {
      const r = await c.call(name, args);
      assert.equal(r.isError, true);
      assert.equal(r.text, DOCS_MISSING);
      assert.equal(c.statements.length, 1, 'only the detection query ran');
      assert.equal(c.statements[0].text, `SELECT to_regprocedure('${signature}') IS NOT NULL AS present`);
    } finally {
      await c.close();
    }
  });
}

test('0033 present: each docs tool detects, then calls its ops function in named notation', async () => {
  const c = await connect(true);
  try {
    for (const [name, args] of docCalls) {
      const before = c.statements.length;
      const r = await c.call(name, args);
      assert.equal(r.isError, false, `${name}: ${r.text}`);
      assert.deepEqual(JSON.parse(r.text), { id: 'doc' }, `${name} returns the jsonb`);
      const after = c.statements.slice(before);
      assert.match(after[0].text, DETECT, `${name} detects first`);
      assert.match(after.at(-1)?.text ?? '', new RegExp(`ops\\.${name}\\(p_node_path => \\$1::public\\.ltree`));
    }
    assert.deepEqual(c.op('write_doc')?.values, ['global.p', 'GUIDE', 'manual', 't', 'c', null, 'review', [], [], SESSION]);
    assert.deepEqual(c.op('approve_doc')?.values, ['global.p', 'GUIDE', SHA, SESSION]);
    assert.deepEqual(c.op('retire_doc')?.values, ['global.p', 'GUIDE', 'r', SESSION]);
  } finally {
    await c.close();
  }
});

test('write_doc: decision_ids, dispatch_ids and segment_id prefixes resolve before the call; an unmatched prefix sends nothing', async () => {
  const c = await connect(true);
  try {
    const r = await c.call('write_doc', {
      ...docCalls[0][1], basis: 'derived', summary: 's', segment_id: 'EEEEEEEE',
      decision_ids: ['DDDDDDDD', DECISION_2], dispatch_ids: ['bbbbbbbb'],
    });
    assert.equal(r.isError, false, r.text);
    const lookups = c.statements.filter((s) => LOOKUP.test(s.text)).map((s) => [LOOKUP.exec(s.text)?.[1], s.values?.[0]]);
    assert.deepEqual(lookups, [['decisions', 'dddddddd'], ['dispatches', 'bbbbbbbb'], ['sessions', 'eeeeeeee']]);
    assert.deepEqual(c.op('write_doc')?.values,
      ['global.p', 'GUIDE', 'manual', 't', 'c', 's', 'derived', [DECISION, DECISION_2], [DISPATCH], SESSION]);

    for (const [field, value, message] of [
      ['decision_ids', ['dddddddd', 'cccccccc'], 'decision_ids[1]: prefix cccccccc matched 0 rows in decisions'],
      ['decision_ids', ['d0d0d0d0', 'd'], 'expected a full UUID or 8-character id prefix at decision_ids[1]'],
      ['dispatch_ids', ['dddddddd'], 'dispatch_ids[0]: prefix dddddddd matched 0 rows in dispatches'],
    ] as [string, string[], string][]) {
      const calls = c.statements.filter((s) => !DETECT.test(s.text) && s.text.includes('ops.write_doc(')).length;
      const bad = await c.call('write_doc', { ...docCalls[0][1], basis: 'derived', [field]: value });
      assert.equal(bad.isError, true);
      assert.ok(bad.text.includes(message), bad.text);
      assert.equal(c.statements.filter((s) => !DETECT.test(s.text) && s.text.includes('ops.write_doc(')).length, calls, 'nothing sent');
    }
  } finally {
    await c.close();
  }
});

test('docs tools: malformed doc_key, sha, basis, blank reason and missing segment_id are refused before any query', async () => {
  const c = await connect(true);
  try {
    const refusals: [string, Record<string, unknown>, RegExp][] = [
      ['write_doc', { ...docCalls[0][1], doc_key: 'guide' }, /doc_key/],
      ['write_doc', { ...docCalls[0][1], basis: 'imported' }, /basis/],
      ['write_doc', { ...docCalls[0][1], content: '' }, /content/],
      ['approve_doc', { ...docCalls[1][1], content_sha256: SHA.toUpperCase() }, /content_sha256/],
      ['approve_doc', { ...docCalls[1][1], content_sha256: 'a'.repeat(63) }, /content_sha256/],
      ['approve_doc', { ...docCalls[1][1], doc_key: 'A-B' }, /doc_key/],
      ['retire_doc', { ...docCalls[2][1], reason: '   ' }, /must not be blank/],
      ['retire_doc', { node_path: 'global.p', doc_key: 'GUIDE', reason: 'r' }, /segment_id is required/],
      ['write_doc', { ...docCalls[0][1], node_path: 'Global' }, /node_path/],
    ];
    for (const [name, args, message] of refusals) {
      const r = await c.call(name, args);
      assert.equal(r.isError, true, `${name} ${JSON.stringify(args)}: ${r.text}`);
      assert.match(r.text, /^MCP error -32602: Input validation error: Invalid arguments for tool /);
      assert.match(r.text, message);
    }
    assert.equal(c.statements.length, 0, 'no statement at all');
  } finally {
    await c.close();
  }
});

test('tools/list: docs tools with their schemas; approve and retire name the operator yes and rule doc_approval', async () => {
  const c = await connect(true);
  try {
    const { tools: listed } = await c.client.listTools();
    const schema = (name: string) => listed.find((x) => x.name === name)?.inputSchema as
      { properties: Record<string, { type?: string; pattern?: string; enum?: string[]; items?: { description?: string } }>;
        required?: string[] };
    assert.deepEqual(Object.keys(schema('write_doc').properties).sort(), ['basis', 'content', 'decision_ids',
      'dispatch_ids', 'doc_key', 'doc_type', 'node_path', 'segment_id', 'summary', 'title']);
    assert.deepEqual([...(schema('write_doc').required ?? [])].sort(), ['basis', 'content', 'doc_key', 'doc_type',
      'node_path', 'segment_id', 'title']);
    assert.deepEqual(schema('write_doc').properties.basis.enum, ['derived', 'review']);
    assert.deepEqual(Object.keys(schema('approve_doc').properties).sort(), ['content_sha256', 'doc_key', 'node_path', 'segment_id']);
    assert.deepEqual([...(schema('approve_doc').required ?? [])].sort(), ['content_sha256', 'doc_key', 'node_path', 'segment_id']);
    assert.equal(schema('approve_doc').properties.content_sha256.pattern, '^[0-9a-f]{64}$');
    assert.deepEqual(Object.keys(schema('retire_doc').properties).sort(), ['doc_key', 'node_path', 'reason', 'segment_id']);
    assert.deepEqual([...(schema('retire_doc').required ?? [])].sort(), ['doc_key', 'node_path', 'reason', 'segment_id']);
    for (const name of ['write_doc', 'approve_doc', 'retire_doc']) {
      assert.equal(schema(name).properties.doc_key.pattern, '^[A-Z0-9_]+$', name);
      const description = listed.find((x) => x.name === name)?.description ?? '';
      assert.match(description, /rule doc_approval/, name);
      assert.match(description, /Needs migration 0033/, name);
    }
    for (const name of ['approve_doc', 'retire_doc']) {
      assert.match(listed.find((x) => x.name === name)?.description ?? '', /operator's explicit yes/, name);
    }
  } finally {
    await c.close();
  }
});
