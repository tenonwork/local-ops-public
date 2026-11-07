// Autorun watcher: Claude-free, run with --once by a scheduler. Checks the gates (G1 an approved candidate, G2 no
// active claim and the lock free, G3 usage headroom, G4 a clean tree, then the claude executable and its version) and,
// when all pass, launches one headless Claude Code run on the first candidate, waits for it and records
// autorun_launch / autorun_result through ops.record_gate as ops_executor. Gate refusals are only logged. The database
// refuses an 'autorun:' claim without a current autorun_approved gate (migration 0039), so the gates here are about
// when to run, not what may run. No password here: pg falls back to pgpass, as in db.ts.
//
//   node mcp/src/watcher.ts --once
import pg from 'pg';
import { execFile, spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, posix, win32 } from 'node:path';
import { fileURLToPath } from 'node:url';
import { access, appendFile, open, readFile, rename, stat, unlink } from 'node:fs/promises';

export interface WatcherConfig {
  model: string;
  claudeCommand: string;
  timeoutMin: number;
  maxReadingAgeS: number;
  maxFiveHourPct: number;
  maxSevenDayPct: number;
}

export interface Usage {
  captured_at?: string;
  age_s?: number;
  client?: string;
  five_hour_pct?: number | null;
  five_hour_resets_at?: string | null;
  seven_day_pct?: number | null;
  seven_day_resets_at?: string | null;
  window_number?: number | null;
}

export interface Candidate { id: string; dispatch_type?: string; title?: string; node_path?: string }

export interface AutorunState { candidates: Candidate[]; active_claims: number; usage: Usage | null }

export interface WatcherDb {
  autorunState(): Promise<AutorunState>;
  // number of the ops.window_state row with live = true, or null when none is live
  liveWindow(): Promise<number | null>;
  recordGate(gateKey: 'autorun_launch' | 'autorun_result', result: 'pass' | 'fail', dispatchId: string,
    reason: string): Promise<void>;
  end(): Promise<void>;
}

export interface ChildResult { code: number | null; stdout: string; stderr: string }
export interface Child { pid?: number; result: Promise<ChildResult>; kill(signal?: NodeJS.Signals): void }
export interface SpawnOpts { cwd: string; shell: false }

export interface Deps {
  readConfig: () => Promise<unknown>;
  connect: () => Promise<WatcherDb>;
  repoRoot: string;
  mcpConfigPath: string;
  // directory of the lock and the log (os.tmpdir() in main)
  stateDir: string;
  gitStatus: (cwd: string) => Promise<string>;
  exists: (path: string) => Promise<boolean>;
  probeVersion: (command: string) => Promise<string>;
  spawn: (command: string, args: string[], opts: SpawnOpts) => Child;
  now: () => Date;
  sleep: (ms: number) => Promise<void>;
  pidAlive: (pid: number) => boolean;
  pid: number;
}

export const MIN_VERSION = [2, 1, 259] as const;
export const LOCK_NAME = 'local-ops-watcher.lock';
export const LOG_NAME = 'local-ops-watcher.log';
export const LOG_MAX_BYTES = 1024 * 1024;
export const KILL_GRACE_MS = 60_000;
export const REASON_MAX = 4000;

export class ConfigError extends Error {}

const KEYS = ['model', 'claudeCommand', 'timeoutMin', 'maxReadingAgeS', 'maxFiveHourPct', 'maxSevenDayPct'] as const;

const isAbsolutePath = (p: string) => win32.isAbsolute(p) || posix.isAbsolute(p);

// Every field required and checked; unknown keys refused. claudeCommand is a bare command name or an absolute path.
export function validateConfig(v: unknown): WatcherConfig {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new ConfigError('config is not an object');
  const o = v as Record<string, unknown>;
  const extra = Object.keys(o).filter((k) => !(KEYS as readonly string[]).includes(k));
  if (extra.length > 0) throw new ConfigError(`unknown config fields: ${extra.join(', ')}`);
  const { model, claudeCommand, timeoutMin, maxReadingAgeS, maxFiveHourPct, maxSevenDayPct } = o;
  if (typeof model !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._\[\]-]*$/.test(model)) {
    throw new ConfigError('model must be a model name or alias');
  }
  if (typeof claudeCommand !== 'string' || claudeCommand.trim() !== claudeCommand || claudeCommand === '') {
    throw new ConfigError('claudeCommand must be a non-blank string');
  }
  if (/[\\/]/.test(claudeCommand) && !isAbsolutePath(claudeCommand)) {
    throw new ConfigError('claudeCommand must be a bare command name or an absolute path');
  }
  const posInt = (n: unknown) => typeof n === 'number' && Number.isInteger(n) && n > 0;
  const pct = (n: unknown) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 100;
  if (!posInt(timeoutMin)) throw new ConfigError('timeoutMin must be a positive integer');
  if (!posInt(maxReadingAgeS)) throw new ConfigError('maxReadingAgeS must be a positive integer');
  if (!pct(maxFiveHourPct)) throw new ConfigError('maxFiveHourPct must be a number from 0 to 100');
  if (!pct(maxSevenDayPct)) throw new ConfigError('maxSevenDayPct must be a number from 0 to 100');
  return {
    model, claudeCommand, timeoutMin: timeoutMin as number, maxReadingAgeS: maxReadingAgeS as number,
    maxFiveHourPct: maxFiveHourPct as number, maxSevenDayPct: maxSevenDayPct as number,
  };
}

// G3. null = pass; otherwise the refusal reason.
export function checkUsage(usage: Usage | null, liveWindow: number | null, c: WatcherConfig): string | null {
  if (liveWindow === null) return null;
  if (!usage) return `no usage reading in live window ${liveWindow}`;
  if (usage.window_number !== liveWindow) {
    return `usage reading is from window ${usage.window_number ?? 'none'}, live window is ${liveWindow}`;
  }
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const age = num(usage.age_s);
  const five = num(usage.five_hour_pct);
  const seven = num(usage.seven_day_pct);
  if (age === null || age > c.maxReadingAgeS) return `usage reading age ${age ?? 'unknown'}s over ${c.maxReadingAgeS}s`;
  if (five === null || five > c.maxFiveHourPct) return `five-hour usage ${five ?? 'unknown'}% over ${c.maxFiveHourPct}%`;
  if (seven === null || seven > c.maxSevenDayPct) return `seven-day usage ${seven ?? 'unknown'}% over ${c.maxSevenDayPct}%`;
  return null;
}

// "2.1.306 (Claude Code)" -> [2, 1, 306]; null when no x.y.z is found.
export function parseVersion(out: string): [number, number, number] | null {
  const m = out.match(/(\d+)\.(\d+)\.(\d+)/);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function versionAtLeast(v: readonly number[], min: readonly number[]): boolean {
  for (let i = 0; i < 3; i++) if (v[i] !== min[i]) return v[i] > min[i];
  return true;
}

export function launchArgs(id: string, c: WatcherConfig, mcpConfigPath: string): string[] {
  return ['-p', `/ops-execute ${id.slice(0, 8)}`, '--model', c.model, '--permission-mode', 'auto',
    '--permission-prompts', 'none', '--output-format', 'json', '--strict-mcp-config', '--mcp-config', mcpConfigPath];
}

// autorun_result: pass only for exit 0 with parsed is_error false. Every field optional; the reason stays under
// REASON_MAX characters (usage is dropped first, then denial names, then the result text).
export function summarizeResult(r: ChildResult, timedOut: boolean): { pass: boolean; reason: string } {
  const out: Record<string, unknown> = { exit_code: r.code };
  let parsed: Record<string, unknown> | null = null;
  try {
    const v = JSON.parse(r.stdout.trim());
    if (v !== null && typeof v === 'object' && !Array.isArray(v)) parsed = v as Record<string, unknown>;
  } catch { /* unparseable */ }
  if (parsed) {
    for (const k of ['subtype', 'is_error', 'session_id', 'num_turns', 'duration_ms', 'total_cost_usd', 'usage'] as const) {
      if (parsed[k] !== undefined) out[k] = parsed[k];
    }
    if (Array.isArray(parsed.permission_denials)) {
      const d = parsed.permission_denials as unknown[];
      out.permission_denials = {
        count: d.length,
        tools: d.map((x) => (x !== null && typeof x === 'object' ? (x as Record<string, unknown>).tool_name : undefined))
          .filter((n): n is string => typeof n === 'string'),
      };
    }
    if (typeof parsed.result === 'string') out.result = parsed.result.slice(0, 300);
  } else if (!timedOut) {
    out.subtype = 'unparseable_output';
  }
  if (timedOut) {
    out.subtype = 'timeout';
    out.note = 'claim may be left claimed: planner reconciles';
  }
  const pass = !timedOut && r.code === 0 && parsed !== null && parsed.is_error === false;
  let reason = JSON.stringify(out);
  if (reason.length >= REASON_MAX) { delete out.usage; reason = JSON.stringify(out); }
  if (reason.length >= REASON_MAX && out.permission_denials) {
    out.permission_denials = { count: (out.permission_denials as { count: number }).count };
    reason = JSON.stringify(out);
  }
  if (reason.length >= REASON_MAX) { delete out.result; reason = JSON.stringify(out); }
  if (reason.length >= REASON_MAX) reason = JSON.stringify({ exit_code: r.code, subtype: out.subtype ?? null });
  return { pass, reason };
}

interface LockBody { pid: number; started_at: string; dispatch_id: string }

// Exclusive create (wx). An existing lock is stale when older than timeoutMin + 15 minutes, its pid is not running,
// or it is unreadable; a stale lock is replaced. Returns null when held, else a note for the log ('' or 'replaced ...').
export async function acquireLock(path: string, body: LockBody, c: WatcherConfig, deps: Pick<Deps, 'now' | 'pidAlive'>):
  Promise<string | null> {
  const create = async () => {
    try {
      const fh = await open(path, 'wx');
      try { await fh.writeFile(JSON.stringify(body)); } finally { await fh.close(); }
      return true;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'EEXIST') return false;
      throw err;
    }
  };
  if (await create()) return '';
  let held: Partial<LockBody> | null = null;
  try { held = JSON.parse(await readFile(path, 'utf8')) as Partial<LockBody>; } catch { /* unreadable: stale */ }
  const started = held && typeof held.started_at === 'string' ? Date.parse(held.started_at) : NaN;
  const maxAgeMs = (c.timeoutMin + 15) * 60_000;
  let stale: string | null = null;
  if (!held || typeof held.pid !== 'number' || Number.isNaN(started)) stale = 'unreadable';
  else if (deps.now().getTime() - started > maxAgeMs) stale = `older than ${c.timeoutMin + 15} min`;
  else if (!deps.pidAlive(held.pid)) stale = `pid ${held.pid} not running`;
  if (stale === null) return null;
  await unlink(path).catch(() => undefined);
  if (!(await create())) return null;
  return `replaced stale lock (${stale}${held?.dispatch_id ? `, dispatch ${held.dispatch_id}` : ''})`;
}

// One line per invocation; a log over LOG_MAX_BYTES is renamed to .1 (replacing) first.
export async function writeLog(dir: string, line: string): Promise<void> {
  const path = join(dir, LOG_NAME);
  try {
    if ((await stat(path)).size > LOG_MAX_BYTES) await rename(path, `${path}.1`);
  } catch { /* no log yet */ }
  await appendFile(path, `${line.replace(/[\r\n]+/g, ' ')}\n`);
}

export interface Outcome { exitCode: 0 | 1; line: string }

export async function runOnce(deps: Deps): Promise<Outcome> {
  const stamp = deps.now().toISOString();
  const notes: string[] = [];
  const finish = async (exitCode: 0 | 1, outcome: string): Promise<Outcome> => {
    const line = `${stamp} ${outcome}${notes.length ? ` [${notes.join('; ')}]` : ''}`;
    await writeLog(deps.stateDir, line).catch(() => undefined);
    return { exitCode, line };
  };

  let config: WatcherConfig;
  try {
    config = validateConfig(await deps.readConfig());
  } catch (err) {
    return finish(1, `config error: ${err instanceof Error ? err.message : String(err)}`);
  }

  let db: WatcherDb;
  try {
    db = await deps.connect();
  } catch (err) {
    return finish(1, `connection error: ${err instanceof Error ? err.message : String(err)}`);
  }

  const lockPath = join(deps.stateDir, LOCK_NAME);
  let locked = false;
  try {
    const state = await db.autorunState();
    const candidate = state.candidates[0];
    if (!candidate) return await finish(0, 'refused G1: no approved candidate');
    const id8 = candidate.id.slice(0, 8);

    if (state.active_claims !== 0) return await finish(0, `refused G2: ${state.active_claims} active claim(s)`);
    const note = await acquireLock(lockPath,
      { pid: deps.pid, started_at: deps.now().toISOString(), dispatch_id: candidate.id }, config, deps);
    if (note === null) return await finish(0, 'refused G2: watcher lock held');
    locked = true;
    if (note) notes.push(note);

    const live = await db.liveWindow();
    const usageRefusal = checkUsage(state.usage, live, config);
    if (usageRefusal) return await finish(0, `refused G3: ${usageRefusal}`);

    let porcelain: string;
    try {
      porcelain = await deps.gitStatus(deps.repoRoot);
    } catch (err) {
      return await finish(0, `refused G4: git status failed: ${err instanceof Error ? err.message : String(err)}`);
    }
    if (porcelain.trim() !== '') return await finish(0, 'refused G4: working tree not clean');

    if (isAbsolutePath(config.claudeCommand) && !(await deps.exists(config.claudeCommand))) {
      return await finish(0, `refused executable: claude executable missing (${config.claudeCommand})`);
    }
    let versionOut: string;
    try {
      versionOut = await deps.probeVersion(config.claudeCommand);
    } catch (err) {
      return await finish(0, `refused version: --version failed: ${err instanceof Error ? err.message : String(err)}`);
    }
    const version = parseVersion(versionOut);
    if (!version) return await finish(0, `refused version: unparseable version output ${JSON.stringify(versionOut.slice(0, 80))}`);
    if (!versionAtLeast(version, MIN_VERSION)) {
      return await finish(0, `refused version: ${version.join('.')} below ${MIN_VERSION.join('.')}`);
    }

    await db.recordGate('autorun_launch', 'pass', candidate.id, JSON.stringify({
      id8, model: config.model, claude_version: version.join('.'), pid: deps.pid, usage: state.usage ?? null,
      live_window: live,
    }));
    const child = deps.spawn(config.claudeCommand, launchArgs(candidate.id, config, deps.mcpConfigPath),
      { cwd: deps.repoRoot, shell: false });

    const TIMED_OUT = Symbol('timeout');
    const first = await Promise.race([child.result, deps.sleep(config.timeoutMin * 60_000).then(() => TIMED_OUT)]);
    let result: ChildResult;
    const timedOut = first === TIMED_OUT;
    if (timedOut) {
      child.kill('SIGINT');
      const settled = await Promise.race([child.result, deps.sleep(KILL_GRACE_MS).then(() => null)]);
      if (settled === null) child.kill();
      result = settled ?? { code: null, stdout: '', stderr: '' };
    } else {
      result = first as ChildResult;
    }

    const summary = summarizeResult(result, timedOut);
    await db.recordGate('autorun_result', summary.pass ? 'pass' : 'fail', candidate.id, summary.reason);
    if (result.stderr.trim()) notes.push(`stderr: ${JSON.stringify(result.stderr.slice(-1000))}`);
    return await finish(0, `launched ${id8}: ${summary.pass ? 'pass' : 'fail'} ${summary.reason}`);
  } catch (err) {
    return await finish(1, `error: ${err instanceof Error ? err.message : String(err)}`);
  } finally {
    if (locked) await unlink(lockPath).catch(() => undefined);
    await db.end().catch(() => undefined);
  }
}

// --- real dependencies (main only) ---

export function defaultDb(): () => Promise<WatcherDb> {
  return async () => {
    const client = new pg.Client({
      host: process.env.LOCAL_OPS_HOST ?? 'localhost',
      port: Number(process.env.LOCAL_OPS_PORT ?? 5432),
      database: process.env.LOCAL_OPS_DB ?? 'local_ops',
      user: 'ops_executor',
      application_name: 'local-ops-watcher',
      connectionTimeoutMillis: 5000,
      statement_timeout: 10000,
    });
    await client.connect();
    return {
      async autorunState() {
        const r = await client.query('SELECT ops.autorun_state() AS s');
        const s = (r.rows[0]?.s ?? {}) as Partial<AutorunState>;
        return { candidates: s.candidates ?? [], active_claims: Number(s.active_claims ?? 0), usage: s.usage ?? null };
      },
      async liveWindow() {
        const r = await client.query('SELECT number FROM ops.window_state WHERE live ORDER BY number DESC LIMIT 1');
        return r.rows.length ? Number(r.rows[0].number) : null;
      },
      async recordGate(gateKey, result, dispatchId, reason) {
        await client.query('SELECT ops.record_gate($1, $2::ops.gate_result, $3::uuid, $4::uuid, $5, $6, $7)',
          [gateKey, result, dispatchId, null, false, null, reason]);
      },
      async end() { await client.end(); },
    };
  };
}

function execText(command: string, args: string[], cwd?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(command, args, { cwd, shell: false, timeout: 30_000, windowsHide: true }, (err, stdout) => {
      if (err) reject(err); else resolve(String(stdout));
    });
  });
}

function realSpawn(command: string, args: string[], opts: SpawnOpts): Child {
  const c = spawn(command, args, { cwd: opts.cwd, shell: opts.shell, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let stdout = '';
  let stderr = '';
  c.stdout?.on('data', (d) => { stdout += String(d); });
  c.stderr?.on('data', (d) => { stderr += String(d); });
  const result = new Promise<ChildResult>((resolve) => {
    c.on('error', (err) => resolve({ code: null, stdout, stderr: `${stderr}${err.message}` }));
    c.on('close', (code) => resolve({ code, stdout, stderr }));
  });
  return { pid: c.pid, result, kill: (signal) => { c.kill(signal); } };
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code !== 'ESRCH';
  }
}

export async function main(): Promise<number> {
  const configPath = fileURLToPath(new URL('../watcher.config.json', import.meta.url));
  const outcome = await runOnce({
    readConfig: async () => JSON.parse(await readFile(configPath, 'utf8')),
    connect: defaultDb(),
    repoRoot: fileURLToPath(new URL('../../', import.meta.url)),
    mcpConfigPath: fileURLToPath(new URL('../autorun.mcp.json', import.meta.url)),
    stateDir: tmpdir(),
    gitStatus: (cwd) => execText('git', ['status', '--porcelain'], cwd),
    exists: (p) => access(p).then(() => true, () => false),
    probeVersion: (cmd) => execText(cmd, ['--version']),
    spawn: realSpawn,
    now: () => new Date(),
    sleep: (ms) => new Promise<void>((resolve) => { setTimeout(resolve, ms).unref(); }),
    pidAlive,
    pid: process.pid,
  });
  process.stderr.write(`${outcome.line}\n`);
  return outcome.exitCode;
}

if (import.meta.main) {
  if (process.argv.includes('--once')) {
    process.noDeprecation = true;
    main().then((code) => process.exit(code), () => process.exit(1));
  } else {
    process.stderr.write('usage: node mcp/src/watcher.ts --once\n');
    process.exit(1);
  }
}
