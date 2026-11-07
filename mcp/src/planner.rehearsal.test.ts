// Integration tests for the planner writer tools (node-keyed functions of migration 0018) and the executor's
// get_pending / claim_dispatch against the rehearsal database.
// Each test runs on one connection inside a transaction that is always rolled back, and uses only a project
// it creates itself. Tool statements run under savepoints so a refused call (or inTransaction's own
// BEGIN/COMMIT/ROLLBACK) never ends the outer transaction.
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

interface Ctx {
  db: pg.Client;
  // A tool call that must succeed; returns its parsed JSON.
  ok: (name: string, args: Json) => Promise<Json>;
  // A tool call that must fail; returns its error text.
  refused: (name: string, args: Json) => Promise<string>;
  // An executor tool call on the same connection that must succeed; returns its parsed JSON.
  execOk: (name: string, args: Json) => Promise<Json>;
  // A fresh project with component 'core' (verify_cmd set), created through the tools; its node path and the
  // component's node path.
  project: string;
  projectPath: string;
  corePath: string;
  columns: (table: string) => Promise<string[]>;
}

async function withRehearsal(fn: (c: Ctx) => Promise<void>): Promise<void> {
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
  // inTransaction's BEGIN / COMMIT / ROLLBACK become a savepoint inside the outer transaction.
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
  const client = new Client({ name: 'planner-it', version: '1.0.0' });
  await client.connect(b);
  const execServer = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerExecutor(execServer, pool);
  const [ea, eb] = InMemoryTransport.createLinkedPair();
  await execServer.connect(ea);
  const execClient = new Client({ name: 'executor-it', version: '1.0.0' });
  await execClient.connect(eb);
  const callOn = async (on: Client, name: string, args: Json) => {
    const r = (await on.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const call = (name: string, args: Json) => callOn(client, name, args);
  const ok = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text) as Json;
  };
  const execOk = async (name: string, args: Json) => {
    const r = await callOn(execClient, name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text) as Json;
  };
  const refused = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, true, `${name} should have been refused: ${r.text}`);
    return r.text;
  };
  const columns = async (table: string) => (await db.query(
    `SELECT column_name FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = $1
      ORDER BY ordinal_position`, [table])).rows.map((r) => r.column_name as string);
  try {
    const project = `it-m4a-${randomBytes(4).toString('hex')}`;
    const projectPath = `global.${project}`;
    const corePath = `${projectPath}.core`;
    await ok('create_project', { parent_path: 'global', key: project, name: 'M4a integration', summary: 'it' });
    await ok('create_component', { parent_path: projectPath, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    await fn({ db, ok, refused, project, projectPath, corePath, columns, execOk });
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await execClient.close().catch(() => undefined);
    await execServer.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
}

test('rehearsal: create_project / create_component write nodes and keep the table row shape', { skip }, () =>
  withRehearsal(async ({ db, ok, project, columns }) => {
    const p = await ok('create_project', { parent_path: 'global', key: `${project}-b`, name: 'second', params: { a: 1 }, summary: 'it' });
    assert.deepEqual(Object.keys(p), await columns('projects'));
    const pn = await db.query('SELECT n.kind, g.kind AS parent_kind FROM ops.nodes n JOIN ops.nodes g ON g.id = n.parent_id WHERE n.id = $1', [p.node_id]);
    assert.deepEqual(pn.rows[0], { kind: 'project', parent_kind: 'global' });

    const c = await ok('create_component', { parent_path: `global.${project}-b`, key: 'web', kind: 'app', repo_ref: 'r', summary: 'it' });
    assert.deepEqual(Object.keys(c), await columns('components'));
    const cn = await db.query('SELECT parent_id, component_id FROM ops.nodes WHERE id = $1', [c.node_id]);
    assert.deepEqual(cn.rows[0], { parent_id: p.node_id, component_id: c.id });
  }));

test('rehearsal: open_session scope explicit and defaulted; create_dispatch / log_decision link session and node', { skip }, () =>
  withRehearsal(async ({ db, ok, projectPath, corePath, columns }) => {
    const { session_id: defaulted } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const { session_id: global } = await ok('open_session', { node_path: projectPath, kind: 'planning', scope: 'global' });
    const scopes = await db.query('SELECT id, scope::text FROM ops.sessions WHERE id = ANY($1::uuid[])', [[defaulted, global]]);
    const scopeOf = Object.fromEntries(scopes.rows.map((r) => [r.id, r.scope]));
    assert.equal(scopeOf[defaulted], 'project', 'a project outside global.local-ops defaults to project');
    assert.equal(scopeOf[global], 'global');

    const d = await ok('create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title: 't', prompt: 'p',
      segment_id: defaulted, vision_none_reason: 'it',
    });
    assert.deepEqual(Object.keys(d), await columns('dispatches'));
    assert.equal(d.session_id, defaulted);
    assert.equal(d.status, 'pending');
    const dn = await db.query(
      'SELECT c.node_id = dn.node_id AS home FROM ops.dispatch_nodes dn JOIN ops.components c ON c.id = $2 WHERE dn.dispatch_id = $1',
      [d.id, d.component_id]);
    assert.deepEqual(dn.rows, [{ home: true }]);

    const dec = await ok('log_decision', { node_path: projectPath, decision: 'x', segment_id: defaulted });
    assert.deepEqual(Object.keys(dec), await columns('decisions'));
    assert.equal(dec.session_id, defaulted);
    const decn = await db.query(
      'SELECT p.node_id = dn.node_id AS home FROM ops.decision_nodes dn JOIN ops.projects p ON p.id = $2 WHERE dn.decision_id = $1',
      [dec.id, dec.project_id]);
    assert.deepEqual(decn.rows, [{ home: true }]);
  }));

test('rehearsal: add_backlog_item allowed_bug with severity; update_backlog_item; shape is columns + source_dispatch_id', { skip }, () =>
  withRehearsal(async ({ db, ok, projectPath, corePath, columns }) => {
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const d = await ok('create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title: 't', prompt: 'p', segment_id: session_id,
      vision_none_reason: 'it',
    });
    const shape = [...await columns('backlog_items'), 'source_dispatch_id'];

    const b = await ok('add_backlog_item', {
      node_path: corePath, title: 'bug', kind: 'allowed_bug', severity: 'high', source_dispatch_id: d.id,
    });
    assert.deepEqual(Object.keys(b), shape);
    assert.equal(b.kind, 'allowed_bug');
    assert.equal(b.severity, 'high');
    assert.equal(b.source, `kind:allowed_bug|dispatch:${d.id}`);
    assert.equal(b.source_dispatch_id, d.id);
    const home = await db.query('SELECT node_id FROM ops.components WHERE id = $1', [d.component_id]);
    assert.equal(b.home_node_id, home.rows[0].node_id);

    const plain = await ok('add_backlog_item', { node_path: projectPath, title: 'task', kind: 'task' });
    assert.equal(plain.severity, 'untriaged');
    assert.equal(plain.source_dispatch_id, null);

    const done = await ok('update_backlog_item', { id: b.id, status: 'done', detail: 'fixed' });
    assert.deepEqual(Object.keys(done), shape);
    assert.equal(done.status, 'done');
    assert.notEqual(done.closed_at, null);
    assert.equal(done.detail, 'fixed');
    const reopened = await ok('update_backlog_item', { id: b.id, status: 'open' });
    assert.equal(reopened.closed_at, null);
    assert.equal(reopened.detail, 'fixed');
    assert.equal(reopened.severity, 'high', 'severity omitted: unchanged');

    const triaged = await ok('update_backlog_item', { id: plain.id, status: 'open', severity: 'critical' });
    assert.deepEqual(Object.keys(triaged), shape);
    assert.equal(triaged.severity, 'critical');
    const later = await ok('update_backlog_item', { id: plain.id, status: 'done' });
    assert.equal(later.severity, 'critical', 'severity omitted on a later call: unchanged');
    assert.equal(later.status, 'done');
  }));

test('rehearsal: refused inputs surface as validation errors carrying the database message', { skip }, () =>
  withRehearsal(async ({ db, ok, refused, project, projectPath, corePath }) => {
    const type = `it_inactive_${randomBytes(3).toString('hex')}`;
    await db.query(`INSERT INTO ops.dispatch_types (type, description, commit_policy, active) VALUES ($1, 'it', 'none', false)`, [type]);
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const base = { node_path: corePath, dispatch_type: 'modification', title: 't', prompt: 'p', segment_id: session_id,
      vision_none_reason: 'it' };

    assert.equal(await refused('create_dispatch', { ...base, node_path: `${projectPath}.nope` }),
      `Validation error (P0001): unknown component ${projectPath}.nope`);
    assert.equal(await refused('create_dispatch', { ...base, dispatch_type: type }),
      `Validation error (23514): dispatch type "${type}" is not active`);
    assert.match(await refused('create_dispatch', { ...base, context_refs: ['NO_SUCH_DOC_IT'] }),
      /^Validation error \(23514\): context ref "NO_SUCH_DOC_IT" does not resolve: /);
    assert.equal(await refused('log_decision', {
      node_path: projectPath, decision: 'x', supersedes: '00000000-0000-4000-8000-000000000000', segment_id: session_id,
    }),
      `Validation error (23514): superseded decision 00000000-0000-4000-8000-000000000000 does not exist in ${projectPath} (the scope of ${projectPath})`);
    assert.equal(await refused('add_backlog_item', { node_path: `${projectPath}.nope`, title: 't', kind: 'task' }),
      `Validation error (P0001): unknown node ${projectPath}.nope`);

    const written = await db.query('SELECT count(*)::int AS n FROM ops.dispatches d JOIN ops.projects p ON p.id = d.project_id WHERE p.key = $1', [project]);
    assert.equal(written.rows[0].n, 0, 'no refused dispatch was written');

    const decisions = async () => (await db.query(
      'SELECT count(*)::int AS n FROM ops.decisions d JOIN ops.projects p ON p.id = d.project_id WHERE p.key = $1', [project])).rows[0].n;
    const before = await decisions();
    assert.match(await refused('log_decision', { node_path: projectPath, decision: 'no session' }), /segment_id is required/);
    assert.equal(await decisions(), before, 'a log_decision without segment_id writes no row');
  }));

test('rehearsal: list_backlog kind is the column; the kind filter runs on the column', { skip }, () =>
  withRehearsal(async ({ db, ok, project, projectPath }) => {
    // home_node_id is the project's node (the home rule for a row without component); NOT NULL since 0015
    const p = await db.query('SELECT id, node_id FROM ops.projects WHERE key = $1', [project]);
    const ins = async (title: string, source: string, kind: string) => (await db.query(
      `INSERT INTO ops.backlog_items (project_id, title, source, kind, home_node_id)
       VALUES ($1, $2, $3, $4::ops.backlog_kind, $5) RETURNING id`,
      [p.rows[0].id, title, source, kind, p.rows[0].node_id])).rows[0].id as string;
    const column = await ins('column wins', 'kind:followup', 'task');

    const all = await ok('list_backlog', { node_path: projectPath });
    const kindOf = Object.fromEntries((all as Json[]).map((b) => [b.id, b.kind]));
    assert.equal(kindOf[column], 'task');
    for (const b of all as Json[]) assert.ok('component_path' in b && 'source_dispatch_id' in b);

    const ids = async (kind: string) => ((await ok('list_backlog', { node_path: projectPath, kind })) as Json[]).map((b) => b.id);
    assert.deepEqual(await ids('task'), [column]);
    assert.deepEqual(await ids('followup'), [], 'the kind in source does not match');
  }));

test('rehearsal: reconstruct_session stores its span; a failed close leaves no session', { skip }, () =>
  withRehearsal(async ({ db, ok, refused, project, projectPath, corePath }) => {
    const hour = 3600_000;
    const occurred_at = new Date(Date.now() - 3 * hour).toISOString();
    const closed_at = new Date(Date.now() - 2 * hour).toISOString();
    const r = await ok('reconstruct_session', {
      node_path: corePath, kind: 'execution', occurred_at, closed_at,
      summary: 's', next_step: 'n', decisions: [{ decision: 'inline' }],
    });
    assert.equal(r.decisions_recorded, 1);
    const s = await db.query(
      `SELECT occurred_at, closed_at, provenance::text, status, close_reason::text FROM ops.sessions WHERE id = $1`, [r.session_id]);
    assert.deepEqual(s.rows[0], {
      occurred_at: new Date(occurred_at), closed_at: new Date(closed_at), provenance: 'reconstructed', status: 'closed',
      close_reason: 'normal',
    });

    const before = await db.query('SELECT count(*)::int AS n FROM ops.sessions s JOIN ops.projects p ON p.id = s.project_id WHERE p.key = $1', [project]);
    const text = await refused('reconstruct_session', {
      node_path: projectPath, kind: 'planning', occurred_at: closed_at, closed_at: occurred_at, summary: 's', next_step: 'n',
    });
    assert.match(text, /^Validation error \(23514\): closed_at .* is outside occurred_at/);
    const after = await db.query('SELECT count(*)::int AS n FROM ops.sessions s JOIN ops.projects p ON p.id = s.project_id WHERE p.key = $1', [project]);
    assert.equal(after.rows[0].n, before.rows[0].n, 'the opened session was rolled back with the failed close');
  }));

// adopt_orphans adopted null-session rows until 0022 made session_id NOT NULL and 0023 dropped ops.adopt_orphans; the
// tool is removed with it. Not skipped: the check reads only the tool lists and needs no database.
test('rehearsal: adopt_orphans is not registered on the planner or the executor', async () => {
  const pool = { query: async () => assert.fail('no database call expected') } as unknown as pg.Pool;
  for (const register of [registerPlanner, registerExecutor]) {
    const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
    register(server, pool);
    const [a, b] = InMemoryTransport.createLinkedPair();
    await server.connect(a);
    const client = new Client({ name: 'planner-it', version: '1.0.0' });
    await client.connect(b);
    try {
      const { tools: listed } = await client.listTools();
      assert.ok(listed.length > 0, `${register.name} registered tools`);
      assert.equal(listed.find((x) => x.name === 'adopt_orphans'), undefined, `${register.name}: adopt_orphans is not listed`);
    } finally {
      await client.close();
      await server.close();
    }
  }
});

test('rehearsal: segment_id links log_decision to the session and closes it', { skip }, () =>
  withRehearsal(async ({ db, ok, projectPath }) => {
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const dec = await ok('log_decision', { node_path: projectPath, decision: 'via segment_id', segment_id: session_id });
    const stored = await db.query('SELECT session_id FROM ops.decisions WHERE id = $1', [dec.id]);
    assert.equal(stored.rows[0].session_id, session_id);

    const closed = await ok('close_session', {
      segment_id: session_id, summary: 's', next_step: 'n', decisions: [{ decision: 'at close' }],
    });
    assert.deepEqual(closed, { session_id, decisions_recorded: 1 });
    const s = await db.query('SELECT closed_at IS NOT NULL AS closed FROM ops.sessions WHERE id = $1', [session_id]);
    assert.deepEqual(s.rows, [{ closed: true }]);
  }));

test('rehearsal: close_session decision items carry supersedes; a foreign or unknown id is refused', { skip }, () =>
  withRehearsal(async ({ db, ok, refused, project, projectPath }) => {
    // 0023 makes close_session's supersedes check node-based, with a new message (M5b release 2).
    const newest = (await db.query('SELECT max(version) AS v FROM ops.schema_migrations')).rows[0].v as string;
    const { session_id: prior } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const old = await ok('log_decision', { node_path: projectPath, decision: 'old', segment_id: prior });
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const supersedesOf = async (sid: string) => (await db.query(
      'SELECT decision, supersedes FROM ops.decisions WHERE session_id = $1 ORDER BY decision', [sid])).rows;
    const sessionClosed = async (sid: string) =>
      (await db.query('SELECT closed_at IS NOT NULL AS closed FROM ops.sessions WHERE id = $1', [sid])).rows[0].closed;

    // A decision of another project, and an id that is no decision at all.
    const other = `${project}-x`;
    await ok('create_project', { parent_path: 'global', key: other, name: 'other', summary: 'it' });
    const { session_id: otherSession } = await ok('open_session', { node_path: `global.${other}`, kind: 'planning' });
    const foreign = await ok('log_decision', { node_path: `global.${other}`, decision: 'foreign', segment_id: otherSession });
    for (const bad of [foreign.id, '00000000-0000-4000-8000-000000000000']) {
      const text = await refused('close_session', {
        segment_id: session_id, summary: 's', next_step: 'n', decisions: [{ decision: 'bad', supersedes: bad }],
      });
      assert.equal(text, newest >= '0023'
        ? `Validation error (23514): superseded decision ${bad} does not exist in ${projectPath} (the scope of session ${session_id})`
        : `Validation error (23514): superseded decision ${bad} does not exist in the project of session ${session_id}`);
      assert.deepEqual(await supersedesOf(session_id), [], 'nothing recorded');
      assert.equal(await sessionClosed(session_id), false, 'the session stays open');
    }

    const closed = await ok('close_session', {
      segment_id: session_id, summary: 's', next_step: 'n',
      decisions: [{ decision: 'new', supersedes: old.id }, { decision: 'plain' }],
    });
    assert.deepEqual(closed, { session_id, decisions_recorded: 2 });
    assert.deepEqual(await supersedesOf(session_id), [
      { decision: 'new', supersedes: old.id }, { decision: 'plain', supersedes: null },
    ]);
  }));

test('rehearsal: reconstruct_session decision items carry supersedes', { skip }, () =>
  withRehearsal(async ({ db, ok, projectPath }) => {
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const old = await ok('log_decision', { node_path: projectPath, decision: 'old', segment_id: session_id });
    const hour = 3600_000;
    const r = await ok('reconstruct_session', {
      node_path: projectPath, kind: 'planning',
      occurred_at: new Date(Date.now() - 3 * hour).toISOString(), closed_at: new Date(Date.now() - 2 * hour).toISOString(),
      summary: 's', next_step: 'n', decisions: [{ decision: 'new', supersedes: old.id }],
    });
    assert.equal(r.decisions_recorded, 1);
    const stored = await db.query('SELECT supersedes FROM ops.decisions WHERE session_id = $1', [r.session_id]);
    assert.deepEqual(stored.rows, [{ supersedes: old.id }]);
  }));

test('rehearsal: 8-hex id prefixes resolve to the full id; an unmatched prefix writes nothing', { skip }, () =>
  withRehearsal(async ({ db, ok, refused, projectPath }) => {
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const old = await ok('log_decision', { node_path: projectPath, decision: 'old', segment_id: session_id.slice(0, 8) });
    assert.equal(old.session_id, session_id, 'the row carries the resolved session id');
    const neu = await ok('log_decision', {
      node_path: projectPath, decision: 'new', segment_id: session_id.slice(0, 8).toUpperCase(), supersedes: old.id.slice(0, 8),
    });
    assert.equal(neu.supersedes, old.id);

    // A prefix no session has: flip the first hex digit of an existing id until no session matches.
    let unmatched = '';
    for (const h of '0123456789abcdef') {
      const p = h + session_id.slice(1, 8);
      if ((await db.query("SELECT 1 FROM ops.sessions WHERE id::text LIKE $1 || '%'", [p])).rowCount === 0) { unmatched = p; break; }
    }
    const count = async () => (await db.query('SELECT count(*)::int AS n FROM ops.decisions WHERE session_id = $1', [session_id])).rows[0].n;
    const before = await count();
    assert.equal(await refused('log_decision', { node_path: projectPath, decision: 'x', segment_id: unmatched }),
      `MCP error -32602: Input validation error: Invalid arguments for tool log_decision: segment_id: prefix ${unmatched} matched 0 rows in sessions`);
    assert.equal(await count(), before, 'nothing written');
  }));

test('rehearsal: an unknown node_path is a validation error; open_session refuses the global path and a path with no project', { skip }, (t) =>
  withRehearsal(async ({ db, ok, refused, project, projectPath }) => {
    const unknown = `${projectPath}.nope`;
    for (const [tool, args] of [
      ['open_session', { node_path: unknown, kind: 'planning' }],
      ['get_unreviewed_reports', { node_path: unknown }],
      ['resolve_context', { node_path: unknown, ref: 'IT_DOC' }],
      ['log_decision', { node_path: unknown, decision: 'x', segment_id: '00000000-0000-4000-8000-000000000000' }],
      ['create_component', { parent_path: unknown, key: 'k', kind: 'service', repo_ref: 'r', summary: 'it' }],
    ] as const) {
      assert.equal(await refused(tool, args), `Validation error (P0001): unknown node ${unknown}`, tool);
    }
    for (const [tool, args] of [
      ['list_queue', { node_path: unknown }], ['list_backlog', { node_path: unknown }],
      ['mark_reviewed', { node_path: unknown, ids: ['00000000-0000-4000-8000-000000000000'] }],
    ] as const) {
      assert.equal(await refused(tool, args), `unknown node ${unknown}`, tool);
    }

    const sessions = async () => (await db.query('SELECT count(*)::int AS n FROM ops.sessions')).rows[0].n;
    const before = await sessions();
    const hour = 3600_000;
    // 0023 lifts both refusals (M5b release 2): from 0023 on the opens succeed with no project and the opened node.
    const newest = (await db.query('SELECT max(version) AS v FROM ops.schema_migrations')).rows[0].v as string;
    if (newest >= '0023') {
      t.diagnostic(`skip: global-path and outside-a-project refusals are lifted from 0023 on (rehearsal ledger newest ${newest})`);
      const row = async (id: string) => (await db.query(
        `SELECT s.project_id, s.component_id, n.path::text AS node, s.scope::text, s.status
           FROM ops.sessions s JOIN ops.nodes n ON n.id = s.node_id WHERE s.id = $1`, [id])).rows[0];
      const g = await ok('open_session', { node_path: 'global', kind: 'planning' });
      assert.deepEqual(await row(g.session_id),
        { project_id: null, component_id: null, node: 'global', scope: 'project', status: 'active' });
      const rc = await ok('reconstruct_session', {
        node_path: 'global', kind: 'planning', occurred_at: new Date(Date.now() - 2 * hour).toISOString(),
        closed_at: new Date(Date.now() - hour).toISOString(), summary: 's', next_step: 'n',
      });
      assert.deepEqual(await row(rc.session_id),
        { project_id: null, component_id: null, node: 'global', scope: 'project', status: 'closed' });
      await db.query(`INSERT INTO ops.nodes (parent_id, key, kind, title)
                      SELECT id, $1, 'node', 'loose' FROM ops.nodes WHERE kind = 'global'`, [`${project}-loose`]);
      const l = await ok('open_session', { node_path: `global.${project}-loose`, kind: 'planning' });
      assert.deepEqual(await row(l.session_id),
        { project_id: null, component_id: null, node: `global.${project}-loose`, scope: 'project', status: 'active' });
      assert.equal(await sessions(), before + 3, 'three sessions written');
      return;
    }
    assert.equal(await refused('open_session', { node_path: 'global', kind: 'planning' }),
      'Postgres error P0001: global-path sessions wait for release 2');
    assert.equal(await refused('reconstruct_session', {
      node_path: 'global', kind: 'planning', occurred_at: new Date(Date.now() - 2 * hour).toISOString(),
      closed_at: new Date(Date.now() - hour).toISOString(), summary: 's', next_step: 'n',
    }), 'Postgres error P0001: global-path sessions wait for release 2');
    // A node directly under global that is no project's node.
    await db.query(`INSERT INTO ops.nodes (parent_id, key, kind, title)
                    SELECT id, $1, 'node', 'loose' FROM ops.nodes WHERE kind = 'global'`, [`${project}-loose`]);
    assert.equal(await refused('open_session', { node_path: `global.${project}-loose`, kind: 'planning' }),
      `Postgres error P0001: unknown project for node global.${project}-loose (sessions outside a project wait for release 2)`);
    assert.equal(await sessions(), before, 'no session written');
  }));

test('rehearsal: list_queue, list_backlog, get_unreviewed_reports and mark_reviewed scope to the node subtree', { skip }, () =>
  withRehearsal(async ({ db, ok, refused, projectPath, corePath }) => {
    const webPath = `${projectPath}.web`;
    await ok('create_component', { parent_path: projectPath, key: 'web', kind: 'app', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const dispatch = async (node_path: string) => (await ok('create_dispatch', {
      node_path, dispatch_type: 'modification', title: 't', prompt: 'p', segment_id: session_id, vision_none_reason: 'it',
    })).id as string;
    const dc = await dispatch(corePath);
    const dw = await dispatch(webPath);

    const queue = async (node_path: string) => (await ok('list_queue', { node_path }) as unknown as Json[])
      .map((d) => [d.id, d.component_path]).sort();
    assert.deepEqual(await queue(corePath), [[dc, corePath]]);
    assert.deepEqual(await queue(webPath), [[dw, webPath]]);
    assert.deepEqual(await queue(projectPath), [[dc, corePath], [dw, webPath]].sort());

    const item = async (node_path: string) =>
      (await ok('add_backlog_item', { node_path, title: node_path, kind: 'task' })).id as string;
    const bc = await item(corePath);
    const bw = await item(webPath);
    const bp = await item(projectPath);
    const backlog = async (node_path: string) => (await ok('list_backlog', { node_path }) as unknown as Json[])
      .map((b) => [b.id, b.component_path]).sort();
    assert.deepEqual(await backlog(corePath), [[bc, corePath]]);
    assert.deepEqual(await backlog(projectPath), [[bc, corePath], [bw, webPath], [bp, null]].sort());

    // Finish both dispatches so they are reviewable.
    // From 0028 a modification dispatch needs a work_log row before complete_dispatch.
    const logWork = (await db.query(
      "SELECT to_regprocedure('ops.log_work(uuid,text,text,text,text[],jsonb,text,jsonb)') IS NOT NULL AS present",
    )).rows[0].present as boolean;
    for (const id of [dc, dw]) {
      await db.query("SELECT ops.claim_dispatch($1, 'it')", [id]);
      if (logWork) await db.query("SELECT ops.log_work($1, 'chore', 'it')", [id]);
      await db.query("SELECT ops.complete_dispatch($1, 'r', 'report')", [id]);
    }
    const unreviewed = async (node_path: string) =>
      (await ok('get_unreviewed_reports', { node_path }) as unknown as Json[]).map((d) => d.id).sort();
    assert.deepEqual(await unreviewed(corePath), [dc]);
    assert.deepEqual(await unreviewed(projectPath), [dc, dw].sort());

    assert.equal(await refused('mark_reviewed', { node_path: corePath, ids: [dc, dw] }),
      `not dispatches under node ${corePath}: ${dw}`);
    assert.deepEqual(await unreviewed(projectPath), [dc, dw].sort(), 'a refused call marks nothing');
    assert.deepEqual(await ok('mark_reviewed', { node_path: projectPath, ids: [dc, dw.slice(0, 8)] }), { marked: 2, requested: 2 });
    assert.deepEqual(await unreviewed(projectPath), []);
  }));

test('rehearsal: resolve_context and the executor get_pending / claim_dispatch work by node path', { skip }, () =>
  withRehearsal(async ({ db, ok, execOk, project, projectPath, corePath }) => {
    // A document on the project node; the component path resolves it as its nearest ancestor.
    const p = await db.query('SELECT id, node_id FROM ops.projects WHERE key = $1', [project]);
    await db.query(
      `INSERT INTO ops.context_documents (project_id, doc_key, title, content, node_id, doc_type)
       VALUES ($1, 'IT_DOC', 'it', $2, $3, 'manual')`,
      [p.rows[0].id, '# Top\nintro\n## Part\nbody', p.rows[0].node_id]);
    assert.equal(await ok('resolve_context', { node_path: corePath, ref: 'IT_DOC#Part' }), '## Part\nbody');
    assert.equal(await execOk('resolve_context', { node_path: corePath, ref: 'IT_DOC' }), '# Top\nintro\n## Part\nbody');

    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const d = await ok('create_dispatch', {
      node_path: corePath, dispatch_type: 'modification', title: 't', prompt: 'p', context_refs: ['IT_DOC#Part'],
      segment_id: session_id, vision_none_reason: 'it',
    });

    const rule = (await db.query("SELECT value FROM ops.protocol_rules WHERE key = 'batch_defaults'")).rows[0].value;
    const pending = await execOk('get_pending', { node_path: corePath });
    assert.deepEqual(pending.rows.map((r: Json) => r.id), [d.id], 'exactly the component at the path');
    assert.deepEqual(pending.caps, { implementation_max: rule.implementation_max, investigation_max: rule.investigation_max },
      'no project override: protocol defaults');

    // A project with a batch_defaults override: its component path reads the depth-2 project's params.
    await ok('create_project', { parent_path: 'global', key: `${project}-caps`, name: 'caps',
      params: { batch_defaults: { implementation_max: 2 } }, summary: 'it' });
    await ok('create_component', { parent_path: `global.${project}-caps`, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const capped = await execOk('get_pending', { node_path: `global.${project}-caps.core` });
    assert.deepEqual(capped.caps, { implementation_max: 2, investigation_max: rule.investigation_max });
    assert.equal(capped.returned, 0);

    const claimed = await execOk('claim_dispatch', { id: d.id });
    assert.equal(claimed.dispatch.id, d.id);
    assert.deepEqual(claimed.context, [{ ref: 'IT_DOC#Part', text: '## Part\nbody' }]);
  }));
