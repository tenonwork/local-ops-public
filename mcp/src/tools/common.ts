// Shared schemas and helpers, the planner's query / resolve_context / record_gate, and the executor's resolve_context.
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { ErrorCode, McpError } from '@modelcontextprotocol/sdk/types.js';
import { readOnlyQuery, rows, tool } from '../db.ts';

export const uuid = z.uuid();
export const key = z.string().regex(/^[a-z0-9][a-z0-9_-]*$/);
// A node path (ltree): keys joined by dots. Passed to the 0018 node-keyed functions as $n::public.ltree.
export const nodePath = z.string().regex(/^[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)*$/)
  .describe('node path such as global.local-ops.core');

// Planner id inputs: a full UUID (passed through, no lookup) or exactly 8 hex characters, resolved by resolveId.
const ID_PREFIX = /^[0-9a-fA-F]{8}$/;
const idForms = 'full UUID or 8-character id prefix';
const idRefOf = (required?: string) => z.union([uuid, z.string().regex(ID_PREFIX)], {
  error: (iss) => (iss.input === undefined ? required : `expected a ${idForms}`),
}).describe(idForms);
export const idRef = idRefOf();

// Prefix lookups read these tables only; the table name never comes from input.
const ID_TABLES = {
  backlog_items: 'ops.backlog_items',
  dispatches: 'ops.dispatches',
  decisions: 'ops.decisions',
  sessions: 'ops.sessions',
} as const;
export type IdTable = keyof typeof ID_TABLES;

// A full UUID comes back unchanged without a query. An 8-hex prefix resolves to the one row of table whose id
// starts with it; zero or several matches are an input validation error and nothing reaches the ops function.
// input is '<tool>.<path>'; the error carries the SDK's schema-error prefix, "Invalid arguments for tool <tool>:".
export async function resolveId(db: pg.Pool | pg.PoolClient, table: IdTable, value: string, input: string): Promise<string> {
  if (!ID_PREFIX.test(value)) return value;
  const prefix = value.toLowerCase();
  const r = await db.query(
    `SELECT id, count(*) OVER () AS n FROM ${ID_TABLES[table]} WHERE id::text LIKE $1 || '%' LIMIT 2`, [prefix]);
  const n = r.rows.length === 0 ? 0 : Number(r.rows[0].n);
  if (n !== 1) {
    const dot = input.indexOf('.');
    throw new McpError(ErrorCode.InvalidParams,
      `Input validation error: Invalid arguments for tool ${input.slice(0, dot)}: ${input.slice(dot + 1)}: `
      + `prefix ${prefix} matched ${n} rows in ${table}`);
  }
  return r.rows[0].id as string;
}

export async function resolveOptional(db: pg.Pool | pg.PoolClient, table: IdTable, value: string | undefined,
  input: string): Promise<string | undefined> {
  return value === undefined ? undefined : resolveId(db, table, value, input);
}

// Session inputs are named segment_id: the computer-link bridge strips any argument named session_id.
// The session_id alias is retired. A call carrying it is refused rather than stripped, so a stale caller
// cannot write rows without their session.
const segmentRef = idRefOf('segment_id is required');
const retiredAlias = 'session_id is no longer accepted; send the session id as segment_id';

// shape plus segment_id, required in the advertised schema when required. The object is loose so the
// refinement sees session_id (a plain object strips it); when: always, so it is reported alongside other issues.
// segment_id also takes an 8-hex prefix (resolve it against sessions before use).
export function withSegment<S extends z.ZodRawShape>(shape: S, required: boolean) {
  return z.looseObject({ ...shape, segment_id: required ? segmentRef : segmentRef.optional() })
    .refine((a) => !Object.hasOwn(a, 'session_id'), {
      path: ['session_id'], message: retiredAlias,
      when: (p) => typeof p.value === 'object' && p.value !== null,
    });
}

// The one tool both roles register.
export function registerResolveContext(server: McpServer, pool: pg.Pool): void {
  server.registerTool('resolve_context', {
    description: "Resolve a context ref via ops.resolve_context at node_path: the document on the nearest ancestor-or-self node holding the doc key. 'DOC_KEY' returns the whole document, 'DOC_KEY#Heading' returns that markdown section.",
    inputSchema: { node_path: nodePath, ref: z.string().min(1) },
  }, tool(async ({ node_path, ref }) =>
    (await rows(pool, 'SELECT ops.resolve_context(p_node_path => $1::public.ltree, p_ref => $2) AS text',
      [node_path, ref]))[0].text));
}

// query, resolve_context and record_gate, in that order: the planner's (registerPlanner). The executor registers
// resolve_context only (registerResolveContext): no dispatch type uses executor-side gates, and prod_apply gates
// are written by scripts/migrate.ts over its own connection. record_gate's dispatch_id and segment_id take
// 8-hex prefixes.
export function registerCommon(server: McpServer, pool: pg.Pool): void {
  server.registerTool('query', {
    description: 'Run one read-only SQL statement (READ ONLY transaction, 5s timeout, always rolled back). Returns at most 200 rows and reports truncation.',
    inputSchema: { sql: z.string().min(1) },
  }, tool(async ({ sql }) => readOnlyQuery(pool, sql)));

  registerResolveContext(server, pool);

  server.registerTool('record_gate', {
    description: 'Record a gate event via ops.record_gate. At least one of dispatch_id / segment_id (the session) is required'
      + `; each is a ${idForms}. An override must have result=fail, override_by and a reason.`,
    inputSchema: withSegment({
      gate_key: z.string().min(1),
      result: z.enum(['pass', 'fail']),
      dispatch_id: idRef.optional(),
      overridden: z.boolean().default(false),
      override_by: z.string().optional(),
      reason: z.string().optional(),
    }, false),
  }, tool(async (a) => {
    const dispatchId = await resolveOptional(pool, 'dispatches', a.dispatch_id, 'record_gate.dispatch_id');
    const segment = await resolveOptional(pool, 'sessions', a.segment_id, 'record_gate.segment_id');
    const r = await rows(pool,
      'SELECT ops.record_gate($1, $2::ops.gate_result, $3::uuid, $4::uuid, $5, $6, $7) AS id',
      [a.gate_key, a.result, dispatchId ?? null, segment ?? null, a.overridden,
       a.override_by ?? null, a.reason ?? null]);
    return { gate_event_id: r[0].id };
  }));
}
