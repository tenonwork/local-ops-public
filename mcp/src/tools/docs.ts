// Context-document tools (migration 0033): the planner's only way to write context documents, through ops.write_doc,
// ops.approve_doc and ops.retire_doc, which own validation. The server reads mcp/src fresh at every session start, so
// this code runs against a database without 0033 (as production before the promote): each tool checks its function
// at call time and, when absent, returns DOCS_MISSING without sending anything else.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, rows, tool } from '../db.ts';
import { idRef, nodePath, resolveId, resolveOptional, withSegment, type IdTable } from './common.ts';

export const DOCS_MISSING = 'context-document writer not installed (migration 0033 is not applied)';

// Each tool's function signature (to_regprocedure). Fixed strings, never input.
const OBJECTS = {
  write: 'ops.write_doc(ltree,text,text,text,text,text,text,uuid[],uuid[],uuid)',
  approve: 'ops.approve_doc(ltree,text,text,uuid)',
  retire: 'ops.retire_doc(ltree,text,text,uuid)',
} as const;

// No row, or present = false, is absent.
async function present(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<boolean> {
  const r = await db.query(`SELECT to_regprocedure('${OBJECTS[object]}') IS NOT NULL AS present`);
  return r.rows[0]?.present === true;
}

async function require0033(db: pg.Pool | pg.PoolClient, object: keyof typeof OBJECTS): Promise<void> {
  if (!(await present(db, object))) throw new CheckError(DOCS_MISSING);
}

const docKey = z.string().regex(/^[A-Z0-9_]+$/);
const nonBlank = z.string().regex(/\S/, 'must not be blank');

export function registerDocs(server: McpServer, pool: pg.Pool): void {
  const session = (value: string | undefined, input: string) => resolveOptional(pool, 'sessions', value, input);
  // Each id resolved against table; input names '<tool>.<field>[i]'.
  const ids = async (table: IdTable, values: string[] | undefined, input: string) => {
    const out: string[] = [];
    for (const [i, v] of (values ?? []).entries()) out.push(await resolveId(pool, table, v, `${input}[${i}]`));
    return out;
  };

  server.registerTool('write_doc', {
    description: 'Create or update the context document at (node_path, doc_key) (ops.write_doc). basis derived lands '
      + 'approved and needs at least one source (decision_ids: non-superseded decisions; dispatch_ids: dispatches with a '
      + 'reviewed report); basis review lands a draft for approve_doc (rule doc_approval). decision_ids and dispatch_ids '
      + 'take a full UUID or 8-character id prefix each. segment_id (the session id) is required: a full UUID or '
      + '8-character id prefix. Returns {id, version, trust_status, created, reactivated, content_sha256}. Needs '
      + 'migration 0033.',
    inputSchema: withSegment({
      node_path: nodePath,
      doc_key: docKey,
      doc_type: z.string().min(1),
      title: z.string().min(1),
      content: z.string().min(1),
      summary: z.string().optional(),
      basis: z.enum(['derived', 'review']),
      decision_ids: z.array(idRef).optional(),
      dispatch_ids: z.array(idRef).optional(),
    }, true),
  }, tool(async (a) => {
    await require0033(pool, 'write');
    const decisions = await ids('decisions', a.decision_ids, 'write_doc.decision_ids');
    const dispatches = await ids('dispatches', a.dispatch_ids, 'write_doc.dispatch_ids');
    const s = await session(a.segment_id, 'write_doc.segment_id');
    return (await rows(pool,
      `SELECT ops.write_doc(p_node_path => $1::public.ltree, p_doc_key => $2, p_doc_type => $3, p_title => $4,
         p_content => $5, p_summary => $6, p_basis => $7, p_decision_ids => $8::uuid[], p_dispatch_ids => $9::uuid[],
         p_session => $10) AS r`,
      [a.node_path, a.doc_key, a.doc_type, a.title, a.content, a.summary ?? null, a.basis, decisions, dispatches,
       s ?? null]))[0].r;
  }));

  server.registerTool('approve_doc', {
    description: 'Approve the draft context document at exactly (node_path, doc_key) (ops.approve_doc), bound to its '
      + "content_sha256. Call only after the operator's explicit yes naming the doc_key and the sha256 (rule "
      + 'doc_approval). segment_id (the session id) is required: a full UUID or 8-character id prefix. Returns '
      + '{id, version}. Needs migration 0033.',
    inputSchema: withSegment({
      node_path: nodePath, doc_key: docKey, content_sha256: z.string().regex(/^[0-9a-f]{64}$/),
    }, true),
  }, tool(async (a) => {
    await require0033(pool, 'approve');
    const s = await session(a.segment_id, 'approve_doc.segment_id');
    return (await rows(pool,
      `SELECT ops.approve_doc(p_node_path => $1::public.ltree, p_doc_key => $2, p_content_sha256 => $3,
         p_session => $4) AS r`,
      [a.node_path, a.doc_key, a.content_sha256, s ?? null]))[0].r;
  }));

  server.registerTool('retire_doc', {
    description: 'Retire the context document at exactly (node_path, doc_key) with a reason (ops.retire_doc); it is '
      + "never deleted. Call only after the operator's explicit yes, unless a logged decision names the retirement (rule "
      + 'doc_approval). segment_id (the session id) is required: a full UUID or 8-character id prefix. Returns '
      + '{id, retired_at}. Needs migration 0033.',
    inputSchema: withSegment({ node_path: nodePath, doc_key: docKey, reason: nonBlank }, true),
  }, tool(async (a) => {
    await require0033(pool, 'retire');
    const s = await session(a.segment_id, 'retire_doc.segment_id');
    return (await rows(pool,
      'SELECT ops.retire_doc(p_node_path => $1::public.ltree, p_doc_key => $2, p_reason => $3, p_session => $4) AS r',
      [a.node_path, a.doc_key, a.reason, s ?? null]))[0].r;
  }));
}
