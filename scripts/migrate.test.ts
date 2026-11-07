// Tests for scripts/migrate.ts. No database: commands run against a fake Db and
// fixture migration files in a temp dir.
//
//   node --test scripts/

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  type Approval,
  type Ctx,
  type GateRecord,
  type PromoteCtx,
  type Db,
  type Entry,
  type Io,
  type Ledger,
  type Target,
  type Tools,
  CONFIG,
  GUARDED_COMMANDS,
  INHERITED_PG_VARS,
  MigrateError,
  PLAIN_COMMANDS,
  REHEARSAL_URL,
  apply,
  checkApproval,
  formatSet,
  incompleteTarget,
  parseApprovalSet,
  pgEnv,
  productionRefusal,
  setDiff,
  dumpPath,
  executorTarget,
  ledgerDiff,
  promote,
  promoteArgs,
  promoteSet,
  refreshRehearsal,
  rehearsalRefusal,
  applyBlockers,
  baseline,
  baselineRefusal,
  baselineVersion,
  checksum,
  describeTarget,
  expectRefusal,
  main,
  parseFiles,
  plan,
  resolveTarget,
  status,
  statusProblems,
  unsupportedEntry,
} from "./migrate.ts";

const sum = (s: string) => checksum(Buffer.from(s));

// ── Fixtures

const FILES: Record<string, string> = {
  "0000_roles.sql": "-- operator-run\n",
  "0001_a.sql": "-- a\n",
  "0002_b.sql": "-- b\n",
  "0003_c.sql": "-- c\n",
};

function fixtureDir(files: Record<string, string> = FILES): string {
  const dir = mkdtempSync(join(tmpdir(), "migrate-test-"));
  for (const [name, body] of Object.entries(files)) writeFileSync(join(dir, name), body);
  return dir;
}

type FakeDb = Db & { ran: string[]; inserted: [string, string][]; rows: Ledger };

// In-memory ledger. runFile registers the version the way a contract-following file does,
// and returns opts.notices as the server messages it printed.
function fakeDb(rows: Ledger, opts: { registerOnRun?: boolean; notices?: string[] } = {}): FakeDb {
  const db: FakeDb = {
    rows,
    ran: [],
    inserted: [],
    ledgerExists: () => true,
    checksumColumnExists: () => true,
    ledger: () => new Map(db.rows),
    runFile: (path) => {
      db.ran.push(path);
      const version = path.split("/").pop()!.replace(/\.sql$/, "");
      if (opts.registerOnRun !== false) db.rows.set(version, "");
      return opts.notices ?? [];
    },
    setChecksum: (version, hash) => {
      if (!db.rows.has(version)) return 0;
      db.rows.set(version, hash);
      return 1;
    },
    insertBaseline: (version, hash) => {
      db.inserted.push([version, hash]);
      db.rows.set(version, hash);
    },
  };
  return db;
}

function ctx(dir: string, db: Db): Ctx & { lines: string[] } {
  const lines: string[] = [];
  return { dir, db, log: (l) => lines.push(l), lines };
}

function withDir<T>(fn: (dir: string) => T, files?: Record<string, string>): T {
  const dir = fixtureDir(files);
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// ── Pure functions

test("checksum is SHA-256 of raw bytes, lowercase hex", () => {
  assert.equal(checksum(Buffer.from("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

test("parseFiles sorts, skips 0000_*, ignores non-.sql, derives version from FILE_RE", () => {
  const r = parseFiles(["0002_b.sql", "README.md", "0000_roles.sql", "0001_a.sql"]);
  assert.deepEqual(r.skipped, ["0000_roles.sql"]);
  assert.deepEqual(r.migrations, [
    { version: "0001_a", file: "0001_a.sql" },
    { version: "0002_b", file: "0002_b.sql" },
  ]);
});

test("parseFiles rejects filenames outside FILE_RE", () => {
  assert.throws(() => parseFiles(["0001-Bad.sql"]), MigrateError);
});

test("plan: every state", () => {
  const files = [
    { version: "0001_ok", checksum: "a".repeat(64) },
    { version: "0002_drift", checksum: "b".repeat(64) },
    { version: "0003_nosum", checksum: "c".repeat(64) },
    { version: "0005_pending", checksum: "d".repeat(64) },
  ];
  const ledger: Ledger = new Map([
    ["0001_ok", "a".repeat(64)],
    ["0002_drift", "f".repeat(64)],
    ["0003_nosum", ""],
    ["0004_orphan", "e".repeat(64)],
  ]);
  assert.deepEqual(plan(files, ledger), [
    { version: "0001_ok", state: "ok", checksum: "a".repeat(64) },
    { version: "0002_drift", state: "drift", ledger: "f".repeat(64), file: "b".repeat(64) },
    { version: "0003_nosum", state: "no-checksum" },
    { version: "0004_orphan", state: "orphan" },
    { version: "0005_pending", state: "pending" },
  ]);
});

test("plan: empty ledger is all pending", () => {
  assert.deepEqual(plan([{ version: "0001_a", checksum: "a".repeat(64) }], new Map()), [
    { version: "0001_a", state: "pending" },
  ]);
});

test("applyBlockers: drift and orphan only", () => {
  const entries: Entry[] = [
    { version: "1", state: "ok", checksum: "x" },
    { version: "2", state: "pending" },
    { version: "3", state: "no-checksum" },
    { version: "4", state: "drift", ledger: "x", file: "y" },
    { version: "5", state: "orphan" },
  ];
  assert.deepEqual(applyBlockers(entries).map((e) => e.version), ["4", "5"]);
  assert.deepEqual(statusProblems(entries).map((e) => e.version), ["3", "4", "5"]);
});

// ── baseline guards

test("baselineVersion: exactly one explicit version", () => {
  assert.equal(baselineVersion(["0004_secret_handling_incidents"]), "0004_secret_handling_incidents");
  assert.throws(() => baselineVersion([]), MigrateError);
  assert.throws(() => baselineVersion(["0001_a", "0002_b"]), MigrateError);
  assert.throws(() => baselineVersion(["all"]), MigrateError);
  assert.throws(() => baselineVersion(["*"]), MigrateError);
  assert.throws(() => baselineVersion(["0004_*"]), MigrateError);
  assert.throws(() => baselineVersion(["0004_x.sql"]), MigrateError);
  assert.throws(() => baselineVersion(["0000_roles"]), MigrateError);
});

test("baselineRefusal: missing file", () => {
  const entries: Entry[] = [{ version: "0001_a", state: "ok", checksum: "x" }];
  assert.match(baselineRefusal("0009_missing", entries)!, /no migration file/);
  assert.match(baselineRefusal("0002_gone", [...entries, { version: "0002_gone", state: "orphan" }])!, /no migration file/);
});

test("baselineRefusal: ledger row already exists", () => {
  for (const e of [
    { version: "0001_a", state: "ok", checksum: "x" },
    { version: "0001_a", state: "no-checksum" },
    { version: "0001_a", state: "drift", ledger: "x", file: "y" },
  ] as Entry[]) {
    assert.match(baselineRefusal("0001_a", [e])!, /already exists/);
  }
});

test("baselineRefusal: earlier version pending", () => {
  const entries: Entry[] = [
    { version: "0001_a", state: "ok", checksum: "x" },
    { version: "0002_b", state: "pending" },
    { version: "0003_c", state: "pending" },
  ];
  assert.match(baselineRefusal("0003_c", entries)!, /earlier version\(s\) pending: 0002_b/);
  assert.equal(baselineRefusal("0002_b", entries), null);
});

test("baseline command: refusals write nothing", () =>
  withDir((dir) => {
    const cases: [string, Ledger][] = [
      ["0009_missing", new Map([["0001_a", sum("-- a\n")]])],
      ["0001_a", new Map([["0001_a", sum("-- a\n")]])],
      ["0003_c", new Map([["0001_a", sum("-- a\n")]])],
    ];
    for (const [version, rows] of cases) {
      const db = fakeDb(rows);
      assert.throws(() => baseline(ctx(dir, db), version), MigrateError);
      assert.deepEqual(db.inserted, []);
      assert.deepEqual(db.ran, []);
    }
  }));

test("baseline command: refuses without checksum column", () =>
  withDir((dir) => {
    const db = fakeDb(new Map());
    db.checksumColumnExists = () => false;
    assert.throws(() => baseline(ctx(dir, db), "0001_a"), /checksum does not exist/);
    assert.deepEqual(db.inserted, []);
  }));

test("baseline command: records version + file checksum without running the file", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", sum("-- a\n")]]));
    const c = ctx(dir, db);
    assert.equal(baseline(c, "0002_b"), 0);
    assert.deepEqual(db.inserted, [["0002_b", sum("-- b\n")]]);
    assert.deepEqual(db.ran, []);
    assert.ok(c.lines.includes(`baseline 0002_b ${sum("-- b\n")}`));
  }));

// ── apply

test("apply refuses on drift and runs nothing", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", "0".repeat(64)]]));
    const c = ctx(dir, db);
    assert.throws(() => apply(c), /refusing to apply/);
    assert.deepEqual(db.ran, []);
    assert.ok(c.lines.some((l) => l.startsWith("DRIFT") && l.includes("0001_a")));
  }));

test("apply refuses on orphan and runs nothing", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", sum("-- a\n")], ["0009_gone", "e".repeat(64)]]));
    assert.throws(() => apply(ctx(dir, db)), /refusing to apply/);
    assert.deepEqual(db.ran, []);
  }));

test("apply passing case: runs pending in order, writes checksums, skips 0000_*", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", sum("-- a\n")]]));
    const c = ctx(dir, db);
    assert.equal(apply(c), 0);
    assert.deepEqual(db.ran, [`${dir}/0002_b.sql`, `${dir}/0003_c.sql`]);
    assert.equal(db.rows.get("0002_b"), sum("-- b\n"));
    assert.equal(db.rows.get("0003_c"), sum("-- c\n"));
    assert.ok(c.lines.includes("skip    0000_roles.sql (operator-run)"));
    assert.ok(c.lines.includes("ok      0001_a (already applied)"));
    assert.equal(c.lines.at(-1), "applied 2 migration(s)");
  }));

test("apply does not block on no-checksum rows", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", ""], ["0002_b", ""], ["0003_c", ""]]));
    const c = ctx(dir, db);
    assert.equal(apply(c), 0);
    assert.equal(c.lines.at(-1), "nothing to apply");
  }));

test("apply stops when a file does not register its ledger row", () =>
  withDir((dir) => {
    const db = fakeDb(new Map(), { registerOnRun: false });
    assert.throws(() => apply(ctx(dir, db)), /did not insert its ledger row '0001_a'/);
    assert.deepEqual(db.ran, [`${dir}/0001_a.sql`]);
  }));

// ── status

test("status: clean ledger exits 0, pending does not fail", () =>
  withDir((dir) => {
    const db = fakeDb(new Map([["0001_a", sum("-- a\n")], ["0002_b", sum("-- b\n")]]));
    const c = ctx(dir, db);
    assert.equal(status(c), 0);
    assert.equal(c.lines.at(-1), "summary: 2 ok, 1 pending");
    assert.deepEqual(db.ran, []);
    assert.deepEqual(db.inserted, []);
  }));

test("status: drift, orphan or no-checksum exits non-zero and writes nothing", () =>
  withDir((dir) => {
    for (const rows of [
      new Map([["0001_a", "0".repeat(64)]]),
      new Map([["0001_a", sum("-- a\n")], ["0009_gone", "e".repeat(64)]]),
      new Map([["0001_a", ""]]),
    ]) {
      const db = fakeDb(rows);
      const before = new Map(db.rows);
      assert.equal(status(ctx(dir, db)), 1);
      assert.deepEqual(db.rows, before);
      assert.deepEqual(db.ran, []);
    }
  }));

// ── target resolution

const REHEARSAL = "postgresql://ops_dev@localhost:5432/local_ops_rehearsal";
const PROD_DOTENV = "# comment\nDATABASE_URL=postgresql://local_ops:s3cret@localhost:5432/local_ops\n";

test("resolveTarget: non-empty shell DATABASE_URL wins over .env", () => {
  const t = resolveTarget({ DATABASE_URL: REHEARSAL }, PROD_DOTENV);
  assert.deepEqual(t, {
    url: REHEARSAL,
    user: "ops_dev",
    host: "localhost",
    port: "5432",
    database: "local_ops_rehearsal",
    source: "shell",
  });
});

test("resolveTarget: empty or unset shell DATABASE_URL falls back to .env", () => {
  for (const env of [{}, { DATABASE_URL: "" }]) {
    const t = resolveTarget(env, PROD_DOTENV);
    assert.equal(t.source, ".env");
    assert.equal(t.database, "local_ops");
    assert.equal(t.user, "local_ops");
  }
});

test("resolveTarget: first .env line wins; one layer of matching quotes removed", () => {
  const u = "postgresql://a@h:1/d1";
  assert.equal(resolveTarget({}, `DATABASE_URL="${u}"\nDATABASE_URL=postgresql://b@h/d2`).url, u);
  assert.equal(resolveTarget({}, `  DATABASE_URL = '${u}'  \r\n`).url, u);
  assert.throws(() => resolveTarget({}, `DATABASE_URL="${u}'`), /not a valid URL/);
});

test("resolveTarget: missing in shell and .env is an error", () => {
  assert.throws(() => resolveTarget({}, null), /DATABASE_URL not set and not found in \.env/);
  assert.throws(() => resolveTarget({ DATABASE_URL: "" }, "OTHER=1\n"), /DATABASE_URL not set/);
});

test("resolveTarget: an invalid URL error does not echo the value", () => {
  assert.throws(
    () => resolveTarget({ DATABASE_URL: "not a url s3cret" }, null),
    (e: Error) => e instanceof MigrateError && !e.message.includes("s3cret"),
  );
});

test("describeTarget: one line, defaults marked, no password or URL", () => {
  const t = resolveTarget({}, PROD_DOTENV);
  const line = describeTarget(t);
  assert.equal(line, "target  local_ops@localhost:5432/local_ops  (from .env)");
  assert.ok(!line.includes("s3cret"));
  assert.ok(!line.includes("postgresql://"));
  assert.equal(
    describeTarget(resolveTarget({ DATABASE_URL: "postgresql://" }, null)),
    "target  (default)@(default):(default)/(default)  (from shell)",
  );
});

// ── expected-database guard

const target = (database: string | null): Target => ({
  url: "postgresql://u@h:1/x",
  user: "u",
  host: "h",
  port: "1",
  database,
  source: "shell",
});

test("expectRefusal: writing commands need MIGRATE_EXPECT_DB equal to the target database", () => {
  assert.deepEqual([...GUARDED_COMMANDS].sort(), ["adopt", "apply", "baseline"]);
  for (const cmd of GUARDED_COMMANDS) {
    assert.match(expectRefusal(cmd, target("local_ops"), undefined)!, /requires MIGRATE_EXPECT_DB.*u@h:1\/local_ops/);
    assert.match(expectRefusal(cmd, target("local_ops"), "")!, /requires MIGRATE_EXPECT_DB/);
    assert.match(
      expectRefusal(cmd, target("local_ops"), "local_ops_rehearsal")!,
      /MIGRATE_EXPECT_DB=local_ops_rehearsal does not match .*u@h:1\/local_ops /,
    );
    assert.match(expectRefusal(cmd, target(null), "local_ops")!, /does not match/);
    assert.equal(expectRefusal(cmd, target("local_ops"), "local_ops"), null);
  }
  assert.equal(expectRefusal("status", target("local_ops"), undefined), null);
});

// ── main: echo and guard run before any connection

const unusedTools: Tools = new Proxy({} as Tools, {
  get: (_, k) => () => assert.fail(`tool ${String(k)} called`),
});

type FakeIo = Io & { out: string[]; err: string[]; connects: number; dotenvReads: number; outAtConnect: number };

function fakeIo(dir: string, env: Record<string, string | undefined>, db: Db = fakeDb(new Map())): FakeIo {
  const io: FakeIo = {
    dir,
    testsDir: dir,
    tmpDir: tmpdir(),
    now: () => new Date(0),
    tools: unusedTools,
    env,
    out: [],
    err: [],
    connects: 0,
    dotenvReads: 0,
    outAtConnect: -1,
    readDotenv: () => {
      io.dotenvReads++;
      return PROD_DOTENV;
    },
    connect: () => {
      io.connects++;
      io.outAtConnect = io.out.length;
      return db;
    },
    log: (l) => io.out.push(l),
    error: (l) => io.err.push(l),
  };
  return io;
}

test("main: no command or a bad command prints usage without reading .env or connecting", () =>
  withDir((dir) => {
    for (const argv of [[], ["nope"], ["status", "extra"], ["baseline"]]) {
      const io = fakeIo(dir, {});
      assert.equal(main(argv, io), 1);
      assert.equal(io.dotenvReads, 0);
      assert.equal(io.connects, 0);
      assert.deepEqual(io.out, []);
    }
  }));

test("main: a shell DATABASE_URL means .env is never read", () =>
  withDir((dir) => {
    const io = fakeIo(dir, { DATABASE_URL: REHEARSAL });
    assert.equal(main(["status"], io), 0);
    assert.equal(io.dotenvReads, 0);
  }));

test("main: guarded commands refuse before connecting when MIGRATE_EXPECT_DB is unset or wrong", () =>
  withDir((dir) => {
    for (const [cmd, ...args] of [["apply"], ["adopt"], ["baseline", "0001_a"]]) {
      for (const expect of [undefined, "local_ops"]) {
        const io = fakeIo(dir, { DATABASE_URL: REHEARSAL, MIGRATE_EXPECT_DB: expect });
        assert.equal(main([cmd, ...args], io), 1, `${cmd} with MIGRATE_EXPECT_DB=${expect}`);
        assert.equal(io.connects, 0);
        assert.deepEqual(io.out, ["target  ops_dev@localhost:5432/local_ops_rehearsal  (from shell)"]);
        assert.match(io.err[0], new RegExp(`^migrate: refusing to ${cmd}: `));
        assert.match(io.err[0], /ops_dev@localhost:5432\/local_ops_rehearsal/);
        if (expect) assert.match(io.err[0], /MIGRATE_EXPECT_DB=local_ops does not match/);
      }
    }
  }));

test("main: guarded commands proceed when MIGRATE_EXPECT_DB matches, after the echo", () =>
  withDir((dir) => {
    for (const [cmd, ...args] of [["apply"], ["adopt"], ["baseline", "0001_a"]]) {
      const io = fakeIo(dir, { DATABASE_URL: REHEARSAL, MIGRATE_EXPECT_DB: "local_ops_rehearsal" });
      assert.equal(main([cmd, ...args], io), 0, cmd);
      assert.equal(io.connects, 1);
      assert.equal(io.outAtConnect, 1);
      assert.equal(io.out[0], "target  ops_dev@localhost:5432/local_ops_rehearsal  (from shell)");
      assert.deepEqual(io.err, []);
    }
  }));

const DISPATCH = "d2211977-9729-4262-971c-b1afe7dc5838";
const OTHER_DISPATCH = "0a4f3c2e-1111-4222-8333-944455556666";

test("main: status refuses production after echoing the target, before connecting, without the password", () =>
  withDir((dir) => {
    const io = fakeIo(dir, {});
    assert.equal(main(["status"], io), 1);
    assert.equal(io.dotenvReads, 1);
    assert.deepEqual(io.out, ["target  local_ops@localhost:5432/local_ops  (from .env)"]);
    assert.equal(io.connects, 0);
    assert.match(io.err[0], /^migrate: refusing to status: status refuses the production database local_ops/);
    assert.match(io.err[0], /only through refresh-rehearsal and promote/);
    assert.ok([...io.out, ...io.err].every((l) => !l.includes("s3cret")));
  }));

test("main: status on rehearsal proceeds after the echo", () =>
  withDir((dir) => {
    const io = fakeIo(dir, { DATABASE_URL: REHEARSAL });
    assert.equal(main(["status"], io), 0);
    assert.equal(io.out[0], "target  ops_dev@localhost:5432/local_ops_rehearsal  (from shell)");
    assert.equal(io.connects, 1);
    assert.equal(io.outAtConnect, 1);
    assert.deepEqual(io.err, []);
  }));

test("main: status, apply, adopt and baseline refuse the production database on any host, before connecting", () =>
  withDir((dir) => {
    const envs: Record<string, string | undefined>[] = [
      {},
      { MIGRATE_EXPECT_DB: "local_ops" },
      { DATABASE_URL: "postgresql://ops_dev@otherhost:5433/local_ops", MIGRATE_EXPECT_DB: "local_ops" },
    ];
    for (const [cmd, ...args] of [["status"], ["apply"], ["adopt"], ["baseline", "0001_a"]]) {
      for (const env of envs) {
        const io = fakeIo(dir, env);
        assert.equal(main([cmd, ...args], io), 1, `${cmd} ${JSON.stringify(env)}`);
        assert.equal(io.connects, 0);
        assert.equal(io.out.length, 1);
        assert.match(io.out[0], /^target  /);
        assert.match(io.err[0], new RegExp(`^migrate: refusing to ${cmd}: ${cmd} refuses the production database local_ops`));
        assert.match(io.err[0], /refresh-rehearsal and promote/);
      }
    }
  }));

test("productionRefusal: the four plain commands on the production database name only", () => {
  assert.deepEqual([...PLAIN_COMMANDS].sort(), ["adopt", "apply", "baseline", "status"]);
  for (const cmd of PLAIN_COMMANDS) {
    assert.match(productionRefusal(cmd, target("local_ops"))!, new RegExp(`^${cmd} refuses the production database local_ops \\(resolved u@h:1/local_ops`));
    assert.equal(productionRefusal(cmd, target("local_ops_rehearsal")), null);
    assert.equal(productionRefusal(cmd, target(null)), null);
  }
  assert.equal(productionRefusal("promote", target("local_ops")), null);
  assert.equal(productionRefusal("refresh-rehearsal", target("local_ops")), null);
});

test("incompleteTarget: user, host, port and database must be explicit", () => {
  const t = (url: string) => resolveTarget({ DATABASE_URL: url }, null);
  assert.equal(incompleteTarget(t(REHEARSAL)), null);
  assert.match(incompleteTarget(t("postgresql://localhost:5432/x"))!, /user missing/);
  assert.match(incompleteTarget({ ...t(REHEARSAL), host: null })!, /host missing in ops_dev@\(default\):5432\/local_ops_rehearsal/);
  assert.match(incompleteTarget(t("postgresql://u@localhost/x"))!, /port missing in u@localhost:\(default\)\/x/);
  assert.match(incompleteTarget(t("postgresql://u@localhost:5432"))!, /database missing/);
  assert.match(incompleteTarget(t("postgresql://"))!, /user, host, port, database missing/);
  assert.match(incompleteTarget(target(null))!, /must state user, host, port and database explicitly; database missing/);
});

test("main: an incomplete target refuses after the echo, before connecting, for every command", () =>
  withDir((dir) => {
    for (const [argv, url] of [
      [["status"], "postgresql://ops_dev@localhost/local_ops_rehearsal"],
      [["apply"], "postgresql://localhost:5432/local_ops_rehearsal"],
      [["promote", DISPATCH], "postgresql://local_ops@localhost/local_ops"],
      [["refresh-rehearsal"], "postgresql://local_ops@localhost/local_ops"],
    ] as [string[], string][]) {
      const io = fakeIo(dir, { DATABASE_URL: url, MIGRATE_EXPECT_DB: "local_ops_rehearsal" });
      assert.equal(main(argv, io), 1, argv[0]);
      assert.equal(io.connects, 0);
      assert.equal(io.out.length, 1);
      assert.match(io.err[0], new RegExp(`^migrate: refusing to ${argv[0]}: target must state user, host, port and database explicitly`));
    }
  }));

test("pgEnv: inherited libpq connection variables are cleared; PGPASSFILE, PGSSLMODE and PGPASSWORD kept as before", () => {
  const inherited: Record<string, string> = {
    PGHOST: "evil",
    PGHOSTADDR: "10.0.0.1",
    PGPORT: "6543",
    PGUSER: "postgres",
    PGDATABASE: "postgres",
    PGSERVICE: "prod",
    PGSERVICEFILE: "x.conf",
    PGOPTIONS: "-c role=postgres",
    PGPASSFILE: "C:\\pgpass.conf",
    PATH: "p",
  };
  assert.deepEqual([...INHERITED_PG_VARS].sort(), [
    "PGDATABASE", "PGHOST", "PGHOSTADDR", "PGOPTIONS", "PGPORT", "PGSERVICE", "PGSERVICEFILE", "PGUSER",
  ]);
  const env = pgEnv(resolveTarget({ DATABASE_URL: `${REHEARSAL}?sslmode=require` }, null), inherited);
  assert.equal(env.PGHOST, "localhost");
  assert.equal(env.PGPORT, "5432");
  assert.equal(env.PGUSER, "ops_dev");
  assert.equal(env.PGDATABASE, "local_ops_rehearsal");
  assert.equal(env.PGSSLMODE, "require");
  assert.equal(env.PGPASSFILE, "C:\\pgpass.conf");
  assert.equal(env.PATH, "p");
  for (const k of ["PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS"]) assert.equal(k in env, false, k);
  // A URL that leaves parts out never inherits them from the environment.
  const bare = pgEnv(resolveTarget({ DATABASE_URL: "postgresql://" }, null), inherited);
  for (const k of INHERITED_PG_VARS) assert.equal(k in bare, false, k);
  // PGPASSWORD: inherited unless the URL carries a password (unchanged behaviour).
  assert.equal(pgEnv(resolveTarget({ DATABASE_URL: REHEARSAL }, null), { PGPASSWORD: "x" }).PGPASSWORD, "x");
  assert.equal(pgEnv(resolveTarget({}, PROD_DOTENV), {}).PGPASSWORD, "s3cret");
});

test("CONFIG: one frozen source of the hard-coded names", () => {
  assert.ok(Object.isFrozen(CONFIG) && Object.isFrozen(CONFIG.production) && Object.isFrozen(CONFIG.rehearsal) && Object.isFrozen(CONFIG.gates));
  assert.deepEqual(CONFIG.production, { user: "local_ops", host: "localhost", port: "5432", database: "local_ops" });
  assert.deepEqual(CONFIG.rehearsal, { user: "ops_dev", host: "localhost", port: "5432", database: "local_ops_rehearsal" });
  assert.equal(CONFIG.executorUser, "ops_executor");
  assert.deepEqual(CONFIG.gates, { approval: "prod_apply_approved", apply: "prod_apply" });
  assert.equal(CONFIG.promoteDispatchType, "promote");
  assert.equal(REHEARSAL_URL, REHEARSAL);
});

// ── refresh-rehearsal and promote (fake Db per database and fake Tools; nothing touches a database)

const APPROVAL_GATE = CONFIG.gates.approval;
const APPLY_GATE = CONFIG.gates.apply;
const PROD = resolveTarget({}, PROD_DOTENV);
const REH = resolveTarget({ DATABASE_URL: REHEARSAL }, null);
const EARLIER = "2026-10-08T09:00:00.000000Z";
const CREATED = "2026-10-08T10:00:00.000000Z";
const LATER = "2026-10-08T10:00:00.000001Z";
const TESTS: Record<string, string> = { "0001_a.sql": "-- t a\n", "0003_c.sql": "-- t c\n", "notes.md": "" };

const A_SUM = sum("-- a\n");
const B_SUM = sum("-- b\n");
const C_SUM = sum("-- c\n");
const APPROVED_REASON = `versions=0003_c:${C_SUM}`;
const SET2_REASON = `versions=0002_b:${B_SUM},0003_c:${C_SUM}`;
const PENDING = [{ version: "0003_c", checksum: C_SUM }];

// An uncompleted promote dispatch created at CREATED with no outcome gate. Gate ids follow array order unless given.
const approved = (
  gates: Partial<Approval["gates"][number]>[] = [{}],
  dispatch: Partial<NonNullable<Approval["dispatch"]>> = {},
  applyGateCount = 0,
): Approval => ({
  dispatch: { id: DISPATCH, dispatchType: "promote", createdAt: CREATED, completedAt: null, ...dispatch },
  applyGateCount,
  gates: gates.map((g, i) => ({
    id: String(i + 1),
    dispatchId: DISPATCH,
    gateKey: APPROVAL_GATE,
    result: "pass",
    overridden: false,
    at: LATER,
    reason: APPROVED_REASON,
    ...g,
  })),
});

type World = { events: string[]; out: string[]; gates: GateRecord[]; prod: FakeDb; reh: FakeDb; pc: PromoteCtx };

type WorldOpts = {
  prodRows?: Ledger;
  approval?: Approval;
  dump?: "ok" | "throws" | "empty" | "missing";
  rehearsalChecksum?: string; // what the rehearsal ledger records instead of the file checksum
  prodChecksum?: string; // what the production ledger records instead of the file checksum
  prodFailOn?: string; // production file that fails (before registering its ledger row)
  testStatus?: Record<string, number>;
};

// Production holds 0001_a and 0002_b; 0003_c is pending. Restore copies the production ledger into rehearsal.
function withWorld(fn: (w: World) => void, o: WorldOpts = {}): void {
  withDir((dir) =>
    withDir((testsDir) => {
      const events: string[] = [];
      const out: string[] = [];
      const gates: GateRecord[] = [];
      const notices = ["psql:0003_c.sql:9: NOTICE:  n1"];
      const prod = fakeDb(o.prodRows ?? new Map([["0001_a", A_SUM], ["0002_b", B_SUM]]), { notices });
      const reh = fakeDb(new Map([["0001_a", "stale"]]), { notices });
      for (const [db, name] of [[prod, "production"], [reh, "rehearsal"]] as const) {
        const run = db.runFile;
        db.runFile = (path) => {
          const f = path.split("/").pop()!;
          events.push(`apply:${name}:${f}`);
          if (name === "production" && o.prodFailOn === f) throw new MigrateError(`psql exited 3\npsql:${f}:4: ERROR:  boom`);
          return run(path);
        };
      }
      for (const [db, forced] of [[reh, o.rehearsalChecksum], [prod, o.prodChecksum]] as const) {
        if (forced === undefined) continue;
        db.setChecksum = (v) => {
          db.rows.set(v, forced);
          return 1;
        };
      }
      const pc: PromoteCtx = {
        dir,
        testsDir,
        tmpDir: join(tmpdir(), "promote-test"),
        now: () => new Date("2026-10-08T13:45:07.123Z"),
        prod: PROD,
        rehearsal: REH,
        connect: (t) =>
          t.database === "local_ops" ? prod : t.database === "local_ops_rehearsal" ? reh : assert.fail(`connect ${t.database}`),
        log: (l) => out.push(l),
        tools: {
          approval: (t, id) => {
            assert.equal(t.database, "local_ops");
            events.push(`approval:${id}`);
            return o.approval ?? approved();
          },
          dump: (t, file) => {
            assert.equal(t.database, "local_ops");
            events.push(`dump:${file}`);
            if (o.dump === "throws") throw new MigrateError("pg_dump exited 1\nconnection refused");
          },
          fileSize: () => (o.dump === "empty" ? 0 : o.dump === "missing" ? null : 4096),
          resetRehearsal: (t) => {
            assert.equal(t.database, "local_ops_rehearsal");
            events.push("reset");
            reh.rows = new Map();
          },
          restore: (t) => {
            assert.equal(t.database, "local_ops_rehearsal");
            events.push("restore");
            reh.rows = new Map(prod.rows);
          },
          runSqlFile: (t, path) => {
            assert.equal(t.database, "local_ops_rehearsal");
            const f = path.split(/[\\/]/).pop()!;
            events.push(`test:${f}`);
            return { status: o.testStatus?.[f] ?? 0, output: [`NOTICE:  ok ${f}`] };
          },
          recordGate: (t, g) => {
            assert.equal(t.user, "ops_executor");
            assert.equal(t.database, "local_ops");
            events.push(`gate:${g.key}:${g.result}`);
            gates.push(g);
          },
        },
      };
      fn({ events, out, gates, prod, reh, pc });
    }, TESTS),
  );
}

const FULL_ORDER = [
  `approval:${DISPATCH}`,
  "dump",
  "reset",
  "restore",
  "apply:rehearsal:0003_c.sql",
  "test:0001_a.sql",
  "test:0003_c.sql",
  "apply:production:0003_c.sql",
  `gate:${APPLY_GATE}:pass`,
];
const FULL_ORDER2 = [
  `approval:${DISPATCH}`,
  "dump",
  "reset",
  "restore",
  "apply:rehearsal:0002_b.sql",
  "apply:rehearsal:0003_c.sql",
  "test:0001_a.sql",
  "test:0003_c.sql",
  "apply:production:0002_b.sql",
  "apply:production:0003_c.sql",
  `gate:${APPLY_GATE}:pass`,
];
const steps = (events: string[]) => events.map((e) => (e.startsWith("dump:") ? "dump" : e));
// Label = the newest version in the set (0003_c for both the one- and the two-version set).
const DUMP_FILE = join(tmpdir(), "promote-test", "local_ops_20261008T134507Z_pre_0003_c.dump");
// A fresh ledger per world: fakeDb mutates the Map it is given.
const onlyA = (): Ledger => new Map([["0001_a", A_SUM]]);

test("promote: passing case runs every step in order and records the pass gate", () =>
  withWorld((w) => {
    assert.equal(promote(w.pc, DISPATCH, false), 0);
    assert.deepEqual(steps(w.events), FULL_ORDER);
    assert.ok(w.events.includes(`dump:${DUMP_FILE}`));
    assert.equal(w.prod.rows.get("0003_c"), C_SUM);
    assert.equal(w.reh.rows.get("0003_c"), C_SUM);
    assert.equal(w.gates.length, 1);
    assert.equal(w.gates[0].dispatchId, DISPATCH);
    assert.equal(
      w.gates[0].reason,
      `versions=0003_c:${C_SUM} approved_at=${LATER} dump=${DUMP_FILE} step=7 record gate (production applied)`,
    );
    assert.ok(w.out.includes(`backup  ${DUMP_FILE}`));
  }));

test("promote: a two-migration set runs end to end, in order, and the gate lists both", () =>
  withWorld(
    (w) => {
      assert.equal(promote(w.pc, DISPATCH, false), 0);
      assert.deepEqual(steps(w.events), FULL_ORDER2);
      assert.ok(w.events.includes(`dump:${DUMP_FILE}`));
      assert.equal(w.prod.rows.get("0002_b"), B_SUM);
      assert.equal(w.prod.rows.get("0003_c"), C_SUM);
      assert.deepEqual(w.gates.map((g) => [g.key, g.result]), [[APPLY_GATE, "pass"]]);
      assert.equal(
        w.gates[0].reason,
        `versions=0002_b:${B_SUM},0003_c:${C_SUM} approved_at=${LATER} dump=${DUMP_FILE} step=7 record gate (production applied)`,
      );
      assert.ok(w.out.includes(`promote 0002_b ${B_SUM}`));
      assert.ok(w.out.includes(`promote 0003_c ${C_SUM}`));
    },
    { prodRows: onlyA(), approval: approved([{ reason: `operator approved ${SET2_REASON}` }]) },
  ));

test("promote: NOTICEs from both applies pass through with prefixes", () =>
  withWorld((w) => {
    promote(w.pc, DISPATCH, false);
    assert.ok(w.out.includes("[rehearsal] notice  psql:0003_c.sql:9: NOTICE:  n1"));
    assert.ok(w.out.includes("[production] notice  psql:0003_c.sql:9: NOTICE:  n1"));
    assert.ok(w.out.includes("[tests] NOTICE:  ok 0003_c.sql"));
  }));

test("promote --dry-run: rehearses and tests, never applies to production, records no gate", () =>
  withWorld((w) => {
    assert.equal(promote(w.pc, DISPATCH, true), 0);
    assert.deepEqual(steps(w.events), FULL_ORDER.slice(0, 7));
    assert.equal(w.prod.rows.has("0003_c"), false);
    assert.deepEqual(w.gates, []);
  }));

test("promote: approval refusals stop before the dump and record nothing", () => {
  const AT2 = "2026-10-08T11:00:00.000000Z";
  const other = sum("-- other\n");
  const cases: [string, Approval, RegExp][] = [
    ["no gate", approved([]), /no 'prod_apply_approved' gate .* after its creation at 2026-10-08T10:00:00\.000000Z/],
    ["gate before created_at", approved([{ at: EARLIER }]), /no 'prod_apply_approved' gate .*\(1 prod_apply_approved row/],
    ["gate at created_at", approved([{ at: CREATED }]), /no 'prod_apply_approved' gate/],
    ["gate for another dispatch", approved([{ dispatchId: OTHER_DISPATCH }]), /no 'prod_apply_approved' gate/],
    ["gate result fail", approved([{ result: "fail" }]), /has result fail/],
    ["overridden gate", approved([{ result: "fail", overridden: true }]), /is overridden/],
    ["other gate key", approved([{ gateKey: APPLY_GATE }]), /no 'prod_apply_approved' gate/],
    ["dispatch completed", approved([{}], { completedAt: LATER }), /completed at 2026-10-08T10:00:00\.000001Z; a retry is a new promote dispatch/],
    ["dispatch_type not promote", approved([{}], { dispatchType: "modification" }), /is a 'modification' dispatch; promote runs only within a 'promote' dispatch/],
    ["prod_apply gate exists (an earlier pass)", approved([{}], {}, 1), /already has 1 'prod_apply' gate row\(s\); one production attempt per promote dispatch/],
    ["prod_apply gates exist (pass and fail)", approved([{}], {}, 2), /already has 2 'prod_apply' gate row\(s\)/],
    ["dispatch not found", { dispatch: null, applyGateCount: 0, gates: [] }, /not found/],
    ["reason null", approved([{ reason: null }]), /no versions=<stem>:<sha256>,\.\.\. token/],
    ["no versions token", approved([{ reason: "operator approved" }]), /no versions=<stem>:<sha256>,\.\.\. token/],
    ["old format token", approved([{ reason: `version=0003_c checksum=${C_SUM}` }]), /retired single-version format \(version=\/checksum=\)/],
    ["old checksum= next to versions=", approved([{ reason: `${APPROVED_REASON} checksum=${C_SUM}` }]), /retired single-version format/],
    ["malformed pair: no colon", approved([{ reason: `versions=0003_c${C_SUM}` }]), /pair '0003_c[0-9a-f]{64}' is not <stem>:<sha256>/],
    ["malformed pair: two colons", approved([{ reason: `versions=0003_c:${C_SUM}:x` }]), /is not <stem>:<sha256>/],
    ["malformed pair: trailing comma", approved([{ reason: `${APPROVED_REASON},` }]), /pair '' is not <stem>:<sha256>/],
    ["checksum too short", approved([{ reason: `versions=0003_c:${C_SUM.slice(1)}` }]), /checksum '[0-9a-f]{63}' for 0003_c is not 64 lowercase hex/],
    ["checksum too long", approved([{ reason: `${APPROVED_REASON}0` }]), /is not 64 lowercase hex/],
    ["checksum uppercase", approved([{ reason: `versions=0003_c:${C_SUM.toUpperCase()}` }]), /is not 64 lowercase hex/],
    ["checksum non-hex", approved([{ reason: `versions=0003_c:${"g".repeat(64)}` }]), /is not 64 lowercase hex/],
    ["checksum empty", approved([{ reason: "versions=0003_c:" }]), /checksum '' for 0003_c is not 64/],
    ["version malformed", approved([{ reason: `versions=0003_c.sql:${C_SUM}` }]), /version '0003_c\.sql' is not a migration file stem/],
    ["0000_ stem", approved([{ reason: `versions=0000_roles:${C_SUM},0003_c:${C_SUM}` }]), /'0000_roles' is operator-run/],
    ["duplicate stem", approved([{ reason: `versions=0003_c:${C_SUM},0003_c:${C_SUM}` }]), /lists 0003_c more than once/],
    ["two versions= tokens", approved([{ reason: `${APPROVED_REASON} ${APPROVED_REASON}` }]), /2 versions= tokens; exactly one/],
    ["empty list", approved([{ reason: "versions=" }]), /versions= lists no migrations/],
    [
      "version mismatch",
      approved([{ reason: `versions=0002_b:${C_SUM}` }]),
      new RegExp(
        `missing \\(approved, not pending\\): 0002_b; extra \\(pending, not approved\\): 0003_c\\): ` +
          `approved versions=0002_b:${C_SUM}; pending versions=0003_c:${C_SUM}`,
      ),
    ],
    [
      "checksum mismatch",
      approved([{ reason: `versions=0003_c:${other}` }]),
      new RegExp(`checksum differs: 0003_c approved ${other} pending ${C_SUM}\\): approved versions=0003_c:${other}; pending versions=0003_c:${C_SUM}`),
    ],
    ["revoked: fail after pass", approved([{}, { at: AT2, result: "fail", reason: "revoked" }]), /id 2 at .* has result fail; the approval is revoked/],
    ["revoked: same at, higher id fails", approved([{}, { result: "fail", reason: "revoked" }]), /id 2 .* has result fail/],
    [
      "latest overridden",
      approved([{}, { at: AT2, result: "fail", overridden: true, reason: "override" }]),
      /id 2 at .* is overridden/,
    ],
    [
      "latest by at, not by array order",
      approved([{ id: "9", at: AT2, result: "fail", reason: "revoked" }, { id: "10" }]),
      /id 9 at 2026-10-08T11:00:00\.000000Z\) has result fail/,
    ],
    [
      "id order is numeric, not text",
      approved([{ id: "10", result: "fail", reason: "revoked" }, { id: "9" }]),
      /id 10 .* has result fail/,
    ],
  ];
  for (const [name, approval, re] of cases) {
    withWorld(
      (w) => {
        assert.throws(() => promote(w.pc, DISPATCH, false), (e: Error) => /refusing to promote/.test(e.message) && re.test(e.message), name);
        assert.deepEqual(w.events, [`approval:${DISPATCH}`], name);
        assert.deepEqual(w.gates, [], name);
      },
      { approval },
    );
  }
});

test("promote: the approved set must equal the pending set; each difference is named", () => {
  const other = sum("-- other\n");
  const cases: [string, string, RegExp][] = [
    ["extra: a pending version not approved", APPROVED_REASON, /extra \(pending, not approved\): 0002_b\)/],
    [
      "missing: an approved version not pending",
      `${SET2_REASON},0004_d:${other}`,
      /missing \(approved, not pending\): 0004_d\): approved versions=0002_b:[0-9a-f]{64},0003_c:[0-9a-f]{64},0004_d:[0-9a-f]{64}; pending versions=0002_b:[0-9a-f]{64},0003_c:[0-9a-f]{64}$/,
    ],
    ["checksum-different", `versions=0002_b:${other},0003_c:${C_SUM}`, new RegExp(`checksum differs: 0002_b approved ${other} pending ${B_SUM}`)],
  ];
  for (const [name, reason, re] of cases) {
    withWorld(
      (w) => {
        assert.throws(() => promote(w.pc, DISPATCH, false), (e: Error) => /refusing to promote/.test(e.message) && re.test(e.message), name);
        assert.deepEqual(w.events, [`approval:${DISPATCH}`], name);
        assert.deepEqual(w.gates, [], name);
      },
      { prodRows: onlyA(), approval: approved([{ reason }]) },
    );
  }
  // Order in the approval does not matter: the sets are compared as sets.
  withWorld(
    (w) => assert.equal(promote(w.pc, DISPATCH, false), 0),
    { prodRows: onlyA(), approval: approved([{ reason: `versions=0003_c:${C_SUM},0002_b:${B_SUM}` }]) },
  );
});

test("promote: accepted approvals proceed, and the outcome gate carries the approval's at", () => {
  const AT2 = "2026-10-08T11:00:00.000000Z";
  const cases: [string, Approval, string][] = [
    ["matching approval", approved(), LATER],
    ["pass after an earlier fail", approved([{ result: "fail", reason: "not yet" }, { at: AT2 }]), AT2],
    ["pass after an earlier overridden fail", approved([{ result: "fail", overridden: true, reason: "x" }, { at: AT2 }]), AT2],
    ["same at, higher id passes", approved([{ result: "fail", reason: "no" }, {}]), LATER],
    ["free text around the token", approved([{ reason: `Operator approved after review:\n  ${APPROVED_REASON}\t(see d2211977). ok` }]), LATER],
    ["token first, text after", approved([{ reason: `${APPROVED_REASON} operator ok` }]), LATER],
    ["gates at or before created_at ignored", approved([{ at: EARLIER, result: "fail", reason: "x" }, { at: CREATED, result: "fail", reason: "y" }, {}]), LATER],
  ];
  for (const [name, approval, at] of cases) {
    withWorld(
      (w) => {
        assert.equal(promote(w.pc, DISPATCH, false), 0, name);
        assert.deepEqual(steps(w.events), FULL_ORDER, name);
        assert.ok(w.gates[0].reason.includes(` approved_at=${at} `), `${name}: ${w.gates[0].reason}`);
      },
      { approval },
    );
  }
});

test("promote: an approval for the old file bytes refuses after the file changes", () =>
  withWorld(
    (w) => {
      writeFileSync(join(w.pc.dir, "0003_c.sql"), "-- c changed\n");
      assert.throws(() => promote(w.pc, DISPATCH, false), /checksum differs: 0003_c/);
      assert.deepEqual(w.events, [`approval:${DISPATCH}`]);
      assert.deepEqual(w.gates, []);
    },
    { approval: approved() },
  ));

test("promote: production must be clean with at least one pending version; nothing else runs", () => {
  const cases: [string, Ledger, RegExp][] = [
    ["0 pending", new Map([["0001_a", A_SUM], ["0002_b", B_SUM], ["0003_c", C_SUM]]), /at least one pending migration; production has 0$/],
    ["drift", new Map([["0001_a", "0".repeat(64)], ["0002_b", B_SUM]]), /not clean.*DRIFT/],
    ["orphan", new Map([["0001_a", A_SUM], ["0002_b", B_SUM], ["0009_x", C_SUM]]), /not clean.*ORPHAN/],
    ["no-checksum", new Map([["0001_a", ""], ["0002_b", B_SUM]]), /not clean.*no-checksum/],
  ];
  for (const [name, prodRows, re] of cases) {
    withWorld(
      (w) => {
        assert.throws(() => promote(w.pc, DISPATCH, false), re, name);
        assert.deepEqual(w.events, [], name);
        assert.deepEqual(w.gates, [], name);
      },
      { prodRows },
    );
  }
  // 2 pending is a set: it proceeds with a matching two-pair approval (see the two-migration test).
  withWorld(
    (w) => assert.equal(promote(w.pc, DISPATCH, true), 0),
    { prodRows: onlyA(), approval: approved([{ reason: SET2_REASON }]) },
  );
});

test("promote: failures after the approval record a not_applied fail gate and never apply to production", () => {
  const cases: [string, WorldOpts, RegExp, string][] = [
    ["dump throws", { dump: "throws" }, /step 3 refresh-rehearsal: pg_dump failed; rehearsal not touched/, "step=3 refresh-rehearsal"],
    ["dump empty", { dump: "empty" }, /is empty; rehearsal not touched/, "step=3 refresh-rehearsal"],
    ["dump missing", { dump: "missing" }, /is missing; rehearsal not touched/, "step=3 refresh-rehearsal"],
    ["rehearsal checksum mismatch", { rehearsalChecksum: "f".repeat(64) }, /rehearsal checksum for 0003_c is f{64}/, "step=4 rehearsal apply"],
    ["SQL test non-zero", { testStatus: { "0001_a.sql": 3 } }, /SQL test 0001_a\.sql exited 3/, "step=5 sql tests"],
  ];
  for (const [name, opts, re, step] of cases) {
    withWorld((w) => {
      assert.throws(() => promote(w.pc, DISPATCH, false), re, name);
      assert.ok(!w.events.some((e) => e.startsWith("apply:production")), name);
      assert.equal(w.prod.rows.has("0003_c"), false, name);
      assert.deepEqual(w.gates.map((g) => [g.key, g.result, g.dispatchId]), [[APPLY_GATE, "fail", DISPATCH]], name);
      assert.ok(w.gates[0].reason.startsWith(`versions=0003_c:${C_SUM} approved_at=${LATER} dump=`), name);
      assert.ok(w.gates[0].reason.includes(`${step} outcome=not_applied error=`), `${name}: ${w.gates[0].reason}`);
      if (opts.dump) assert.ok(!w.events.includes("reset"), `${name}: rehearsal untouched`);
    }, opts);
  }
});

test("promote: a mid-set production failure stops at that file and records apply_failed with applied and failed", () => {
  const cases: [string, string, string, string][] = [
    ["second file fails", "0003_c.sql", "applied=0002_b failed=0003_c", "apply:production:0003_c.sql"],
    ["first file fails", "0002_b.sql", "applied=none failed=0002_b", "apply:production:0002_b.sql"],
  ];
  for (const [name, prodFailOn, outcome, lastApply] of cases) {
    withWorld(
      (w) => {
        assert.throws(
          () => promote(w.pc, DISPATCH, false),
          (e: Error) =>
            /step 6 production apply: psql exited 3/.test(e.message) &&
            e.message.includes(`gate prod_apply fail recorded (outcome=apply_failed ${outcome})`),
          name,
        );
        assert.equal(w.events.filter((e) => e.startsWith("apply:production")).at(-1), lastApply, name);
        assert.ok(!w.events.includes("apply:production:0003_c.sql") || prodFailOn === "0003_c.sql", name);
        assert.equal(w.prod.rows.has("0002_b"), prodFailOn === "0003_c.sql", name);
        assert.equal(w.prod.rows.has("0003_c"), false, name);
        assert.deepEqual(w.gates.map((g) => [g.key, g.result]), [[APPLY_GATE, "fail"]], name);
        assert.ok(
          w.gates[0].reason.endsWith(`step=6 production apply outcome=apply_failed ${outcome} error=psql exited 3`),
          `${name}: ${w.gates[0].reason}`,
        );
        assert.ok(w.gates[0].reason.startsWith(`versions=0002_b:${B_SUM},0003_c:${C_SUM} approved_at=${LATER} dump=${DUMP_FILE} `), name);
      },
      { prodRows: onlyA(), approval: approved([{ reason: SET2_REASON }]), prodFailOn },
    );
  }
});

test("promote: a failed post-apply check records apply_failed with failed=none", () =>
  withWorld(
    (w) => {
      assert.throws(() => promote(w.pc, DISPATCH, false), /step 6 production apply: production not clean after apply/);
      assert.deepEqual(w.gates.map((g) => [g.key, g.result]), [[APPLY_GATE, "fail"]]);
      assert.match(w.gates[0].reason, / outcome=apply_failed applied=0003_c failed=none error=production not clean after apply/);
    },
    { prodChecksum: "f".repeat(64) },
  ));

test("promote: a failure to record the pass gate after a clean apply records no fail gate and lists the set", () =>
  withWorld(
    (w) => {
      const calls: string[] = [];
      w.pc.tools.recordGate = (_t, g) => {
        calls.push(g.result);
        if (g.result === "pass") throw new MigrateError("psql exited 1\npermission denied");
      };
      assert.throws(
        () => promote(w.pc, DISPATCH, false),
        (e: Error) =>
          e.message.startsWith(
            "promote stopped at step 7 record gate (production applied): production holds the whole set (0002_b, 0003_c) " +
              "but the prod_apply gate is not recorded; the planner must reconcile. Gate error: psql exited 1",
          ) && e.message.endsWith(`; backup ${DUMP_FILE}`),
      );
      assert.deepEqual(calls, ["pass"]);
      assert.equal(w.prod.rows.get("0002_b"), B_SUM);
      assert.equal(w.prod.rows.get("0003_c"), C_SUM);
    },
    { prodRows: onlyA(), approval: approved([{ reason: SET2_REASON }]) },
  ));

test("promote: a failing SQL test stops the suite at that file", () =>
  withWorld(
    (w) => {
      assert.throws(() => promote(w.pc, DISPATCH, false), /0001_a/);
      assert.ok(!w.events.includes("test:0003_c.sql"));
    },
    { testStatus: { "0001_a.sql": 1 } },
  ));

test("promote --dry-run: a failure records no gate", () =>
  withWorld(
    (w) => {
      assert.throws(() => promote(w.pc, DISPATCH, true), /step 5 sql tests/);
      assert.deepEqual(w.gates, []);
    },
    { testStatus: { "0003_c.sql": 3 } },
  ));

test("promote: a failure to record the fail gate is reported with the original error", () =>
  withWorld(
    (w) => {
      w.pc.tools.recordGate = () => {
        throw new MigrateError("psql exited 1");
      };
      assert.throws(() => promote(w.pc, DISPATCH, false), /pg_dump failed.*recording gate prod_apply fail also failed: psql exited 1/s);
    },
    { dump: "throws" },
  ));

test("refresh-rehearsal: dumps, resets, restores, checks ledgers; label 'refresh' when nothing is pending", () => {
  const all = new Map([["0001_a", A_SUM], ["0002_b", B_SUM], ["0003_c", C_SUM]]);
  withWorld(
    (w) => {
      const file = refreshRehearsal(w.pc);
      assert.equal(file, join(tmpdir(), "promote-test", "local_ops_20261008T134507Z_pre_refresh.dump"));
      assert.deepEqual(steps(w.events), ["dump", "reset", "restore"]);
      assert.deepEqual(w.reh.rows, all);
      assert.ok(w.out.includes(`backup  ${file}`));
    },
    { prodRows: all },
  );
  withWorld((w) => assert.equal(refreshRehearsal(w.pc), DUMP_FILE));
});

test("refresh-rehearsal: a rehearsal ledger that differs after restore fails", () =>
  withWorld((w) => {
    w.pc.tools.restore = () => {
      w.reh.rows = new Map([["0001_a", A_SUM]]);
    };
    assert.throws(() => refreshRehearsal(w.pc), /differs from production[\s\S]*0002_b production=\w+ rehearsal=\(none\)/);
  }));

test("refresh-rehearsal: a reset or restore failure says rehearsal may have no ops schema and to re-run refresh-rehearsal", () => {
  for (const which of ["resetRehearsal", "restore"] as const) {
    withWorld((w) => {
      w.pc.tools[which] = () => {
        throw new MigrateError(`${which} exited 1\nerror: x`);
      };
      assert.throws(
        () => refreshRehearsal(w.pc),
        new RegExp(
          "rehearsal reset or restore failed; local_ops_rehearsal may have no ops schema\\. " +
            `Re-run \`node scripts/migrate\\.ts refresh-rehearsal\`\\n${which} exited 1`,
        ),
        which,
      );
    });
  }
  // Inside promote it is a step 3 failure, recorded as not_applied.
  withWorld((w) => {
    w.pc.tools.restore = () => {
      throw new MigrateError("pg_restore exited 1");
    };
    assert.throws(() => promote(w.pc, DISPATCH, false), /step 3 refresh-rehearsal: rehearsal reset or restore failed/);
    assert.match(w.gates[0].reason, /step=3 refresh-rehearsal outcome=not_applied error=rehearsal reset or restore failed/);
  });
});

test("pure helpers: promoteSet, checkApproval, parseApprovalSet, setDiff, formatSet, ledgerDiff, dumpPath, executorTarget", () => {
  assert.deepEqual(promoteSet([{ version: "0001_a", state: "ok", checksum: "x" }, { version: "0002_b", state: "pending" }]), ["0002_b"]);
  assert.deepEqual(
    promoteSet([{ version: "0001_a", state: "ok", checksum: "x" }, { version: "0002_b", state: "pending" }, { version: "0003_c", state: "pending" }]),
    ["0002_b", "0003_c"],
  );
  assert.throws(() => promoteSet([{ version: "0001_a", state: "ok", checksum: "x" }]), /at least one pending/);
  assert.throws(() => promoteSet([{ version: "0001_a", state: "no-checksum" }, { version: "0002_b", state: "pending" }]), /not clean/);
  assert.deepEqual(checkApproval(DISPATCH, approved(), PENDING), { approvedAt: LATER });
  assert.deepEqual(checkApproval(DISPATCH, approved([{ result: "fail" }, {}]), PENDING), { approvedAt: LATER });
  assert.ok("refusal" in checkApproval(DISPATCH, approved([{}, { result: "fail" }]), PENDING));
  assert.match((checkApproval(OTHER_DISPATCH, approved(), PENDING) as { refusal: string }).refusal, /not found/);
  // Refusal order: dispatch type before completion before the one-attempt rule before the approval rows.
  assert.match((checkApproval(DISPATCH, approved([], { dispatchType: "fix", completedAt: LATER }, 1), PENDING) as { refusal: string }).refusal, /'fix' dispatch/);
  assert.match((checkApproval(DISPATCH, approved([], { completedAt: LATER }, 1), PENDING) as { refusal: string }).refusal, /completed at/);
  assert.match((checkApproval(DISPATCH, approved([], {}, 1), PENDING) as { refusal: string }).refusal, /one production attempt/);
  assert.deepEqual(parseApprovalSet(`x ${APPROVED_REASON} z`), PENDING);
  assert.deepEqual(parseApprovalSet(`versions=0003_c:${C_SUM},0002_b:${B_SUM}`), [
    { version: "0003_c", checksum: C_SUM },
    { version: "0002_b", checksum: B_SUM },
  ]);
  assert.match(parseApprovalSet(`versions=0003_c=1:${C_SUM}`) as string, /not a migration file stem/);
  assert.match(parseApprovalSet("") as string, /no versions=/);
  assert.match(parseApprovalSet(`Versions=0003_c:${C_SUM}`) as string, /no versions=/);
  assert.match(parseApprovalSet(`version=0003_c`) as string, /retired/);
  assert.deepEqual(setDiff(parseApprovalSet(SET2_REASON) as { version: string; checksum: string }[], [
    { version: "0003_c", checksum: C_SUM },
    { version: "0002_b", checksum: B_SUM },
  ]), []);
  assert.equal(formatSet([{ version: "0002_b", checksum: "b" }, { version: "0003_c", checksum: "c" }]), "0002_b:b,0003_c:c");
  assert.deepEqual(ledgerDiff(new Map([["a", "1"], ["b", "2"]]), new Map([["a", "1"], ["b", "3"], ["c", "4"]])), [
    "b production=2 rehearsal=3",
    "c production=(none) rehearsal=4",
  ]);
  assert.equal(dumpPath("T", new Date("2026-01-02T03:04:05.678Z"), "x"), join("T", "local_ops_20260102T030405Z_pre_x.dump"));
  const ex = executorTarget(resolveTarget({ DATABASE_URL: "postgresql://local_ops:s3cret@db:5433/local_ops?sslmode=require" }, null));
  assert.equal(ex.url, "postgresql://ops_executor@db:5433/local_ops?sslmode=require");
  assert.equal(ex.user, "ops_executor");
});

test("rehearsalRefusal: user, host, port and database of both targets, no PGPASSWORD", () => {
  const t = (url: string) => resolveTarget({ DATABASE_URL: url }, null);
  assert.equal(rehearsalRefusal(PROD, REH, {}), null);
  assert.match(rehearsalRefusal(REH, REH, {})!, /production target must be database local_ops/);
  assert.match(rehearsalRefusal(t("postgresql://u@h/local_ops_x"), REH, {})!, /must be database local_ops/);
  assert.match(rehearsalRefusal(t("postgresql://u@h:1"), REH, {})!, /must be database local_ops/);
  const prodCases: [string, RegExp][] = [
    ["postgresql://local_ops@127.0.0.1:5432/local_ops", /\(differs: host 127\.0\.0\.1 \(expected localhost\)\)/],
    ["postgresql://local_ops@localhost:5433/local_ops", /\(differs: port 5433 \(expected 5432\)\)/],
    ["postgresql://ops_dev@localhost:5432/local_ops", /\(differs: user ops_dev \(expected local_ops\)\)/],
    ["postgresql://local_ops@localhost/local_ops", /\(differs: port \(default\) \(expected 5432\)\)/],
    ["postgresql://localhost:5432/local_ops", /\(differs: user \(default\) \(expected local_ops\)\)/],
  ];
  for (const [url, re] of prodCases) {
    const r = rehearsalRefusal(t(url), REH, {})!;
    assert.match(r, /^production target must be database local_ops as local_ops on localhost:5432 /, url);
    assert.match(r, re, url);
  }
  assert.match(rehearsalRefusal(PROD, t("postgresql://ops_dev@localhost/local_ops"), {})!, /rehearsal target must be ops_dev/);
  assert.match(rehearsalRefusal(PROD, t("postgresql://local_ops@localhost/local_ops_rehearsal"), {})!, /rehearsal target must be ops_dev/);
  const rehCases: [string, RegExp][] = [
    ["postgresql://ops_dev@127.0.0.1:5432/local_ops_rehearsal", /\(differs: host 127\.0\.0\.1 \(expected localhost\)\)/],
    ["postgresql://ops_dev@localhost:5433/local_ops_rehearsal", /\(differs: port 5433 \(expected 5432\)\)/],
    ["postgresql://local_ops@localhost:5432/local_ops_rehearsal", /\(differs: user local_ops \(expected ops_dev\)\)/],
    ["postgresql://ops_dev@localhost/local_ops_rehearsal", /\(differs: port \(default\) \(expected 5432\)\)/],
    ["postgresql://ops_dev@localhost:5432", /\(differs: database \(default\) \(expected local_ops_rehearsal\)\)/],
  ];
  for (const [url, re] of rehCases) {
    const r = rehearsalRefusal(PROD, t(url), {})!;
    assert.match(r, /^rehearsal target must be ops_dev on local_ops_rehearsal at localhost:5432 /, url);
    assert.match(r, re, url);
  }
  assert.match(rehearsalRefusal(PROD, REH, { PGPASSWORD: "x" })!, /PGPASSWORD is set/);
  assert.match(rehearsalRefusal(REH, REH, { PGPASSWORD: "x" })!, /PGPASSWORD is set/);
});

test("promoteArgs: one lowercase uuid, optional --dry-run", () => {
  assert.deepEqual(promoteArgs([DISPATCH]), { dispatchId: DISPATCH, dryRun: false });
  assert.deepEqual(promoteArgs(["--dry-run", DISPATCH]), { dispatchId: DISPATCH, dryRun: true });
  for (const bad of [[], ["--dry-run"], [DISPATCH, DISPATCH], [DISPATCH, "--dry-run", "--dry-run"], ["x"], [DISPATCH.toUpperCase()], ["'; drop"]]) {
    assert.throws(() => promoteArgs(bad), MigrateError, JSON.stringify(bad));
  }
});

test("main: promote and refresh-rehearsal refuse before connecting when production is not local_ops or PGPASSWORD is set", () =>
  withDir((dir) => {
    for (const argv of [["promote", DISPATCH], ["refresh-rehearsal"]]) {
      for (const env of [{ DATABASE_URL: REHEARSAL }, { PGPASSWORD: "x" }, { DATABASE_URL: "postgresql://local_ops@127.0.0.1:5432/local_ops" }]) {
        const io = fakeIo(dir, env);
        assert.equal(main(argv, io), 1, `${argv[0]} ${JSON.stringify(env)}`);
        assert.equal(io.connects, 0);
        assert.match(io.err[0], new RegExp(`^migrate: refusing to ${argv[0]}: `));
      }
    }
  }));

test("main: bad promote / refresh-rehearsal arguments print usage without reading .env or connecting", () =>
  withDir((dir) => {
    for (const argv of [["promote"], ["promote", "x"], ["refresh-rehearsal", "extra"]]) {
      const io = fakeIo(dir, {});
      assert.equal(main(argv, io), 1);
      assert.equal(io.dotenvReads, 0);
      assert.equal(io.connects, 0);
    }
  }));

test("main: promote --help prints the approval format, the anchor and the one-attempt rule without reading .env or connecting", () =>
  withDir((dir) => {
    const io = fakeIo(dir, {});
    assert.equal(main(["promote", "--help"], io), 0);
    assert.equal(io.dotenvReads, 0);
    assert.equal(io.connects, 0);
    const help = io.out.join("\n");
    assert.match(help, /versions=<stem>:<sha256>,<stem>:<sha256>,\.\.\./);
    assert.match(help, /promote dispatch that has not completed and has no prod_apply gate yet/);
    assert.match(help, /one production attempt per promote dispatch/);
    assert.match(help, /recorded after its created_at/);
    assert.match(help, /single-version version=\/checksum= format is retired/);
    assert.match(help, /revokes an earlier pass/);
    assert.match(help, /status, apply, adopt and baseline refuse production/);
    const bad = fakeIo(dir, {});
    assert.equal(main(["promote", "x"], bad), 1);
    assert.match(bad.err.join("\n"), /versions=<stem>:<sha256>/);
    const usage = fakeIo(dir, {});
    assert.equal(main([], usage), 1);
    assert.match(usage.err.join("\n"), /status, apply, adopt and baseline refuse the production database/);
  }));

// ── entry point

test("unsupportedEntry: only when import.meta.main is missing and this file is the entry", () => {
  const self = join(process.cwd(), "scripts", "migrate.ts");
  assert.equal(unsupportedEntry(true, self, self), false);
  assert.equal(unsupportedEntry(false, self, self), false);
  assert.equal(unsupportedEntry(undefined, self, self), true);
  assert.equal(unsupportedEntry(undefined, join("scripts", "migrate.ts"), self), true);
  assert.equal(unsupportedEntry(undefined, join(process.cwd(), "scripts", "migrate.test.ts"), self), false);
  assert.equal(unsupportedEntry(undefined, undefined, self), false);
});
