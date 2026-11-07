-- tests/sql/0013_planner_only_apply_gate.sql
-- Tests for migrations/0013_planner_only_apply_gate.sql. Run as the schema owner against a non-production
-- database where 0013 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0013_planner_only_apply_gate.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file uses only rows it creates and counts relative to the starting state.
--
-- Roles: the rule keys on session_user, which only a new login (or a superuser's SET SESSION AUTHORIZATION)
-- changes. The tests connect as ops_dev only, and ops_dev is a member of neither ops_planner nor ops_executor,
-- so SET ROLE is not available (and would not change session_user anyway). Hence:
--   - the real ops.record_gate is called as ops_dev (block 1, 2);
--   - ops_planner and ops_executor are covered by a probe (block 3): pg_temp.record_gate_probe is built from
--     pg_get_functiondef(ops.record_gate) with each session_user replaced by current_setting('ops_test.session_user').
--     The block asserts the definition holds exactly two session_user references, so the probe runs the deployed
--     body and nothing else differs.

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row count before the transaction, kept in a session setting so the final check can read it
DO $$ BEGIN
  PERFORM set_config('ops_test.gate_events_before', (SELECT count(*) FROM ops.gate_events)::text, false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- runs p_sql in a subtransaction; returns 'SQLSTATE message' on error, NULL on success
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;

-- a dispatch of this file's own, for the gate rows (on a component the file creates)
DO $$
DECLARE c ops.components; v_d uuid; v_s uuid; v_cn uuid;
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0013-comp', 'node', 't0013-comp') RETURNING id INTO v_cn;
  INSERT INTO ops.components (key, kind, node_id) VALUES ('t0013-comp', 'test', v_cn) RETURNING * INTO c;
  -- the dispatch carries a session of its own (session_id NOT NULL from 0022)
  INSERT INTO ops.sessions (project_id, kind) VALUES (c.project_id, 'planning') RETURNING id INTO v_s;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
  VALUES (c.project_id, c.id, 'addition', v_s, 't0013', 'p')
  RETURNING id INTO v_d;
  PERFORM set_config('ops_test.dispatch', v_d::text, true);
END $$;

-- 1. as the schema owner: 'prod_apply_approved' raises check_violation and writes nothing
DO $$
DECLARE v_d uuid := current_setting('ops_test.dispatch')::uuid; e text;
        v_before bigint := (SELECT count(*) FROM ops.gate_events);
BEGIN
  PERFORM pg_temp.check(session_user NOT IN ('ops_planner', 'ops_executor'),
                        'tests run as the schema owner, got ' || session_user);
  e := pg_temp.err(format($q$SELECT ops.record_gate('prod_apply_approved', 'pass', %L)$q$, v_d));
  PERFORM pg_temp.check(e = format('23514 gate prod_apply_approved may only be recorded by ops_planner (session user is %s)', session_user),
                        'approval rejected as ' || session_user || ': ' || coalesce(e, 'success'));
  e := pg_temp.err(format($q$SELECT ops.record_gate('prod_apply_approved', 'fail', %L, NULL, true, 'x', 'y')$q$, v_d));
  PERFORM pg_temp.check(e LIKE '23514 %', 'approval rejected for fail/override too: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check((SELECT count(*) FROM ops.gate_events) = v_before, 'no gate row written');
  RAISE NOTICE 'ok   1 % cannot record prod_apply_approved', session_user;
END $$;

-- 2. as the schema owner: other gate keys record exactly as before (row contents, overrides, table CHECKs)
DO $$
DECLARE v_d uuid := current_setting('ops_test.dispatch')::uuid; v_id bigint; e text; g ops.gate_events;
BEGIN
  v_id := ops.record_gate('prod_apply', 'pass', v_d, NULL, false, NULL, 't0013 reason');
  SELECT * INTO g FROM ops.gate_events WHERE id = v_id;
  PERFORM pg_temp.check(g.gate_key = 'prod_apply' AND g.result = 'pass' AND g.dispatch_id = v_d AND g.session_id IS NULL
                        AND NOT g.overridden AND g.override_by IS NULL AND g.reason = 't0013 reason' AND g.at = now(),
                        'prod_apply row: ' || to_jsonb(g)::text);
  v_id := ops.record_gate('tests', 'fail', v_d, NULL, true, 'operator', 'accepted risk');
  PERFORM pg_temp.check((SELECT overridden AND override_by = 'operator' FROM ops.gate_events WHERE id = v_id), 'override row');
  -- defaults: only key, result and dispatch
  v_id := ops.record_gate('lint', 'pass', v_d);
  PERFORM pg_temp.check((SELECT NOT overridden AND reason IS NULL FROM ops.gate_events WHERE id = v_id), 'defaults row');
  -- table CHECKs still apply through the function
  e := pg_temp.err($q$SELECT ops.record_gate('lint', 'pass')$q$);
  PERFORM pg_temp.check(e LIKE '23514 %gate_events%', 'no dispatch and no session rejected: ' || coalesce(e, 'success'));
  e := pg_temp.err(format($q$SELECT ops.record_gate('lint', 'pass', %L, NULL, true, 'x', 'y')$q$, v_d));
  PERFORM pg_temp.check(e LIKE '23514 %gate_events%', 'override on pass rejected: ' || coalesce(e, 'success'));
  -- a key that only resembles the guarded one is not guarded
  v_id := ops.record_gate('prod_apply_approved_x', 'pass', v_d);
  PERFORM pg_temp.check(v_id IS NOT NULL, 'similar key records');
  RAISE NOTICE 'ok   2 other gate keys record as before';
END $$;

-- 3. probe with the deployed body: ops_planner records the approval; ops_executor and ops_dev raise;
--    other keys record for all three
DO $$
DECLARE v_def text := pg_get_functiondef('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure);
        v_d uuid := current_setting('ops_test.dispatch')::uuid; v_id bigint; e text; r text;
BEGIN
  PERFORM pg_temp.check(regexp_count(v_def, 'session_user') = 2, 'record_gate has 2 session_user references, got '
                        || regexp_count(v_def, 'session_user'));
  PERFORM pg_temp.check(regexp_count(v_def, 'FUNCTION ops\.record_gate\(') = 1, 'one function header');
  v_def := replace(v_def, 'FUNCTION ops.record_gate(', 'FUNCTION pg_temp.record_gate_probe(');
  v_def := replace(v_def, 'session_user', 'current_setting(''ops_test.session_user'')');
  EXECUTE v_def;

  PERFORM set_config('ops_test.session_user', 'ops_planner', true);
  v_id := pg_temp.record_gate_probe('prod_apply_approved', 'pass', v_d, NULL, false, NULL, 'operator approved');
  PERFORM pg_temp.check((SELECT gate_key = 'prod_apply_approved' AND result = 'pass' AND dispatch_id = v_d AND NOT overridden
                           FROM ops.gate_events WHERE id = v_id), 'planner approval row');

  FOREACH r IN ARRAY ARRAY['ops_executor', 'ops_dev', 'local_ops'] LOOP
    PERFORM set_config('ops_test.session_user', r, true);
    e := pg_temp.err(format($q$SELECT pg_temp.record_gate_probe('prod_apply_approved', 'pass', %L)$q$, v_d));
    PERFORM pg_temp.check(e = format('23514 gate prod_apply_approved may only be recorded by ops_planner (session user is %s)', r),
                          r || ' approval rejected: ' || coalesce(e, 'success'));
  END LOOP;

  FOREACH r IN ARRAY ARRAY['ops_planner', 'ops_executor', 'ops_dev'] LOOP
    PERFORM set_config('ops_test.session_user', r, true);
    v_id := pg_temp.record_gate_probe('prod_apply', 'fail', v_d, NULL, false, NULL, r);
    PERFORM pg_temp.check((SELECT reason FROM ops.gate_events WHERE id = v_id) = r, r || ' records prod_apply');
  END LOOP;
  RAISE NOTICE 'ok   3 probe: planner approves; executor, ops_dev, local_ops rejected; other keys for all';
END $$;

-- 4. catalog: signature, defaults, return type, SECURITY DEFINER, search_path, owner, ACL, one overload
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text;
BEGIN
  PERFORM set_config('search_path', 'pg_catalog', true);   -- type names print schema-qualified
  SELECT coalesce(to_jsonb(p)::text, 'missing') INTO v_bad
    FROM (SELECT 1) one
    LEFT JOIN LATERAL (
      SELECT pg_get_function_arguments(oid) args, pg_get_function_result(oid) res, prosecdef, proconfig,
             pg_get_userbyid(proowner) owner, proacl::text acl, prokind, (SELECT lanname::text FROM pg_language l WHERE l.oid = prolang) lang
        FROM pg_proc WHERE oid = to_regprocedure('ops.record_gate(text,ops.gate_result,uuid,uuid,boolean,text,text)')) p ON true
   WHERE p IS NULL
      OR p.args <> 'p_gate_key text, p_result ops.gate_result, p_dispatch uuid DEFAULT NULL::uuid, p_session uuid DEFAULT NULL::uuid, '
                   'p_overridden boolean DEFAULT false, p_override_by text DEFAULT NULL::text, p_reason text DEFAULT NULL::text'
      OR p.res <> 'bigint' OR NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
      OR p.owner <> v_owner OR p.acl <> format('{%1$s=X/%1$s,ops_planner=X/%1$s,ops_executor=X/%1$s}', v_owner)
      OR p.prokind <> 'f' OR p.lang <> 'plpgsql';
  PERFORM set_config('search_path', 'ops, pg_temp', true);
  PERFORM pg_temp.check(v_bad IS NULL, 'record_gate catalog: ' || coalesce(v_bad, ''));
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                          WHERE n.nspname = 'ops' AND p.proname = 'record_gate') = 1, 'one record_gate overload');
  RAISE NOTICE 'ok   4 signature, security, search_path, owner % and ACL', v_owner;
END $$;

-- 5. EXECUTE: ops_planner and ops_executor yes; PUBLIC no
DO $$
DECLARE f text := 'ops.record_gate(text,ops.gate_result,uuid,uuid,boolean,text,text)';
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'ops_planner executes record_gate');
  PERFORM pg_temp.check(has_function_privilege('ops_executor', f, 'EXECUTE'), 'ops_executor executes record_gate');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'PUBLIC does not execute record_gate');
  RAISE NOTICE 'ok   5 execute grants';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.gate_events) <> current_setting('ops_test.gate_events_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   6 no leftover rows; 0013 tests passed';
END $$;
