-- tests/sql/0017_promote_dispatch_type.sql
-- Tests for migrations/0017_promote_dispatch_type.sql. Run as the schema owner against a non-production database
-- where 0017 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0017_promote_dispatch_type.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: asserts on the promote row, the hard_boundaries rules as 0002/0004/0017 wrote them, and a
-- dispatch it creates itself; counts are relative to the starting state.

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
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'dispatch_types', (SELECT count(*) FROM ops.dispatch_types),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))::text, false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- ── 1. the promote row
DO $$
DECLARE t ops.dispatch_types;
BEGIN
  SELECT * INTO t FROM ops.dispatch_types WHERE type = 'promote';
  PERFORM pg_temp.check(FOUND, 'promote type exists');
  PERFORM pg_temp.check(t.description = 'Promote the approved migration set to production through node scripts/migrate.ts promote. No repo file changes.',
                        'description');
  PERFORM pg_temp.check(t.commit_policy = 'none', 'commit_policy none');
  PERFORM pg_temp.check(t.active, 'active');
  PERFORM pg_temp.check(t.project_id IS NULL, 'portable (project_id NULL)');
  PERFORM pg_temp.check(t.created_at IS NOT NULL, 'created_at set');
  PERFORM pg_temp.check((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(t.execution_rules) k)
                          = ARRAY['phases', 'requires', 'writes'], 'execution_rules keys phases, requires, writes');
  PERFORM pg_temp.check(t.execution_rules -> 'phases' = '["read", "dry_run", "promote", "verify", "report"]'::jsonb,
                        'phases read, dry_run, promote, verify, report');
  PERFORM pg_temp.check(t.execution_rules ->> 'writes'
                          = 'production database only, through node scripts/migrate.ts promote <dispatch_id>; no repo files',
                        'writes');
  PERFORM pg_temp.check(t.execution_rules ->> 'requires'
                          = 'a prod_apply_approved gate recorded by the planner against this dispatch, naming every version and checksum in the set',
                        'requires');
  RAISE NOTICE 'ok   1 promote dispatch type row';
END $$;

-- ── 2. hard_boundaries: new rules 1 and 2 at positions 1 and 2, the other rules unchanged and in order
--       (from 0037 on, rule 3 is the hard_boundaries v4 text; tests/sql/0037 asserts it)
DO $$
DECLARE v_rules jsonb := (SELECT value -> 'rules' FROM ops.protocol_rules WHERE key = 'hard_boundaries');
        v_rule3 text := 'Touching a file outside scope means stop and report.';
BEGIN
  IF (SELECT max(version) FROM ops.schema_migrations) >= '0037' THEN
    v_rule3 := 'Touching a file outside scope means stop and report. Within scope, a harmless fix found along the way may be made in place: comments, documentation text, typos, or a test-only fix to an assertion pinned on old state. Never a migration, a SQL function body, a grant, .claude/**, a credential, or any change in behaviour. Each such fix is listed under FOLLOW-UPS tagged [fixed-in-place] and must pass the dispatch''s verify.';
    RAISE NOTICE 'skip 2 rule 3 pre-0037 text (newest migration is %); asserting the 0037 text', (SELECT max(version) FROM ops.schema_migrations);
  END IF;
  PERFORM pg_temp.check(v_rules ->> 0 = 'No production access from the executor except through node scripts/migrate.ts refresh-rehearsal (read-only dump of production) and node scripts/migrate.ts promote, and promote only within a promote dispatch whose approval the planner has recorded.',
                        'rule 1 text');
  PERFORM pg_temp.check(v_rules ->> 1 = 'Read-only types (investigation) write nothing but their report.', 'rule 2 text');
  PERFORM pg_temp.check(NOT (v_rules ? 'No production access from the executor.')
                        AND NOT (v_rules ? 'Read-only types write nothing but their report.'), 'old rule texts gone');
  -- rules 3.. are the 0002 seed rules 3-5 and the 0004 secret rule, in order (none added or dropped)
  PERFORM pg_temp.check((SELECT jsonb_agg(r ORDER BY n) FROM jsonb_array_elements(v_rules) WITH ORDINALITY t(r, n) WHERE n > 2)
                          = jsonb_build_array(
                              v_rule3,
                              'No unlisted dispatch types; a needed new type is reported, and the planner adds it.',
                              'Implementation types commit locally only; pushing happens only through a push dispatch created after human confirmation.',
                              'Never print, cat, echo, open in output or log the contents of secret-bearing files (.env, .env.*, pgpass.conf, credential or key files). Check key names or presence only, never values. If a secret appears in output anyway, stop and record it under INCIDENTS.'),
                        'other rules unchanged, same count and order');
  RAISE NOTICE 'ok   2 hard_boundaries rules 1-2 amended, other rules unchanged';
END $$;

-- ── 3. changelog version 5
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) >= 5, 'protocol version at least 5');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.protocol_changelog
                          WHERE version = 5 AND rule_keys = ARRAY['hard_boundaries']
                            AND changes LIKE '%New dispatch type promote (decisions 15d47a9a, bcc002fd).') = 1,
                        'one changelog row version 5 for hard_boundaries');
  RAISE NOTICE 'ok   3 protocol_changelog version 5';
END $$;

-- ── 4. create_dispatch accepts promote for local-ops/core (active; commit_policy none needs no verify_cmd)
DO $$
DECLARE r ops.dispatches; v_before bigint := (SELECT count(*) FROM ops.dispatches); v_s uuid;
BEGIN
  -- the dispatch carries a test session in local-ops (required from 0022), opened on the global.local-ops node
  -- rather than inserted with the local-ops project row (0023 deletes that row)
  v_s := ops.open_session(p_node_path => 'global.local-ops'::public.ltree, p_kind => 'planning');
  r := ops.create_dispatch(p_node_path => 'global.local-ops.core'::public.ltree, p_dispatch_type => 'promote',
                           p_title => 't0017 promote', p_prompt => 't0017 prompt', p_session => v_s);
  PERFORM pg_temp.check(r.dispatch_type = 'promote' AND r.status = 'pending', 'promote dispatch created pending');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) = v_before + 1, 'one dispatch added');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM ops.dispatch_nodes WHERE dispatch_id = r.id), 'dispatch_nodes row');
  RAISE NOTICE 'ok   4 create_dispatch accepts promote';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'dispatch_types', (SELECT count(*) FROM ops.dispatch_types),
    'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   5 no leftover rows; 0017 tests passed';
END $$;
