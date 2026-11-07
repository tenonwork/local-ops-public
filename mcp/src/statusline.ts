// Claude Code statusLine command (usage reader b9cbaad8). Reads the status-line JSON on stdin, prints one line, and
// sends the plan-usage reading (rate_limits five_hour / seven_day) to ops.record_usage as ops_executor, only when it
// differs from the last reading this session sent. Fail-silent: every error is swallowed, the line still prints and
// the process exits 0. No password here: pg falls back to pgpass, as in db.ts.
//
//   echo '{"session_id":"s","rate_limits":{...}}' | node mcp/src/statusline.ts
import pg from 'pg';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFile, writeFile } from 'node:fs/promises';

export interface WindowReading { pct: number; resetsAt: Date }
export interface Reading { sessionId: string; fiveHour?: WindowReading; sevenDay?: WindowReading }

// The last reading sent (resets as epoch seconds) and the window label from the last tick line.
export interface Cache {
  fiveHourPct: number | null;
  fiveHourResetsAt: number | null;
  sevenDayPct: number | null;
  sevenDayResetsAt: number | null;
  window: string | null;
}

export interface StatusClient {
  connect(): Promise<unknown>;
  query(text: string, values?: unknown[]): Promise<{ rows: Record<string, unknown>[] }>;
  end(): Promise<unknown>;
}

export const TIMEOUT_MS = 2500;

function windowOf(v: unknown): WindowReading | undefined {
  if (v === null || typeof v !== 'object') return undefined;
  const { used_percentage: pct, resets_at: at } = v as Record<string, unknown>;
  if (typeof pct !== 'number' || !Number.isFinite(pct) || typeof at !== 'number' || !Number.isFinite(at)) return undefined;
  return { pct, resetsAt: new Date(at * 1000) };
}

// null on unparseable input; missing fields leave the window (or the session id) absent.
export function parseInput(json: string): Reading | null {
  let v: unknown;
  try {
    v = JSON.parse(json);
  } catch {
    return null;
  }
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const out: Reading = { sessionId: typeof o.session_id === 'string' ? o.session_id : '' };
  const rl = o.rate_limits;
  if (rl !== null && typeof rl === 'object') {
    const fiveHour = windowOf((rl as Record<string, unknown>).five_hour);
    const sevenDay = windowOf((rl as Record<string, unknown>).seven_day);
    if (fiveHour) out.fiveHour = fiveHour;
    if (sevenDay) out.sevenDay = sevenDay;
  }
  return out;
}

const hhmm = (d: Date) => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;

// "5h 42% → 04:45 · 7d 18%" (+ " · W056" when cached); "5h –" / "7d –" for an absent window; "usage –" for none.
export function formatLine(reading: Reading | null, cached: Cache | null): string {
  const label = cached?.window ? ` · ${cached.window}` : '';
  if (!reading || (!reading.fiveHour && !reading.sevenDay)) return `usage –${label}`;
  const five = reading.fiveHour ? `5h ${Math.round(reading.fiveHour.pct)}% → ${hhmm(reading.fiveHour.resetsAt)}` : '5h –';
  const seven = reading.sevenDay ? `7d ${Math.round(reading.sevenDay.pct)}%` : '7d –';
  return `${five} · ${seven}${label}`;
}

const secs = (w?: WindowReading) => (w ? Math.floor(w.resetsAt.getTime() / 1000) : null);

// Compares the four values with the last reading sent.
export function changed(reading: Reading, cached: Cache | null): boolean {
  if (!cached) return true;
  return (reading.fiveHour?.pct ?? null) !== cached.fiveHourPct
    || secs(reading.fiveHour) !== cached.fiveHourResetsAt
    || (reading.sevenDay?.pct ?? null) !== cached.sevenDayPct
    || secs(reading.sevenDay) !== cached.sevenDayResetsAt;
}

export function cachePath(dir: string, sessionId: string): string {
  const id = sessionId.replace(/[^A-Za-z0-9_-]/g, '_') || 'unknown';
  return join(dir, `claude-statusline-${id}.json`);
}

export async function readCache(path: string): Promise<Cache | null> {
  try {
    const c = JSON.parse(await readFile(path, 'utf8')) as Cache;
    return c !== null && typeof c === 'object' ? c : null;
  } catch {
    return null;
  }
}

export function defaultClient(): StatusClient {
  return new pg.Client({
    host: process.env.LOCAL_OPS_HOST ?? 'localhost',
    port: Number(process.env.LOCAL_OPS_PORT ?? 5432),
    database: process.env.LOCAL_OPS_DB ?? 'local_ops',
    user: 'ops_executor',
    application_name: 'local-ops-statusline',
    connectionTimeoutMillis: 1500,
    statement_timeout: 2000,
  });
}

// One ops.record_usage call; returns the cache to keep. The client is always ended.
export async function send(client: StatusClient, reading: Reading, cached: Cache | null): Promise<Cache> {
  try {
    await client.connect();
    const r = await client.query(
      `SELECT ops.record_usage(p_client => $1, p_session_ref => $2, p_five_hour_pct => $3,
                               p_five_hour_resets_at => $4::timestamptz, p_seven_day_pct => $5,
                               p_seven_day_resets_at => $6::timestamptz) AS r`,
      ['statusline', reading.sessionId || null, reading.fiveHour?.pct ?? null,
       reading.fiveHour?.resetsAt.toISOString() ?? null, reading.sevenDay?.pct ?? null,
       reading.sevenDay?.resetsAt.toISOString() ?? null]);
    const res = r.rows[0]?.r as { tick?: { line?: unknown } | null } | undefined;
    const line = res?.tick?.line;
    const window = (typeof line === 'string' ? line.match(/\bW\d+\b/)?.[0] : undefined) ?? cached?.window ?? null;
    return {
      fiveHourPct: reading.fiveHour?.pct ?? null,
      fiveHourResetsAt: secs(reading.fiveHour),
      sevenDayPct: reading.sevenDay?.pct ?? null,
      sevenDayResetsAt: secs(reading.sevenDay),
      window,
    };
  } finally {
    await client.end().catch(() => undefined);
  }
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const c of process.stdin) chunks.push(c as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

export interface MainDeps {
  stdin?: () => Promise<string>;
  // the clock the overall timeout runs on
  sleep?: (ms: number) => Promise<void>;
  cacheDir?: string;
  client?: () => StatusClient;
  write?: (line: string) => void;
  warn?: (msg: string) => void;
  timeoutMs?: number;
}

// Prints exactly one line and never throws; returns the line.
export async function main(deps: MainDeps = {}): Promise<string> {
  const write = deps.write ?? ((l: string) => { process.stdout.write(`${l}\n`); });
  const warn = deps.warn ?? ((m: string) => { process.stderr.write(`statusline: ${m.slice(0, 120)}\n`); });
  const sleep = deps.sleep
    ?? ((ms: number) => new Promise<void>((resolve) => { setTimeout(resolve, ms).unref(); }));
  let line = formatLine(null, null);
  let warned = false;
  const swallow = (err: unknown) => {
    if (warned) return;
    warned = true;
    try { warn(err instanceof Error ? err.message : String(err)); } catch { /* nothing */ }
  };

  const work = (async () => {
    const reading = parseInput(await (deps.stdin ?? readStdin)());
    if (!reading) return;
    const path = cachePath(deps.cacheDir ?? tmpdir(), reading.sessionId);
    let cached = await readCache(path);
    line = formatLine(reading, cached);
    if ((reading.fiveHour || reading.sevenDay) && changed(reading, cached)) {
      cached = await send((deps.client ?? defaultClient)(), reading, cached);
      line = formatLine(reading, cached);
      await writeFile(path, JSON.stringify(cached));
    }
  })().catch(swallow);

  await Promise.race([work, sleep(deps.timeoutMs ?? TIMEOUT_MS).then(() => swallow(new Error('timed out')))]);
  try { write(line); } catch { /* nothing */ }
  return line;
}

if (import.meta.main) {
  process.noDeprecation = true;  // pg's pgpass deprecation warning would be a second stderr line
  main().finally(() => process.exit(0));
}
