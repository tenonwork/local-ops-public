// Connection pool and query helpers. No password here: pg falls back to pgpass
// (%APPDATA%\postgresql\pgpass.conf on Windows) when none is supplied.
import pg from 'pg';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';

export type Role = 'planner' | 'executor';
export type Row = Record<string, unknown>;

export const QUERY_MAX_ROWS = 200;

export function createPool(role: Role): pg.Pool {
  const pool = new pg.Pool({
    host: process.env.LOCAL_OPS_HOST ?? 'localhost',
    port: Number(process.env.LOCAL_OPS_PORT ?? 5432),
    database: process.env.LOCAL_OPS_DB ?? 'local_ops',
    user: role === 'planner' ? 'ops_planner' : 'ops_executor',
    max: 2,
    application_name: `local-ops-mcp:${role}`,
  });
  pool.on('error', (err) => log(`pool error: ${err.message}`));
  return pool;
}

export function log(msg: string): void {
  // stdout carries the MCP protocol; everything else goes to stderr.
  process.stderr.write(`[local-ops-mcp] ${msg}\n`);
}

export async function rows(pool: pg.Pool, text: string, values: unknown[] = []): Promise<Row[]> {
  return (await pool.query(text, values)).rows as Row[];
}

// Runs fn inside BEGIN/COMMIT on one client; any throw rolls back.
export async function inTransaction<T>(pool: pg.Pool, fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}

// Ad-hoc SQL: single statement (extended protocol rejects multi-statement text),
// read-only transaction, 5s timeout, always rolled back.
export async function readOnlyQuery(pool: pg.Pool, sql: string): Promise<Row> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN READ ONLY');
    await client.query("SET LOCAL statement_timeout = '5s'");
    const config = { text: sql, queryMode: 'extended' };
    const res = await client.query(config);
    const all = (res.rows ?? []) as Row[];
    return {
      command: res.command,
      row_count: res.rowCount ?? all.length,
      returned: Math.min(all.length, QUERY_MAX_ROWS),
      truncated: all.length > QUERY_MAX_ROWS,
      rows: all.slice(0, QUERY_MAX_ROWS),
    };
  } finally {
    await client.query('ROLLBACK').catch(() => undefined);
    client.release();
  }
}

export function ok(data: unknown): CallToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] };
}

export function fail(message: string): CallToolResult {
  return { isError: true, content: [{ type: 'text', text: message }] };
}

// Server-side check failures (not database errors).
export class CheckError extends Error {}

// Input rejected by an ops function: check_violation, ops._component's / ops._node's P0001 for an unknown component
// or node, or 42601 for a path that is not valid ltree syntax.
export function isValidationError(err: unknown): boolean {
  return err instanceof pg.DatabaseError
    && (err.code === '23514' || err.code === '42601'
      || (err.code === 'P0001' && (err.message.startsWith('unknown component ') || err.message.startsWith('unknown node '))));
}

export function describe(err: unknown): string {
  if (err instanceof pg.DatabaseError) {
    const head = isValidationError(err) ? `Validation error (${err.code}): ${err.message}`
      : `Postgres error ${err.code ?? ''}: ${err.message}`.replace(' :', ':');
    const parts = [head];
    if (err.detail) parts.push(`DETAIL: ${err.detail}`);
    if (err.hint) parts.push(`HINT: ${err.hint}`);
    return parts.join('\n');
  }
  return err instanceof Error ? err.message : String(err);
}

// Wraps a handler so every failure becomes a tool error. No retries, no fallbacks.
export function tool<A>(fn: (args: A) => Promise<unknown>): (args: A) => Promise<CallToolResult> {
  return async (args: A) => {
    try {
      return ok(await fn(args));
    } catch (err) {
      return fail(describe(err));
    }
  };
}

// The id of the node at path. Reads ops.nodes directly: ops._node is owner-only.
export async function nodeId(db: pg.Pool | pg.PoolClient, path: string): Promise<string> {
  const r = await db.query('SELECT id FROM ops.nodes WHERE path OPERATOR(public.=) $1::public.ltree', [path]);
  if (r.rows.length === 0) throw new CheckError(`unknown node ${path}`);
  return r.rows[0].id as string;
}
