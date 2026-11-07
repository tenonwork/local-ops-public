// Tests for the work-log layer of the MCP tools: the executor's complete_dispatch `work` (ops.log_work and
// ops.complete_dispatch in one transaction), claim_dispatch work_log delivery (ops.get_work_log), both feature-detected
// at call time with to_regprocedure, and the planner's create_dispatch task_files. No database: tools run on a real
// McpServer over an in-memory transport, against a fake pool that records every statement and the connection it ran on.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerExecutor } from './tools/executor.ts';
import { registerPlanner } from './tools/planner.ts';

const NODE = 'global.p.core';
const SESSION = 'eeeeeeee-1111-4111-8111-111111111111';
const COMPLETE_REFUSAL = 'dispatch 44444444 (commit_policy local) has no work_log entry; call ops.log_work first';

// Executor state (claims, delivered work-log ids) lives in the module for the whole process, so every test uses
// its own dispatch and work_log ids.
const id = (n: number) => `${String(n).repeat(8)}-aaaa-4aaa-8aaa-${String(n).repeat(12)}`;
const logId = (n: number) => `${String(n).repeat(8)}-bbbb-4bbb-8bbb-${String(n).repeat(12)}`;

interface Statement { on: 'pool' | 'client'; text: string; values?: unknown[] }

// detect: how to_regprocedure answers, per function: 'present', 'false' (present = false) or 'no row'.
interface Options {
  pending: Record<string, unknown>[];
  detect: 'present' | 'false' | 'no row';
  workLog?: Record<string, unknown>[];
  workLogError?: Error;
  completeError?: Error;
}

async function harness(o: Options) {
  const statements: Statement[] = [];
  const run = (on: Statement['on']) => async (q: string | { text: string }, values?: unknown[]) => {
    const text = typeof q === 'string' ? q : q.text;
    statements.push({ on, text, values });
    if (text.includes('to_regprocedure(')) {
      return { rows: o.detect === 'no row' ? [] : [{ present: o.detect === 'present' }] };
    }
    if (text.includes('ops.get_pending(')) return { rows: o.pending };
    if (text.includes("key = 'batch_defaults'")) return { rows: [{ value: { implementation_max: 100, investigation_max: 1 } }] };
    if (text.includes('ops.get_work_log(')) {
      if (o.workLogError) throw o.workLogError;
      return { rows: o.workLog ?? [] };
    }
    if (text.includes('ops.log_work(')) return { rows: [{ id: logId(9) }] };
    if (text.includes('ops.complete_dispatch(') && o.completeError) throw o.completeError;
    return { rows: [] };
  };
  const pool = { query: run('pool'), connect: async () => ({ query: run('client'), release() {} }) } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerExecutor(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'worklog-test', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown>) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const ok = async (name: string, args: Record<string, unknown>) => {
    const r = await call(name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text);
  };
  const count = async () => (await ok('get_pending', { node_path: NODE })).claimed_this_process as number;
  return { call, ok, count, statements, close: async () => { await client.close(); await server.close(); } };
}

function refusal(message: string): pg.DatabaseError {
  const e = new pg.DatabaseError(message, 0, 'error');
  e.code = '23514';
  return e;
}

const WORK = {
  entry_type: 'feature', title: 'work-log layer', description: 'd', files_changed: ['mcp/src/tools/executor.ts'],
  follow_ups: [{ tag: 'discovery', text: 'f' }], test_summary: '80 pass', external_refs: [{ kind: 'commit', sha: 'abc' }],
};

for (const detect of ['no row', 'false'] as const) {
  test(`(a) work-log functions absent (${detect}): complete_dispatch with or without work and claim_dispatch behave as before`, async () => {
    const [d1, d2] = detect === 'no row' ? [id(1), id(2)] : [id(3), id(4)];
    const c = await harness({ pending: [{ id: d1, dispatch_type: 'addition', context_refs: [], task_files: ['a.ts'] },
      { id: d2, dispatch_type: 'addition', context_refs: [] }], detect });
    try {
      await c.ok('get_pending', { node_path: NODE });
      const claim = await c.ok('claim_dispatch', { id: d1 });
      assert.equal(claim.work_log, null);
      assert.deepEqual(await c.ok('complete_dispatch', { id: d1, result: 'r', report: 'rep', work: WORK }),
        { id: d1, status: 'done', work_log: 'not recorded: ops.log_work is absent in this database' });

      await c.ok('claim_dispatch', { id: d2 });
      assert.deepEqual(await c.ok('complete_dispatch', { id: d2, result: 'r', report: 'rep' }), { id: d2, status: 'done' });

      assert.equal(c.statements.filter((s) => s.text.includes('ops.get_work_log(p_node_path')).length, 0, 'no get_work_log');
      assert.equal(c.statements.filter((s) => s.text.includes('ops.log_work($1')).length, 0, 'no log_work');
      assert.equal(c.statements.filter((s) => s.on === 'client').length, 0, 'no transaction');
      assert.deepEqual(c.statements.filter((s) => s.text.includes('ops.complete_dispatch(')).map((s) => s.values),
        [[d1, 'r', 'rep'], [d2, 'r', 'rep']]);
      assert.deepEqual(c.statements.filter((s) => s.text.includes('to_regprocedure(')).map((s) => s.text), [
        "SELECT to_regprocedure('ops.get_work_log(public.ltree,text[],integer)') IS NOT NULL AS present",
        "SELECT to_regprocedure('ops.log_work(uuid,text,text,text,text[],jsonb,text,jsonb)') IS NOT NULL AS present",
        "SELECT to_regprocedure('ops.get_work_log(public.ltree,text[],integer)') IS NOT NULL AS present",
      ], 'detected at call time; complete without work does not detect');
    } finally {
      await c.close();
    }
  });
}

test('(b) log_work present: complete with work runs BEGIN, log_work, complete_dispatch, COMMIT on one connection', async () => {
  const d = id(5);
  const c = await harness({ pending: [{ id: d, dispatch_type: 'addition', context_refs: [] }], detect: 'present' });
  try {
    await c.ok('get_pending', { node_path: NODE });
    await c.ok('claim_dispatch', { id: d });
    const from = c.statements.length;
    assert.deepEqual(await c.ok('complete_dispatch', { id: d, result: 'r', report: 'rep', work: WORK }),
      { id: d, status: 'done', work_log_id: logId(9) });
    const tx = c.statements.slice(from).filter((s) => s.on === 'client');
    assert.deepEqual(tx.map((s) => s.text), [
      'BEGIN',
      'SELECT ops.log_work($1, $2, $3, $4, $5::text[], $6::jsonb, $7, $8::jsonb) AS id',
      'SELECT ops.complete_dispatch($1, $2, $3)',
      'COMMIT',
    ]);
    assert.deepEqual(tx[1].values, [d, 'feature', 'work-log layer', 'd', ['mcp/src/tools/executor.ts'],
      JSON.stringify(WORK.follow_ups), '80 pass', JSON.stringify(WORK.external_refs)]);
    assert.deepEqual(tx[2].values, [d, 'r', 'rep']);
    assert.equal(c.statements.slice(from).filter((s) => s.on === 'pool' && s.text.includes('ops.complete_dispatch(')).length, 0);
    assert.equal((await c.call('complete_dispatch', { id: d, result: 'r', report: 'rep' })).text,
      `dispatch ${d} was not claimed by this process`, 'released after commit');

    // Defaults: optional fields null, arrays empty.
    const e = id(6);
    const c2 = await harness({ pending: [{ id: e, dispatch_type: 'addition', context_refs: [] }], detect: 'present' });
    try {
      await c2.ok('get_pending', { node_path: NODE });
      await c2.ok('claim_dispatch', { id: e });
      await c2.ok('complete_dispatch', { id: e, result: 'r', report: 'rep', work: { entry_type: 'fix', title: 't' } });
      const log = c2.statements.find((s) => s.text.includes('ops.log_work($1'));
      assert.deepEqual(log?.values, [e, 'fix', 't', null, [], '[]', null, '[]']);
      for (const bad of [{ entry_type: ' ', title: 't' }, { entry_type: 'fix', title: '' }, { title: 't' }]) {
        const r = await c2.call('complete_dispatch', { id: e, result: 'r', report: 'rep', work: bad });
        assert.equal(r.isError, true, JSON.stringify(bad));
        assert.match(r.text, /Input validation error/);
      }
    } finally {
      await c2.close();
    }
  } finally {
    await c.close();
  }
});

test('(b) log_work present: a complete_dispatch refusal rolls back both statements and the id stays claimed', async () => {
  const d = id(7);
  const opts: Options = { pending: [{ id: d, dispatch_type: 'addition', context_refs: [] }], detect: 'present',
    completeError: refusal(COMPLETE_REFUSAL) };
  const c = await harness(opts);
  try {
    await c.ok('get_pending', { node_path: NODE });
    await c.ok('claim_dispatch', { id: d });
    const from = c.statements.length;
    const r = await c.call('complete_dispatch', { id: d, result: 'r', report: 'rep', work: WORK });
    assert.equal(r.isError, true);
    assert.equal(r.text, `Validation error (23514): ${COMPLETE_REFUSAL}`);
    assert.deepEqual(c.statements.slice(from).filter((s) => s.on === 'client').map((s) => s.text.split('(')[0]),
      ['BEGIN', 'SELECT ops.log_work', 'SELECT ops.complete_dispatch', 'ROLLBACK'], 'no COMMIT');

    // Without work, the database's refusal passes through unchanged and nothing is logged.
    const plain = c.statements.length;
    const p = await c.call('complete_dispatch', { id: d, result: 'r', report: 'rep' });
    assert.equal(p.text, `Validation error (23514): ${COMPLETE_REFUSAL}`);
    assert.deepEqual(c.statements.slice(plain).map((s) => [s.on, s.text]),
      [['pool', 'SELECT ops.complete_dispatch($1, $2, $3)']]);

    opts.completeError = undefined;
    assert.deepEqual(await c.ok('complete_dispatch', { id: d, result: 'r', report: 'rep', work: WORK }),
      { id: d, status: 'done', work_log_id: logId(9) }, 'still claimed after the refusals');
  } finally {
    await c.close();
  }
});

test('(c) get_work_log present: claim passes node path and task_files, returns rows; a later claim omits delivered ids', async () => {
  const [d1, d2] = [id(1).replace('aaaa-4aaa', 'cccc-4ccc'), id(2).replace('aaaa-4aaa', 'cccc-4ccc')];
  const rows = [
    { id: logId(1), entry_type: 'feature', title: 'x', files_changed: ['a.ts'], file_overlap: true },
    { id: logId(2), entry_type: 'fix', title: 'y', files_changed: ['b.ts'], file_overlap: false },
  ];
  const c = await harness({ pending: [
    { id: d1, dispatch_type: 'addition', context_refs: [], task_files: ['a.ts', 'c.ts'] },
    { id: d2, dispatch_type: 'addition', context_refs: [] },
  ], detect: 'present', workLog: rows });
  try {
    await c.ok('get_pending', { node_path: NODE });
    const first = await c.ok('claim_dispatch', { id: d1 });
    assert.deepEqual(first.work_log, { rows, already_delivered: [] });
    const lookups = () => c.statements.filter((s) => s.text.includes('ops.get_work_log(p_node_path'));
    assert.equal(lookups()[0].text,
      'SELECT * FROM ops.get_work_log(p_node_path => $1::public.ltree, p_files => $2::text[], p_limit => NULL)');
    assert.deepEqual(lookups()[0].values, [NODE, ['a.ts', 'c.ts']]);

    const second = await c.ok('claim_dispatch', { id: d2 });
    assert.deepEqual(second.work_log, { rows: [], already_delivered: [logId(1), logId(2)] });
    assert.deepEqual(lookups()[1].values, [NODE, []], 'no task_files: empty array');
    const order = c.statements.map((s) => s.text);
    const lastClaim = order.findLastIndex((t) => t.includes('ops.claim_dispatch('));
    assert.ok(order.findLastIndex((t) => t.includes('ops.get_work_log(p_node_path')) < lastClaim, 'lookup before claim');
  } finally {
    await c.close();
  }
});

test('(d) a get_work_log error fails the claim before ops.claim_dispatch and uses no batch slot', async () => {
  const d = id(8);
  const err = new pg.DatabaseError('unknown node global.p.core', 0, 'error');
  err.code = 'P0001';
  const c = await harness({ pending: [{ id: d, dispatch_type: 'addition', context_refs: [] }], detect: 'present',
    workLogError: err });
  try {
    const before = await c.count();
    const r = await c.call('claim_dispatch', { id: d });
    assert.equal(r.isError, true);
    assert.equal(r.text, 'Validation error (P0001): unknown node global.p.core');
    assert.equal(c.statements.filter((s) => s.text.includes('ops.claim_dispatch(')).length, 0, 'no claim statement');
    assert.equal(await c.count(), before, 'claim count unchanged');
    assert.equal((await c.call('complete_dispatch', { id: d, result: 'r', report: 'rep' })).text,
      `dispatch ${d} was not claimed by this process`);
  } finally {
    await c.close();
  }
});

// The create_dispatch call before task_files (a3ea668), byte for byte.
const CREATE_DISPATCH = `SELECT * FROM ops.create_dispatch(p_node_path => $1::public.ltree, p_dispatch_type => $2,
       p_title => $3, p_prompt => $4, p_context_refs => $5::text[], p_priority => $6, p_session => $7)`;

test('(e) planner create_dispatch: empty task_files sends today\'s call; non-empty adds $8 text[] with the deduped list', async () => {
  const statements: Statement[] = [];
  const run = async (q: string | { text: string }, values?: unknown[]) => {
    statements.push({ on: 'pool', text: typeof q === 'string' ? q : q.text, values });
    return { rows: [{ id: 'x' }] };
  };
  const pool = { query: run, connect: async () => ({ query: run, release() {} }) } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'worklog-test', version: '1.0.0' });
  await client.connect(b);
  try {
    const base = { node_path: NODE, dispatch_type: 'addition', title: 't', prompt: 'p', context_refs: ['R', 'R'],
      segment_id: SESSION };
    const today = [NODE, 'addition', 't', 'p', ['R'], 100, SESSION];
    for (const args of [base, { ...base, task_files: [] }]) {
      const r = (await client.callTool({ name: 'create_dispatch', arguments: args })) as CallToolResult;
      assert.notEqual(r.isError, true);
      const s = statements.at(-1)!;
      assert.equal(s.text, CREATE_DISPATCH);
      assert.deepEqual(s.values, today);
    }
    const r = (await client.callTool({ name: 'create_dispatch',
      arguments: { ...base, task_files: ['a.ts', 'b/c.sql', 'a.ts'] } })) as CallToolResult;
    assert.notEqual(r.isError, true);
    const s = statements.at(-1)!;
    assert.equal(s.text, CREATE_DISPATCH.replace(/\)$/, ', p_task_files => $8::text[])'));
    assert.deepEqual(s.values, [...today, ['a.ts', 'b/c.sql']]);

    const before = statements.length;
    const bad = (await client.callTool({ name: 'create_dispatch', arguments: { ...base, task_files: [''] } })) as CallToolResult;
    assert.equal(bad.isError, true, 'a blank task file is a schema error');
    assert.equal(statements.length, before, 'and reaches no database');

    const { tools } = await client.listTools();
    assert.match(tools.find((t) => t.name === 'create_dispatch')!.description!, /full UUID or 8-character id prefix/);
    assert.match(tools.find((t) => t.name === 'create_dispatch')!.description!, /task_files/);
  } finally {
    await client.close();
    await server.close();
  }
});
