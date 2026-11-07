// Tests for the passive tick middleware and the tick tools. No database: tools run on a real
// McpServer over an in-memory transport, against a fake pool that records every statement.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import type pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { CLIENT_SOURCES, CONTACT_USAGE, PASSIVE_SKIP, callLine, contactFor, installPassiveTick, parseContactSetting,
         passiveNote } from './tick.ts';
import { registerCommon } from './tools/common.ts';
import { registerTick, registerWindowLink } from './tools/window.ts';

const OK = { state: 'ok', line: 'ok W001 · 4h10 left', directive: null };
const NEW = { state: 'new', line: 'new W002 · from 10:00 (inferred)', directive: 'CAL_CREATE' };

interface Event { on: 'pool' | 'client'; text: string; values?: unknown[] }

// tickResult: what ops.tick returns, or an Error to throw.
function fakePool(tickResult: object | Error) {
  const events: Event[] = [];
  const run = async (on: Event['on'], q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    events.push({ on, text, values });
    if (text.includes('ops.tick(')) {
      if (tickResult instanceof Error) throw tickResult;
      return { rows: [{ t: tickResult }] };
    }
    if (text.includes('ops.window_link_event(')) return { rows: [{ number: values?.[0], calendar_event_id: values?.[1] }] };
    return { command: 'SELECT', rowCount: 1, rows: [{ n: 1, text: 'doc' }] };
  };
  const pool = {
    query: (q: string, values?: unknown[]) => run('pool', q, values),
    connect: async () => ({ query: (q: string, values?: unknown[]) => run('client', q, values), release() {} }),
  };
  return { pool: pool as unknown as pg.Pool, events };
}

async function connect(pool: pg.Pool, clientName: string | null, planner = false) {
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  const contact = () => contactFor(server.server.getClientVersion());
  installPassiveTick(server, pool, contact);
  registerCommon(server, pool);
  registerTick(server, pool, contact);
  if (planner) registerWindowLink(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  // An empty name stands in for a client that sent no usable clientInfo.
  const client = new Client({ name: clientName ?? '', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown> = {}) =>
    (await client.callTool({ name, arguments: args })) as CallToolResult;
  return { call, close: async () => { await client.close(); await server.close(); } };
}

const texts = (r: CallToolResult) => r.content.map((c) => (c.type === 'text' ? c.text : `<${c.type}>`));
const ticks = (events: Event[]) => events.filter((e) => e.text.includes('ops.tick('));

test('source map: Claude Code is code, everything else is chat, missing clientInfo is unknown', () => {
  assert.deepEqual(CLIENT_SOURCES, { 'claude-code': 'code' });
  assert.deepEqual(contactFor({ name: 'claude-code', version: '2' }), { source: 'code', client: 'claude-code' });
  assert.deepEqual(contactFor({ name: 'claude-ai', version: '1' }), { source: 'chat', client: 'claude-ai' });
  assert.deepEqual(contactFor({ name: 'toString', version: '1' }), { source: 'chat', client: 'toString' });
  assert.deepEqual(contactFor(undefined), { source: 'chat', client: 'unknown' });
  assert.deepEqual(contactFor({ name: '  ', version: '1' }), { source: 'chat', client: 'unknown' });
});

test('passive tick uses the initialize clientInfo name', async () => {
  for (const [name, source, client] of [['claude-code', 'code', 'claude-code'], ['claude-ai', 'chat', 'claude-ai'],
                                        [null, 'chat', 'unknown']] as const) {
    const { pool, events } = fakePool(OK);
    const s = await connect(pool, name);
    await s.call('resolve_context', { node_path: 'p', ref: 'DOC' });
    await s.close();
    const [t] = ticks(events);
    assert.deepEqual(t.values?.slice(0, 2), [source, client]);
  }
});

test('passive tick runs on the pool before the query tool, never inside its READ ONLY transaction', async () => {
  const { pool, events } = fakePool(OK);
  const s = await connect(pool, 'claude-code');
  const r = await s.call('query', { sql: 'SELECT 1 AS n' });
  await s.close();
  assert.equal(r.isError, undefined);
  assert.equal(ticks(events).length, 1);
  assert.equal(events[0].on, 'pool');
  assert.match(events[0].text, /ops\.tick\(/);
  const begin = events.findIndex((e) => e.text === 'BEGIN READ ONLY');
  assert.ok(begin > 0, 'tick precedes BEGIN READ ONLY');
  assert.ok(events.slice(begin).every((e) => e.on === 'client' && !e.text.includes('ops.tick(')));
});

test('fail-open: a tick error is logged and the tool result is unchanged', async (t) => {
  const logged: string[] = [];
  t.mock.method(process.stderr, 'write', (chunk: unknown) => { logged.push(String(chunk)); return true; });
  const failing = fakePool(new Error('connection refused'));
  const s1 = await connect(failing.pool, 'claude-code');
  const r1 = await s1.call('query', { sql: 'SELECT 1 AS n' });
  await s1.close();
  const healthy = fakePool(OK);
  const s2 = await connect(healthy.pool, 'claude-code');
  const r2 = await s2.call('query', { sql: 'SELECT 1 AS n' });
  await s2.close();
  t.mock.restoreAll();
  assert.equal(r1.isError, undefined);
  assert.deepEqual(r1.content, r2.content);
  assert.ok(logged.some((l) => l.includes('passive tick failed') && l.includes('connection refused')));
});

test('skip list: tick and window_link_event get no passive tick', async () => {
  assert.deepEqual([...PASSIVE_SKIP].sort(), ['tick', 'window_link_event']);
  const { pool, events } = fakePool(NEW);
  const s = await connect(pool, 'claude-ai', true);
  const r1 = await s.call('tick');
  const r2 = await s.call('window_link_event', { number: 2, event_id: 'evt' });
  await s.close();
  assert.equal(ticks(events).length, 1, 'only the explicit tick');
  assert.ok(!texts(r1).some((x) => x.startsWith('[tick]')));
  assert.ok(!texts(r2).some((x) => x.startsWith('[tick]')));
});

test('non-ok passive state appends one [tick] block; ok appends nothing', async () => {
  const quiet = fakePool(OK);
  const s1 = await connect(quiet.pool, 'claude-code');
  const r1 = await s1.call('resolve_context', { node_path: 'p', ref: 'DOC' });
  await s1.close();
  assert.equal(r1.content.length, 1);

  const loud = fakePool(NEW);
  const s2 = await connect(loud.pool, 'claude-ai');
  const r2 = await s2.call('resolve_context', { node_path: 'p', ref: 'DOC' });
  await s2.close();
  assert.equal(r2.content.length, 2);
  assert.equal(texts(r2)[1], '[tick] new W002 · from 10:00 (inferred) · directive CAL_CREATE');

  assert.equal(passiveNote({ state: 'resume', line: 'resume W001 · idle 40m · 2h left', directive: null }),
    '[tick] resume W001 · idle 40m · 2h left · directive none');
  assert.equal(passiveNote(OK), null);
  assert.equal(passiveNote(null), null);
});

test('explicit tick returns line first, then the full JSON, and passes its inputs', async () => {
  const { pool, events } = fakePool(NEW);
  const s = await connect(pool, 'claude-ai');
  const calendar = [{ id: 'e1', start: '2026-10-06T10:00:00+03:00', end: '2026-10-06T15:00:00+03:00', title: 't' }];
  const r = await s.call('tick', { reset_at: '2026-10-06T15:00:00+03:00', reset_source: 'stated', calendar, chat_ref: 'c1' });
  const bad = await s.call('tick', { reset_at: '2026-10-06T15:00:00+03:00' });
  await s.close();
  assert.deepEqual(texts(r), [NEW.line, JSON.stringify(NEW, null, 2)]);
  assert.deepEqual(ticks(events)[0].values,
    ['chat', 'claude-ai', 'c1', '2026-10-06T15:00:00+03:00', 'stated', JSON.stringify(calendar)]);
  assert.equal(bad.isError, true);
  assert.match(texts(bad)[0], /must be given together/);
  assert.equal(ticks(events).length, 1, 'the refused call never reached ops.tick');
});

test('call log: one stderr line per call with role, tool and sorted argument keys, never values', async (t) => {
  const logged: string[] = [];
  t.mock.method(process.stderr, 'write', (chunk: unknown) => { logged.push(String(chunk)); return true; });
  const { pool } = fakePool(OK);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  installPassiveTick(server, pool, () => contactFor(server.server.getClientVersion()), 'executor');
  registerCommon(server, pool);
  registerTick(server, pool, () => contactFor(server.server.getClientVersion()));
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'claude-code', version: '1.0.0' });
  await client.connect(b);
  await client.callTool({ name: 'resolve_context', arguments: { ref: 'SECRET_REF_VALUE', node_path: 'secret-project-value' } });
  await client.callTool({ name: 'tick', arguments: { chat_ref: 'secret-chat-value' } });
  await client.close();
  await server.close();
  t.mock.restoreAll();

  const calls = logged.filter((l) => l.includes(' tool='));
  assert.equal(calls.length, 2, 'one line per call, skip-list tools included');
  assert.match(calls[0], /^\[local-ops-mcp\] \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z role=executor tool=resolve_context args=\[node_path,ref\]\n$/);
  assert.match(calls[1], / role=executor tool=tick args=\[chat_ref\]\n$/);
  assert.ok(!logged.some((l) => /secret-|SECRET_/.test(l)), 'no argument value reaches stderr');
  assert.match(callLine('planner', 'x', undefined), / role=planner tool=x args=\[\]$/);
});

test('LOCAL_OPS_CONTACT: unset ticks, none does not, any other value is refused', () => {
  assert.equal(parseContactSetting(undefined), true);
  assert.equal(parseContactSetting('none'), false);
  for (const value of ['', 'None', 'off', 'NONE', ' none', 'chat', '0']) {
    assert.throws(() => parseContactSetting(value), { message: CONTACT_USAGE }, `refused: ${JSON.stringify(value)}`);
  }
  assert.match(CONTACT_USAGE, /LOCAL_OPS_CONTACT/);
  assert.match(CONTACT_USAGE, /\bunset\b/);
  assert.match(CONTACT_USAGE, /\bnone\b/);
});

test('LOCAL_OPS_CONTACT=none: handlers run and the call log is written, but no tick reaches the pool and no [tick] note', async (t) => {
  const logged: string[] = [];
  t.mock.method(process.stderr, 'write', (chunk: unknown) => { logged.push(String(chunk)); return true; });
  const { pool, events } = fakePool(NEW);
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  installPassiveTick(server, pool, () => contactFor(server.server.getClientVersion()), 'executor', false);
  registerCommon(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'codex', version: '1.0.0' });
  await client.connect(b);
  const r1 = (await client.callTool({ name: 'resolve_context', arguments: { node_path: 'p', ref: 'DOC' } })) as CallToolResult;
  const r2 = (await client.callTool({ name: 'query', arguments: { sql: 'SELECT 1 AS n' } })) as CallToolResult;
  await client.close();
  await server.close();
  t.mock.restoreAll();

  assert.equal(r1.isError, undefined);
  assert.equal(r2.isError, undefined);
  assert.equal(r1.content.length, 1, 'no [tick] block appended');
  assert.ok(![...texts(r1), ...texts(r2)].some((x) => x.startsWith('[tick]')));
  assert.equal(ticks(events).length, 0, 'no ops.tick statement');
  assert.ok(events.some((e) => e.text.includes('ops.resolve_context(')), 'resolve_context handler ran');
  assert.ok(events.some((e) => e.text === 'BEGIN READ ONLY'), 'query handler ran');
  const calls = logged.filter((l) => l.includes(' tool='));
  assert.equal(calls.length, 2);
  assert.match(calls[0], / role=executor tool=resolve_context args=\[node_path,ref\]\n$/);
  assert.match(calls[1], / role=executor tool=query args=\[sql\]\n$/);
});
