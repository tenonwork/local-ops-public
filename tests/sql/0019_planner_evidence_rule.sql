-- tests/sql/0019_planner_evidence_rule.sql
-- Tests for migrations/0019_planner_evidence_rule.sql. Run as the schema owner against a non-production database
-- where 0019 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0019_planner_evidence_rule.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: asserts on the planner_evidence row and the version 6 changelog row only; no absolute counts.

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

-- ── 1. the planner_evidence row
DO $$
DECLARE r ops.protocol_rules;
BEGIN
  SELECT * INTO r FROM ops.protocol_rules WHERE key = 'planner_evidence';
  PERFORM pg_temp.check(FOUND, 'planner_evidence row exists');
  PERFORM pg_temp.check(r.version = 1, 'rule version 1');
  PERFORM pg_temp.check((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r.value) k) = ARRAY['rule'],
                        'value has exactly the key rule');
  PERFORM pg_temp.check(r.value ->> 'rule' = 'Every factual claim the planner writes (backlog item, decision, session summary, review, message to the operator) names its source: a query, a report line, a tool result, or a file read this session. A claim without one is written as a hypothesis ("unverified: ...") and is never the basis for a severity, a decision or a dispatch premise.',
                        'rule text');
  RAISE NOTICE 'ok   1 planner_evidence row';
END $$;

-- ── 2. changelog version 6
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) >= 6, 'protocol version at least 6');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog
                          WHERE version = 6 AND rule_keys = ARRAY['planner_evidence']
                            AND changes LIKE '%decision 6d9b48ed%') = 1,
                        'one changelog row version 6 for planner_evidence naming 6d9b48ed');
  RAISE NOTICE 'ok   2 protocol_changelog version 6';
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
  RAISE NOTICE 'ok   4 no leftover rows; 0019 tests passed';
END $$;
