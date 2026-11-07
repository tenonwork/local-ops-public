// Migration runner for local-ops.
//
//   node scripts/migrate.ts status              read-only: state of every version; exit 1 on drift, orphan or no-checksum
//   node scripts/migrate.ts apply               apply unapplied migrations/*.sql in lexical order; refuses on drift or orphan
//   node scripts/migrate.ts adopt               backfill checksums for applied rows that have none
//   node scripts/migrate.ts baseline <version>  record a migration applied out of band, without running it
//   node scripts/migrate.ts refresh-rehearsal   dump production, reset local_ops_rehearsal and restore the dump into it
//   node scripts/migrate.ts promote <dispatch_id> [--dry-run]
//                                               apply the pending set to production within a promote dispatch, after
//                                               its approval gate, a fresh dump, a rehearsal apply and the full tests/sql suite
//
// Migration files own their transaction and their ledger row. The runner never wraps
// a file in a transaction and never inserts ledger rows for files it runs: it runs the
// file, checks the file registered itself, then writes the SHA-256 of the file bytes to
// that row. `baseline` is the one exception: it inserts the row (with checksum) for a
// file that was applied outside the runner, and never runs the file.
// 0000_* files are operator-run as a superuser and are always skipped.
//
// Connection: DATABASE_URL from the environment, else from .env, read only when a
// command runs (importing this module has no side effects). psql: env PSQL.
// Every command prints its target first, then refuses before any connection when the
// target leaves user, host, port or database to libpq. status, apply, adopt and baseline
// refuse the production database (CONFIG.production.database, on any host): production is
// reached only through refresh-rehearsal and promote. apply, adopt and baseline write, so
// they also require MIGRATE_EXPECT_DB to equal the target database. refresh-rehearsal and
// promote take production from the same DATABASE_URL and always use the CONFIG.rehearsal
// target; they check user, host, port and database of both against CONFIG and refuse while
// PGPASSWORD is set. Inherited libpq connection variables (PGHOST, PGUSER, ...) are cleared
// before every client call.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = `${import.meta.dirname}/..`;
const MIGRATIONS_DIR = `${ROOT}/migrations`;
const TESTS_DIR = `${ROOT}/tests/sql`;
const FILE_RE = /^(\d{4}_[a-z0-9_]+)\.sql$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Every hard-coded name the runner checks against. Approvals and gates are read from and written to the
// control plane, which is production.
export const CONFIG = Object.freeze({
  production: Object.freeze({ user: "local_ops", host: "localhost", port: "5432", database: "local_ops" }),
  rehearsal: Object.freeze({ user: "ops_dev", host: "localhost", port: "5432", database: "local_ops_rehearsal" }),
  executorUser: "ops_executor",
  gates: Object.freeze({ approval: "prod_apply_approved", apply: "prod_apply" }),
  promoteDispatchType: "promote",
});
const USAGE =
  "usage: node scripts/migrate.ts status|apply|adopt|baseline <version>|refresh-rehearsal|promote <dispatch_id> [--dry-run]\n" +
  "status, apply, adopt and baseline refuse the production database; production is reached only through\n" +
  "refresh-rehearsal and promote (promote runs within a promote dispatch, once; see promote --help).";
const PROMOTE_HELP = [
  "usage: node scripts/migrate.ts promote <dispatch_id> [--dry-run]",
  "",
  "The dispatch must be a promote dispatch that has not completed and has no prod_apply gate yet:",
  "one production attempt per promote dispatch; a retry is a new promote dispatch with a new approval.",
  "Requires an approval: the most recent prod_apply_approved gate for the dispatch recorded after its created_at",
  "must be result pass, not overridden, with a reason containing exactly one whitespace-separated token",
  "  versions=<stem>:<sha256>,<stem>:<sha256>,...  (stem = migration file stem; sha256 = of the file bytes, 64 lowercase hex)",
  "e.g. 'operator approved versions=0014_example:<64 hex>,0015_next:<64 hex>'. The set must equal the pending set on",
  "production exactly (same versions, same checksums). The single-version version=/checksum= format is retired.",
  "A later prod_apply_approved row with result fail for the same dispatch revokes an earlier pass.",
  "status, apply, adopt and baseline refuse production; only refresh-rehearsal and promote reach it.",
].join("\n");

export type Migration = { version: string; file: string; path: string };

// version -> checksum ('' when null or when the checksum column does not exist yet)
export type Ledger = Map<string, string>;

export type Entry =
  | { version: string; state: "ok"; checksum: string }
  | { version: string; state: "pending" }
  | { version: string; state: "drift"; ledger: string; file: string }
  | { version: string; state: "no-checksum" }
  | { version: string; state: "orphan" };

export interface Db {
  ledgerExists(): boolean;
  checksumColumnExists(): boolean;
  ledger(): Ledger;
  // Returns the server messages (NOTICE, WARNING) the file printed.
  runFile(path: string): string[];
  // Returns the number of rows updated.
  setChecksum(version: string, checksum: string): number;
  // Inserts version + checksum in one transaction.
  insertBaseline(version: string, checksum: string): void;
}

export type Ctx = { dir: string; db: Db; log: (line: string) => void };

export class MigrateError extends Error {}

function fail(msg: string): never {
  throw new MigrateError(msg);
}

// ── Pure functions

// Splits migration filenames into runnable migrations (lexical order) and operator-run skips.
export function parseFiles(names: string[]): { migrations: Omit<Migration, "path">[]; skipped: string[] } {
  const migrations: Omit<Migration, "path">[] = [];
  const skipped: string[] = [];
  for (const file of names.filter((f) => f.endsWith(".sql")).sort()) {
    if (file.startsWith("0000_")) {
      skipped.push(file);
      continue;
    }
    const m = file.match(FILE_RE);
    if (!m) fail(`unexpected migration filename: ${file}`);
    migrations.push({ version: m[1], file });
  }
  return { migrations, skipped };
}

export function checksum(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

// Per-version state, in version order. Ledger rows with no file are orphans.
export function plan(files: { version: string; checksum: string }[], ledger: Ledger): Entry[] {
  const entries: Entry[] = files.map(({ version, checksum: file }): Entry => {
    if (!ledger.has(version)) return { version, state: "pending" };
    const recorded = ledger.get(version)!;
    if (recorded === "") return { version, state: "no-checksum" };
    if (recorded !== file) return { version, state: "drift", ledger: recorded, file };
    return { version, state: "ok", checksum: file };
  });
  const known = new Set(files.map((f) => f.version));
  for (const version of ledger.keys()) {
    if (!known.has(version)) entries.push({ version, state: "orphan" });
  }
  return entries.sort((a, b) => (a.version < b.version ? -1 : a.version > b.version ? 1 : 0));
}

export function describe(e: Entry): string {
  switch (e.state) {
    case "ok": return `ok          ${e.version}`;
    case "pending": return `pending     ${e.version}`;
    case "drift": return `DRIFT       ${e.version} ledger=${e.ledger} file=${e.file}`;
    case "no-checksum": return `no-checksum ${e.version} (run adopt)`;
    case "orphan": return `ORPHAN      ${e.version} (ledger row, no file)`;
  }
}

// Entries that block `apply`.
export function applyBlockers(entries: Entry[]): Entry[] {
  return entries.filter((e) => e.state === "drift" || e.state === "orphan");
}

// Entries that make `status` exit non-zero.
export function statusProblems(entries: Entry[]): Entry[] {
  return entries.filter((e) => e.state === "drift" || e.state === "orphan" || e.state === "no-checksum");
}

// Why `baseline <version>` must refuse, or null if it may proceed.
export function baselineRefusal(version: string, entries: Entry[]): string | null {
  const target = entries.find((e) => e.version === version);
  if (!target || target.state === "orphan") return `no migration file for version '${version}'`;
  if (target.state !== "pending") return `ledger row for '${version}' already exists (${target.state})`;
  const earlier = entries.filter((e) => e.version < version && e.state === "pending").map((e) => e.version);
  if (earlier.length > 0) return `earlier version(s) pending: ${earlier.join(", ")}; apply or baseline them first`;
  return null;
}

// ── Commands (all I/O goes through ctx)

function discover(ctx: Ctx): Migration[] {
  const { migrations, skipped } = parseFiles(readdirSync(ctx.dir));
  for (const file of skipped) ctx.log(`skip    ${file} (operator-run)`);
  return migrations.map((m) => ({ ...m, path: `${ctx.dir}/${m.file}` }));
}

function sha256(m: Migration): string {
  return checksum(readFileSync(m.path));
}

function currentPlan(ctx: Ctx, migrations: Migration[]): Entry[] {
  return plan(migrations.map((m) => ({ version: m.version, checksum: sha256(m) })), ctx.db.ledger());
}

function writeChecksum(ctx: Ctx, m: Migration): void {
  const hash = sha256(m);
  const updated = ctx.db.setChecksum(m.version, hash);
  if (updated !== 1) fail(`checksum write for ${m.version} touched ${updated} rows`);
  ctx.log(`sum     ${m.version} ${hash}`);
}

export function status(ctx: Ctx): number {
  const entries = currentPlan(ctx, discover(ctx));
  for (const e of entries) ctx.log(describe(e));
  const counts = new Map<string, number>();
  for (const e of entries) counts.set(e.state, (counts.get(e.state) ?? 0) + 1);
  ctx.log(`summary: ${[...counts].map(([s, n]) => `${n} ${s}`).join(", ") || "no migrations"}`);
  return statusProblems(entries).length > 0 ? 1 : 0;
}

export function apply(ctx: Ctx): number {
  const migrations = discover(ctx);
  const blockers = applyBlockers(currentPlan(ctx, migrations));
  if (blockers.length > 0) {
    for (const e of blockers) ctx.log(describe(e));
    fail(`refusing to apply: ${blockers.length} drifted or orphaned version(s); nothing was run`);
  }
  const applied = ctx.db.ledger();
  // Files applied before the checksum column exists (fresh instance) get their
  // checksum once a later file in this run creates the column.
  const awaitingChecksum: Migration[] = [];
  let ran = 0;

  for (const m of migrations) {
    if (applied.has(m.version)) {
      ctx.log(`ok      ${m.version} (already applied)`);
      continue;
    }
    ctx.log(`apply   ${m.file}`);
    for (const line of ctx.db.runFile(m.path)) ctx.log(`notice  ${line}`);
    ran++;

    if (!ctx.db.ledger().has(m.version)) {
      fail(`${m.file} ran but did not insert its ledger row '${m.version}'; no checksum written. Stopping.`);
    }
    awaitingChecksum.push(m);
    if (ctx.db.checksumColumnExists()) {
      for (const pending of awaitingChecksum.splice(0)) writeChecksum(ctx, pending);
    }
  }

  if (awaitingChecksum.length > 0) {
    fail(`no checksum column; unsummed: ${awaitingChecksum.map((m) => m.version).join(", ")}`);
  }
  ctx.log(ran === 0 ? "nothing to apply" : `applied ${ran} migration(s)`);
  return 0;
}

export function adopt(ctx: Ctx): number {
  if (!ctx.db.ledgerExists() || !ctx.db.checksumColumnExists()) {
    fail("ops.schema_migrations.checksum does not exist; run apply first");
  }
  const applied = ctx.db.ledger();
  let adopted = 0;
  for (const m of discover(ctx)) {
    if (!applied.has(m.version)) {
      ctx.log(`pending ${m.version} (not applied; use apply)`);
      continue;
    }
    const existing = applied.get(m.version);
    if (existing) {
      const now = sha256(m);
      ctx.log(existing === now ? `ok      ${m.version} (checksum present)` : `DRIFT   ${m.version} ledger=${existing} file=${now}`);
      continue;
    }
    writeChecksum(ctx, m);
    adopted++;
  }
  ctx.log(`adopted ${adopted} checksum(s)`);
  return 0;
}

// Exactly one explicit version; no wildcards, no 'all', no operator-run 0000_* files.
export function baselineVersion(args: string[]): string {
  if (args.length !== 1) fail(`baseline takes exactly one version\n${USAGE}`);
  const version = args[0];
  if (!FILE_RE.test(`${version}.sql`) || version.startsWith("0000_")) {
    fail(`'${version}' is not a migration version (expected e.g. 0004_secret_handling_incidents)`);
  }
  return version;
}

export function baseline(ctx: Ctx, version: string): number {
  if (!ctx.db.ledgerExists() || !ctx.db.checksumColumnExists()) {
    fail("ops.schema_migrations.checksum does not exist; run apply first");
  }
  const migrations = discover(ctx);
  const refusal = baselineRefusal(version, currentPlan(ctx, migrations));
  if (refusal) fail(`refusing to baseline: ${refusal}`);
  const hash = sha256(migrations.find((m) => m.version === version)!);
  ctx.db.insertBaseline(version, hash);
  ctx.log(`baseline ${version} ${hash}`);
  return 0;
}

// ── Target resolution and guard (pure; main does the I/O)

// Connection parts from DATABASE_URL; null means the URL leaves it to libpq.
export type Target = {
  url: string;
  user: string | null;
  host: string | null;
  port: string | null;
  database: string | null;
  source: "shell" | ".env";
};

// A non-empty shell DATABASE_URL wins and .env is ignored. Otherwise the first
// DATABASE_URL= line of the .env text (null: no .env), one layer of matching quotes removed.
export function resolveTarget(env: Record<string, string | undefined>, dotenvText: string | null): Target {
  let url: string | undefined;
  let source: Target["source"] = "shell";
  if (env.DATABASE_URL) {
    url = env.DATABASE_URL;
  } else if (dotenvText !== null) {
    source = ".env";
    for (const line of dotenvText.split(/\r?\n/)) {
      const m = line.match(/^\s*DATABASE_URL\s*=\s*(.*?)\s*$/);
      if (m) {
        url = m[1].replace(/^(['"])(.*)\1$/, "$2");
        break;
      }
    }
  }
  if (url === undefined) fail("DATABASE_URL not set and not found in .env");
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    // Never echo the value: it may hold a password.
    fail(`DATABASE_URL from ${source} is not a valid URL`);
  }
  const part = (s: string) => (s ? decodeURIComponent(s) : null);
  return {
    url,
    user: part(u.username),
    host: u.hostname || null,
    port: u.port || null,
    database: part(u.pathname.replace(/^\//, "")),
    source,
  };
}

// One line naming the target. Never includes the password or the URL.
export function describeTarget(t: Target): string {
  const d = (v: string | null) => v ?? "(default)";
  return `target  ${d(t.user)}@${d(t.host)}:${d(t.port)}/${d(t.database)}  (from ${t.source})`;
}

const targetText = (t: Target) => describeTarget(t).replace(/^target\s+/, "");

const TARGET_PARTS = ["user", "host", "port", "database"] as const;

// Why t must not be used because it leaves a connection part to libpq, or null.
export function incompleteTarget(t: Target): string | null {
  const missing = TARGET_PARTS.filter((k) => t[k] === null);
  if (missing.length === 0) return null;
  return `target must state user, host, port and database explicitly; ${missing.join(", ")} missing in ${targetText(t)}`;
}

// Commands that never reach production.
export const PLAIN_COMMANDS: ReadonlySet<string> = new Set(["status", "apply", "adopt", "baseline"]);

// Why cmd must not run against t because t is the production database (on any host), or null.
export function productionRefusal(cmd: string, t: Target): string | null {
  if (!PLAIN_COMMANDS.has(cmd) || t.database !== CONFIG.production.database) return null;
  return (
    `${cmd} refuses the production database ${CONFIG.production.database} (resolved ${targetText(t)}); ` +
    "production is reached only through refresh-rehearsal and promote"
  );
}

// Commands that write to the target. adopt writes checksums to the ledger.
export const GUARDED_COMMANDS: ReadonlySet<string> = new Set(["apply", "adopt", "baseline"]);

// Why `cmd` must not run against `t` given MIGRATE_EXPECT_DB, or null if it may.
// A URL with no database name never matches: libpq would pick one the guard cannot see.
export function expectRefusal(cmd: string, t: Target, expected: string | undefined): string | null {
  if (!GUARDED_COMMANDS.has(cmd)) return null;
  const where = describeTarget(t).replace(/^target\s+/, "");
  if (!expected) return `${cmd} requires MIGRATE_EXPECT_DB (expected database name, currently unset); resolved target is ${where}`;
  if (t.database !== expected) return `MIGRATE_EXPECT_DB=${expected} does not match the resolved target ${where}`;
  return null;
}

// ── refresh-rehearsal and promote
//
// Production is the resolved DATABASE_URL (normally .env), which must be CONFIG.production. Rehearsal is always
// CONFIG.rehearsal, password from pgpass. Approvals and gates live on the control plane (production): the approval
// is read as the production owner; the outcome gate is written as CONFIG.executorUser (pgpass), on the production
// host, port and database.

export const REHEARSAL_URL =
  `postgresql://${CONFIG.rehearsal.user}@${CONFIG.rehearsal.host}:${CONFIG.rehearsal.port}/${CONFIG.rehearsal.database}`;

// The dispatch, its approval gates and its count of outcome (prod_apply) gates, as read from production.
// Timestamps are fixed-width UTC text (YYYY-MM-DDTHH:MM:SS.ffffffZ), so string comparison is time order at
// microsecond precision. id is the gate_events bigint id as decimal text; reason is null when the row has none.
export type Approval = {
  dispatch: { id: string; dispatchType: string; createdAt: string; completedAt: string | null } | null;
  applyGateCount: number;
  gates: {
    id: string;
    dispatchId: string;
    gateKey: string;
    result: string;
    overridden: boolean;
    at: string;
    reason: string | null;
  }[];
};

export type GateRecord = { key: string; result: "pass" | "fail"; dispatchId: string; reason: string };

// Process-level operations; tests pass fakes.
export interface Tools {
  // pg_dump -Fc of t into file. Throws MigrateError on failure.
  dump(t: Target, file: string): void;
  // Size in bytes, or null if the file does not exist.
  fileSize(file: string): number | null;
  // As the rehearsal user, in one transaction: DROP SCHEMA ops CASCADE; DROP EXTENSION IF EXISTS ltree, pg_trgm.
  resetRehearsal(t: Target): void;
  // pg_restore --no-owner --single-transaction of file into t. Throws MigrateError on failure.
  restore(t: Target, file: string): void;
  // psql -f path against t. Never throws on a non-zero exit; returns it with the output lines.
  runSqlFile(t: Target, path: string): { status: number; output: string[] };
  // Reads the dispatch, its approval gate rows and its count of apply gate rows from production (t is the
  // production target).
  approval(t: Target, dispatchId: string): Approval;
  // ops.record_gate on t (the executor target).
  recordGate(t: Target, gate: GateRecord): void;
}

export type PromoteCtx = {
  dir: string;
  testsDir: string;
  tmpDir: string;
  now: () => Date;
  prod: Target;
  rehearsal: Target;
  connect: (t: Target) => Db;
  tools: Tools;
  log: (line: string) => void;
};

// The parts of t that differ from want, e.g. "host 127.0.0.1 (expected localhost)".
function partDiffs(t: Target, want: { [K in (typeof TARGET_PARTS)[number]]: string }): string[] {
  return TARGET_PARTS.filter((k) => t[k] !== want[k]).map((k) => `${k} ${t[k] ?? "(default)"} (expected ${want[k]})`);
}

// Why refresh-rehearsal / promote must not run against these targets, or null.
export function rehearsalRefusal(prod: Target, rehearsal: Target, env: Record<string, string | undefined>): string | null {
  if (env.PGPASSWORD) return "PGPASSWORD is set; unset it (connections use .env and pgpass only)";
  const p = CONFIG.production;
  const prodDiffs = partDiffs(prod, p);
  if (prodDiffs.length > 0) {
    return (
      `production target must be database ${p.database} as ${p.user} on ${p.host}:${p.port} ` +
      `(differs: ${prodDiffs.join(", ")}), resolved ${targetText(prod)}`
    );
  }
  const r = CONFIG.rehearsal;
  const rehDiffs = partDiffs(rehearsal, r);
  if (rehDiffs.length > 0) {
    return (
      `rehearsal target must be ${r.user} on ${r.database} at ${r.host}:${r.port} ` +
      `(differs: ${rehDiffs.join(", ")}), got ${targetText(rehearsal)}`
    );
  }
  return null;
}

// %TEMP%\local_ops_<UTC yyyymmddThhmmssZ>_pre_<label>.dump
export function dumpPath(dir: string, now: Date, label: string): string {
  const stamp = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  return join(dir, `local_ops_${stamp}_pre_${label}.dump`);
}

// Same host, port, database and options as production, as the executor user with no password (pgpass).
export function executorTarget(prod: Target): Target {
  const u = new URL(prod.url);
  u.username = CONFIG.executorUser;
  u.password = "";
  return { ...prod, url: u.toString(), user: CONFIG.executorUser };
}

// Ledger rows that differ between production and rehearsal (version + checksum).
export function ledgerDiff(prod: Ledger, rehearsal: Ledger): string[] {
  const versions = [...new Set([...prod.keys(), ...rehearsal.keys()])].sort();
  return versions
    .filter((v) => prod.get(v) !== rehearsal.get(v))
    .map((v) => `${v} production=${prod.get(v) ?? "(none)"} rehearsal=${rehearsal.get(v) ?? "(none)"}`);
}

// The versions promote applies, in order, given the production plan: production must be clean and have
// at least one pending version; every pending version is in the set.
export function promoteSet(entries: Entry[]): string[] {
  const problems = statusProblems(entries);
  if (problems.length > 0) {
    fail(`production is not clean (${problems.map(describe).join("; ")}); run status`);
  }
  const pending = entries.filter((e) => e.state === "pending").map((e) => e.version);
  if (pending.length === 0) fail("promote needs at least one pending migration; production has 0");
  return pending;
}

const VERSION_RE = /^\d{4}_[a-z0-9_]+$/;
const CHECKSUM_RE = /^[0-9a-f]{64}$/;

export type VersionSum = { version: string; checksum: string };

export const formatSet = (set: VersionSum[]): string => set.map((p) => `${p.version}:${p.checksum}`).join(",");

// The approved set from an approval reason: exactly one whitespace-separated token versions=<stem>:<sha256>,...,
// other text ignored. Returns the pairs in the order given, or why the reason does not name a set.
export function parseApprovalSet(reason: string | null): VersionSum[] | string {
  const tokens = (reason ?? "").split(/\s+/).filter((t) => t !== "");
  if (tokens.some((t) => /^(version|checksum)=/.test(t))) {
    return "approval reason uses the retired single-version format (version=/checksum=); use versions=<stem>:<sha256>,...";
  }
  const found = tokens.filter((t) => t.startsWith("versions=")).map((t) => t.slice("versions=".length));
  if (found.length === 0) return "approval reason has no versions=<stem>:<sha256>,... token";
  if (found.length > 1) return `approval reason has ${found.length} versions= tokens; exactly one is allowed`;
  if (found[0] === "") return "approval reason versions= lists no migrations";
  const pairs: VersionSum[] = [];
  for (const pair of found[0].split(",")) {
    const m = pair.match(/^([^:]*):([^:]*)$/);
    if (!m) return `approval reason pair '${pair}' is not <stem>:<sha256>`;
    const [, version, sum] = m;
    if (!VERSION_RE.test(version)) return `approval reason version '${version}' is not a migration file stem`;
    if (version.startsWith("0000_")) return `approval reason version '${version}' is operator-run (0000_*) and cannot be promoted`;
    if (!CHECKSUM_RE.test(sum)) return `approval reason checksum '${sum}' for ${version} is not 64 lowercase hex characters`;
    if (pairs.some((p) => p.version === version)) return `approval reason lists ${version} more than once`;
    pairs.push({ version, checksum: sum });
  }
  return pairs;
}

// How the approved set differs from the pending set, or [] when they are equal as sets.
export function setDiff(approved: VersionSum[], pending: VersionSum[]): string[] {
  const a = new Map(approved.map((p) => [p.version, p.checksum]));
  const p = new Map(pending.map((x) => [x.version, x.checksum]));
  const missing = [...a.keys()].filter((v) => !p.has(v)).sort();
  const extra = [...p.keys()].filter((v) => !a.has(v)).sort();
  const changed = [...a.keys()].filter((v) => p.has(v) && p.get(v) !== a.get(v)).sort();
  const out: string[] = [];
  if (missing.length > 0) out.push(`missing (approved, not pending): ${missing.join(", ")}`);
  if (extra.length > 0) out.push(`extra (pending, not approved): ${extra.join(", ")}`);
  for (const v of changed) out.push(`checksum differs: ${v} approved ${a.get(v)} pending ${p.get(v)}`);
  return out;
}

const byAtThenId = (x: Approval["gates"][number], y: Approval["gates"][number]) =>
  x.at !== y.at ? (x.at < y.at ? -1 : 1) : BigInt(x.id) < BigInt(y.id) ? -1 : BigInt(x.id) > BigInt(y.id) ? 1 : 0;

// Whether the approval authorises promoting the pending set within dispatchId. The dispatch must be an uncompleted
// promote dispatch with no outcome gate yet (one attempt per dispatch); the most recent approval row for it after its
// created_at (by at, then id) must be an unoverridden pass whose reason names exactly the pending set.
// Returns the approval's at, or why promote must refuse.
export function checkApproval(
  dispatchId: string,
  a: Approval,
  pending: VersionSum[],
): { approvedAt: string } | { refusal: string } {
  const { approval: APPROVAL, apply: APPLY } = CONFIG.gates;
  if (!a.dispatch || a.dispatch.id !== dispatchId) return { refusal: `dispatch ${dispatchId} not found` };
  const d = a.dispatch;
  if (d.dispatchType !== CONFIG.promoteDispatchType) {
    return { refusal: `dispatch ${dispatchId} is a '${d.dispatchType}' dispatch; promote runs only within a '${CONFIG.promoteDispatchType}' dispatch` };
  }
  if (d.completedAt) {
    return { refusal: `dispatch ${dispatchId} completed at ${d.completedAt}; a retry is a new promote dispatch with a new approval` };
  }
  if (a.applyGateCount > 0) {
    return {
      refusal:
        `dispatch ${dispatchId} already has ${a.applyGateCount} '${APPLY}' gate row(s); one production attempt per promote ` +
        "dispatch, a retry is a new promote dispatch with a new approval",
    };
  }
  const mine = a.gates.filter((g) => g.dispatchId === dispatchId && g.gateKey === APPROVAL);
  const latest = mine.filter((g) => g.at > d.createdAt).sort(byAtThenId).at(-1);
  if (!latest) {
    return {
      refusal:
        `no '${APPROVAL}' gate for dispatch ${dispatchId} recorded after its creation at ${d.createdAt}` +
        ` (${mine.length} ${APPROVAL} row(s) for this dispatch); the planner records it after the operator approves`,
    };
  }
  const which = `latest '${APPROVAL}' gate (id ${latest.id} at ${latest.at})`;
  if (latest.overridden) return { refusal: `${which} is overridden` };
  if (latest.result !== "pass") return { refusal: `${which} has result ${latest.result}; the approval is revoked or was refused` };
  const parsed = parseApprovalSet(latest.reason);
  if (typeof parsed === "string") return { refusal: `${which}: ${parsed}` };
  const diff = setDiff(parsed, pending);
  if (diff.length > 0) {
    return {
      refusal:
        `${which} does not match the pending set (${diff.join("; ")}):` +
        ` approved versions=${formatSet(parsed)}; pending versions=${formatSet(pending)}`,
    };
  }
  return { approvedAt: latest.at };
}

function prefixed(log: (line: string) => void, prefix: string): (line: string) => void {
  return (line) => log(`${prefix} ${line}`);
}

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

// Dumps production, resets rehearsal, restores the dump, checks both ledgers match. Returns the dump path.
export function refreshRehearsal(pc: PromoteCtx, label?: string): string {
  const prodDb = pc.connect(pc.prod);
  if (label === undefined) {
    const pending = currentPlan({ dir: pc.dir, db: prodDb, log: () => {} }, discover({ dir: pc.dir, db: prodDb, log: () => {} }))
      .find((e) => e.state === "pending");
    label = pending?.version ?? "refresh";
  }
  const file = dumpPath(pc.tmpDir, pc.now(), label);
  const rel = relative(resolve(ROOT), resolve(file));
  if (rel === "" || (!rel.startsWith("..") && !isAbsolute(rel))) fail(`dump path ${file} is inside the repository`);

  pc.log(`dump    production -> ${file}`);
  try {
    pc.tools.dump(pc.prod, file);
  } catch (e) {
    if (!(e instanceof MigrateError)) throw e;
    fail(`pg_dump failed; rehearsal not touched\n${e.message}`);
  }
  const size = pc.tools.fileSize(file);
  if (!size) fail(`dump ${file} is ${size === null ? "missing" : "empty"}; rehearsal not touched`);
  pc.log(`dump    ${size} bytes`);

  const rehDb = CONFIG.rehearsal.database;
  try {
    pc.log(`reset   ${rehDb} (drop schema ops, extensions ltree, pg_trgm)`);
    pc.tools.resetRehearsal(pc.rehearsal);
    pc.log(`restore ${file} -> ${rehDb} (--no-owner)`);
    pc.tools.restore(pc.rehearsal, file);
  } catch (e) {
    fail(
      `rehearsal reset or restore failed; ${rehDb} may have no ops schema. ` +
        `Re-run \`node scripts/migrate.ts refresh-rehearsal\`\n${errorText(e)}`,
    );
  }

  const diff = ledgerDiff(prodDb.ledger(), pc.connect(pc.rehearsal).ledger());
  if (diff.length > 0) fail(`rehearsal ledger differs from production after restore:\n  ${diff.join("\n  ")}`);
  pc.log(`ledger  rehearsal equals production (${prodDb.ledger().size} versions)`);
  pc.log(`backup  ${file}`);
  return file;
}

function runSqlTests(pc: PromoteCtx): void {
  const files = readdirSync(pc.testsDir).filter((f) => f.endsWith(".sql")).sort();
  if (files.length === 0) fail(`no SQL tests in ${pc.testsDir}`);
  for (const f of files) {
    const r = pc.tools.runSqlFile(pc.rehearsal, join(pc.testsDir, f));
    for (const line of r.output) pc.log(`[tests] ${line}`);
    if (r.status !== 0) fail(`SQL test ${f} exited ${r.status} on ${CONFIG.rehearsal.database}`);
    pc.log(`[tests] pass ${f}`);
  }
}

// Steps 1–7 of the promote flow (README). Stops at the first failure. Refusals in steps 1–2 record nothing; after
// step 2 every failure is recorded as a fail outcome gate (outcome=not_applied before step 6, outcome=apply_failed
// with the applied and failed versions in step 6) unless dryRun (a dry run records nothing and never applies to
// production). A failure to record the pass gate after a clean apply records no fail gate: the planner reconciles.
export function promote(pc: PromoteCtx, dispatchId: string, dryRun: boolean): number {
  const APPLY = CONFIG.gates.apply;
  const prodLog = prefixed(pc.log, "[production]");
  const rehLog = prefixed(pc.log, "[rehearsal]");

  // 1. production status
  pc.log("step 1  production status");
  const prodDb = pc.connect(pc.prod);
  const prodCtx: Ctx = { dir: pc.dir, db: prodDb, log: prodLog };
  const migrations = discover(prodCtx);
  const before = currentPlan(prodCtx, migrations);
  for (const e of before) prodLog(describe(e));
  const set: VersionSum[] = promoteSet(before).map((version) => ({
    version,
    checksum: sha256(migrations.find((m) => m.version === version)!),
  }));
  const versions = set.map((p) => p.version);
  for (const p of set) pc.log(`promote ${p.version} ${p.checksum}${dryRun ? " (dry run)" : ""}`);

  // 2. approval
  pc.log("step 2  approval");
  const approval = checkApproval(dispatchId, pc.tools.approval(pc.prod, dispatchId), set);
  if ("refusal" in approval) fail(`refusing to promote: ${approval.refusal}`);
  const { approvedAt } = approval;
  pc.log(`approved ${CONFIG.gates.approval} for dispatch ${dispatchId} at ${approvedAt} (set of ${set.length} matches)`);

  let step = "3 refresh-rehearsal";
  let phase: "before-apply" | "apply" | "record" = "before-apply";
  let dump = "(none)";
  let prodSnapshot: Ledger = new Map();
  const reason = () => `versions=${formatSet(set)} approved_at=${approvedAt} dump=${dump} step=${step}`;
  try {
    // 3. fresh production dump (the backup) restored into rehearsal
    pc.log(`step ${step}`);
    dump = refreshRehearsal(pc, versions.at(-1));

    // 4. rehearse the whole set
    step = "4 rehearsal apply";
    pc.log(`step ${step}`);
    const rehDb = pc.connect(pc.rehearsal);
    apply({ dir: pc.dir, db: rehDb, log: rehLog });
    const rehLedger = rehDb.ledger();
    for (const p of set) {
      const rehSum = rehLedger.get(p.version);
      if (rehSum !== p.checksum) fail(`rehearsal checksum for ${p.version} is ${rehSum || "(none)"}, file is ${p.checksum}`);
    }
    const rehLeft = currentPlan({ dir: pc.dir, db: rehDb, log: rehLog }, migrations).filter((e) => e.state !== "ok");
    if (rehLeft.length > 0) fail(`rehearsal not clean after apply: ${rehLeft.map(describe).join("; ")}`);

    // 5. full SQL suite on the refreshed rehearsal
    step = "5 sql tests";
    pc.log(`step ${step}`);
    runSqlTests(pc);

    if (dryRun) {
      pc.log(`dry run: production not applied, no gate recorded; ${versions.join(", ")} rehearsed and tested, backup ${dump}`);
      return 0;
    }

    // 6. production apply of the set (files own their transactions; stops at the first failing file)
    step = "6 production apply";
    pc.log(`step ${step}`);
    prodSnapshot = prodDb.ledger();
    phase = "apply";
    apply(prodCtx);
    const after = currentPlan(prodCtx, migrations);
    for (const e of after) prodLog(describe(e));
    const left = after.filter((e) => e.state !== "ok");
    if (left.length > 0) fail(`production not clean after apply: ${left.map(describe).join("; ")}`);
    const prodLedger = prodDb.ledger();
    for (const p of set) {
      const prodSum = prodLedger.get(p.version);
      const rehSum = rehLedger.get(p.version);
      if (prodSum !== rehSum) fail(`production checksum for ${p.version} is ${prodSum || "(none)"}, rehearsal is ${rehSum}`);
    }

    // 7. outcome gate
    step = "7 record gate (production applied)";
    phase = "record";
    pc.tools.recordGate(executorTarget(pc.prod), { key: APPLY, result: "pass", dispatchId, reason: reason() });
    pc.log(`gate    ${APPLY} pass recorded for dispatch ${dispatchId}`);
    pc.log(`promoted ${formatSet(set)}; backup ${dump}`);
    return 0;
  } catch (e) {
    const msg = errorText(e);
    if (phase === "record") {
      fail(
        `promote stopped at step ${step}: production holds the whole set (${versions.join(", ")}) but the ${APPLY} gate ` +
          `is not recorded; the planner must reconcile. Gate error: ${msg}; backup ${dump}`,
      );
    }
    let gateNote = "";
    if (!dryRun) {
      let outcome = "outcome=not_applied";
      if (phase === "apply") {
        let appliedText = "unknown";
        let failed = "unknown";
        try {
          const now = prodDb.ledger();
          const applied = versions.filter((v) => now.has(v) && !prodSnapshot.has(v));
          appliedText = applied.length > 0 ? applied.join(",") : "none";
          failed = versions.find((v) => !applied.includes(v)) ?? "none";
        } catch {
          // The ledger could not be re-read: applied and failed stay unknown; the original error stays the message.
        }
        outcome = `outcome=apply_failed applied=${appliedText} failed=${failed}`;
      }
      try {
        pc.tools.recordGate(executorTarget(pc.prod), {
          key: APPLY,
          result: "fail",
          dispatchId,
          reason: `${reason()} ${outcome} error=${msg.split(/\r?\n/)[0].slice(0, 300)}`,
        });
        gateNote = `; gate ${APPLY} fail recorded (${outcome})`;
      } catch (g) {
        gateNote = `; recording gate ${APPLY} fail also failed: ${errorText(g)}`;
      }
    }
    fail(`promote stopped at step ${step}: ${msg}${gateNote}; backup ${dump}`);
  }
}

// ── psql-backed Db (only constructed by main)

// libpq connection variables cleared from the inherited environment before every client call, so only
// the target's own URL decides where a client connects. PGPASSFILE, PGSSLMODE and PGPASSWORD are not cleared.
export const INHERITED_PG_VARS = ["PGHOST", "PGHOSTADDR", "PGPORT", "PGUSER", "PGDATABASE", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS"] as const;

// Pass the connection through libpq env vars so the password never appears in argv.
export function pgEnv(t: Target, base: Record<string, string | undefined> = process.env): NodeJS.ProcessEnv {
  const u = new URL(t.url);
  const env: NodeJS.ProcessEnv = { ...base };
  for (const k of INHERITED_PG_VARS) delete env[k];
  if (u.hostname) env.PGHOST = u.hostname;
  if (u.port) env.PGPORT = u.port;
  if (u.username) env.PGUSER = decodeURIComponent(u.username);
  if (u.password) env.PGPASSWORD = decodeURIComponent(u.password);
  const db = decodeURIComponent(u.pathname.replace(/^\//, ""));
  if (db) env.PGDATABASE = db;
  for (const [k, v] of u.searchParams) {
    if (k === "sslmode") env.PGSSLMODE = v;
  }
  return env;
}

const PSQL_PATH = process.env.PSQL ?? "C:\\Program Files\\PostgreSQL\\18\\bin\\psql.exe";
const PG_DUMP_PATH = process.env.PG_DUMP ?? join(dirname(PSQL_PATH), "pg_dump.exe");
const PG_RESTORE_PATH = process.env.PG_RESTORE ?? join(dirname(PSQL_PATH), "pg_restore.exe");

const lines = (s: string) => s.split(/\r?\n/).filter((l) => l !== "");

// Runs a PostgreSQL client binary against t. Throws MigrateError on a spawn error, and on a
// non-zero exit unless allowFail.
function pgRun(bin: string, t: Target, args: string[], opts: { input?: string; allowFail?: boolean } = {}) {
  const r = spawnSync(bin, args, { env: pgEnv(t), input: opts.input, encoding: "utf8" });
  if (r.error) fail(`could not run ${bin}: ${r.error.message}`);
  if (r.status !== 0 && !opts.allowFail) fail(`${bin} exited ${r.status}\n${r.stderr.trim()}`);
  return { status: r.status ?? 1, stdout: r.stdout, stderr: r.stderr };
}

function psqlClient(t: Target) {
  const psql = (args: string[], input?: string) => pgRun(PSQL_PATH, t, ["-X", "-q", "-v", "ON_ERROR_STOP=1", ...args], { input });

  // Runs SQL from stdin so psql :'var' interpolation works (it does not with -c).
  function query(sql: string, vars: Record<string, string> = {}): string[] {
    const varArgs = Object.entries(vars).flatMap(([k, v]) => ["-v", `${k}=${v}`]);
    return lines(psql(["-At", ...varArgs, "-f", "-"], sql).stdout);
  }
  return { psql, query };
}

function psqlDb(t: Target): Db {
  const { psql, query } = psqlClient(t);

  const db: Db = {
    ledgerExists: () => query("SELECT to_regclass('ops.schema_migrations') IS NOT NULL;")[0] === "t",
    checksumColumnExists: () =>
      query(
        "SELECT count(*) FROM information_schema.columns " +
          "WHERE table_schema = 'ops' AND table_name = 'schema_migrations' AND column_name = 'checksum';",
      )[0] === "1",
    ledger: () => {
      if (!db.ledgerExists()) return new Map();
      const sql = db.checksumColumnExists()
        ? "SELECT version || '|' || coalesce(checksum, '') FROM ops.schema_migrations;"
        : "SELECT version || '|' FROM ops.schema_migrations;";
      return new Map(query(sql).map((l) => l.split("|") as [string, string]));
    },
    runFile: (path) => lines(psql(["-f", path]).stderr),
    setChecksum: (version, hash) =>
      query("UPDATE ops.schema_migrations SET checksum = :'c' WHERE version = :'v' RETURNING version;", {
        v: version,
        c: hash,
      }).length,
    insertBaseline: (version, hash) =>
      void query(
        "BEGIN;\nINSERT INTO ops.schema_migrations (version, checksum) VALUES (:'v', :'c');\nCOMMIT;",
        { v: version, c: hash },
      ),
  };
  return db;
}

const UTC_TEXT = `'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'`;

export function pgTools(): Tools {
  return {
    dump: (t, file) => void pgRun(PG_DUMP_PATH, t, ["-w", "-Fc", "--file", file]),
    fileSize: (file) => (existsSync(file) ? statSync(file).size : null),
    resetRehearsal: (t) =>
      void psqlClient(t).psql(["-1", "-f", "-"], [
        "DO $$ BEGIN",
        `  IF current_database() <> '${CONFIG.rehearsal.database}' OR session_user <> '${CONFIG.rehearsal.user}' THEN`,
        "    RAISE EXCEPTION 'reset refused: % as %', current_database(), session_user;",
        "  END IF;",
        "END $$;",
        "DROP SCHEMA IF EXISTS ops CASCADE;",
        "DROP EXTENSION IF EXISTS ltree, pg_trgm;",
      ].join("\n")),
    restore: (t, file) =>
      void pgRun(PG_RESTORE_PATH, t, ["-w", "--no-owner", "--single-transaction", "--exit-on-error", "-d", t.database!, file]),
    runSqlFile: (t, path) => {
      const r = pgRun(PSQL_PATH, t, ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", path], { allowFail: true });
      return { status: r.status, output: [...lines(r.stdout), ...lines(r.stderr)] };
    },
    approval: (t, dispatchId) => {
      const { query } = psqlClient(t);
      const d = query(
        `SELECT id || '|' || dispatch_type || '|' || to_char(created_at AT TIME ZONE 'UTC', ${UTC_TEXT}) || '|' ||` +
          ` coalesce(to_char(completed_at AT TIME ZONE 'UTC', ${UTC_TEXT}), '') FROM ops.dispatches WHERE id = :'id';`,
        { id: dispatchId },
      );
      // Every outcome gate row for the dispatch, pass or fail: any one means promote has run.
      const applyGates = query("SELECT count(*) FROM ops.gate_events WHERE gate_key = :'k' AND dispatch_id = :'id';", {
        id: dispatchId,
        k: CONFIG.gates.apply,
      });
      // reason is hex-encoded so '|' and newlines in it cannot break the row format; NULL stays empty.
      const gates = query(
        `SELECT id || '|' || dispatch_id || '|' || gate_key || '|' || result || '|' || overridden || '|' ||` +
          ` to_char(at AT TIME ZONE 'UTC', ${UTC_TEXT}) || '|' || (reason IS NULL) || '|' ||` +
          ` coalesce(encode(convert_to(reason, 'UTF8'), 'hex'), '')` +
          ` FROM ops.gate_events WHERE gate_key = :'k' AND dispatch_id = :'id' ORDER BY at, id;`,
        { id: dispatchId, k: CONFIG.gates.approval },
      );
      return {
        dispatch:
          d.length === 0
            ? null
            : (([id, dispatchType, createdAt, c]) => ({ id, dispatchType, createdAt, completedAt: c || null }))(d[0].split("|")),
        applyGateCount: Number(applyGates[0]),
        gates: gates.map((l) => {
          const [id, gDispatch, gateKey, result, overridden, at, reasonNull, reasonHex] = l.split("|");
          const reason = reasonNull === "true" ? null : Buffer.from(reasonHex, "hex").toString("utf8");
          return { id, dispatchId: gDispatch, gateKey, result, overridden: overridden === "true", at, reason };
        }),
      };
    },
    recordGate: (t, g) =>
      void psqlClient(t).query(
        "SELECT ops.record_gate(:'k', :'r'::ops.gate_result, :'d'::uuid, NULL, false, NULL, :'reason');",
        { k: g.key, r: g.result, d: g.dispatchId, reason: g.reason.replace(/\s+/g, " ") },
      ),
  };
}

// Everything main touches outside this module; tests pass fakes.
export type Io = {
  dir: string;
  testsDir: string;
  tmpDir: string;
  now: () => Date;
  env: Record<string, string | undefined>;
  // .env contents, or null if there is none. Called only when the shell DATABASE_URL is empty.
  readDotenv: () => string | null;
  connect: (t: Target) => Db;
  tools: Tools;
  log: (line: string) => void;
  error: (line: string) => void;
};

function processIo(): Io {
  return {
    dir: MIGRATIONS_DIR,
    testsDir: TESTS_DIR,
    tmpDir: tmpdir(),
    now: () => new Date(),
    env: process.env,
    readDotenv: () => {
      const envFile = `${ROOT}/.env`;
      return existsSync(envFile) ? readFileSync(envFile, "utf8") : null;
    },
    connect: psqlDb,
    tools: pgTools(),
    log: console.log,
    error: console.error,
  };
}

const COMMANDS: ReadonlySet<string> = new Set(["status", "apply", "adopt", "baseline", "refresh-rehearsal", "promote"]);

// promote <dispatch_id> [--dry-run]
export function promoteArgs(args: string[]): { dispatchId: string; dryRun: boolean } {
  const dryRun = args.includes("--dry-run");
  const rest = args.filter((a) => a !== "--dry-run");
  if (rest.length !== 1 || args.length - rest.length > 1) fail(`promote takes one dispatch id and optionally --dry-run\n${PROMOTE_HELP}`);
  if (!UUID_RE.test(rest[0])) fail(`'${rest[0]}' is not a dispatch id (lowercase uuid)\n${PROMOTE_HELP}`);
  return { dispatchId: rest[0], dryRun };
}

export function main(argv: string[], io: Io = processIo()): number {
  const [cmd, ...args] = argv;
  try {
    // Validate arguments before touching .env or the database.
    if (cmd === undefined || !COMMANDS.has(cmd)) fail(USAGE);
    if (cmd === "promote" && args.length === 1 && args[0] === "--help") {
      io.log(PROMOTE_HELP);
      return 0;
    }
    const version = cmd === "baseline" ? baselineVersion(args) : undefined;
    const promoteOpts = cmd === "promote" ? promoteArgs(args) : undefined;
    if (cmd !== "baseline" && cmd !== "promote" && args.length > 0) fail(USAGE);

    // Echo the target, then check it is explicit, not production for the plain commands, and
    // MIGRATE_EXPECT_DB, all before connecting.
    const target = resolveTarget(io.env, io.env.DATABASE_URL ? null : io.readDotenv());
    io.log(describeTarget(target));
    const refusal =
      incompleteTarget(target) ?? productionRefusal(cmd, target) ?? expectRefusal(cmd, target, io.env.MIGRATE_EXPECT_DB);
    if (refusal) fail(`refusing to ${cmd}: ${refusal}`);

    if (cmd === "refresh-rehearsal" || cmd === "promote") {
      const rehearsal = resolveTarget({ DATABASE_URL: REHEARSAL_URL }, null);
      io.log(`rehearsal ${targetText(rehearsal)}`);
      const r = rehearsalRefusal(target, rehearsal, io.env);
      if (r) fail(`refusing to ${cmd}: ${r}`);
      const pc: PromoteCtx = {
        dir: io.dir,
        testsDir: io.testsDir,
        tmpDir: io.tmpDir,
        now: io.now,
        prod: target,
        rehearsal,
        connect: io.connect,
        tools: io.tools,
        log: io.log,
      };
      if (cmd === "refresh-rehearsal") {
        refreshRehearsal(pc);
        return 0;
      }
      return promote(pc, promoteOpts!.dispatchId, promoteOpts!.dryRun);
    }

    const ctx: Ctx = { dir: io.dir, db: io.connect(target), log: io.log };
    switch (cmd) {
      case "status": return status(ctx);
      case "apply": return apply(ctx);
      case "adopt": return adopt(ctx);
      default: return baseline(ctx, version!);
    }
  } catch (e) {
    if (!(e instanceof MigrateError)) throw e;
    io.error(`migrate: ${e.message}`);
    return 1;
  }
}

// ── Entry point

// True when this file is the entry point but the runtime has no import.meta.main
// (Node outside package.json engines). The main() guard below would then be skipped
// and the process would exit 0 having run nothing.
export function unsupportedEntry(isMain: boolean | undefined, entry: string | undefined, self: string): boolean {
  if (isMain !== undefined || entry === undefined) return false;
  const norm = (p: string) => (process.platform === "win32" ? resolve(p).toLowerCase() : resolve(p));
  return norm(entry) === norm(self);
}

function enginesRange(): string {
  try {
    const pkg = JSON.parse(readFileSync(fileURLToPath(new URL("../package.json", import.meta.url)), "utf8"));
    return pkg.engines?.node ?? "unknown";
  } catch {
    return "see package.json engines";
  }
}

if (import.meta.main) {
  process.exitCode = main(process.argv.slice(2));
} else if (unsupportedEntry(import.meta.main, process.argv[1], fileURLToPath(import.meta.url))) {
  console.error(
    `migrate: Node ${process.version} has no import.meta.main, so no command can run; ` +
      `supported Node: ${enginesRange()} (package.json engines)`,
  );
  process.exitCode = 1;
}
