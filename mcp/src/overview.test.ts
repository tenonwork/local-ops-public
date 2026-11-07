// Tests for open_session's node overview (tools/planner.ts, migration 0036): after ops.open_session the tool detects
// ops.node_overview at call time and, when present, returns the overview beside the session id; when absent, only the
// session id, as before 0036. An overview failure (detection or call) is reported as overview_error and never loses the
// session id; an ops.open_session failure fails the tool as before, with nothing else sent. reconstruct_session never
// reads the overview. No database: tools run on a real McpServer over an in-memory transport, against a fake pool that
// answers from fixed rows.
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
import { registerExecutor } from './tools/executor.ts';
import { describe } from './db.ts';

interface Statement { text: string; values?: unknown[] }
const OPEN_TEXT = 'SELECT ops.open_session(p_node_path => $1::public.ltree, p_kind => $2, p_scope => $3::ops.segment_scope) AS id';
const DETECT_TEXT = "SELECT to_regprocedure('ops.node_overview(ltree,integer)') IS NOT NULL AS present";
const OVERVIEW_TEXT = 'SELECT ops.node_overview(p_node_path => $1::public.ltree) AS overview';
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const OVERVIEW = 'NODE global.p (project) — p\nCONTEXT\n  global — g\nCHILDREN\n  none\nNEXT STEP\n  none at this node\n'
  + 'BACKLOG (open, subtree)\n  none';

function dbError(message: string, code: string): pg.DatabaseError {
  const err = new pg.DatabaseError(message, 0, 'error');
  err.code = code;
  return err;
}

interface Behaviour { present?: boolean; detectError?: Error; overviewError?: Error; openError?: Error }

function fakePool(b: Behaviour) {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ text, values });
    if (text === DETECT_TEXT) {
      if (b.detectError) throw b.detectError;
      return { rows: [{ present: b.present === true }] };
    }
    if (text === OVERVIEW_TEXT) {
      if (b.overviewError) throw b.overviewError;
      return { rows: [{ overview: OVERVIEW }] };
    }
    if (text === OPEN_TEXT && b.openError) throw b.openError;
    return { rows: [{ id: SESSION, n: 0 }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) };
  return { pool: pool as unknown as pg.Pool, statements };
}

async function connect(b: Behaviour, register = registerPlanner) {
  const { pool, statements } = fakePool(b);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  register(server, pool);
  const [a, c] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'overview-test', version: '1.0.0' });
  await client.connect(c);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((x) => (x.type === 'text' ? x.text : '')).join('\n') };
  };
  return { client, call, statements, close: async () => { await client.close(); await server.close(); } };
}

const OPEN = { text: OPEN_TEXT, values: ['global.p', 'planning', null] };
const DETECT = { text: DETECT_TEXT, values: undefined };

test('0036 absent: open_session returns exactly {session_id}; open call, then detection only', async () => {
  const c = await connect({ present: false });
  try {
    const r = await c.call('open_session', { node_path: 'global.p', kind: 'planning' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), { session_id: SESSION });
    assert.deepEqual(c.statements, [OPEN, DETECT]);
  } finally {
    await c.close();
  }
});

test('0036 present: open_session returns {session_id, overview}; open, detection, named node_overview call', async () => {
  const c = await connect({ present: true });
  try {
    const r = await c.call('open_session', { node_path: 'global.p', kind: 'planning' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), { session_id: SESSION, overview: OVERVIEW });
    assert.deepEqual(c.statements, [OPEN, DETECT, { text: OVERVIEW_TEXT, values: ['global.p'] }]);
  } finally {
    await c.close();
  }
});

test('node_overview raising: open_session succeeds with {session_id, overview_error} as describe() formats it', async () => {
  const err = dbError('p_max_chars must be at least 500', '22023');
  const c = await connect({ present: true, overviewError: err });
  try {
    const r = await c.call('open_session', { node_path: 'global.p', kind: 'planning' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), { session_id: SESSION, overview_error: describe(err) });
    assert.equal(describe(err), 'Postgres error 22023: p_max_chars must be at least 500');
    assert.deepEqual(c.statements.map((s) => s.text), [OPEN_TEXT, DETECT_TEXT, OVERVIEW_TEXT]);
  } finally {
    await c.close();
  }
});

test('detection raising: open_session succeeds with {session_id, overview_error}; no node_overview call', async () => {
  const err = new Error('Connection terminated unexpectedly');
  const c = await connect({ present: true, detectError: err });
  try {
    const r = await c.call('open_session', { node_path: 'global.p', kind: 'planning' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), { session_id: SESSION, overview_error: describe(err) });
    assert.deepEqual(c.statements.map((s) => s.text), [OPEN_TEXT, DETECT_TEXT]);
  } finally {
    await c.close();
  }
});

test('ops.open_session raising: the tool fails with the database text; no detection statement', async () => {
  const c = await connect({ present: true, openError: dbError('unknown node global.nope', 'P0001') });
  try {
    const r = await c.call('open_session', { node_path: 'global.nope', kind: 'planning' });
    assert.equal(r.isError, true);
    assert.equal(r.text, 'Validation error (P0001): unknown node global.nope');
    assert.deepEqual(c.statements.map((s) => s.text), [OPEN_TEXT]);
  } finally {
    await c.close();
  }
});

test('reconstruct_session sends no detection or node_overview statement', async () => {
  const c = await connect({ present: true });
  try {
    const now = '2026-10-20T00:00:00.000Z';
    const r = await c.call('reconstruct_session', { node_path: 'global.p', kind: 'planning', occurred_at: now,
      closed_at: now, summary: 's', next_step: 'n' });
    assert.equal(r.isError, false, r.text);
    assert.deepEqual(JSON.parse(r.text), { session_id: SESSION, decisions_recorded: 0 });
    assert.equal(c.statements.some((s) => s.text === DETECT_TEXT || s.text.includes('node_overview')), false);
  } finally {
    await c.close();
  }
});

test('executor: open_session is not registered', async () => {
  const e = await connect({ present: true }, registerExecutor);
  try {
    const { tools: listed } = await e.client.listTools();
    assert.equal(listed.some((x) => x.name === 'open_session'), false);
  } finally {
    await e.close();
  }
});
