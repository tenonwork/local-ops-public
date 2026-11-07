// Vision tools (migration 0032): the planner's only way to the vision table, whose writer functions own validation.
// The server reads mcp/src fresh at every session start, so this code runs against a database without 0032 (as
// production before the promote): each tool checks its function or view at call time and, when absent, returns
// VISION_MISSING without sending anything else. The create_dispatch / log_decision / add_backlog_item vision inputs
// (planner.ts) use visionLinkPresent and visionLink the same way.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { ErrorCode, McpError } from '@modelcontextprotocol/sdk/types.js';
import { CheckError, rows, tool } from '../db.ts';
import { idRef, resolveId, resolveOptional, withSegment, type IdTable } from './common.ts';

export const VISION_MISSING = 'vision table not installed (migration 0032 is not applied)';

// Each tool's object: a function signature (to_regprocedure) or a view (to_regclass). Fixed strings, never input.
const OBJECTS = {
  upsert: ['to_regprocedure', 'ops.vision_upsert(jsonb,uuid)'],
  link: ['to_regprocedure', 'ops.vision_link(jsonb,uuid)'],
  unlink: ['to_regprocedure', 'ops.vision_unlink(jsonb,uuid)'],
  set_status: ['to_regprocedure', 'ops.vision_set_status(text,text,text,uuid,text)'],
  true_close: ['to_regprocedure', 'ops.vision_true_close(text,text,uuid)'],
  check: ['to_regprocedure', 'ops.vision_check()'],
  status: ['to_regclass', 'ops.vision_status'],
} as const;

// No row, or present = false, is absent.
async function present(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<boolean> {
  const [fn, name] = OBJECTS[object];
  const r = await db.query(`SELECT ${fn}('${name}') IS NOT NULL AS present`);
  return r.rows[0]?.present === true;
}

async function require0032(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<void> {
  if (!(await present(db, object))) throw new CheckError(VISION_MISSING);
}

export const visionLinkPresent = (db: pg.Pool | pg.PoolClient) => present(db, 'link');

// An input error raised in the handler, worded like the SDK's schema errors (and resolveId's).
export function inputError(tool: string, message: string): McpError {
  return new McpError(ErrorCode.InvalidParams, `Input validation error: Invalid arguments for tool ${tool}: ${message}`);
}

export const relation = z.enum(['defines', 'refines', 'sequencing', 'milestone', 'constrains', 'process_rule',
  'superseded', 'abandons']);
export const role = z.enum(['blocks', 'improves']);
const linkKind = z.enum(['decision', 'backlog', 'dispatch']);
const KIND_TABLE: Record<z.infer<typeof linkKind>, IdTable> =
  { decision: 'decisions', backlog: 'backlog_items', dispatch: 'dispatches' };

type Link = { item_key?: string; kind: z.infer<typeof linkKind>; ref: string; relation?: string; role?: string;
  none_reason?: string };

// One ops.vision_link call; undefined fields are left out of the JSON (the function refuses unknown fields).
export async function visionLink(db: pg.Pool | pg.PoolClient, links: Link[], session: string | null): Promise<unknown> {
  const r = await db.query('SELECT ops.vision_link(p_links => $1::jsonb, p_session => $2) AS r',
    [JSON.stringify(links), session]);
  return r.rows[0].r;
}

// Link refs resolved by kind; input names '<tool>.links[i].ref'.
async function resolveLinks<L extends { kind: Link['kind']; ref: string }>(db: pg.Pool, links: L[], tool: string): Promise<L[]> {
  const out: L[] = [];
  for (const [i, l] of links.entries()) out.push({ ...l, ref: await resolveId(db, KIND_TABLE[l.kind], l.ref, `${tool}.links[${i}].ref`) });
  return out;
}

const itemKey = z.string().min(1);
const nonBlank = z.string().regex(/\S/, 'must not be blank');

export function registerVision(server: McpServer, pool: pg.Pool): void {
  const session = (value: string | undefined, input: string) => resolveOptional(pool, 'sessions', value, input);

  server.registerTool('vision_upsert', {
    description: 'Insert or update vision items (ops.vision_upsert). Each item is an object passed through as JSON: key, '
      + 'parent_key (null for a root), home_node_path, title, intent, acceptance, status, status_reason, phase, seq, sources, '
      + 'requires ("kind:name"), status_note, abandoned_reason; the database validates. status true_closed is set only by '
      + 'vision_true_close. segment_id (the session id) is required: a full UUID or 8-character id prefix. Returns '
      + '{inserted, updated, status_changes}. Needs migration 0032.',
    inputSchema: withSegment({ items: z.array(z.record(z.string(), z.unknown())).min(1) }, true),
  }, tool(async (a) => {
    await require0032(pool, 'upsert');
    const s = await session(a.segment_id, 'vision_upsert.segment_id');
    return (await rows(pool, 'SELECT ops.vision_upsert(p_items => $1::jsonb, p_session => $2) AS r',
      [JSON.stringify(a.items), s ?? null]))[0].r;
  }));

  server.registerTool('vision_link', {
    description: 'Link vision items to decisions, backlog items or dispatches (ops.vision_link). Each link: kind (decision / '
      + 'backlog / dispatch), ref (a full UUID or 8-character id prefix of a row of that kind), item_key, and relation '
      + '(decision), role (backlog: blocks / improves) or, for a dispatch that advances no item, none_reason in place of '
      + 'item_key. segment_id (the session id) is required: a full UUID or 8-character id prefix. Returns {linked, updated}. '
      + 'Needs migration 0032.',
    inputSchema: withSegment({
      links: z.array(z.object({
        item_key: itemKey.optional(), kind: linkKind, ref: idRef,
        relation: relation.optional(), role: role.optional(), none_reason: z.string().optional(),
      })).min(1),
    }, true),
  }, tool(async (a) => {
    await require0032(pool, 'link');
    const links = await resolveLinks(pool, a.links, 'vision_link');
    return visionLink(pool, links, (await session(a.segment_id, 'vision_link.segment_id')) ?? null);
  }));

  server.registerTool('vision_unlink', {
    description: 'Remove links of vision items (ops.vision_unlink). Each link: kind (decision / backlog / dispatch), ref (a '
      + 'full UUID or 8-character id prefix), and item_key (omitted for a dispatch none row). segment_id (the session id) '
      + 'is required: a full UUID or 8-character id prefix. Returns {removed}. Needs migration 0032.',
    inputSchema: withSegment({
      links: z.array(z.object({ item_key: itemKey.optional(), kind: linkKind, ref: idRef })).min(1),
    }, true),
  }, tool(async (a) => {
    await require0032(pool, 'unlink');
    const links = await resolveLinks(pool, a.links, 'vision_unlink');
    const s = await session(a.segment_id, 'vision_unlink.segment_id');
    const [r] = await rows(pool, 'SELECT ops.vision_unlink(p_links => $1::jsonb, p_session => $2) AS n',
      [JSON.stringify(links), s ?? null]);
    return { removed: r.n };
  }));

  server.registerTool('vision_set_status', {
    description: 'Set the status of a vision item (ops.vision_set_status: idea / designed / partial / shipped / abandoned; '
      + 'true_closed only through vision_true_close) with a reason; abandoned needs abandoned_reason. shipped is refused '
      + 'while a blocking backlog item is open. segment_id (the session id) is required: a full UUID or 8-character id '
      + 'prefix. Returns {key, changed}. Needs migration 0032.',
    inputSchema: withSegment({
      key: itemKey, status: z.string().min(1), reason: z.string().min(1), abandoned_reason: z.string().optional(),
    }, true),
  }, tool(async (a) => {
    await require0032(pool, 'set_status');
    const s = await session(a.segment_id, 'vision_set_status.segment_id');
    const [r] = await rows(pool,
      `SELECT ops.vision_set_status(p_key => $1, p_status => $2, p_reason => $3, p_session => $4,
         p_abandoned_reason => $5) AS changed`,
      [a.key, a.status, a.reason, s ?? null, a.abandoned_reason ?? null]);
    return { key: a.key, changed: r.changed };
  }));

  server.registerTool('vision_true_close', {
    description: "True-close a shipped vision item (ops.vision_true_close). Call only after the operator's explicit yes, "
      + 'with the evidence that its acceptance passed in real use. Refused while a blocking backlog item is open. '
      + 'segment_id (the session id) is required: a full UUID or 8-character id prefix. Needs migration 0032.',
    inputSchema: withSegment({ key: itemKey, evidence: nonBlank }, true),
  }, tool(async (a) => {
    await require0032(pool, 'true_close');
    const s = await session(a.segment_id, 'vision_true_close.segment_id');
    await rows(pool, 'SELECT ops.vision_true_close(p_key => $1, p_evidence => $2, p_session => $3)', [a.key, a.evidence, s ?? null]);
    return { key: a.key, status: 'true_closed' };
  }));

  server.registerTool('vision_check', {
    description: 'Consistency rows of the vision table (ops.vision_check): missing_object, open_blocker, status_lag, '
      + 'rollup_mismatch, abandoned_parent, unlinked_decision / unlinked_backlog / unlinked_dispatch, none_reason. '
      + 'Needs migration 0032.',
    inputSchema: {},
  }, tool(async () => {
    await require0032(pool, 'check');
    return rows(pool, 'SELECT * FROM ops.vision_check()');
  }));

  server.registerTool('vision_status', {
    description: 'Rows of ops.vision_status (stored status, children rollup, requirement and link counts) ordered by key; '
      + 'with under (an item key), that item and its descendants by parent. Needs migration 0032.',
    inputSchema: { under: itemKey.optional() },
  }, tool(async ({ under }) => {
    await require0032(pool, 'status');
    if (under === undefined) return rows(pool, 'SELECT * FROM ops.vision_status ORDER BY key');
    const found = await rows(pool,
      `WITH RECURSIVE t AS (
         SELECT id, key FROM ops.vision_items WHERE key = $1
         UNION ALL
         SELECT c.id, c.key FROM ops.vision_items c JOIN t ON c.parent_id = t.id)
       SELECT s.* FROM ops.vision_status s JOIN t ON t.key = s.key ORDER BY s.key`, [under]);
    if (found.length === 0) throw new CheckError(`vision item ${under} does not exist`);
    return found;
  }));
}
