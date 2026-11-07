-- 0031_work_log_backfill
-- Public edition. The private deployment's migration 0031 backfilled 66 historical work-log rows from a
-- retired plain-text log and checked the dispatches they referenced. That log and its rows are not part of
-- this edition, so this migration is index-only: it keeps the backlog item (an index on work_log.dispatch_id)
-- and the original version string, which 0032 pins as the newest ledger version.
-- Writes: one index. No work_log rows, no protocol_rules or protocol_changelog change.

BEGIN;

-- 0. guard: newest ledger version 0030, protocol version 10, work log empty, index state
DO $$
DECLARE v_newest text; v_n integer;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0030_read_first_order_v2' THEN
    RAISE EXCEPTION '0031: expected newest ledger version 0030_read_first_order_v2, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION '0031: expected protocol version 10, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM ops.work_log) OR EXISTS (SELECT 1 FROM ops.work_log_nodes) THEN
    RAISE EXCEPTION '0031: ops.work_log or ops.work_log_nodes is not empty';
  END IF;
  IF to_regclass('ops.work_log_claude_log_line_uq') IS NULL THEN
    RAISE EXCEPTION '0031: index ops.work_log_claude_log_line_uq missing';
  END IF;
  IF to_regclass('ops.work_log_dispatch_id_idx') IS NOT NULL THEN
    RAISE EXCEPTION '0031: index ops.work_log_dispatch_id_idx already exists';
  END IF;
  SELECT count(*) INTO v_n FROM ops.nodes WHERE path::text = 'global.local-ops.core';
  IF v_n <> 1 THEN
    RAISE EXCEPTION '0031: expected exactly one node global.local-ops.core, found %', v_n;
  END IF;
END $$;

-- 1. backlog b234443b
CREATE INDEX work_log_dispatch_id_idx ON ops.work_log (dispatch_id);

-- 2. checks
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ops.work_log) OR EXISTS (SELECT 1 FROM ops.work_log_nodes) THEN
    RAISE EXCEPTION '0031: no work_log rows may be written by this edition';
  END IF;
  IF to_regclass('ops.work_log_dispatch_id_idx') IS NULL THEN
    RAISE EXCEPTION '0031: index ops.work_log_dispatch_id_idx missing';
  END IF;
  IF (SELECT array_agg(a.attname::text)
        FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
       WHERE i.indexrelid = 'ops.work_log_dispatch_id_idx'::regclass) IS DISTINCT FROM ARRAY['dispatch_id'] THEN
    RAISE EXCEPTION '0031: index ops.work_log_dispatch_id_idx is not on work_log (dispatch_id)';
  END IF;
  RAISE NOTICE '0031 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0031_work_log_backfill');

COMMIT;
