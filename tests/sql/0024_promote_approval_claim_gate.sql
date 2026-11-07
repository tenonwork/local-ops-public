-- tests/sql/0024_promote_approval_claim_gate.sql
-- Tests for migrations/0024_promote_approval_claim_gate.sql. Run as the schema owner against a non-production
-- database where 0024 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0024_promote_approval_claim_gate.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0024a, component ca and session through the
-- node-keyed writers, inserts its own approval rows into ops.gate_events, and asserts only on rows it creates (plus
-- catalog state 0024 establishes). Within the transaction now() is fixed, so every test dispatch has the same
-- created_at and gate rows are dated relative to it.

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
    'gate_events', (SELECT count(*) FROM ops.gate_events)))::text, false);
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

-- a new pending dispatch of type p_type on global.t0024a.ca
CREATE FUNCTION pg_temp.dispatch(p_type text, p_title text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.create_dispatch(p_node_path => 'global.t0024a.ca'::public.ltree, p_dispatch_type => p_type,
                              p_title => p_title, p_prompt => 'p', p_session => pg_temp.id('s'))).id;
$$;

-- an approval row for p_dispatch, dated p_offset after (or before, if negative) its created_at
CREATE FUNCTION pg_temp.gate(p_dispatch uuid, p_result text, p_offset interval) RETURNS void LANGUAGE sql AS $$
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT d.id, pg_temp.id('s'), 'prod_apply_approved', p_result::ops.gate_result, 't0024 ' || p_result, d.created_at + p_offset
    FROM ops.dispatches d WHERE d.id = p_dispatch;
$$;

CREATE FUNCTION pg_temp.listed(p_dispatch uuid) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM ops.get_pending('global.t0024a.ca'::public.ltree) WHERE id = p_dispatch);
$$;

CREATE FUNCTION pg_temp.status(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT status::text FROM ops.dispatches WHERE id = p_dispatch;
$$;

CREATE FUNCTION pg_temp.claim_err(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.claim_dispatch(%L, %L)', p_dispatch, 't0024-agent'));
$$;

-- asserts p_dispatch is an unapproved pending promote: not listed, claim refused 23514 with the message, still pending
CREATE FUNCTION pg_temp.unapproved(p_dispatch uuid, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text;
BEGIN
  PERFORM pg_temp.check(NOT pg_temp.listed(p_dispatch), p_what || ': not listed by get_pending');
  e := pg_temp.claim_err(p_dispatch);
  PERFORM pg_temp.check(e = '23514 promote dispatch ' || p_dispatch
                            || ' has no current prod_apply_approved pass recorded after its creation; it stays pending',
                        p_what || ': claim refused 23514 with the message, got ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(p_dispatch) = 'pending', p_what || ': status still pending');
END $$;

-- 0. fixtures: project t0024a, component ca, a session on ca
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  PERFORM pg_temp.check((SELECT commit_policy = 'none' AND active FROM ops.dispatch_types WHERE type = 'promote'),
                        'promote dispatch type exists, active, commit_policy none');
  p := ops.create_project('global'::public.ltree, 't0024a', 'T0024 A');
  c := ops.create_component('global.t0024a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0024a.ca'::public.ltree,
                                                     p_kind => 'planning')::text, true);
  RAISE NOTICE 'ok   0 fixtures (t0024a/ca, session)';
END $$;

-- a. catalog 0024 establishes (bounded: asserted while 0024 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_grantees text[]; v_owner text;
BEGIN
  IF NOT (newest >= '0024' AND newest < '0025') THEN
    RAISE NOTICE 'skip a catalog of 0024 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND provolatile = 's'
                                AND pg_get_function_result(oid) = 'boolean' AND pg_get_userbyid(proowner) = v_owner
                           FROM pg_proc WHERE oid = to_regprocedure('ops._promote_approved(uuid)')),
                        '_promote_approved: STABLE SECURITY DEFINER boolean, search_path ops, pg_temp, owner of ops');
  SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END), '{}')
    INTO v_grantees
    FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'ops._promote_approved(uuid)'::regprocedure AND a.grantee <> p.proowner;
  PERFORM pg_temp.check(v_grantees = '{}'::text[]
                        AND NOT has_function_privilege('ops_executor', 'ops._promote_approved(uuid)', 'EXECUTE')
                        AND NOT has_function_privilege('ops_planner', 'ops._promote_approved(uuid)', 'EXECUTE')
                        AND NOT has_function_privilege('public', 'ops._promote_approved(uuid)', 'EXECUTE'),
                        '_promote_approved owner-only, grantees ' || v_grantees::text);
  PERFORM pg_temp.check(obj_description('ops._promote_approved(uuid)'::regprocedure, 'pg_proc') LIKE 'Release 3 (34502bc1): %',
                        '_promote_approved comment');

  PERFORM pg_temp.check((SELECT proargnames = ARRAY['p_node_path'] AND proargtypes::text = 'public.ltree'::regtype::oid::text
                                AND pronargdefaults = 0 AND prosecdef AND provolatile = 's'
                                AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND proretset AND prorettype = 'ops.dispatches'::regtype
                           FROM pg_proc WHERE oid = to_regprocedure('ops.get_pending(public.ltree)')),
                        'get_pending signature, result, secdef, search_path, owner');
  PERFORM pg_temp.check(has_function_privilege('ops_executor', 'ops.get_pending(public.ltree)', 'EXECUTE')
                        AND NOT has_function_privilege('ops_planner', 'ops.get_pending(public.ltree)', 'EXECUTE')
                        AND NOT has_function_privilege('public', 'ops.get_pending(public.ltree)', 'EXECUTE'),
                        'get_pending ACL: executor only');
  PERFORM pg_temp.check(obj_description('ops.get_pending(public.ltree)'::regprocedure, 'pg_proc')
                        = 'M5b release 1 (43992f43): node-keyed get_pending; exactly the component at the path.'
                          ' Release 3 (34502bc1): a promote dispatch is listed only with a current prod_apply_approved pass.',
                        'get_pending comment = 0018 comment + release 3 sentence');

  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_id uuid, p_agent_session text' AND prosecdef
                                AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND NOT proretset AND prorettype = 'void'::regtype
                           FROM pg_proc WHERE oid = to_regprocedure('ops.claim_dispatch(uuid, text)')),
                        'claim_dispatch signature, result, secdef, search_path, owner');
  PERFORM pg_temp.check(has_function_privilege('ops_executor', 'ops.claim_dispatch(uuid, text)', 'EXECUTE')
                        AND NOT has_function_privilege('ops_planner', 'ops.claim_dispatch(uuid, text)', 'EXECUTE')
                        AND NOT has_function_privilege('public', 'ops.claim_dispatch(uuid, text)', 'EXECUTE'),
                        'claim_dispatch ACL: executor only');
  PERFORM pg_temp.check(obj_description('ops.claim_dispatch(uuid, text)'::regprocedure, 'pg_proc') LIKE 'Release 3 (34502bc1): %',
                        'claim_dispatch comment');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                           AND proname IN ('get_pending', 'claim_dispatch', '_promote_approved')) = 3,
                        'one overload each of get_pending, claim_dispatch, _promote_approved');

  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'record_gate',
                                'resolve_context', 'tick'],
                        'ops_executor EXECUTE set unchanged');
  RAISE NOTICE 'ok   a catalog: _promote_approved owner-only; get_pending / claim_dispatch signature, ACL, comments; executor set';
END $$;

-- b. an unapproved promote: not listed, claim refused 23514, status still pending
DO $$
DECLARE v_d uuid := pg_temp.dispatch('promote', 't0024 b');
BEGIN
  PERFORM set_config('ops_test.b', v_d::text, true);
  PERFORM pg_temp.unapproved(v_d, 'b no gate');
  RAISE NOTICE 'ok   b unapproved promote: hidden, claim refused 23514, stays pending';
END $$;

-- c. a pass gate dated before created_at does not approve (nor one exactly at created_at)
DO $$
DECLARE v_d uuid := pg_temp.dispatch('promote', 't0024 c');
BEGIN
  PERFORM pg_temp.gate(v_d, 'pass', interval '-1 minute');
  PERFORM pg_temp.unapproved(v_d, 'c pass before created_at');
  PERFORM pg_temp.gate(v_d, 'pass', interval '0');
  PERFORM pg_temp.unapproved(v_d, 'c pass at created_at');
  RAISE NOTICE 'ok   c pass gates at or before created_at do not approve';
END $$;

-- d. a pass gate after created_at: listed, claim succeeds
DO $$
DECLARE v_d uuid := pg_temp.dispatch('promote', 't0024 d');
BEGIN
  PERFORM set_config('ops_test.d', v_d::text, true);
  PERFORM pg_temp.gate(v_d, 'pass', interval '1 minute');
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'd approved promote listed');
  PERFORM pg_temp.check(pg_temp.claim_err(v_d) IS NULL, 'd approved promote claimable');
  PERFORM pg_temp.check((SELECT status = 'claimed' AND claimed_by = 't0024-agent' FROM ops.dispatches WHERE id = v_d),
                        'd claimed by the agent');
  PERFORM pg_temp.check(NOT pg_temp.listed(v_d), 'd claimed promote no longer listed');
  -- the unapproved b is still hidden beside it
  PERFORM pg_temp.check(NOT pg_temp.listed(pg_temp.id('b')), 'd: unapproved b still hidden');
  RAISE NOTICE 'ok   d pass after created_at: listed and claimed';
END $$;

-- e. the latest gate wins: pass then fail (revoked), fail then pass (approved), equal at: the higher id wins
DO $$
DECLARE v_d uuid := pg_temp.dispatch('promote', 't0024 e');
BEGIN
  PERFORM pg_temp.gate(v_d, 'pass', interval '1 minute');
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'e pass: listed');
  PERFORM pg_temp.gate(v_d, 'fail', interval '2 minutes');
  PERFORM pg_temp.unapproved(v_d, 'e pass then later fail');
  PERFORM pg_temp.gate(v_d, 'pass', interval '3 minutes');
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'e fail then later pass: listed');
  -- equal at: pass (lower id) then fail (higher id) -> revoked
  PERFORM pg_temp.gate(v_d, 'pass', interval '4 minutes');
  PERFORM pg_temp.gate(v_d, 'fail', interval '4 minutes');
  PERFORM pg_temp.check((SELECT count(DISTINCT at) = 1 AND count(*) = 2 FROM ops.gate_events
                          WHERE dispatch_id = v_d AND at = (SELECT created_at + interval '4 minutes' FROM ops.dispatches WHERE id = v_d)),
                        'e two gates with equal at');
  PERFORM pg_temp.unapproved(v_d, 'e equal at, fail has the higher id');
  -- equal at: fail (lower id) then pass (higher id) -> approved
  PERFORM pg_temp.gate(v_d, 'fail', interval '5 minutes');
  PERFORM pg_temp.gate(v_d, 'pass', interval '5 minutes');
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'e equal at, pass has the higher id: listed');
  -- a gate for another dispatch, or another gate_key, does not count
  PERFORM pg_temp.gate(pg_temp.id('b'), 'fail', interval '6 minutes');
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT id, pg_temp.id('s'), 'prod_apply', 'fail', 't0024 other key', created_at + interval '6 minutes'
    FROM ops.dispatches WHERE id = v_d;
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'e other dispatch / other gate_key ignored: still listed');
  PERFORM pg_temp.check(pg_temp.claim_err(v_d) IS NULL AND pg_temp.status(v_d) = 'claimed', 'e approved: claimed');
  -- a pass on b for another gate_key does not approve b
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT id, pg_temp.id('s'), 'prod_apply', 'pass', 't0024 other key', created_at + interval '7 minutes'
    FROM ops.dispatches WHERE id = pg_temp.id('b');
  PERFORM pg_temp.unapproved(pg_temp.id('b'), 'e b with a pass on another gate_key');
  RAISE NOTICE 'ok   e latest gate wins: revocation, re-approval, equal at by id; other dispatches and keys ignored';
END $$;

-- f. a non-promote dispatch on the same component is listed and claimable with no gate
DO $$
DECLARE v_d uuid := pg_temp.dispatch('modification', 't0024 f');
BEGIN
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.gate_events WHERE dispatch_id = v_d), 'f no gate');
  PERFORM pg_temp.check(pg_temp.listed(v_d), 'f modification listed');
  PERFORM pg_temp.check(pg_temp.claim_err(v_d) IS NULL AND pg_temp.status(v_d) = 'claimed', 'f modification claimed');
  RAISE NOTICE 'ok   f non-promote dispatch listed and claimable without a gate';
END $$;

-- g. claim on a non-pending row still raises P0001 'dispatch % is not pending'
DO $$
DECLARE v_d uuid := pg_temp.id('d'); v_x uuid := gen_random_uuid(); e text;
BEGIN
  e := pg_temp.claim_err(v_d);
  PERFORM pg_temp.check(e = 'P0001 dispatch ' || v_d || ' is not pending', 'g claimed promote: ' || coalesce(e, 'success'));
  e := pg_temp.claim_err(v_x);
  PERFORM pg_temp.check(e = 'P0001 dispatch ' || v_x || ' is not pending', 'g unknown id: ' || coalesce(e, 'success'));
  e := pg_temp.err(format('SELECT ops.claim_dispatch(%L, NULL)', pg_temp.id('b')));
  PERFORM pg_temp.check(e = 'P0001 agent session id required', 'g null agent session: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(pg_temp.id('b')) = 'pending', 'g b still pending');
  RAISE NOTICE 'ok   g non-pending rows: P0001 dispatch %% is not pending; agent session still required';
END $$;

ROLLBACK;

-- h. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'gate_events', (SELECT count(*) FROM ops.gate_events)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   h no leftover rows; 0024 tests passed';
END $$;
