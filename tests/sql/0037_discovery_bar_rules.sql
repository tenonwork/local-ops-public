-- tests/sql/0037_discovery_bar_rules.sql
-- Tests for migrations/0037_discovery_bar_rules.sql. Run as the schema owner against a non-production database
-- where 0037 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0037_discovery_bar_rules.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: asserts on the hard_boundaries and report_format rows and the version 13 changelog row only;
-- no absolute counts.

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

-- a. protocol version 13 and its changelog row (bounded: asserted while 0037 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF NOT (newest >= '0037' AND newest < '0038') THEN
    RAISE NOTICE 'skip a protocol version 13 (newest migration is %)', newest;
    RETURN;
  END IF;
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) = 13, 'a protocol version 13');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog WHERE version = 13) = 1,
                        'a exactly one changelog row at version 13');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog
                          WHERE version = 13 AND rule_keys = ARRAY['hard_boundaries', 'report_format']
                            AND changes = 'hard_boundaries v4: harmless in-scope fixes allowed, tagged [fixed-in-place]; report_format v4: FOLLOW-UPS tags [side-effect], [discovery] (meets the bar), [fixed-in-place], [known-weakness]; known weaknesses go to the work entry''s follow_ups (decision cb0e9866).') = 1,
                        'a changelog row version 13 as written');
  RAISE NOTICE 'ok   a protocol_changelog version 13';
END $$;

-- b. hard_boundaries v4 rule 3 and report_format v4 FOLLOW-UPS sentences
DO $$
DECLARE hb ops.protocol_rules; rf ops.protocol_rules;
BEGIN
  SELECT * INTO hb FROM ops.protocol_rules WHERE key = 'hard_boundaries';
  PERFORM pg_temp.check(FOUND, 'b hard_boundaries row exists');
  PERFORM pg_temp.check(hb.version >= 4, 'b hard_boundaries version at least 4');
  PERFORM pg_temp.check(jsonb_array_length(hb.value -> 'rules') = 6, 'b hard_boundaries has 6 rules');
  PERFORM pg_temp.check(hb.value -> 'rules' ->> 2 = 'Touching a file outside scope means stop and report. Within scope, a harmless fix found along the way may be made in place: comments, documentation text, typos, or a test-only fix to an assertion pinned on old state. Never a migration, a SQL function body, a grant, .claude/**, a credential, or any change in behaviour. Each such fix is listed under FOLLOW-UPS tagged [fixed-in-place] and must pass the dispatch''s verify.',
                        'b hard_boundaries rule 3 text');

  SELECT * INTO rf FROM ops.protocol_rules WHERE key = 'report_format';
  PERFORM pg_temp.check(FOUND, 'b report_format row exists');
  PERFORM pg_temp.check(rf.version >= 4, 'b report_format version at least 4');
  PERFORM pg_temp.check(strpos(rf.value ->> 'rule', 'Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before and meets the bar (it blocks, breaks, brings a genuine noticeable improvement, causes a real problem later, gets costlier with deferral, recurs, or touches security or data integrity), [fixed-in-place] for a harmless in-scope fix (hard_boundaries), or [known-weakness] for anything below the bar. A committing dispatch also writes its known weaknesses into its work entry''s follow_ups. The executor never assigns priority; the planner sets the priority of discoveries at review.') > 0,
                        'b report_format rule contains the new FOLLOW-UPS sentences');
  PERFORM pg_temp.check(strpos(rf.value ->> 'rule', '[discovery] if it existed before. The') = 0,
                        'b report_format rule no longer holds the old [discovery] sentence');
  PERFORM pg_temp.check(rf.value -> 'fields' = jsonb_build_array('STATUS', 'FILES', 'DONE', 'VERIFY', 'COMMIT', 'INCIDENTS', 'FOLLOW-UPS'),
                        'b report_format fields unchanged');
  RAISE NOTICE 'ok   b hard_boundaries v4 rule 3, report_format v4 FOLLOW-UPS tags';
END $$;

ROLLBACK;

-- c. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   c no leftover rows; 0037 tests passed';
END $$;
