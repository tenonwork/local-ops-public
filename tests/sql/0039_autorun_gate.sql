-- tests/sql/0039_autorun_gate.sql
-- Tests for migrations/0039_autorun_gate.sql. Run as the schema owner against a non-production database where 0039 is
-- applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0039_autorun_gate.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared as text.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own project t0039a, components ca and cb and a session through the node-keyed
-- writers, inserts its own approval rows into ops.gate_events, and asserts only on rows it creates (plus catalog state
-- 0039 establishes). Within the transaction now() is fixed, so every test dispatch has the same created_at and gate rows
-- are dated relative to it (as tests/sql/0024 does).
-- Roles: the planner-only rule keys on session_user, and ops_dev cannot become ops_planner, so ops_planner and
-- ops_executor are covered by the tests/sql/0013 block 3 probe: pg_temp.record_gate_probe is built from the deployed
-- record_gate body with each session_user replaced by current_setting('ops_test.session_user').

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
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'gate_events', (SELECT count(*) FROM ops.gate_events),
    'autorun_allowed', (SELECT array_agg(type ORDER BY type) FROM ops.dispatch_types WHERE autorun_allowed)))::text, false);
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

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- a new pending dispatch of type p_type on global.t0039a.<p_comp>
CREATE FUNCTION pg_temp.dispatch(p_type text, p_title text, p_comp text DEFAULT 'ca', p_priority integer DEFAULT 100)
RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.create_dispatch(p_node_path => ('global.t0039a.' || p_comp)::public.ltree, p_dispatch_type => p_type,
                              p_title => p_title, p_prompt => 'p', p_priority => p_priority,
                              p_session => pg_temp.id('s'))).id;
$$;

-- an autorun approval row for p_dispatch, dated p_offset after (or before, if negative) its created_at
CREATE FUNCTION pg_temp.gate(p_dispatch uuid, p_result text, p_offset interval) RETURNS void LANGUAGE sql AS $$
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT d.id, pg_temp.id('s'), 'autorun_approved', p_result::ops.gate_result, 't0039 ' || p_result, d.created_at + p_offset
    FROM ops.dispatches d WHERE d.id = p_dispatch;
$$;

CREATE FUNCTION pg_temp.status(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT status::text FROM ops.dispatches WHERE id = p_dispatch;
$$;

CREATE FUNCTION pg_temp.claim_err(p_dispatch uuid, p_agent text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.claim_dispatch(%L, %L)', p_dispatch, p_agent));
$$;

CREATE FUNCTION pg_temp.autorun_msg(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT '23514 dispatch ' || p_dispatch
         || ' has no current autorun_approved pass or its type is not autorun-allowed; it stays pending';
$$;

-- the probe's call as session user p_user; returns 'SQLSTATE message' on error, NULL on success
CREATE FUNCTION pg_temp.probe_err(p_user text, p_key text, p_result text, p_dispatch uuid) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('ops_test.session_user', p_user, true);
  RETURN pg_temp.err(format('SELECT pg_temp.record_gate_probe(%L, %L, %L)', p_key, p_result, p_dispatch));
END $$;

-- 0. fixtures: project t0039a, components ca and cb, a session on the project; the record_gate probe
DO $$
DECLARE v_def text := pg_get_functiondef('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure);
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  PERFORM ops.create_project('global'::public.ltree, 't0039a', 'T0039 A');
  PERFORM ops.create_component('global.t0039a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM ops.create_component('global.t0039a'::public.ltree, 'cb', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0039a'::public.ltree,
                                                     p_kind => 'planning')::text, true);
  -- the probe runs the deployed body with session_user replaced, nothing else
  PERFORM pg_temp.check(regexp_count(v_def, 'session_user') = 2, 'record_gate has 2 session_user references, got '
                        || regexp_count(v_def, 'session_user'));
  PERFORM pg_temp.check(regexp_count(v_def, 'FUNCTION ops\.record_gate\(') = 1, 'one function header');
  v_def := replace(v_def, 'FUNCTION ops.record_gate(', 'FUNCTION pg_temp.record_gate_probe(');
  v_def := replace(v_def, 'session_user', 'current_setting(''ops_test.session_user'')');
  EXECUTE v_def;
  RAISE NOTICE 'ok   0 fixtures (t0039a/ca, cb, session, record_gate probe)';
END $$;

-- a. catalog 0039 establishes (bounded: asserted while 0039 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
BEGIN
  IF NOT (newest >= '0039' AND newest < '0040') THEN
    RAISE NOTICE 'skip a catalog of 0039 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                                 WHERE a.attrelid = 'ops.dispatch_types'::regclass AND a.attname = 'autorun_allowed'
                                   AND a.atttypid = 'boolean'::regtype AND a.attnotnull AND NOT a.attisdropped
                                   AND pg_get_expr(d.adbin, d.adrelid) = 'false'),
                        'a autorun_allowed boolean NOT NULL DEFAULT false');
  PERFORM pg_temp.check((SELECT array_agg(type ORDER BY type) FROM ops.dispatch_types WHERE autorun_allowed)
                        = ARRAY['addition', 'chore', 'docs', 'investigation', 'modification', 'repair'],
                        'a six autorun-allowed types');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.dispatch_types
                                     WHERE type IN ('promote', 'push', 'scaffold') AND autorun_allowed),
                        'a promote, push, scaffold not allowed');
  PERFORM pg_temp.check(col_description('ops.dispatch_types'::regclass,
                          (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.dispatch_types'::regclass
                              AND attname = 'autorun_allowed')::integer) LIKE 'Autorun gate (05022018): %',
                        'a column comment');

  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_dispatch uuid' AND pg_get_function_result(oid) = 'boolean'
                                AND prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') LIKE 'Autorun gate (05022018): %'
                           FROM pg_proc WHERE oid = to_regprocedure('ops._autorun_approved(uuid)')),
                        'a _autorun_approved signature, STABLE SECURITY DEFINER, search_path, owner, comment');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = '' AND pg_get_function_result(oid) = 'jsonb'
                                AND prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') LIKE 'Autorun gate (05022018): %'
                           FROM pg_proc WHERE oid = to_regprocedure('ops.autorun_state()')),
                        'a autorun_state signature, STABLE SECURITY DEFINER, search_path, owner, comment');
  -- under search_path ops the type prints unqualified
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid)
                                = 'p_gate_key text, p_result gate_result, p_dispatch uuid DEFAULT NULL::uuid, '
                                  'p_session uuid DEFAULT NULL::uuid, p_overridden boolean DEFAULT false, '
                                  'p_override_by text DEFAULT NULL::text, p_reason text DEFAULT NULL::text'
                                AND pg_get_function_result(oid) = 'bigint' AND prosecdef
                                AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') LIKE '%Autorun gate (05022018)%'
                           FROM pg_proc WHERE oid = to_regprocedure('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)')),
                        'a record_gate signature, defaults, result, definer, search_path, owner, comment');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_id uuid, p_agent_session text'
                                AND pg_get_function_result(oid) = 'void' AND prosecdef
                                AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc')
                                    = 'Release 3 (34502bc1): claims a pending dispatch; a promote dispatch without a current'
                                      ' prod_apply_approved pass is refused (23514) and stays pending. Autorun gate (05022018):'
                                      ' an agent session starting ''autorun:'' claims only a dispatch with a current'
                                      ' autorun_approved pass and an autorun-allowed type (23514 otherwise; it stays pending).'
                           FROM pg_proc WHERE oid = to_regprocedure('ops.claim_dispatch(uuid, text)')),
                        'a claim_dispatch signature, result, definer, search_path, owner, comment');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                           AND proname IN ('record_gate', 'claim_dispatch', '_autorun_approved', 'autorun_state')) = 4,
                        'a one overload each');
  RAISE NOTICE 'ok   a catalog: column and six types; _autorun_approved, autorun_state, record_gate, claim_dispatch';
END $$;

-- b. grants (always asserted)
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        f_state text := 'ops.autorun_state()'; f_appr text := 'ops._autorun_approved(uuid)';
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_executor', f_state, 'EXECUTE')
                        AND has_function_privilege('ops_planner', f_state, 'EXECUTE'), 'b planner and executor EXECUTE on autorun_state');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f_state, 'EXECUTE'), 'b PUBLIC no EXECUTE on autorun_state');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                                     WHERE p.oid = f_appr::regprocedure AND a.grantee <> p.proowner)
                        AND NOT has_function_privilege('ops_executor', f_appr, 'EXECUTE')
                        AND NOT has_function_privilege('ops_planner', f_appr, 'EXECUTE')
                        AND NOT has_function_privilege('public', f_appr, 'EXECUTE'), 'b _autorun_approved has no grantees');
  PERFORM pg_temp.check((SELECT proacl::text FROM pg_proc
                          WHERE oid = 'ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure)
                        = format('{%1$s=X/%1$s,ops_planner=X/%1$s,ops_executor=X/%1$s}', v_owner), 'b record_gate ACL unchanged');
  PERFORM pg_temp.check((SELECT proacl::text FROM pg_proc WHERE oid = 'ops.claim_dispatch(uuid, text)'::regprocedure)
                        = format('{%1$s=X/%1$s,ops_executor=X/%1$s}', v_owner), 'b claim_dispatch ACL unchanged');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = ARRAY['autorun_state', 'claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending',
                                'get_work_log', 'log_work', 'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now'],
                        'b ops_executor EXECUTE set = 0038 set plus autorun_state');
  PERFORM pg_temp.check((SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                            AND has_table_privilege('ops_executor', c.oid, 'SELECT'))
                        = ARRAY['components', 'context_documents', 'dispatch_types', 'doc_types', 'entry_types', 'node_paths',
                                'nodes', 'projects', 'protocol_rules', 'window_state'], 'b ops_executor SELECT set unchanged');
  RAISE NOTICE 'ok   b grants: autorun_state planner and executor; _autorun_approved none; record_gate, claim_dispatch ACL; executor sets';
END $$;

-- c. record_gate: only ops_planner records autorun_approved (pass and fail); prod_apply_approved message unchanged
DO $$
DECLARE v_d uuid := pg_temp.dispatch('addition', 't0039 c'); v_id bigint; e text; r text;
        v_before bigint;
BEGIN
  PERFORM set_config('ops_test.c', v_d::text, true);
  -- the real function as the schema owner
  PERFORM pg_temp.check(session_user NOT IN ('ops_planner', 'ops_executor'),
                        'tests run as the schema owner, got ' || session_user);
  v_before := (SELECT count(*) FROM ops.gate_events);
  e := pg_temp.err(format($q$SELECT ops.record_gate('autorun_approved', 'pass', %L)$q$, v_d));
  PERFORM pg_temp.check(e = format('23514 gate autorun_approved may only be recorded by ops_planner (session user is %s)', session_user),
                        'c autorun pass rejected as ' || session_user || ': ' || coalesce(e, 'success'));
  e := pg_temp.err(format($q$SELECT ops.record_gate('prod_apply_approved', 'pass', %L)$q$, v_d));
  PERFORM pg_temp.check(e = format('23514 gate prod_apply_approved may only be recorded by ops_planner (session user is %s)', session_user),
                        'c prod_apply_approved message unchanged: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check((SELECT count(*) FROM ops.gate_events) = v_before, 'c no gate row written');

  -- the probe: planner records pass and fail
  PERFORM set_config('ops_test.session_user', 'ops_planner', true);
  v_id := pg_temp.record_gate_probe('autorun_approved', 'pass', v_d, pg_temp.id('s'), false, NULL, 'operator said yes');
  PERFORM pg_temp.check((SELECT gate_key = 'autorun_approved' AND result = 'pass' AND dispatch_id = v_d AND NOT overridden
                                AND reason = 'operator said yes' FROM ops.gate_events WHERE id = v_id), 'c planner pass row');
  v_id := pg_temp.record_gate_probe('autorun_approved', 'fail', v_d, NULL, false, NULL, 'operator revoked');
  PERFORM pg_temp.check((SELECT gate_key = 'autorun_approved' AND result = 'fail' AND dispatch_id = v_d
                           FROM ops.gate_events WHERE id = v_id), 'c planner fail row');

  -- everyone else refused with the exact message, for both keys and both results
  v_before := (SELECT count(*) FROM ops.gate_events);
  FOREACH r IN ARRAY ARRAY['ops_executor', 'ops_dev', 'local_ops'] LOOP
    e := pg_temp.probe_err(r, 'autorun_approved', 'pass', v_d);
    PERFORM pg_temp.check(e = format('23514 gate autorun_approved may only be recorded by ops_planner (session user is %s)', r),
                          'c ' || r || ' autorun pass rejected: ' || coalesce(e, 'success'));
    e := pg_temp.probe_err(r, 'autorun_approved', 'fail', v_d);
    PERFORM pg_temp.check(e = format('23514 gate autorun_approved may only be recorded by ops_planner (session user is %s)', r),
                          'c ' || r || ' autorun fail rejected: ' || coalesce(e, 'success'));
    e := pg_temp.probe_err(r, 'prod_apply_approved', 'pass', v_d);
    PERFORM pg_temp.check(e = format('23514 gate prod_apply_approved may only be recorded by ops_planner (session user is %s)', r),
                          'c ' || r || ' prod_apply_approved message unchanged: ' || coalesce(e, 'success'));
  END LOOP;
  PERFORM pg_temp.check((SELECT count(*) FROM ops.gate_events) = v_before, 'c refusals wrote nothing');

  -- other keys still record for anyone (as 0013 block 3)
  FOREACH r IN ARRAY ARRAY['ops_planner', 'ops_executor', 'ops_dev'] LOOP
    PERFORM set_config('ops_test.session_user', r, true);
    v_id := pg_temp.record_gate_probe('prod_apply', 'fail', v_d, NULL, false, NULL, r);
    PERFORM pg_temp.check((SELECT reason FROM ops.gate_events WHERE id = v_id) = r, 'c ' || r || ' records prod_apply');
  END LOOP;
  RAISE NOTICE 'ok   c planner records autorun_approved pass and fail; executor, ops_dev, local_ops rejected; other keys open';
END $$;

-- d. pass refusals (planner probe): no dispatch, unknown, non-pending, promote, push, scaffold; a fail records on those
DO $$
DECLARE v_claimed uuid := pg_temp.dispatch('addition', 't0039 d claimed');
        v_promote uuid := pg_temp.dispatch('promote', 't0039 d promote');
        v_push uuid := pg_temp.dispatch('push', 't0039 d push');
        v_scaffold uuid := pg_temp.dispatch('scaffold', 't0039 d scaffold');
        v_unknown uuid := gen_random_uuid(); v_before bigint; e text; t text; v_x uuid;
BEGIN
  PERFORM pg_temp.check(pg_temp.claim_err(v_claimed, 't0039-agent') IS NULL, 'd claimed fixture');
  v_before := (SELECT count(*) FROM ops.gate_events);

  e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'pass', NULL);
  PERFORM pg_temp.check(e = '23514 gate autorun_approved needs a dispatch', 'd pass without dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'fail', NULL);
  PERFORM pg_temp.check(e = '23514 gate autorun_approved needs a dispatch', 'd fail without dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'pass', v_unknown);
  PERFORM pg_temp.check(e = '23514 gate autorun_approved: dispatch ' || v_unknown || ' does not exist',
                        'd pass on unknown dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'pass', v_claimed);
  PERFORM pg_temp.check(e = '23514 gate autorun_approved: dispatch ' || v_claimed || ' is claimed, not pending',
                        'd pass on claimed dispatch: ' || coalesce(e, 'success'));
  FOREACH t IN ARRAY ARRAY['promote', 'push', 'scaffold'] LOOP
    v_x := CASE t WHEN 'promote' THEN v_promote WHEN 'push' THEN v_push ELSE v_scaffold END;
    e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'pass', v_x);
    PERFORM pg_temp.check(e = format('23514 gate autorun_approved: dispatch %s has type %s, which is not autorun-allowed', v_x, t),
                          'd pass on ' || t || ': ' || coalesce(e, 'success'));
  END LOOP;
  PERFORM pg_temp.check((SELECT count(*) FROM ops.gate_events) = v_before, 'd refusals wrote nothing');

  -- a fail (revocation) needs only the planner and a dispatch
  FOREACH v_x IN ARRAY ARRAY[v_claimed, v_promote, v_push, v_scaffold] LOOP
    e := pg_temp.probe_err('ops_planner', 'autorun_approved', 'fail', v_x);
    PERFORM pg_temp.check(e IS NULL, 'd planner fail on ' || v_x || ': ' || coalesce(e, 'success'));
  END LOOP;
  PERFORM pg_temp.check((SELECT count(*) FROM ops.gate_events) = v_before + 4
                        AND (SELECT count(*) FROM ops.gate_events WHERE gate_key = 'autorun_approved' AND result = 'fail'
                               AND dispatch_id IN (v_claimed, v_promote, v_push, v_scaffold)) = 4, 'd four fail rows');
  RAISE NOTICE 'ok   d pass refused without, unknown, non-pending, promote/push/scaffold dispatch; fail records';
END $$;

-- e. _autorun_approved
DO $$
DECLARE v_none uuid := pg_temp.dispatch('addition', 't0039 e none');
        v_before uuid := pg_temp.dispatch('addition', 't0039 e before');
        v_after uuid := pg_temp.dispatch('investigation', 't0039 e after');
        v_revoked uuid := pg_temp.dispatch('modification', 't0039 e revoked');
        v_again uuid := pg_temp.dispatch('repair', 't0039 e again');
        v_eq_fail uuid := pg_temp.dispatch('docs', 't0039 e equal fail');
        v_eq_pass uuid := pg_temp.dispatch('docs', 't0039 e equal pass');
        v_chore uuid := pg_temp.dispatch('chore', 't0039 e chore');
        v_promote uuid := pg_temp.dispatch('promote', 't0039 e promote');
BEGIN
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_none), 'e no gate: false');
  PERFORM pg_temp.check(NOT ops._autorun_approved(gen_random_uuid()), 'e unknown dispatch: false');
  PERFORM pg_temp.gate(v_before, 'pass', interval '-1 minute');
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_before), 'e pass before created_at: false');
  PERFORM pg_temp.gate(v_before, 'pass', interval '0');
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_before), 'e pass at created_at: false');
  PERFORM pg_temp.gate(v_after, 'pass', interval '1 minute');
  PERFORM pg_temp.check(ops._autorun_approved(v_after), 'e pass after created_at: true');
  PERFORM pg_temp.gate(v_revoked, 'pass', interval '1 minute');
  PERFORM pg_temp.gate(v_revoked, 'fail', interval '2 minutes');
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_revoked), 'e pass then fail: false');
  PERFORM pg_temp.gate(v_again, 'fail', interval '1 minute');
  PERFORM pg_temp.gate(v_again, 'pass', interval '2 minutes');
  PERFORM pg_temp.check(ops._autorun_approved(v_again), 'e fail then pass: true');
  -- equal at: the higher id wins
  PERFORM pg_temp.gate(v_eq_fail, 'pass', interval '3 minutes');
  PERFORM pg_temp.gate(v_eq_fail, 'fail', interval '3 minutes');
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_eq_fail), 'e equal at, fail has the higher id: false');
  PERFORM pg_temp.gate(v_eq_pass, 'fail', interval '3 minutes');
  PERFORM pg_temp.gate(v_eq_pass, 'pass', interval '3 minutes');
  PERFORM pg_temp.check(ops._autorun_approved(v_eq_pass), 'e equal at, pass has the higher id: true');
  -- another gate_key, or another dispatch's gate, does not count
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT id, pg_temp.id('s'), 'prod_apply_approved', 'pass', 't0039 other key', created_at + interval '5 minutes'
    FROM ops.dispatches WHERE id = v_none;
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_none), 'e another gate_key: false');
  PERFORM pg_temp.gate(v_after, 'fail', interval '-5 minutes');
  PERFORM pg_temp.check(ops._autorun_approved(v_after) AND NOT ops._autorun_approved(v_none), 'e gates stay per dispatch');
  -- the type must be autorun-allowed when asked
  PERFORM pg_temp.gate(v_chore, 'pass', interval '1 minute');
  PERFORM pg_temp.check(ops._autorun_approved(v_chore), 'e chore pass: true');
  UPDATE ops.dispatch_types SET autorun_allowed = false WHERE type = 'chore';
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_chore), 'e chore pass with the type no longer allowed: false');
  UPDATE ops.dispatch_types SET autorun_allowed = true WHERE type = 'chore';
  PERFORM pg_temp.check(ops._autorun_approved(v_chore), 'e chore allowed again: true');
  -- a pass row on a promote (only possible by direct insert) does not approve
  PERFORM pg_temp.gate(v_promote, 'pass', interval '1 minute');
  PERFORM pg_temp.check(NOT ops._autorun_approved(v_promote), 'e promote with a pass row: false');
  RAISE NOTICE 'ok   e _autorun_approved: none, before/at, after, revoked, re-approved, equal at by id, type allowed';
END $$;

-- f. claim_dispatch with an 'autorun:' agent session
DO $$
DECLARE v_d uuid := pg_temp.dispatch('addition', 't0039 f');
        v_r uuid := pg_temp.dispatch('addition', 't0039 f revoked');
        v_plain uuid := pg_temp.dispatch('addition', 't0039 f plain');
        v_promote uuid := pg_temp.dispatch('promote', 't0039 f promote');
        v_x uuid := gen_random_uuid(); e text;
BEGIN
  e := pg_temp.claim_err(v_d, 'autorun:t0039');
  PERFORM pg_temp.check(e = pg_temp.autorun_msg(v_d), 'f unapproved autorun claim refused: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(v_d) = 'pending', 'f unapproved: still pending');
  PERFORM pg_temp.gate(v_d, 'pass', interval '1 minute');
  PERFORM pg_temp.check(pg_temp.claim_err(v_d, 'autorun:t0039') IS NULL, 'f approved autorun claim succeeds');
  PERFORM pg_temp.check((SELECT status = 'claimed' AND claimed_by = 'autorun:t0039' FROM ops.dispatches WHERE id = v_d),
                        'f claimed by the autorun agent');
  e := pg_temp.claim_err(v_d, 'autorun:t0039');
  PERFORM pg_temp.check(e = 'P0001 dispatch ' || v_d || ' is not pending', 'f claimed: P0001 not pending: ' || coalesce(e, 'success'));
  e := pg_temp.claim_err(v_x, 'autorun:t0039');
  PERFORM pg_temp.check(e = 'P0001 dispatch ' || v_x || ' is not pending', 'f unknown: P0001 not pending: ' || coalesce(e, 'success'));

  PERFORM pg_temp.gate(v_r, 'pass', interval '1 minute');
  PERFORM pg_temp.gate(v_r, 'fail', interval '2 minutes');
  e := pg_temp.claim_err(v_r, 'autorun:t0039');
  PERFORM pg_temp.check(e = pg_temp.autorun_msg(v_r), 'f revoked autorun claim refused: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(v_r) = 'pending', 'f revoked: still pending');

  -- any other agent session claims as before
  PERFORM pg_temp.check(pg_temp.claim_err(v_plain, 't0039-agent') IS NULL
                        AND pg_temp.status(v_plain) = 'claimed', 'f non-autorun agent claims an unapproved dispatch');
  PERFORM pg_temp.check(pg_temp.claim_err(v_r, 'claude-code:1:x') IS NULL, 'f non-autorun agent claims a revoked dispatch');
  e := pg_temp.claim_err(v_promote, 't0039-agent');
  PERFORM pg_temp.check(e = '23514 promote dispatch ' || v_promote
                            || ' has no current prod_apply_approved pass recorded after its creation; it stays pending',
                        'f unapproved promote keeps its own message: ' || coalesce(e, 'success'));
  e := pg_temp.claim_err(v_promote, 'autorun:t0039');
  PERFORM pg_temp.check(e = pg_temp.autorun_msg(v_promote), 'f autorun on a promote refused: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(v_promote) = 'pending', 'f promote still pending');
  e := pg_temp.err(format('SELECT ops.claim_dispatch(%L, NULL)', v_promote));
  PERFORM pg_temp.check(e = 'P0001 agent session id required', 'f null agent session: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   f autorun claim: refused unapproved and revoked, claims approved; other agents and promote as before';
END $$;

-- g. autorun_state
DO $$
DECLARE v_g1 uuid := pg_temp.dispatch('addition', 't0039 g1', 'cb', 50);
        v_g2 uuid := pg_temp.dispatch('investigation', 't0039 g2', 'cb', 10);
        v_g3 uuid := pg_temp.dispatch('docs', 't0039 g3', 'cb', 90);
        v_none uuid := pg_temp.dispatch('addition', 't0039 g none', 'cb', 1);
        v_rev uuid := pg_temp.dispatch('addition', 't0039 g revoked', 'cb', 1);
        v_promote uuid := pg_temp.dispatch('promote', 't0039 g promote', 'cb', 1);
        v_claim uuid := pg_temp.dispatch('addition', 't0039 g claimed', 'cb', 1);
        s jsonb; c jsonb; v_active integer;
BEGIN
  PERFORM pg_temp.gate(v_g1, 'pass', interval '1 minute');
  PERFORM pg_temp.gate(v_g2, 'pass', interval '2 minutes');
  PERFORM pg_temp.gate(v_g3, 'fail', interval '1 minute');
  PERFORM pg_temp.gate(v_g3, 'pass', interval '3 minutes');
  PERFORM pg_temp.gate(v_rev, 'pass', interval '1 minute');
  PERFORM pg_temp.gate(v_rev, 'fail', interval '2 minutes');
  PERFORM pg_temp.gate(v_promote, 'pass', interval '1 minute');
  PERFORM pg_temp.gate(v_claim, 'pass', interval '1 minute');

  s := ops.autorun_state();
  PERFORM pg_temp.check((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(s) k)
                        = ARRAY['active_claims', 'at', 'candidates', 'usage'], 'g keys: ' || s::text);
  PERFORM pg_temp.check((s->>'at')::timestamptz = now(), 'g at = now()');
  PERFORM pg_temp.check(jsonb_typeof(s->'usage') IN ('object', 'null'), 'g usage is an object or null');
  PERFORM pg_temp.check(s->'usage' = coalesce((SELECT to_jsonb(u) FROM ops.usage_now() u), 'null'::jsonb), 'g usage = usage_now');
  PERFORM pg_temp.check(jsonb_typeof(s->'candidates') = 'array' AND jsonb_typeof(s->'active_claims') = 'number',
                        'g candidates array, active_claims number');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'candidates') x WHERE x ? 'prompt'), 'g no prompt key');
  SELECT jsonb_agg(x ORDER BY o) INTO c FROM jsonb_array_elements(s->'candidates') WITH ORDINALITY t(x, o)
   WHERE x->>'node_path' = 'global.t0039a.cb';
  PERFORM pg_temp.check(jsonb_array_length(c) = 4, 'g four cb candidates: ' || coalesce(c::text, 'none'));
  PERFORM pg_temp.check((SELECT array_agg((x->>'id')::uuid ORDER BY o) FROM jsonb_array_elements(c) WITH ORDINALITY t(x, o))
                        = ARRAY[v_claim, v_g2, v_g1, v_g3], 'g candidates by priority: ' || c::text);
  PERFORM pg_temp.check(c->1 = jsonb_build_object('id', v_g2, 'dispatch_type', 'investigation', 'title', 't0039 g2',
                                                  'node_path', 'global.t0039a.cb', 'priority', 10,
                                                  'created_at', (SELECT created_at FROM ops.dispatches WHERE id = v_g2),
                                                  'approved_at', (SELECT created_at + interval '2 minutes' FROM ops.dispatches WHERE id = v_g2)),
                        'g candidate shape: ' || (c->1)::text);
  PERFORM pg_temp.check((c->3->>'approved_at')::timestamptz = (SELECT created_at + interval '3 minutes' FROM ops.dispatches WHERE id = v_g3),
                        'g approved_at is the deciding row');
  -- every candidate anywhere is pending and approved
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'candidates') x
                                     WHERE NOT ops._autorun_approved((x->>'id')::uuid)
                                        OR pg_temp.status((x->>'id')::uuid) <> 'pending'), 'g all candidates pending and approved');
  PERFORM pg_temp.check((s->>'active_claims')::integer = (SELECT count(*) FROM ops.dispatches WHERE status = 'claimed'),
                        'g active_claims = claimed count');

  -- a claim: one more active claim, one fewer candidate
  v_active := (s->>'active_claims')::integer;
  PERFORM pg_temp.check(pg_temp.claim_err(v_claim, 'autorun:t0039') IS NULL, 'g autorun claim');
  s := ops.autorun_state();
  PERFORM pg_temp.check((s->>'active_claims')::integer = v_active + 1, 'g active_claims rises by one');
  PERFORM pg_temp.check((SELECT array_agg((x->>'id')::uuid ORDER BY o) FROM jsonb_array_elements(s->'candidates') WITH ORDINALITY t(x, o)
                          WHERE x->>'node_path' = 'global.t0039a.cb') = ARRAY[v_g2, v_g1, v_g3], 'g claimed dispatch leaves the candidates');
  RAISE NOTICE 'ok   g autorun_state: approved pending candidates by priority, approved_at, no prompt, active_claims, usage';
END $$;

ROLLBACK;

-- h. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'gate_events', (SELECT count(*) FROM ops.gate_events),
    'autorun_allowed', (SELECT array_agg(type ORDER BY type) FROM ops.dispatch_types WHERE autorun_allowed)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   h no leftover rows; 0039 tests passed';
END $$;
