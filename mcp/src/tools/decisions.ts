// Decision reader tool (migration 0034): the planner's proposal-time read of current decisions at a node and its
// ancestors, nearest first, as gists with ids, through ops.get_decisions; full text is read by id with query. The
// server reads mcp/src fresh at every session start, so this code runs against a database without 0034 (as production
// before the promote): the tool checks its function at call time and, when absent, returns DECISIONS_MISSING without
// sending anything else.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, rows, tool } from '../db.ts';
import { nodePath } from './common.ts';

export const DECISIONS_MISSING = 'decision reader not installed (migration 0034 is not applied)';

// No row, or present = false, is absent. The signature is a fixed string, never input.
async function present(db: pg.Pool | pg.PoolClient): Promise<boolean> {
  const r = await db.query(`SELECT to_regprocedure('ops.get_decisions(ltree,integer)') IS NOT NULL AS present`);
  return r.rows[0]?.present === true;
}

export function registerDecisions(server: McpServer, pool: pg.Pool): void {
  server.registerTool('get_decisions', {
    description: 'Current decisions at node_path and its ancestors, nearest first, as one-line gists with ids '
      + '(ops.get_decisions): id, id8, gist, node_path, distance (0 = this node), occurred_at. limit 1-200, default 50. '
      + 'Read full text by id with query. Needs migration 0034.',
    inputSchema: { node_path: nodePath, limit: z.number().int().min(1).max(200).optional() },
  }, tool(async ({ node_path, limit }) => {
    if (!(await present(pool))) throw new CheckError(DECISIONS_MISSING);
    return rows(pool, 'SELECT * FROM ops.get_decisions(p_node_path => $1::public.ltree, p_limit => $2)',
      [node_path, limit ?? 50]);
  }));
}
