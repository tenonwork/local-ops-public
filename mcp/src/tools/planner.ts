// Planner tools. Every write goes through an ops function, which owns validation; the server-side checks left are
// the node lookup of list_queue / list_backlog / mark_reviewed and mark_reviewed's subtree membership. Node inputs
// are paths (node_path, or parent_path for create_project / create_component), passed to the 0018 node-keyed
// functions in named notation, by convention: it keeps each call explicit (the project-keyed overloads it once
// disambiguated from were dropped in 0021). Id inputs take a full UUID or an 8-hex prefix, resolved to one row
// (resolveId) before the ops function is called.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, describe, inTransaction, nodeId, rows, tool, type Row } from '../db.ts';
import { idRef, key, nodePath, registerCommon, resolveId, resolveOptional, withSegment } from './common.ts';
import { registerDecisions } from './decisions.ts';
import { registerDocs } from './docs.ts';
import { nodeSummary, overviewPresent, registerNodes, require0035 } from './nodes.ts';
import { inputError, registerVision, relation, role, visionLink, visionLinkPresent } from './vision.ts';

const dispatchStatus = z.enum(['pending', 'claimed', 'done', 'failed', 'refused_premise', 'cancelled']);
const backlogStatus = z.enum(['open', 'done', 'dropped']);
const backlogKind = z.enum(['task', 'followup', 'proposal', 'discussion', 'allowed_bug']);
const backlogSeverity = z.enum(['low', 'medium', 'high', 'critical', 'untriaged']);
const sessionKind = z.enum(['planning', 'execution']);
const params = z.record(z.string(), z.unknown());

const decisionInput = z.object({
  decision: z.string().min(1),
  rationale: z.string().optional(),
  rejected_alternatives: z.array(z.unknown()).optional(),
  revisit_condition: z.string().optional(),
  scope: z.string().optional(),
  supersedes: idRef.optional(),
});
type DecisionInput = z.infer<typeof decisionInput>;

// Decision items with each supersedes prefix resolved against decisions; other fields unchanged.
async function resolveDecisions(db: pg.Pool | pg.PoolClient, decisions: DecisionInput[], tool: string): Promise<DecisionInput[]> {
  const out: DecisionInput[] = [];
  for (const [i, d] of decisions.entries()) {
    out.push(d.supersedes === undefined ? d
      : { ...d, supersedes: await resolveId(db, 'decisions', d.supersedes, `${tool}.decisions[${i}].supersedes`) });
  }
  return out;
}

// The single row an ops writer function returns.
async function one(pool: pg.Pool, text: string, values: unknown[]): Promise<Row> {
  return (await rows(pool, text, values))[0];
}

// source is "kind:<kind>" optionally followed by "|dispatch:<uuid>".
export function parseSource(source: unknown): { kind: string | null; source_dispatch_id: string | null } {
  const m = /^kind:([a-z_]+)(?:\|dispatch:([0-9a-f-]{36}))?$/.exec(String(source ?? ''));
  return { kind: m?.[1] ?? null, source_dispatch_id: m?.[2] ?? null };
}

// kind is the backlog_items.kind column (NOT NULL since 0015); source gives only source_dispatch_id.
export function withSource(b: Row): Row {
  return { ...b, source_dispatch_id: parseSource(b.source).source_dispatch_id };
}

export function registerPlanner(server: McpServer, pool: pg.Pool): void {
  registerCommon(server, pool);
  registerVision(server, pool);
  registerDocs(server, pool);
  registerDecisions(server, pool);
  registerNodes(server, pool);

  // ── Function-backed
  server.registerTool('open_session', {
    description: 'Open a session at node_path (ops.open_session). Auto-closes stale active sessions of the same node first. The session is anchored to the opened node, which may be the global node or a node outside any project; it carries a project only when the node has a depth-2 project. scope (global / project) defaults in the database: global inside global.local-ops, else project. Returns the session id.'
      + ' Also returns overview, the opened node\'s bounded overview (ops.node_overview: node, context and document index,'
      + ' children, latest next_step at this node, open backlog), or overview_error if it could not be read; without'
      + ' migration 0036 only session_id is returned.',
    inputSchema: {
      node_path: nodePath,
      kind: sessionKind,
      scope: z.enum(['global', 'project']).optional(),
    },
  }, tool(async ({ node_path, kind, scope }) => {
    const [r] = await rows(pool,
      'SELECT ops.open_session(p_node_path => $1::public.ltree, p_kind => $2, p_scope => $3::ops.segment_scope) AS id',
      [node_path, kind, scope ?? null]);
    // The session is open from here on: an overview failure is reported beside its id, never instead of it.
    try {
      if (await overviewPresent(pool)) {
        const [o] = await rows(pool, 'SELECT ops.node_overview(p_node_path => $1::public.ltree) AS overview', [node_path]);
        return { session_id: r.id, overview: o.overview };
      }
      return { session_id: r.id };
    } catch (err) {
      return { session_id: r.id, overview_error: describe(err) };
    }
  }));

  server.registerTool('close_session', {
    description: 'Close an active session (ops.close_session), recording its decisions; segment_id (the session id) links each decision to the session. decisions must be given explicitly: [] if none were made. A decision item may carry supersedes (the id of an existing decision within the scope of the depth-2 node of the session). segment_id and supersedes are each a full UUID or 8-character id prefix.',
    inputSchema: withSegment({
      summary: z.string().min(1),
      next_step: z.string().min(1),
      decisions: z.array(decisionInput),
      reason: z.enum(['normal', 'erosion']).default('normal'),
    }, true),
  }, tool(async (a) => {
    const { summary, next_step, reason } = a;
    const session_id = await resolveOptional(pool, 'sessions', a.segment_id, 'close_session.segment_id');
    const decisions = await resolveDecisions(pool, a.decisions, 'close_session');
    const [r] = await rows(pool,
      'SELECT ops.close_session($1, $2, $3, $4::jsonb, $5::ops.close_reason) AS n',
      [session_id, summary, next_step, JSON.stringify(decisions), reason]);
    return { session_id, decisions_recorded: r.n };
  }));

  server.registerTool('cancel_dispatch', {
    description: 'Cancel a pending or claimed dispatch (ops.cancel_dispatch). id is a full UUID or 8-character id prefix. A reason is required.',
    inputSchema: { id: idRef, reason: z.string().min(1) },
  }, tool(async (a) => {
    const id = await resolveId(pool, 'dispatches', a.id, 'cancel_dispatch.id');
    const { reason } = a;
    await rows(pool, 'SELECT ops.cancel_dispatch($1, $2)', [id, reason]);
    return { id, status: 'cancelled' };
  }));

  server.registerTool('get_unreviewed_reports', {
    description: 'Finished dispatches (done / failed / refused_premise) not yet reviewed, oldest first, whose component node is in the subtree of node_path (ops.get_unreviewed_reports).',
    inputSchema: { node_path: nodePath },
  }, tool(async ({ node_path }) =>
    rows(pool, 'SELECT * FROM ops.get_unreviewed_reports(p_node_path => $1::public.ltree)', [node_path])));

  server.registerTool('mark_reviewed', {
    description: "Mark finished dispatches as reviewed (ops.mark_reviewed). Each id is a full UUID or 8-character id prefix; every id must be a dispatch whose component node is in the subtree of node_path.",
    inputSchema: { node_path: nodePath, ids: z.array(idRef).min(1).describe('full UUIDs or 8-character id prefixes') },
  }, tool(async ({ node_path, ids }) => inTransaction(pool, async (db) => {
    const root = await nodeId(db, node_path);
    const resolved: string[] = [];
    for (const [i, id] of ids.entries()) resolved.push(await resolveId(db, 'dispatches', id, `mark_reviewed.ids[${i}]`));
    const unique = [...new Set(resolved)];
    const found = await db.query(
      `SELECT d.id FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id
         JOIN ops.nodes cn ON cn.id = c.node_id JOIN ops.nodes root ON root.id = $1
        WHERE cn.path OPERATOR(public.<@) root.path AND d.id = ANY($2::uuid[])`,
      [root, unique]);
    const inSubtree = new Set(found.rows.map((r) => r.id as string));
    const foreign = unique.filter((id) => !inSubtree.has(id));
    if (foreign.length > 0) {
      throw new CheckError(`not dispatches under node ${node_path}: ${foreign.join(', ')}`);
    }
    const r = await db.query('SELECT ops.mark_reviewed($1::uuid[]) AS n', [unique]);
    return { marked: r.rows[0].n, requested: unique.length };
  })));

  // ── Reads
  server.registerTool('list_queue', {
    description: "List dispatches whose component node is in the subtree of node_path, newest first, optionally filtered by status. Each row names its component by node path (component_path). Prompt and report bodies are omitted (use get_unreviewed_reports or query).",
    inputSchema: { node_path: nodePath, status: dispatchStatus.optional(), limit: z.number().int().min(1).max(200).default(50) },
  }, tool(async ({ node_path, status, limit }) => {
    const root = await nodeId(pool, node_path);
    return rows(pool,
      `SELECT d.id, cn.path::text AS component_path, d.dispatch_type, d.title, d.status, d.priority,
              d.context_refs, d.claimed_by, d.claimed_at, d.completed_at, d.result, d.error,
              d.reviewed_at, d.created_at
         FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id
         JOIN ops.nodes cn ON cn.id = c.node_id JOIN ops.nodes root ON root.id = $1
        WHERE cn.path OPERATOR(public.<@) root.path AND ($2::ops.dispatch_status IS NULL OR d.status = $2)
        ORDER BY d.created_at DESC LIMIT $3`,
      [root, status ?? null, limit]);
  }));

  server.registerTool('list_backlog', {
    description: "List backlog items whose home node is in the subtree of node_path, optionally filtered by status and kind. Each row names its component by node path (component_path, null without a component).",
    inputSchema: { node_path: nodePath, status: backlogStatus.optional(), kind: backlogKind.optional() },
  }, tool(async ({ node_path, status, kind }) => {
    const root = await nodeId(pool, node_path);
    const items = await rows(pool,
      `SELECT b.*, cn.path::text AS component_path
         FROM ops.backlog_items b JOIN ops.nodes hn ON hn.id = b.home_node_id JOIN ops.nodes root ON root.id = $1
         LEFT JOIN ops.components c ON c.id = b.component_id LEFT JOIN ops.nodes cn ON cn.id = c.node_id
        WHERE hn.path OPERATOR(public.<@) root.path AND ($2::text IS NULL OR b.status = $2)
          AND ($3::ops.backlog_kind IS NULL OR b.kind = $3)
        ORDER BY b.created_at`,
      [root, status ?? null, kind ?? null]);
    return items.map(withSource);
  }));

  // ── Writers: each tool is one call to its ops.* function (migrations 0014, 0018); the database validates.
  server.registerTool('create_dispatch', {
    description: 'Create a pending dispatch for the component at node_path (ops.create_dispatch). The database checks: component active, dispatch_type active, every context_ref resolves at node_path (nearest ancestor-or-self), a verify_cmd for committing types, segment_id (the session id) within the scope of node_path (its depth-2 ancestor). segment_id is required: a full UUID or 8-character id prefix. task_files = the repo-relative files the dispatch will touch (stored as dispatches.task_files; the executor\'s claim delivers work-log rows touching them first); sent only when non-empty. Vision (once migration 0032 is installed): exactly one of vision_item (the key of the vision item the dispatch advances) and vision_none_reason is required, and ops.vision_link records it in the same transaction, so a refused link leaves no dispatch; before 0032 both are ignored.',
    inputSchema: withSegment({
      node_path: nodePath,
      dispatch_type: z.string().min(1),
      title: z.string().min(1),
      prompt: z.string().min(1),
      context_refs: z.array(z.string().min(1)).default([]),
      priority: z.number().int().default(100),
      task_files: z.array(z.string().min(1)).default([]),
      vision_item: z.string().min(1).optional(),
      vision_none_reason: z.string().regex(/\S/, 'must not be blank').optional(),
    }, true),
  }, tool(async (a) => {
    // The vision link only once ops.vision_link exists (0032); before that both vision inputs are ignored.
    const linked = await visionLinkPresent(pool);
    if (linked && (a.vision_item === undefined) === (a.vision_none_reason === undefined)) {
      throw inputError('create_dispatch', 'exactly one of vision_item and vision_none_reason is required');
    }
    // p_task_files (0029) only when non-empty, so the 7-argument function before 0029 still takes the call.
    const taskFiles = [...new Set(a.task_files)];
    const session = (await resolveOptional(pool, 'sessions', a.segment_id, 'create_dispatch.segment_id')) ?? null;
    const values: unknown[] = [a.node_path, a.dispatch_type, a.title, a.prompt, [...new Set(a.context_refs)], a.priority,
      session];
    if (taskFiles.length > 0) values.push(taskFiles);
    const text = `SELECT * FROM ops.create_dispatch(p_node_path => $1::public.ltree, p_dispatch_type => $2,
       p_title => $3, p_prompt => $4, p_context_refs => $5::text[], p_priority => $6, p_session => $7${
        taskFiles.length > 0 ? ', p_task_files => $8::text[]' : ''})`;
    if (!linked) return one(pool, text, values);
    // One transaction: a refused link leaves no dispatch.
    return inTransaction(pool, async (db) => {
      const d = (await db.query(text, values)).rows[0] as Row;
      await visionLink(db, [a.vision_item !== undefined
        ? { item_key: a.vision_item, kind: 'dispatch', ref: d.id as string }
        : { none_reason: a.vision_none_reason, kind: 'dispatch', ref: d.id as string }], session);
      return d;
    });
  }));

  server.registerTool('log_decision', {
    description: 'Append a decision homed at node_path (ops.log_decision; append-only: to change one, log a new decision with supersedes = the old id). segment_id (the session id) is required and links the row to its session; supersedes and segment_id must lie within the scope of node_path (its depth-2 ancestor); each is a full UUID or 8-character id prefix. vision_item and vision_relation (both or neither) link the decision to that vision item (ops.vision_link, same transaction, same session) once migration 0032 is installed; before 0032 they are ignored.',
    inputSchema: withSegment({
      node_path: nodePath,
      decision: z.string().min(1),
      rationale: z.string().optional(),
      rejected_alternatives: z.array(z.unknown()).default([]),
      revisit_condition: z.string().optional(),
      scope: z.string().optional(),
      supersedes: idRef.optional(),
      vision_item: z.string().min(1).optional(),
      vision_relation: relation.optional(),
    }, true),
  }, tool(async (a) => {
    if ((a.vision_item === undefined) !== (a.vision_relation === undefined)) {
      throw inputError('log_decision', 'vision_item and vision_relation are given together or not at all');
    }
    const text = `SELECT * FROM ops.log_decision(p_node_path => $1::public.ltree, p_decision => $2,
       p_rationale => $3, p_rejected_alternatives => $4::jsonb, p_revisit_condition => $5, p_scope => $6,
       p_supersedes => $7, p_session => $8)`;
    const values = async (db: pg.Pool | pg.PoolClient) =>
      [a.node_path, a.decision, a.rationale ?? null, JSON.stringify(a.rejected_alternatives),
       a.revisit_condition ?? null, a.scope ?? null,
       (await resolveOptional(db, 'decisions', a.supersedes, 'log_decision.supersedes')) ?? null,
       (await resolveOptional(db, 'sessions', a.segment_id, 'log_decision.segment_id')) ?? null];
    if (a.vision_item === undefined || !(await visionLinkPresent(pool))) return one(pool, text, await values(pool));
    return inTransaction(pool, async (db) => {
      const v = await values(db);
      const d = (await db.query(text, v)).rows[0] as Row;
      await visionLink(db, [{ item_key: a.vision_item, kind: 'decision', ref: d.id as string, relation: a.vision_relation }],
        v[7] as string | null);
      return d;
    });
  }));

  server.registerTool('add_backlog_item', {
    description: 'Add an open backlog item homed at node_path (ops.add_backlog_item) of kind task / followup / proposal / discussion / allowed_bug, optionally with a severity (default untriaged) and the dispatch it came from (source_dispatch_id: a full UUID or 8-character id prefix, within the scope of node_path). vision_item and vision_role (blocks / improves; both or neither, with segment_id, the session id as a full UUID or 8-character id prefix) link the item to that vision item (ops.vision_link, same transaction) once migration 0032 is installed; before 0032 they are ignored.',
    inputSchema: withSegment({
      node_path: nodePath,
      title: z.string().min(1),
      detail: z.string().optional(),
      kind: backlogKind,
      source_dispatch_id: idRef.optional(),
      severity: backlogSeverity.optional(),
      vision_item: z.string().min(1).optional(),
      vision_role: role.optional(),
    }, false),
  }, tool(async (a) => {
    if ((a.vision_item === undefined) !== (a.vision_role === undefined)) {
      throw inputError('add_backlog_item', 'vision_item and vision_role are given together or not at all');
    }
    if (a.vision_item !== undefined && a.segment_id === undefined) {
      throw inputError('add_backlog_item', 'segment_id is required with vision_item');
    }
    const text = `SELECT * FROM ops.add_backlog_item(p_node_path => $1::public.ltree, p_kind => $2::ops.backlog_kind, p_title => $3,
       p_detail => $4, p_source_dispatch => $5,
       p_severity => coalesce($6::ops.backlog_severity, 'untriaged'))`;
    const values = async (db: pg.Pool | pg.PoolClient) => [a.node_path, a.kind, a.title, a.detail ?? null,
      (await resolveOptional(db, 'dispatches', a.source_dispatch_id, 'add_backlog_item.source_dispatch_id')) ?? null,
      a.severity ?? null];
    if (a.vision_item === undefined || !(await visionLinkPresent(pool))) {
      return withSource(await one(pool, text, await values(pool)));
    }
    return withSource(await inTransaction(pool, async (db) => {
      const session = (await resolveOptional(db, 'sessions', a.segment_id, 'add_backlog_item.segment_id')) ?? null;
      const b = (await db.query(text, await values(db))).rows[0] as Row;
      await visionLink(db, [{ item_key: a.vision_item, kind: 'backlog', ref: b.id as string, role: a.vision_role }], session);
      return b;
    }));
  }));

  server.registerTool('update_backlog_item', {
    description: 'Set a backlog item status (ops.update_backlog_item: open / done / dropped) and optionally replace its detail and severity (omitted = unchanged). A change to done or dropped stamps closed_at; reopening clears it. id is a full UUID or 8-character id prefix.',
    inputSchema: { id: idRef, status: backlogStatus, detail: z.string().optional(), severity: backlogSeverity.optional() },
  }, tool(async ({ id, status, detail, severity }) => withSource(await one(pool,
    'SELECT * FROM ops.update_backlog_item(p_id => $1, p_status => $2, p_detail => $3, p_severity => $4::ops.backlog_severity)',
    [await resolveId(pool, 'backlog_items', id, 'update_backlog_item.id'), status, detail ?? null, severity ?? null]))));

  server.registerTool('create_project', {
    description: 'Register a project and its node under parent_path (ops.create_project); the database requires the parent to be the global node (global). key: lowercase [a-z0-9_-], starting alphanumeric. summary (required): the node\'s one-line description. Needs migration 0035.',
    inputSchema: { parent_path: nodePath, key, name: z.string().min(1), params: params.default({}), summary: nodeSummary },
  }, tool(async (a) => {
    await require0035(pool, 'project');
    return one(pool,
      `SELECT * FROM ops.create_project(p_parent_path => $1::public.ltree, p_key => $2, p_name => $3, p_params => $4::jsonb,
         p_summary => $5)`,
      [a.parent_path, a.key, a.name, JSON.stringify(a.params), a.summary]);
  }));

  server.registerTool('create_component', {
    description: 'Register a component and its node under parent_path (ops.create_component); the database requires the parent to be a project node or a plain node outside any component. verify_cmd is required before implementation-class dispatches can target it. summary (required): the node\'s one-line description. Needs migration 0035.',
    inputSchema: {
      parent_path: nodePath,
      key,
      kind: z.string().min(1),
      repo_ref: z.string().min(1),
      verify_cmd: z.string().min(1).optional(),
      params: params.default({}),
      summary: nodeSummary,
    },
  }, tool(async (a) => {
    await require0035(pool, 'component');
    return one(pool,
      `SELECT * FROM ops.create_component(p_parent_path => $1::public.ltree, p_key => $2, p_kind => $3, p_repo_ref => $4,
         p_verify_cmd => $5, p_params => $6::jsonb, p_summary => $7)`,
      [a.parent_path, a.key, a.kind, a.repo_ref, a.verify_cmd ?? null, JSON.stringify(a.params), a.summary]);
  }));

  // ── Sessions after the fact
  server.registerTool('reconstruct_session', {
    description: 'Record a past session at node_path in one transaction: ops.open_session with occurred_at and provenance reconstructed, then ops.close_session with closed_at and reason normal. Nothing is written if either step fails. A decision item may carry supersedes (the id of an existing decision within the scope of the depth-2 node of the session; a full UUID or 8-character id prefix). Returns the session id.',
    inputSchema: {
      node_path: nodePath,
      kind: sessionKind,
      occurred_at: z.iso.datetime({ offset: true }),
      closed_at: z.iso.datetime({ offset: true }),
      summary: z.string().min(1),
      next_step: z.string().min(1),
      decisions: z.array(decisionInput).default([]),
    },
  }, tool(async (a) => inTransaction(pool, async (db) => {
    const decisions = await resolveDecisions(db, a.decisions, 'reconstruct_session');
    const opened = await db.query(
      `SELECT ops.open_session(p_node_path => $1::public.ltree, p_kind => $2,
         p_occurred_at => $3::timestamptz, p_provenance => 'reconstructed') AS id`,
      [a.node_path, a.kind, a.occurred_at]);
    const session_id = opened.rows[0].id as string;
    const closed = await db.query(
      `SELECT ops.close_session(p_session => $1, p_summary => $2, p_next_step => $3, p_decisions => $4::jsonb,
         p_reason => 'normal', p_closed_at => $5::timestamptz) AS n`,
      [session_id, a.summary, a.next_step, JSON.stringify(decisions), a.closed_at]);
    return { session_id, decisions_recorded: closed.rows[0].n };
  })));
}
