-- tests/sql/0025_read_first_order_rule.sql
-- Tests for migrations/0025_read_first_order_rule.sql. Run as the schema owner against a non-production database
-- where 0025 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0025_read_first_order_rule.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: asserts on the read_first_order row and the version 8 changelog row only; no absolute counts.

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
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))::text, false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- ── 1. the read_first_order row (v1 value asserted while newest < 0030; 0030 updates the rule to v2)
DO $$
DECLARE r ops.protocol_rules; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  SELECT * INTO r FROM ops.protocol_rules WHERE key = 'read_first_order';
  PERFORM pg_temp.check(FOUND, 'read_first_order row exists');
  PERFORM pg_temp.check((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r.value) k) = ARRAY['order', 'rule'],
                        'value has exactly the keys order and rule');
  IF newest >= '0030' THEN
    RAISE NOTICE 'skip 1 read_first_order v1 value (newest is %)', newest;
    RETURN;
  END IF;
  PERFORM pg_temp.check(r.version = 1, 'rule version 1');
  PERFORM pg_temp.check(r.value -> 'order' = jsonb_build_array('global node context', 'CLAUDE.md', 'CLAUDE_LOG.md', 'task files'),
                        'order array');
  PERFORM pg_temp.check(r.value ->> 'rule' = 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then CLAUDE_LOG.md, then the task files only. Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.',
                        'rule text');
  RAISE NOTICE 'ok   1 read_first_order row';
END $$;

-- ── 2. changelog version 8
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) >= 8, 'protocol version at least 8');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog WHERE version = 8) = 1,
                        'exactly one changelog row at version 8');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog
                          WHERE version = 8 AND rule_keys = ARRAY['read_first_order']
                            AND changes LIKE '%b2427ed1%') = 1,
                        'changelog row version 8 for read_first_order naming b2427ed1');
  RAISE NOTICE 'ok   2 protocol_changelog version 8';
END $$;

-- ── 3. planner and executor can read the row
DO $$ BEGIN
  PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.protocol_rules', 'SELECT'), 'ops_planner SELECT on protocol_rules');
  PERFORM pg_temp.check(has_table_privilege('ops_executor', 'ops.protocol_rules', 'SELECT'), 'ops_executor SELECT on protocol_rules');
  RAISE NOTICE 'ok   3 ops_planner and ops_executor can SELECT protocol_rules';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   4 no leftover rows; 0025 tests passed';
END $$;
