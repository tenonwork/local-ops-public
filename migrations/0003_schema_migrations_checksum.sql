-- 0003_schema_migrations_checksum.sql
-- Adds a checksum column to the migration ledger. The runner (scripts/migrate.ts)
-- writes the SHA-256 of each migration file's bytes here after the file applies.
-- Nullable: rows applied before this migration are backfilled by `migrate.ts adopt`.
-- Run as local_ops. Self-registering, like 0001/0002.

BEGIN;

ALTER TABLE ops.schema_migrations
  ADD COLUMN checksum text CHECK (checksum ~ '^[0-9a-f]{64}$');

COMMENT ON COLUMN ops.schema_migrations.checksum IS
  'SHA-256 (lowercase hex) of the migration file bytes as applied; written by scripts/migrate.ts, not by the migration itself.';

INSERT INTO ops.schema_migrations (version) VALUES ('0003_schema_migrations_checksum');

COMMIT;
