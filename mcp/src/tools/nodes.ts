// Node summary tools (migration 0035): the planner's writer of a node's one-line summary, through ops.set_node_summary,
// and the summary input that create_project / create_component (planner.ts) require. The database keeps the column
// nullable and enforces the shape; completeness is enforced here, by requiring a summary on every node the planner
// creates. The server reads mcp/src fresh at every session start, so this code runs against a database without 0035
// (as production before the promote): each tool checks its function at call time and, when absent, returns
// NODES_MISSING without sending anything else.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, rows, tool } from '../db.ts';
import { nodePath, resolveOptional, withSegment } from './common.ts';

export const NODES_MISSING = 'node summary writer not installed (migration 0035 is not applied)';

// Each tool's function signature (to_regprocedure). Fixed strings, never input.
const OBJECTS = {
  set: 'ops.set_node_summary(ltree,text,uuid)',
  project: 'ops.create_project(ltree,text,text,jsonb,text)',
  component: 'ops.create_component(ltree,text,text,text,text,jsonb,text)',
  overview: 'ops.node_overview(ltree,integer)',
} as const;

// No row, or present = false, is absent.
async function present(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<boolean> {
  const r = await db.query(`SELECT to_regprocedure('${OBJECTS[object]}') IS NOT NULL AS present`);
  return r.rows[0]?.present === true;
}

export async function require0035(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<void> {
  if (!(await present(db, object))) throw new CheckError(NODES_MISSING);
}

// ops.node_overview (migration 0036), read by open_session (planner.ts) after the session is open.
export async function overviewPresent(db: pg.Pool | pg.PoolClient): Promise<boolean> {
  return present(db, 'overview');
}

// The shape of CHECK nodes_summary_shape, refused before any query.
export const nodeSummary = z.string().regex(/\S/, 'must not be blank').max(200)
  .refine((s) => !/[\r\n]/.test(s), 'must be one line');

export function registerNodes(server: McpServer, pool: pg.Pool): void {
  server.registerTool('set_node_summary', {
    description: "Set a node's one-line summary (ops.set_node_summary): non-empty, one line, at most 200 characters; "
      + 'stamps summary_updated_at and the session. segment_id (the session id) is required: a full UUID or 8-character '
      + 'id prefix. Returns node_path, summary, summary_updated_at, summary_session_id. Needs migration 0035.',
    inputSchema: withSegment({ node_path: nodePath, summary: nodeSummary }, true),
  }, tool(async (a) => {
    await require0035(pool, 'set');
    const s = await resolveOptional(pool, 'sessions', a.segment_id, 'set_node_summary.segment_id');
    return (await rows(pool,
      'SELECT * FROM ops.set_node_summary(p_node_path => $1::public.ltree, p_summary => $2, p_session => $3)',
      [a.node_path, a.summary, s ?? null]))[0];
  }));
}
