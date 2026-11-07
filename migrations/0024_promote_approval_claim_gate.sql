-- 0024_promote_approval_claim_gate
-- Dispatch 69fa92dc. Release 3, migration 1 of 4 (0024-0027 are promoted together as one set by a separate promote
-- dispatch after planner review). Decision 34502bc1 (2026-10-13): promote dispatch 81c6897b was claimed with no
-- approval gate, migrate.ts promote refused it at the approval step, and failing the dispatch burned it. The fix is
-- database-side:
--   * ops._promote_approved(dispatch) (owner-only): true iff the most recent ops.gate_events row for the dispatch
--     with gate_key 'prod_apply_approved' and at > the dispatch's created_at (ordered by at, then id) has result
--     'pass' and overridden false; false when there is no such row. This is the rule of checkApproval in
--     scripts/migrate.ts minus the versions= set check, which stays in migrate.ts only. A later fail row (a
--     revocation) makes the dispatch unapproved again.
--   * ops.get_pending(ltree) lists a promote dispatch only when it is approved; other types are unaffected.
--   * ops.claim_dispatch(uuid, text) refuses a pending, unapproved promote with 23514 (check_violation) and leaves it
--     pending; a non-pending row still raises P0001 'dispatch % is not pending'.
-- Replaced functions keep signature, result, owner, SECURITY DEFINER, search_path and ACL (step 5 checks that).

BEGIN;

-- ── 1. guard; catalog state of the functions to replace
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0023_node_anchor_drop_project_row' THEN
    RAISE EXCEPTION '0024: expected newest ledger version 0023_node_anchor_drop_project_row, found %', v_newest;
  END IF;
  IF to_regprocedure('ops.get_pending(public.ltree)') IS NULL THEN
    RAISE EXCEPTION '0024: ops.get_pending(public.ltree) does not exist';
  END IF;
  IF to_regprocedure('ops.claim_dispatch(uuid, text)') IS NULL THEN
    RAISE EXCEPTION '0024: ops.claim_dispatch(uuid, text) does not exist';
  END IF;
  IF to_regprocedure('ops._promote_approved(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION '0024: ops._promote_approved(uuid) already exists';
  END IF;

  PERFORM set_config('ops_m0024.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text))
      FROM pg_proc p
     WHERE p.oid IN ('ops.get_pending(public.ltree)'::regprocedure, 'ops.claim_dispatch(uuid, text)'::regprocedure))::text,
    true);
  PERFORM set_config('ops_m0024.get_pending_comment',
    obj_description('ops.get_pending(public.ltree)'::regprocedure, 'pg_proc'), true);
  PERFORM set_config('ops_m0024.executor_fns', (
    SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
     WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))::text, true);
END $$;

-- ── 2. the approval rule (34502bc1 rule 1), owner-only
CREATE FUNCTION ops._promote_approved(p_dispatch uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT coalesce((
    SELECT g.result = 'pass' AND NOT g.overridden
      FROM ops.gate_events g JOIN ops.dispatches d ON d.id = g.dispatch_id
     WHERE g.dispatch_id = p_dispatch AND g.gate_key = 'prod_apply_approved' AND g.at > d.created_at
     ORDER BY g.at DESC, g.id DESC
     LIMIT 1), false);
$$;
REVOKE ALL ON FUNCTION ops._promote_approved(uuid) FROM PUBLIC;
COMMENT ON FUNCTION ops._promote_approved(uuid) IS
  'Release 3 (34502bc1): owner-only; true iff the latest prod_apply_approved gate for the dispatch after its created_at (by at, then id) is an unoverridden pass.';

-- ── 3. get_pending (0018 3b): a promote dispatch is listed only when approved
CREATE OR REPLACE FUNCTION ops.get_pending(p_node_path public.ltree)
RETURNS SETOF ops.dispatches LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components := ops._component(p_node_path);
BEGIN
  RETURN QUERY SELECT * FROM ops.dispatches
   WHERE component_id = c.id AND status = 'pending'
     AND (dispatch_type <> 'promote' OR ops._promote_approved(id))
   ORDER BY priority, created_at;
END $$;
DO $$ BEGIN
  EXECUTE format('COMMENT ON FUNCTION ops.get_pending(public.ltree) IS %L',
                 current_setting('ops_m0024.get_pending_comment')
                 || ' Release 3 (34502bc1): a promote dispatch is listed only with a current prod_apply_approved pass.');
END $$;

-- ── 4. claim_dispatch (0001): an unapproved promote is refused and stays pending
CREATE OR REPLACE FUNCTION ops.claim_dispatch(p_id uuid, p_agent_session text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF p_agent_session IS NULL THEN RAISE EXCEPTION 'agent session id required'; END IF;
  UPDATE ops.dispatches SET status = 'claimed', claimed_by = p_agent_session, claimed_at = now()
   WHERE id = p_id AND status = 'pending' AND (dispatch_type <> 'promote' OR ops._promote_approved(id));
  IF NOT FOUND THEN
    IF EXISTS (SELECT 1 FROM ops.dispatches WHERE id = p_id AND status = 'pending' AND dispatch_type = 'promote') THEN
      RAISE EXCEPTION 'promote dispatch % has no current prod_apply_approved pass recorded after its creation; it stays pending',
        p_id USING ERRCODE = 'check_violation';
    END IF;
    RAISE EXCEPTION 'dispatch % is not pending', p_id;
  END IF;
END $$;
COMMENT ON FUNCTION ops.claim_dispatch(uuid, text) IS
  'Release 3 (34502bc1): claims a pending dispatch; a promote dispatch without a current prod_apply_approved pass is refused (23514) and stays pending.';

-- ── 5. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0024.fn_before')::jsonb; v_bad text; v_grantees text[];
BEGIN
  SELECT string_agg(b.key, ', ') INTO v_bad
    FROM jsonb_each(v_before) b LEFT JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE p.oid IS NULL
      OR jsonb_build_object('args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text,
                            'result', pg_get_function_result(p.oid), 'secdef', p.prosecdef, 'config', p.proconfig,
                            'owner', pg_get_userbyid(p.proowner), 'acl', p.proacl::text)
         IS DISTINCT FROM b.value;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0024: signature, owner, security, search_path or ACL changed: %', v_bad;
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_before)) <> 2 THEN
    RAISE EXCEPTION '0024: snapshot does not hold both replaced functions';
  END IF;
  IF obj_description('ops.get_pending(public.ltree)'::regprocedure, 'pg_proc')
     IS DISTINCT FROM current_setting('ops_m0024.get_pending_comment')
                      || ' Release 3 (34502bc1): a promote dispatch is listed only with a current prod_apply_approved pass.'
     OR obj_description('ops.get_pending(public.ltree)'::regprocedure, 'pg_proc') NOT LIKE 'M5b release 1 (%' THEN
    RAISE EXCEPTION '0024: get_pending comment is %', obj_description('ops.get_pending(public.ltree)'::regprocedure, 'pg_proc');
  END IF;
  IF obj_description('ops.claim_dispatch(uuid, text)'::regprocedure, 'pg_proc') NOT LIKE 'Release 3 (34502bc1): %'
     OR obj_description('ops._promote_approved(uuid)'::regprocedure, 'pg_proc') NOT LIKE 'Release 3 (34502bc1): %' THEN
    RAISE EXCEPTION '0024: claim_dispatch or _promote_approved comment does not start ''Release 3 (34502bc1): ''';
  END IF;
  IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND provolatile = 's'
                 AND pg_get_function_result(oid) = 'boolean'
            FROM pg_proc WHERE oid = 'ops._promote_approved(uuid)'::regprocedure) THEN
    RAISE EXCEPTION '0024: _promote_approved is not STABLE SECURITY DEFINER boolean with search_path ops, pg_temp';
  END IF;
  SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END), '{}')
    INTO v_grantees
    FROM pg_proc p, aclexplode(p.proacl) a
   WHERE p.oid = 'ops._promote_approved(uuid)'::regprocedure AND a.grantee <> p.proowner;
  IF v_grantees <> '{}'::text[]
     OR has_function_privilege('ops_executor', 'ops._promote_approved(uuid)', 'EXECUTE')
     OR has_function_privilege('ops_planner', 'ops._promote_approved(uuid)', 'EXECUTE')
     OR has_function_privilege('public', 'ops._promote_approved(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION '0024: _promote_approved is executable beyond its owner (grantees %)', v_grantees;
  END IF;
  IF (SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
       WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
     IS DISTINCT FROM ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'record_gate',
                            'resolve_context', 'tick']
     OR current_setting('ops_m0024.executor_fns') IS DISTINCT FROM
        ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'record_gate', 'resolve_context', 'tick']::text THEN
    RAISE EXCEPTION '0024: ops_executor EXECUTE set changed (before %)', current_setting('ops_m0024.executor_fns');
  END IF;
  RAISE NOTICE '0024 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0024_promote_approval_claim_gate');

COMMIT;
