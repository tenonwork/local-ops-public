-- tests/sql/0030_read_first_order_v2.sql
-- Tests for migrations/0030_read_first_order_v2.sql. Run as the schema owner against a non-production database
-- where 0030 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0030_read_first_order_v2.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: asserts on the read_first_order row and the version 10 changelog row only; no absolute counts.

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

-- a. the read_first_order row (exact v2 value bounded: asserted while 0030 is the newest migration)
DO $$
DECLARE r ops.protocol_rules; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  SELECT * INTO r FROM ops.protocol_rules WHERE key = 'read_first_order';
  PERFORM pg_temp.check(FOUND, 'a read_first_order row exists');
  PERFORM pg_temp.check(r.version >= 2, 'a rule version at least 2');
  PERFORM pg_temp.check((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r.value) k) = ARRAY['order', 'rule'],
                        'a value has exactly the keys order and rule');
  PERFORM pg_temp.check(NOT (r.value -> 'order') ? 'CLAUDE_LOG.md', 'a CLAUDE_LOG.md is not in the order');
  IF NOT (newest >= '0030' AND newest < '0031') THEN
    RAISE NOTICE 'skip a read_first_order v2 value (newest migration is %)', newest;
    RETURN;
  END IF;
  PERFORM pg_temp.check(r.version = 2, 'a rule version 2');
  PERFORM pg_temp.check(r.value -> 'order' = jsonb_build_array('global node context', 'CLAUDE.md', 'task files'),
                        'a order array');
  PERFORM pg_temp.check(r.value ->> 'rule' = 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then the task files only. CLAUDE_LOG.md is not read: the change history is ops.work_log, and claim_dispatch delivers the rows relevant to the dispatch''s node and task files (work_log_delivery). Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.',
                        'a rule text');
  RAISE NOTICE 'ok   a read_first_order row v2';
END $$;

-- b. changelog version 10
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) >= 10, 'b protocol version at least 10');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog WHERE version = 10) = 1,
                        'b exactly one changelog row at version 10');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog
                          WHERE version = 10 AND rule_keys = ARRAY['read_first_order']
                            AND changes LIKE '%2346fdf9%') = 1,
                        'b changelog row version 10 for read_first_order naming 2346fdf9');
  RAISE NOTICE 'ok   b protocol_changelog version 10';
END $$;

-- c. planner and executor can read the rules; no role other than the owner holds a write privilege on them
DO $$ BEGIN
  PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.protocol_rules', 'SELECT'), 'c ops_planner SELECT on protocol_rules');
  PERFORM pg_temp.check(has_table_privilege('ops_executor', 'ops.protocol_rules', 'SELECT'), 'c ops_executor SELECT on protocol_rules');
  PERFORM pg_temp.check(NOT EXISTS (
      SELECT 1 FROM pg_class c, aclexplode(c.relacl) a
       WHERE c.oid = 'ops.protocol_rules'::regclass AND a.grantee <> c.relowner AND a.privilege_type <> 'SELECT'),
    'c no grantee other than the owner holds a privilege beyond SELECT on protocol_rules');
  RAISE NOTICE 'ok   c ops_planner and ops_executor SELECT protocol_rules; no write privilege granted';
END $$;

ROLLBACK;

-- d. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   d no leftover rows; 0030 tests passed';
END $$;
