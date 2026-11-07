// Window tracking (ops.tick, migration 0006). The contact source comes from the MCP client's
// initialize clientInfo.name; every other tool call is a passive tick (fail-open, own statement).
import type pg from 'pg';
import type { McpServer, RegisteredTool } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult, Implementation } from '@modelcontextprotocol/sdk/types.js';
import { log, type Row } from './db.ts';

export type ContactSource = 'chat' | 'code';
export interface Contact { source: ContactSource; client: string }

// clientInfo.name -> contact source. Anything not listed is 'chat'.
export const CLIENT_SOURCES: Readonly<Record<string, ContactSource>> = {
  'claude-code': 'code',
};

export function contactFor(info: Implementation | undefined): Contact {
  const name = info?.name?.trim();
  if (!name) return { source: 'chat', client: 'unknown' };
  return { source: Object.hasOwn(CLIENT_SOURCES, name) ? CLIENT_SOURCES[name] : 'chat', client: name };
}

export interface TickArgs {
  chat_ref?: string;
  reset_at?: string;
  reset_source?: 'stated' | 'observed';
  calendar?: unknown[];
}

// One autocommit statement on the pool, never on a client that holds a transaction.
export async function tick(pool: pg.Pool, contact: Contact, a: TickArgs = {}): Promise<Row> {
  const r = await pool.query(
    `SELECT ops.tick($1::ops.contact_source, $2, $3, $4::timestamptz, $5::ops.window_start_source, $6::jsonb) AS t`,
    [contact.source, contact.client, a.chat_ref ?? null, a.reset_at ?? null, a.reset_source ?? null,
     a.calendar === undefined ? null : JSON.stringify(a.calendar)]);
  return r.rows[0].t as Row;
}

// LOCAL_OPS_CONTACT (launch config, for non-Claude executors): unset -> ticking on; 'none' -> this process
// records no contacts. Any other value, empty included, throws, so a typo never falls back to ticking.
export const CONTACT_USAGE = 'LOCAL_OPS_CONTACT must be unset or none';

export function parseContactSetting(value: string | undefined): boolean {
  if (value === undefined) return true;
  if (value === 'none') return false;
  throw new Error(CONTACT_USAGE);
}

// Tools that tick themselves and so get no passive tick.
export const PASSIVE_SKIP: ReadonlySet<string> = new Set(['tick', 'window_link_event']);

export function passiveNote(t: Row | null): string | null {
  if (t === null || t.state === 'ok') return null;
  return `[tick] ${String(t.line)} · directive ${t.directive ?? 'none'}`;
}

// Fail-open: any error is logged to stderr and yields null.
export async function passiveTick(pool: pg.Pool, contact: Contact): Promise<Row | null> {
  try {
    return await tick(pool, contact);
  } catch (err) {
    log(`passive tick failed (tool call proceeds): ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

type AnyCallback = (...args: unknown[]) => CallToolResult | Promise<CallToolResult>;
type RegisterTool = (name: string, config: { inputSchema?: unknown }, cb: AnyCallback) => RegisteredTool;

// One stderr line per tool call: timestamp, role, tool name and the sorted argument key names
// (after input parsing, so defaulted keys appear). Never values.
export function callLine(role: string, name: string, args: unknown): string {
  const keys = args !== null && typeof args === 'object' ? Object.keys(args).sort() : [];
  return `${new Date().toISOString()} role=${role} tool=${name} args=[${keys.join(',')}]`;
}

// The pool's login role (ops_planner / ops_executor) without the prefix; 'unknown' when not a real pool.
function roleOf(pool: pg.Pool): string {
  const user = (pool as { options?: { user?: unknown } }).options?.user;
  return typeof user === 'string' ? user.replace(/^ops_/, '') : 'unknown';
}

// Wraps server.registerTool so tools registered afterwards log their call and tick passively before
// their handler runs. The tick finishes before the handler starts, so it can never share the handler's
// transaction. ticking = false (LOCAL_OPS_CONTACT=none) keeps the call log and skips the passive tick.
export function installPassiveTick(server: McpServer, pool: pg.Pool, contact: () => Contact, role = roleOf(pool),
                                   ticking = true): void {
  const register = server.registerTool.bind(server) as RegisterTool;
  const patched: RegisterTool = (name, config, cb) => register(name, config, async (...args) => {
    // Without an inputSchema the handler's first argument is the request context, not arguments.
    log(callLine(role, name, config.inputSchema === undefined ? undefined : args[0]));
    if (!ticking || PASSIVE_SKIP.has(name)) return cb(...args);
    const note = passiveNote(await passiveTick(pool, contact()));
    const result = await cb(...args);
    if (note === null) return result;
    return { ...result, content: [...(result.content ?? []), { type: 'text', text: note }] };
  });
  (server as unknown as { registerTool: RegisterTool }).registerTool = patched;
}
