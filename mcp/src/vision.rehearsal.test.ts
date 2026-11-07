// Integration test for the vision tools and the vision inputs of create_dispatch / log_decision / add_backlog_item
// against the rehearsal database (migration 0032): a small item tree on a project the test creates, dispatch links
// (item and none reason) written with the dispatch in one transaction, a refused link leaving no dispatch, link /
// unlink by 8-hex prefix, shipped refused while a blocking backlog item is open, and vision_check / vision_status.
// Runs on one connection inside a transaction that is always rolled back; tool statements run under savepoints
// (inTransaction's BEGIN / COMMIT / ROLLBACK become one), as in planner.rehearsal.test.ts, and as the URL's role.
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
import { registerPlanner } from './tools/planner.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';
const skip = url === '' && 'LOCAL_OPS_REHEARSAL_URL not set';
type Json = Record<string, any>;

test('rehearsal: vision tools, and dispatch / decision / backlog links written in the same transaction', { skip }, async () => {
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
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'vision-it', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Json) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const ok = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text);
  };
  const refused = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, true, `${name} should have been refused: ${r.text}`);
    return r.text;
  };
  try {
    const present = (await db.query("SELECT to_regprocedure('ops.vision_link(jsonb,uuid)') IS NOT NULL AS present")).rows[0].present;
    assert.equal(present, true, 'rehearsal has ops.vision_link (0032)');

    const hex = randomBytes(4).toString('hex');
    const projectPath = `global.it-vis-${hex}`;
    const corePath = `${projectPath}.core`;
    await ok('create_project', { parent_path: 'global', key: `it-vis-${hex}`, name: 'vision integration', summary: 'it' });
    await ok('create_component', { parent_path: projectPath, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const seg = session_id.slice(0, 8);

    // A root, a child under its key, and a child whose key is not under the root's key (vision_status follows parents).
    const root = `itv_${hex}`;
    const child = `${root}.a`;
    const other = `itw_${hex}`;
    const item = (key: string, parent_key: string | null, status: string) =>
      ({ key, parent_key, home_node_path: projectPath, title: key, intent: 'i', acceptance: 'a', status, phase: 'setup' });
    assert.deepEqual(await ok('vision_upsert', {
      items: [item(root, null, 'idea'), item(child, root, 'designed'), item(other, root, 'idea')], segment_id: seg,
    }), { inserted: 3, updated: 0, status_changes: 0 });

    const dispatchRows = async () => (await db.query(
      `SELECT d.id FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id JOIN ops.nodes n ON n.id = c.node_id
        WHERE n.path OPERATOR(public.=) $1::public.ltree`, [corePath])).rows.length;
    const dispatch = (title: string, vision: Json) => call('create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title, prompt: 'p', segment_id: session_id, ...vision,
    });

    const d1 = JSON.parse((await dispatch('linked', { vision_item: child })).text);
    const l1 = await db.query(
      'SELECT i.key, x.none_reason FROM ops.vision_dispatches x LEFT JOIN ops.vision_items i ON i.id = x.item_id WHERE x.dispatch_id = $1',
      [d1.id]);
    assert.deepEqual(l1.rows, [{ key: child, none_reason: null }]);
    assert.equal(d1.status, 'pending', 'the result is the dispatch row');

    const d2 = JSON.parse((await dispatch('unlinked', { vision_none_reason: 'probe only' })).text);
    const l2 = await db.query('SELECT item_id, none_reason FROM ops.vision_dispatches WHERE dispatch_id = $1', [d2.id]);
    assert.deepEqual(l2.rows, [{ item_id: null, none_reason: 'probe only' }]);

    assert.equal(await dispatchRows(), 2);
    const bad = await dispatch('unknown item', { vision_item: `${root}.nope` });
    assert.equal(bad.isError, true);
    assert.equal(bad.text, `Validation error (23514): vision_link element 1: vision item ${root}.nope does not exist`);
    assert.equal(await dispatchRows(), 2, 'a refused link leaves no dispatch');
    assert.match(await refused('create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title: 'neither', prompt: 'p', segment_id: session_id,
    }), /exactly one of vision_item and vision_none_reason is required/);

    // Decision linked on creation, then unlinked and relinked by prefix.
    const dec = await ok('log_decision', {
      node_path: projectPath, decision: 'vision it', segment_id: session_id, vision_item: root, vision_relation: 'defines',
    });
    const decLinks = async () => (await db.query(
      'SELECT relation FROM ops.vision_decisions WHERE decision_id = $1', [dec.id])).rows.map((r) => r.relation);
    assert.deepEqual(await decLinks(), ['defines']);
    assert.deepEqual(await ok('vision_unlink', { links: [{ item_key: root, kind: 'decision', ref: dec.id.slice(0, 8) }], segment_id: seg }),
      { removed: 1 });
    assert.deepEqual(await decLinks(), []);
    assert.deepEqual(await ok('vision_link', {
      links: [{ item_key: root, kind: 'decision', ref: dec.id.slice(0, 8), relation: 'refines' }], segment_id: seg,
    }), { linked: 1, updated: 0 });
    assert.deepEqual(await decLinks(), ['refines']);

    // A blocking backlog item stops shipped.
    const bl = await ok('add_backlog_item', {
      node_path: corePath, title: 'blocker', kind: 'task', vision_item: child, vision_role: 'blocks', segment_id: seg,
    });
    assert.equal(bl.source_dispatch_id, null, 'result shape unchanged');
    assert.equal(await refused('vision_set_status', { key: child, status: 'shipped', reason: 'done', segment_id: seg }),
      `Validation error (23514): vision item ${child}: cannot be shipped while blocking backlog items are open: ${bl.id.slice(0, 8)}`);
    assert.deepEqual(await ok('vision_set_status', { key: child, status: 'partial', reason: 'started', segment_id: seg }),
      { key: child, changed: true });
    assert.equal(await refused('vision_true_close', { key: child, evidence: 'e', segment_id: seg }),
      `Validation error (23514): vision item ${child}: is partial, not shipped`);

    const checks = (await ok('vision_check', {})) as Json[];
    assert.ok(checks.some((r) => r.check_kind === 'rollup_mismatch' && r.item_key === root), 'root idea, children partial');
    assert.ok(checks.some((r) => r.check_kind === 'none_reason' && r.ref === d2.id && r.detail === 'probe only'));
    assert.ok(!checks.some((r) => r.check_kind === 'unlinked_dispatch' && [d1.id, d2.id].includes(r.ref)));

    const under = (await ok('vision_status', { under: root })) as Json[];
    assert.deepEqual(under.map((r) => r.key), [root, child, other].sort());
    assert.equal(under.find((r) => r.key === root)?.rollup_status, 'partial');
    assert.deepEqual(((await ok('vision_status', { under: child })) as Json[]).map((r) => r.key), [child]);
    const all = ((await ok('vision_status', {})) as Json[]).map((r) => r.key);
    assert.ok([root, child, other].every((k) => all.includes(k)));
    assert.equal(await refused('vision_status', { under: `${root}.nope` }), `vision item ${root}.nope does not exist`);
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
