# local-ops

This is the substrate for the **AI-Maintainable Systems portable matrix**.

> **Public edition.** This tree is a sanitized fork of a private deployment. History is a single curated
> commit; the retired plain-text work log and the private instruction texts are not included; and migrations
> `0002`, `0010` and `0031` differ from the private ledger, so checksums do not match that database. Use it as
> a fresh installation. The release pipeline in `scripts/migrate.ts` is wired to the database names `local_ops`
> and `local_ops_rehearsal`; change those constants for another instance.

- Local Postgres database: `local_ops` (role `local_ops`). Connection string lives in `.env` as `DATABASE_URL` (gitignored).

## Schema

Migrations live in `migrations/` and are applied in filename order:

- `0000_roles.sql` is run **once by the operator as a superuser** (`postgres`). It creates the actor roles `ops_planner` and `ops_executor` and grants them `CONNECT`. `local_ops` lacks `CREATEROLE`, so this cannot live in 0001.
- Every migration from `0001` on is applied by the runner (see "Usage: applying migrations").
- `migrations/` holds the files; `ops.work_log` records what each one did. The plain-text log used before the work-log release is not part of this edition.

All objects live in the `ops` schema. `ops_planner` and `ops_executor` are `LOGIN` roles with **no passwords** — they cannot authenticate until the operator sets one (`ALTER ROLE ... PASSWORD`). Passwords are never committed.

## Usage: applying migrations

From 0001 onward, migrations are applied with the runner (Node `^22.18.0 || >=24.2.0`, see `engines` in `package.json`; no build, no dependencies):

```sh
node scripts/migrate.ts status              # read-only: state of every version; exit 1 on drift, orphan or no-checksum
node scripts/migrate.ts apply               # apply unapplied migrations/*.sql in lexical order; refuses on drift or orphan
node scripts/migrate.ts adopt               # backfill checksums for applied rows that have none
node scripts/migrate.ts baseline <version>  # record a migration applied out of band, without running it
node scripts/migrate.ts refresh-rehearsal   # dump production, reset local_ops_rehearsal, restore the dump into it
node scripts/migrate.ts promote <dispatch_id> [--dry-run]   # production apply of the pending set within an approved promote dispatch (see below)
```

Operator rules:

- Production applies go only through `node scripts/migrate.ts promote <dispatch_id>` within an approved promote dispatch, never through `apply` or a SQL client.
- `status`, `apply`, `adopt` and `baseline` refuse the production database (`local_ops`, on any host) before connecting. Production is reached only through `refresh-rehearsal` and `promote`.
- `node scripts/migrate.ts baseline <version>` records an out-of-band apply on a non-production target only. Do not hand-insert the ledger row, and do not run `apply`, which would run the file again. Production cannot be recorded through the runner: an out-of-band production apply is reported to the planner instead.
- Run `status` before and after every `apply`.
- `apply`, `adopt` and `baseline` write to the target, so they refuse to run unless `MIGRATE_EXPECT_DB` equals the target database name.

Target and guard:

- Every command first prints `target  <user>@<host>:<port>/<database>  (from shell|.env)`. Parts the URL leaves out show as `(default)`. The password and URL are never printed.
- Every target must state user, host, port and database explicitly. If any part is left out (shown as `(default)`), the command exits 1 after the echo, before connecting.
- Before every `psql`, `pg_dump` or `pg_restore` call the runner clears the inherited libpq connection variables `PGHOST`, `PGHOSTADDR`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGSERVICE`, `PGSERVICEFILE` and `PGOPTIONS`, so only the target URL decides where the client connects. `PGPASSFILE` and `PGSSLMODE` (from `sslmode=` in the URL) are kept; `PGPASSWORD` is passed through unless the URL carries a password.
- A non-empty `DATABASE_URL` in the shell wins, and `.env` is not read. If it is unset or empty (or misspelled), the `.env` value, which is production, is used. The echo shows `(from .env)` when that happens.
- The production refusal and `MIGRATE_EXPECT_DB` are checked before any connection. If `MIGRATE_EXPECT_DB` is unset or differs from the resolved database, the command exits 1 and names the target and the expected value. `status` does not need it.

Rehearsal (dev database `local_ops_rehearsal`, role `ops_dev`, password from pgpass).

Refresh it from production with one command. Leave `DATABASE_URL` unset in the shell so production comes from `.env`:

```sh
node scripts/migrate.ts refresh-rehearsal
```

1. Refuses unless `PGPASSWORD` is unset, production resolves to exactly `local_ops@localhost:5432/local_ops` (user, host, port and database each checked), and rehearsal is exactly `ops_dev@localhost:5432/local_ops_rehearsal` (fixed: `postgresql://ops_dev@localhost:5432/local_ops_rehearsal`). The refusal names each part that differs. These names live in one `CONFIG` object in `scripts/migrate.ts`.
2. `pg_dump -Fc` of production to `%TEMP%\local_ops_<UTC yyyymmddThhmmssZ>_pre_<next pending version, or refresh>.dump`, outside the repository. That label is for a standalone `refresh-rehearsal`; inside `promote` the label is the newest version in the set. If the dump fails or the file is missing or empty, it stops before rehearsal is touched.
3. As `ops_dev`, in one transaction: `DROP SCHEMA ops CASCADE; DROP EXTENSION IF EXISTS ltree, pg_trgm` (the reset itself refuses any database other than `local_ops_rehearsal` and any session user other than `ops_dev`).
4. `pg_restore --no-owner --single-transaction --exit-on-error` of the dump as `ops_dev`. Objects end up owned by `ops_dev`; grants to `ops_planner` and `ops_executor` are kept. If the reset or the restore fails, `local_ops_rehearsal` may have no `ops` schema; the error says so and to re-run `node scripts/migrate.ts refresh-rehearsal`.
5. Checks that the rehearsal ledger equals the production ledger (versions and checksums) and prints the dump path (`backup  <path>`). The dump is the backup; it is not deleted.

Then rehearse a new migration on it. Put the rehearsal URL in the shell, without a password:

```sh
# bash: the variables apply to this one command only
DATABASE_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal MIGRATE_EXPECT_DB=local_ops_rehearsal node scripts/migrate.ts status
DATABASE_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal MIGRATE_EXPECT_DB=local_ops_rehearsal node scripts/migrate.ts apply
```

```powershell
# PowerShell: $env: variables last for the whole session, so remove them afterwards
$env:DATABASE_URL = 'postgresql://ops_dev@localhost:5432/local_ops_rehearsal'
$env:MIGRATE_EXPECT_DB = 'local_ops_rehearsal'
node scripts/migrate.ts status
node scripts/migrate.ts apply
Remove-Item Env:DATABASE_URL, Env:MIGRATE_EXPECT_DB
```

- Check that the `target` line reads `ops_dev@localhost:5432/local_ops_rehearsal  (from shell)` before trusting the output.
- A `PGPASSWORD` left in the shell (for example for another role) is sent instead of the pgpass entry. Unset it before a rehearsal. `refresh-rehearsal` and `promote` refuse to run while it is set.
- pgpass matches the host literally: the entry needs `localhost:5432:local_ops_rehearsal:ops_dev:<password>` for the URL above, and `localhost` does not match `127.0.0.1`. `promote` also needs the `ops_executor` entry for `local_ops` on the production host and port (the one the MCP bridge uses).
- `pg_dump` and `pg_restore` default to the directory of `psql` (`PSQL`); override with `PG_DUMP` and `PG_RESTORE`.

Promote (production apply by the executor). Production applies go only through `promote`, within a promote dispatch whose approval the planner has recorded. One release is the set of migrations pending on production:

1. The executor finishes the migration dispatch(es) (file, SQL tests, rehearsal run) and files the reports.
2. The planner creates a `promote` dispatch for the release.
3. The operator reviews and approves. The planner then records `ops.record_gate('prod_apply_approved', 'pass', <promote dispatch_id>)` with a reason that names the whole set in one token, `versions=<stem>:<sha256>,<stem>:<sha256>,...`, for example `operator approved versions=0014_example:<64 lowercase hex>,0015_next:<64 lowercase hex>`. Each checksum is the SHA-256 of the file bytes, as `status` and the ledger compute it. Since 0013 only an `ops_planner` session can record that gate key; the executor cannot approve its own apply. To revoke, the planner records a later `prod_apply_approved` row with result `fail` for the same dispatch; a later `pass` (with the token) approves again. The single-version `version=… checksum=…` format is retired and refused.
4. The executor runs it while executing the claimed promote dispatch, on that dispatch's id (with `DATABASE_URL` unset, so production comes from `.env`):

```sh
node scripts/migrate.ts promote <dispatch_id> --dry-run   # required first (the promote dispatch type's dry_run phase): steps 1-5 only
node scripts/migrate.ts promote <dispatch_id>
```

One production attempt per promote dispatch: once any `prod_apply` gate (pass or fail) exists for it, `promote` refuses. A retry is a new promote dispatch with a new approval.

`promote` runs these steps in order and stops at the first failure with exit 1:

1. Production status: no drift, orphan or missing checksum, and at least one pending migration. Every pending migration is in the set, with its current file checksum.
2. Approval (read from production, the control plane). Refused, in this order, when: the dispatch is not found; its `dispatch_type` is not `promote`; its `completed_at` is set; a `prod_apply` gate already exists for it; no `prod_apply_approved` gate for it was recorded strictly after its `created_at` (rows at or before are ignored); the most recent such row (by `at`, then `id`) is overridden or not `pass`; its reason does not carry exactly one valid `versions=` token (pairs `<stem>:<64 lowercase hex>`, comma-separated, at least one, no duplicate stem, no `0000_*`; other text is ignored); or the approved set differs from the pending set. The sets are compared as sets (versions and checksums); on a difference both are printed, with the versions missing (approved, not pending), extra (pending, not approved) or checksum-different, so an approval does not cover a file edited after it. `node scripts/migrate.ts promote --help` prints the format. Refusals in steps 1-2 record nothing.
3. `refresh-rehearsal` (above), dump label = the newest version in the set. Its dump is the backup.
4. Applies the whole set to rehearsal; every set version's rehearsal checksum must equal its file checksum, and rehearsal must be clean afterwards.
5. Runs every `tests/sql/*.sql` file against rehearsal; each must exit 0.
6. Applies the set to production through the `apply` path. Files own their transactions, so it stops at the first failing file; there is no automatic restore. Afterwards production must be clean and every set version's production checksum must equal the rehearsal one.
7. Records `ops.record_gate('prod_apply', 'pass', <dispatch_id>)` as `ops_executor`, reason `versions=<the set pairs> approved_at=… dump=… step=…` (`approved_at` is the `at` of the approval row used).

Outcome on failure after step 2 (never in a dry run): `prod_apply` `fail` is recorded with the same reason plus

- before step 6: `outcome=not_applied error=<first line>`;
- in step 6 or its checks: `outcome=apply_failed applied=<set versions now on production, or none> failed=<first set version not applied, or none if all applied but a post-apply check failed> error=<first line>`;
- in step 7 (production holds the whole set but writing the pass gate fails): no fail gate is recorded. `promote` exits 1 with a message that lists the set, says the `prod_apply` gate is not recorded and the planner must reconcile, and includes the gate error.

If recording the fail gate also fails, the message carries both errors.

Output from the two applies is prefixed `[rehearsal]` and `[production]`, and each migration's NOTICEs are printed (`notice  …`); test output is prefixed `[tests]`. `--dry-run` runs steps 1-5, never applies to production and records no gate.

Commands and exit codes:

- `status` writes nothing. It prints one line per version (`ok`, `pending`, `DRIFT ledger=… file=…`, `no-checksum (run adopt)`, `ORPHAN (ledger row, no file)`) and a summary. It exits 1 if any version has drifted, is an orphan (ledger row with no file) or has no checksum. Pending versions alone exit 0.
- `apply` checks every version first. If any has drifted or is an orphan, it prints them and exits 1 without running anything. Otherwise it runs each pending file and prints the file's server messages (NOTICEs) as `notice  …` lines. It exits 1 if a file fails or does not insert its own ledger row.
- `adopt` writes the checksum for applied rows that have none. It prints `ok`, `DRIFT` or `pending` for each version, and exits 1 if the checksum column does not exist.
- `baseline <version>` takes exactly one version such as `0004_secret_handling_incidents`. It does not accept `all`, wildcards, `.sql` filenames or `0000_*`. It inserts the version and the file's checksum in one transaction and prints the checksum. It exits 1 and writes nothing if the file is missing, a ledger row already exists, an earlier version is pending, or the checksum column does not exist.

SQL tests (`tests/sql/`, one file per migration) run against the rehearsal database after the migration is applied there, as the schema owner. Each file runs in one transaction that ends in `ROLLBACK`, so it is rerunnable and leaves no rows. A failed assertion raises, and psql exits 3. The file refuses to run against `local_ops`.

```sh
"/c/Program Files/PostgreSQL/18/bin/psql.exe" -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0006_window_tracking.sql
```

Checks (no database): `npm run test:scripts` runs the runner tests, and `npm run typecheck:scripts` type-checks `scripts/` with the TypeScript installed in `mcp/` (run `npm --prefix mcp install` first).

- Connects with `DATABASE_URL` from the environment or `.env` (production: `local_ops`, which only `refresh-rehearsal` and `promote` may reach). psql defaults to `C:\Program Files\PostgreSQL\18\bin\psql.exe`; override with `PSQL`. Every run uses `-v ON_ERROR_STOP=1`.
- `0000_*` files are always skipped (they are run by the operator as a superuser).
- Each migration owns its `BEGIN`/`COMMIT` and inserts its own `ops.schema_migrations` row. The runner does not wrap files in a transaction or insert ledger rows. After a file runs, the runner checks that its row exists (and stops if it does not), then writes the file's SHA-256 to `ops.schema_migrations.checksum`. That column is added by `0003_schema_migrations_checksum.sql`.
- Running `apply` again does nothing for files that are already applied. `baseline` is the only command that inserts a ledger row itself, and it never runs the file.

## License

MIT. See `LICENSE`.

## Security

Report vulnerabilities privately as described in `SECURITY.md`.
