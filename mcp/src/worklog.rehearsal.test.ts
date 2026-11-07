// Integration test for the work-log layer against the rehearsal database (migrations 0028-0029): through the
// executor tools, complete_dispatch with `work` writes one work_log row and its work_log_nodes row in the same
// transaction as the completion, complete_dispatch without `work` is refused for a local-policy dispatch, and
// claim_dispatch delivers a work_log row with file_overlap for a matching task file.
// Runs on one connection inside a transaction that is always rolled back, on a project it creates itself; tool
// statements run under savepoints (inTransaction's BEGIN / COMMIT / ROLLBACK become one), as in planner.rehearsal.test.ts,
// and as the same role (the URL's).
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
import { registerExecutor } from './tools/executor.ts';
import { registerPlanner } from './tools/planner.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';
const skip = url === '' && 'LOCAL_OPS_REHEARSAL_URL not set';
type Json = Record<string, any>;

test('rehearsal: complete_dispatch with work logs atomically, without work is refused; claim delivers overlapping work_log', { skip }, async () => {
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
  const clients: [McpServer, Client][] = [];
  const connect = async (register: typeof registerPlanner, name: string) => {
    const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
    register(server, pool);
    const [a, b] = InMemoryTransport.createLinkedPair();
    await server.connect(a);
    const client = new Client({ name, version: '1.0.0' });
    await client.connect(b);
    clients.push([server, client]);
    return async (tool: string, args: Json) => {
      const r = (await client.callTool({ name: tool, arguments: args })) as CallToolResult;
      return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
    };
  };
  try {
    const plan = await connect(registerPlanner, 'worklog-it-planner');
    const exec = await connect(registerExecutor, 'worklog-it-executor');
    const ok = async (call: typeof plan, tool: string, args: Json) => {
      const r = await call(tool, args);
      assert.equal(r.isError, false, `${tool}: ${r.text}`);
      return JSON.parse(r.text) as Json;
    };

    const present = (await db.query(
      `SELECT to_regprocedure('ops.log_work(uuid,text,text,text,text[],jsonb,text,jsonb)') IS NOT NULL
          AND to_regprocedure('ops.get_work_log(public.ltree,text[],integer)') IS NOT NULL AS present`)).rows[0].present;
    assert.equal(present, true, 'rehearsal has ops.log_work and ops.get_work_log (0028)');

    const project = `it-wl-${randomBytes(4).toString('hex')}`;
    const projectPath = `global.${project}`;
    const corePath = `${projectPath}.core`;
    await ok(plan, 'create_project', { parent_path: 'global', key: project, name: 'work-log integration', summary: 'it' });
    const core = await ok(plan, 'create_component',
      { parent_path: projectPath, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const { session_id } = await ok(plan, 'open_session', { node_path: projectPath, kind: 'planning' });
    const dispatch = async (title: string) => (await ok(plan, 'create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title, prompt: 'p', segment_id: session_id,
      task_files: ['src/x.ts', 'src/x.ts'], vision_none_reason: 'it',
    })).id as string;
    const d1 = await dispatch('logged');
    const d2 = await dispatch('unlogged');
    const stored = await db.query('SELECT task_files FROM ops.dispatches WHERE id = $1', [d1]);
    assert.deepEqual(stored.rows[0].task_files, ['src/x.ts'], 'task_files stored deduped');

    const pending = await ok(exec, 'get_pending', { node_path: corePath });
    assert.deepEqual(pending.rows.map((r: Json) => r.id).sort(), [d1, d2].sort());

    // d1: claim, then complete with work.
    const c1 = await ok(exec, 'claim_dispatch', { id: d1 });
    assert.notEqual(c1.work_log, null);
    assert.equal(c1.work_log.rows.some((r: Json) => r.dispatch_id === d1), false);
    const done = await ok(exec, 'complete_dispatch', {
      id: d1, result: 'r', report: 'rep',
      work: { entry_type: 'feature', title: 'it', files_changed: ['src/x.ts'], external_refs: [{ kind: 'commit', sha: 'abc' }] },
    });
    assert.equal(done.status, 'done');
    const logged = await db.query(
      `SELECT w.id, w.entry_type, w.title, w.files_changed, w.external_refs, w.origin, w.provenance::text, n.path::text AS node
         FROM ops.work_log w JOIN ops.work_log_nodes wn ON wn.work_log_id = w.id JOIN ops.nodes n ON n.id = wn.node_id
        WHERE w.dispatch_id = $1`, [d1]);
    assert.deepEqual(logged.rows, [{
      id: done.work_log_id, entry_type: 'feature', title: 'it', files_changed: ['src/x.ts'],
      external_refs: [{ kind: 'commit', sha: 'abc' }], origin: 'code', provenance: 'recorded', node: corePath,
    }], 'one work_log row and one work_log_nodes row on the component node');
    assert.equal((await db.query('SELECT node_id FROM ops.components WHERE id = $1', [core.id])).rows[0].node_id,
      (await db.query('SELECT node_id FROM ops.work_log_nodes WHERE work_log_id = $1', [done.work_log_id])).rows[0].node_id);
    assert.equal((await db.query('SELECT status::text FROM ops.dispatches WHERE id = $1', [d1])).rows[0].status, 'done');

    // d2: the claim delivers d1's row first, with file_overlap; completion without work is refused.
    const c2 = await ok(exec, 'claim_dispatch', { id: d2 });
    assert.equal(c2.work_log.rows[0].id, done.work_log_id);
    assert.equal(c2.work_log.rows[0].file_overlap, true);
    assert.equal(c2.work_log.rows[0].dispatch_id, d1);
    const refused = await exec('complete_dispatch', { id: d2, result: 'r', report: 'rep' });
    assert.equal(refused.isError, true);
    assert.equal(refused.text,
      `Validation error (23514): dispatch ${d2.slice(0, 8)} (commit_policy local) has no work_log entry; call ops.log_work first`);
    assert.equal((await db.query('SELECT status::text FROM ops.dispatches WHERE id = $1', [d2])).rows[0].status, 'claimed');
    assert.equal((await db.query('SELECT count(*)::int AS n FROM ops.work_log WHERE dispatch_id = $1', [d2])).rows[0].n, 0);
  } finally {
    for (const [server, client] of clients) {
      await client.close().catch(() => undefined);
      await server.close().catch(() => undefined);
    }
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
