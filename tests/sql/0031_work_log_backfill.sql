-- tests/sql/0031_work_log_backfill.sql
-- Tests for migrations/0031_work_log_backfill.sql (public edition: index-only). Run as the schema owner
-- against a non-production database where 0031 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0031_work_log_backfill.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- This edition writes no backfill rows, so the assertions are state-independent: they hold after the work log
-- grows through normal use.

\encoding UTF8
\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in a session setting so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.counts_before', (SELECT jsonb_build_object(
    'work_log', (SELECT count(*) FROM ops.work_log),
    'work_log_nodes', (SELECT count(*) FROM ops.work_log_nodes)))::text, false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- a. the index and the absence of the private edition's backfill
DO $$ BEGIN
  PERFORM pg_temp.check(to_regclass('ops.work_log_dispatch_id_idx') IS NOT NULL,
                        'a index work_log_dispatch_id_idx exists');
  PERFORM pg_temp.check((SELECT array_agg(a.attname::text)
                           FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                          WHERE i.indexrelid = 'ops.work_log_dispatch_id_idx'::regclass) = ARRAY['dispatch_id'],
                        'a work_log_dispatch_id_idx is on work_log (dispatch_id)');
  PERFORM pg_temp.check(to_regclass('ops.work_log_claude_log_line_uq') IS NOT NULL,
                        'a index work_log_claude_log_line_uq still exists');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.work_log
                                     WHERE external_refs @> '[{"kind":"claude_log"}]'::jsonb),
                        'a no backfilled claude_log rows');
  RAISE NOTICE 'ok   a index and no backfilled rows';
END $$;

-- b. the ledger row records this migration
DO $$ BEGIN
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM ops.schema_migrations WHERE version = '0031_work_log_backfill'),
                        'b ledger row 0031_work_log_backfill');
  RAISE NOTICE 'ok   b ledger row';
END $$;

ROLLBACK;

-- c. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'work_log', (SELECT count(*) FROM ops.work_log),
    'work_log_nodes', (SELECT count(*) FROM ops.work_log_nodes)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   c no leftover rows; 0031 tests passed';
END $$;
