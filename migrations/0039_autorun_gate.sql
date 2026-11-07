-- 0039_autorun_gate
-- Dispatch 57b83b04. Autorun gate (05022018). Staged on 0038; promoted later with the set.
-- No protocol_rules change. The database side of autonomous execution:
--   * ops.dispatch_types.autorun_allowed (default false): the types that may run without the operator; true for
--     investigation, addition, modification, repair, chore, docs; never promote, push, scaffold. A new type is excluded
--     until opted in.
--   * ops._autorun_approved(dispatch) (owner-only): true iff the dispatch's type is autorun-allowed and the most recent
--     ops.gate_events row for it with gate_key 'autorun_approved' and at > its created_at (by at, then id) is an
--     unoverridden pass. The rule of ops._promote_approved (0024); a later fail row revokes.
--   * ops.record_gate: 'autorun_approved', like 'prod_apply_approved', is recorded only by an ops_planner session; a
--     pass needs an existing, pending dispatch of an autorun-allowed type, a fail (revocation) needs a dispatch. Every
--     other key unchanged; the prod_apply_approved message is unchanged.
--   * ops.claim_dispatch: an agent session starting 'autorun:' claims only a dispatch whose autorun approval is current
--     (23514 otherwise, the dispatch stays pending); any other agent session claims as before.
--   * ops.autorun_state() (planner and executor): facts for the watcher (approved pending candidates, active claims,
--     the usage_now row); no thresholds, never a prompt.
-- record_gate and claim_dispatch keep signature, result, owner, SECURITY DEFINER, search_path and ACL (step 7 checks).
-- The executor's SELECT set is unchanged; its EXECUTE set gains autorun_state.

BEGIN;

-- ── 1. guard; snapshots for step 7
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0038_usage_snapshots' THEN
    RAISE EXCEPTION '0039: expected newest ledger version 0038_usage_snapshots, found %', v_newest;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.dispatch_types'::regclass AND attname = 'autorun_allowed'
                AND NOT attisdropped) THEN
    RAISE EXCEPTION '0039: ops.dispatch_types already has autorun_allowed';
  END IF;
  IF to_regprocedure('ops.autorun_state()') IS NOT NULL OR to_regprocedure('ops._autorun_approved(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION '0039: ops.autorun_state() or ops._autorun_approved(uuid) already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.gate_events WHERE gate_key = 'autorun_approved') THEN
    RAISE EXCEPTION '0039: gate_events already holds autorun_approved rows';
  END IF;
  IF to_regprocedure('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)') IS NULL
     OR to_regprocedure('ops.claim_dispatch(uuid, text)') IS NULL THEN
    RAISE EXCEPTION '0039: ops.record_gate or ops.claim_dispatch missing';
  END IF;

  PERFORM set_config('ops_m0039.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text))
      FROM pg_proc p
     WHERE p.oid IN ('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure,
                     'ops.claim_dispatch(uuid, text)'::regprocedure))::text, true);
  PERFORM set_config('ops_m0039.claim_comment',
    obj_description('ops.claim_dispatch(uuid, text)'::regprocedure, 'pg_proc'), true);
  PERFORM set_config('ops_m0039.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0039.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0039.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
END $$;

-- ── 2. which types may run without the operator
ALTER TABLE ops.dispatch_types ADD COLUMN autorun_allowed boolean NOT NULL DEFAULT false;
DO $$
DECLARE v_n integer;
BEGIN
  UPDATE ops.dispatch_types SET autorun_allowed = true
   WHERE type IN ('investigation', 'addition', 'modification', 'repair', 'chore', 'docs');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 6 THEN
    RAISE EXCEPTION '0039: expected 6 autorun-allowed dispatch types, updated %', v_n;
  END IF;
END $$;
COMMENT ON COLUMN ops.dispatch_types.autorun_allowed IS
  'Autorun gate (05022018): a dispatch of this type may run without the operator once the planner records autorun_approved (pass) on it. Default false: a new type is excluded until opted in; never promote, push, scaffold.';

-- ── 3. the approval rule, owner-only
CREATE FUNCTION ops._autorun_approved(p_dispatch uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT coalesce((
    SELECT g.result = 'pass' AND NOT g.overridden AND t.autorun_allowed
      FROM ops.gate_events g
      JOIN ops.dispatches d ON d.id = g.dispatch_id
      JOIN ops.dispatch_types t ON t.type = d.dispatch_type
     WHERE g.dispatch_id = p_dispatch AND g.gate_key = 'autorun_approved' AND g.at > d.created_at
     ORDER BY g.at DESC, g.id DESC
     LIMIT 1), false);
$$;
REVOKE ALL ON FUNCTION ops._autorun_approved(uuid) FROM PUBLIC;
COMMENT ON FUNCTION ops._autorun_approved(uuid) IS
  'Autorun gate (05022018): owner-only; true iff the dispatch''s type is autorun-allowed and the latest autorun_approved gate for it after its created_at (by at, then id) is an unoverridden pass.';

-- ── 4. record_gate (0013): autorun_approved is planner-only too; a pass needs a pending, autorun-allowed dispatch
CREATE OR REPLACE FUNCTION ops.record_gate(p_gate_key text, p_result ops.gate_result,
                                p_dispatch uuid DEFAULT NULL, p_session uuid DEFAULT NULL,
                                p_overridden boolean DEFAULT false,
                                p_override_by text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_id bigint; v_status text; v_type text; v_allowed boolean;
BEGIN
  IF p_gate_key IN ('prod_apply_approved', 'autorun_approved') AND session_user <> 'ops_planner' THEN
    RAISE EXCEPTION 'gate % may only be recorded by ops_planner (session user is %)', p_gate_key, session_user
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_gate_key = 'autorun_approved' THEN
    IF p_dispatch IS NULL THEN
      RAISE EXCEPTION 'gate autorun_approved needs a dispatch' USING ERRCODE = 'check_violation';
    END IF;
    IF p_result = 'pass' THEN
      SELECT d.status::text, d.dispatch_type, t.autorun_allowed INTO v_status, v_type, v_allowed
        FROM ops.dispatches d JOIN ops.dispatch_types t ON t.type = d.dispatch_type
       WHERE d.id = p_dispatch;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'gate autorun_approved: dispatch % does not exist', p_dispatch USING ERRCODE = 'check_violation';
      END IF;
      IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'gate autorun_approved: dispatch % is %, not pending', p_dispatch, v_status
          USING ERRCODE = 'check_violation';
      END IF;
      IF NOT v_allowed THEN
        RAISE EXCEPTION 'gate autorun_approved: dispatch % has type %, which is not autorun-allowed', p_dispatch, v_type
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;
  INSERT INTO ops.gate_events (gate_key, result, dispatch_id, session_id, overridden, override_by, reason)
  VALUES (p_gate_key, p_result, p_dispatch, p_session, p_overridden, p_override_by, p_reason)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
COMMENT ON FUNCTION ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text) IS
  'Records a gate event. prod_apply_approved (0013) and autorun_approved only from an ops_planner session (23514). Autorun gate (05022018): an autorun_approved pass needs an existing, pending dispatch of an autorun-allowed type; a fail (revocation) needs a dispatch.';

-- ── 5. claim_dispatch (0024): an 'autorun:' agent claims only a dispatch with a current autorun approval
CREATE OR REPLACE FUNCTION ops.claim_dispatch(p_id uuid, p_agent_session text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF p_agent_session IS NULL THEN RAISE EXCEPTION 'agent session id required'; END IF;
  UPDATE ops.dispatches SET status = 'claimed', claimed_by = p_agent_session, claimed_at = now()
   WHERE id = p_id AND status = 'pending' AND (dispatch_type <> 'promote' OR ops._promote_approved(id))
     AND (p_agent_session NOT LIKE 'autorun:%' OR ops._autorun_approved(id));
  IF NOT FOUND THEN
    IF p_agent_session LIKE 'autorun:%'
       AND EXISTS (SELECT 1 FROM ops.dispatches WHERE id = p_id AND status = 'pending') AND NOT ops._autorun_approved(p_id) THEN
      RAISE EXCEPTION 'dispatch % has no current autorun_approved pass or its type is not autorun-allowed; it stays pending',
        p_id USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM ops.dispatches WHERE id = p_id AND status = 'pending' AND dispatch_type = 'promote') THEN
      RAISE EXCEPTION 'promote dispatch % has no current prod_apply_approved pass recorded after its creation; it stays pending',
        p_id USING ERRCODE = 'check_violation';
    END IF;
    RAISE EXCEPTION 'dispatch % is not pending', p_id;
  END IF;
END $$;
DO $$ BEGIN
  EXECUTE format('COMMENT ON FUNCTION ops.claim_dispatch(uuid, text) IS %L',
                 current_setting('ops_m0039.claim_comment')
                 || ' Autorun gate (05022018): an agent session starting ''autorun:'' claims only a dispatch with a current autorun_approved pass and an autorun-allowed type (23514 otherwise; it stays pending).');
END $$;

-- ── 6. the watcher's state: facts only
CREATE FUNCTION ops.autorun_state()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT jsonb_build_object(
    'at', now(),
    'candidates', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', d.id, 'dispatch_type', d.dispatch_type, 'title', d.title, 'node_path', cn.path::text,
               'priority', d.priority, 'created_at', d.created_at, 'approved_at', g.at)
             ORDER BY d.priority, d.created_at, d.id)
        FROM ops.dispatches d
        JOIN ops.components c ON c.id = d.component_id
        JOIN ops.nodes cn ON cn.id = c.node_id
        JOIN LATERAL (SELECT g.at FROM ops.gate_events g
                       WHERE g.dispatch_id = d.id AND g.gate_key = 'autorun_approved' AND g.at > d.created_at
                       ORDER BY g.at DESC, g.id DESC LIMIT 1) g ON true
       WHERE d.status = 'pending' AND ops._autorun_approved(d.id)), '[]'::jsonb),
    'active_claims', (SELECT count(*)::integer FROM ops.dispatches WHERE status = 'claimed'),
    'usage', (SELECT to_jsonb(u) FROM ops.usage_now() u));
$$;
REVOKE ALL ON FUNCTION ops.autorun_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.autorun_state() TO ops_executor, ops_planner;
COMMENT ON FUNCTION ops.autorun_state() IS
  'Autorun gate (05022018): facts for the watcher: {at, candidates (pending dispatches with a current autorun approval, by priority then created_at; no prompt), active_claims (claimed dispatches, all nodes), usage (the usage_now row or null)}. Thresholds stay in the watcher.';

-- ── 7. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0039.fn_before')::jsonb;
        v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text;
BEGIN
  -- column and its six true rows
  IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                  WHERE a.attrelid = 'ops.dispatch_types'::regclass AND a.attname = 'autorun_allowed'
                    AND a.atttypid = 'boolean'::regtype AND a.attnotnull AND NOT a.attisdropped
                    AND pg_get_expr(d.adbin, d.adrelid) = 'false') THEN
    RAISE EXCEPTION '0039: ops.dispatch_types.autorun_allowed missing or not boolean NOT NULL DEFAULT false';
  END IF;
  IF (SELECT array_agg(type ORDER BY type) FROM ops.dispatch_types WHERE autorun_allowed)
     IS DISTINCT FROM ARRAY['addition', 'chore', 'docs', 'investigation', 'modification', 'repair'] THEN
    RAISE EXCEPTION '0039: autorun-allowed types are %', (SELECT array_agg(type ORDER BY type) FROM ops.dispatch_types WHERE autorun_allowed);
  END IF;

  -- replaced functions: signature, result, definer, search_path, owner, ACL as before
  SELECT string_agg(b.key, ', ') INTO v_bad
    FROM jsonb_each(v_before) b LEFT JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE p.oid IS NULL
      OR jsonb_build_object('args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text,
                            'result', pg_get_function_result(p.oid), 'secdef', p.prosecdef, 'config', p.proconfig,
                            'owner', pg_get_userbyid(p.proowner), 'acl', p.proacl::text)
         IS DISTINCT FROM b.value;
  IF v_bad IS NOT NULL OR (SELECT count(*) FROM jsonb_object_keys(v_before)) <> 2 THEN
    RAISE EXCEPTION '0039: signature, owner, security, search_path or ACL changed: %', coalesce(v_bad, 'snapshot incomplete');
  END IF;
  IF regexp_count(pg_get_functiondef('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure),
                  'session_user') <> 2 THEN
    RAISE EXCEPTION '0039: record_gate must hold exactly two session_user references';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
        AND proname IN ('record_gate', 'claim_dispatch', '_autorun_approved', 'autorun_state')) <> 4 THEN
    RAISE EXCEPTION '0039: expected one overload each of record_gate, claim_dispatch, _autorun_approved, autorun_state';
  END IF;

  -- new functions: owner, definer, search_path, volatility, result
  IF (SELECT count(*) FROM pg_proc p
       WHERE p.oid IN ('ops._autorun_approved(uuid)'::regprocedure, 'ops.autorun_state()'::regprocedure)
         AND p.prosecdef AND p.proconfig = ARRAY['search_path=ops, pg_temp'] AND p.provolatile = 's'
         AND pg_get_userbyid(p.proowner) = v_owner) <> 2
     OR pg_get_function_result('ops._autorun_approved(uuid)'::regprocedure) <> 'boolean'
     OR pg_get_function_result('ops.autorun_state()'::regprocedure) <> 'jsonb' THEN
    RAISE EXCEPTION '0039: _autorun_approved or autorun_state owner, definer, search_path, volatility or result wrong';
  END IF;

  -- comments
  IF obj_description('ops._autorun_approved(uuid)'::regprocedure, 'pg_proc') NOT LIKE 'Autorun gate (05022018): %'
     OR obj_description('ops.autorun_state()'::regprocedure, 'pg_proc') NOT LIKE 'Autorun gate (05022018): %'
     OR obj_description('ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure, 'pg_proc')
          NOT LIKE '%Autorun gate (05022018)%'
     OR obj_description('ops.claim_dispatch(uuid, text)'::regprocedure, 'pg_proc')
          IS DISTINCT FROM current_setting('ops_m0039.claim_comment')
                           || ' Autorun gate (05022018): an agent session starting ''autorun:'' claims only a dispatch with a current autorun_approved pass and an autorun-allowed type (23514 otherwise; it stays pending).'
     OR current_setting('ops_m0039.claim_comment') NOT LIKE 'Release 3 (34502bc1): %' THEN
    RAISE EXCEPTION '0039: comments wrong';
  END IF;

  -- grants
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
              WHERE p.oid = 'ops._autorun_approved(uuid)'::regprocedure AND a.grantee <> p.proowner)
     OR has_function_privilege('public', 'ops._autorun_approved(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION '0039: _autorun_approved is executable beyond its owner';
  END IF;
  IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
        FROM pg_proc p, aclexplode(p.proacl) a
       WHERE p.oid = 'ops.autorun_state()'::regprocedure AND a.grantee <> p.proowner) <> ARRAY['ops_executor', 'ops_planner'] THEN
    RAISE EXCEPTION '0039: autorun_state ACL wrong';
  END IF;
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0039.executor_reads') THEN
    RAISE EXCEPTION '0039: ops_executor SELECT set changed';
  END IF;
  IF (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
       WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))
     IS DISTINCT FROM (SELECT array_agg(DISTINCT f ORDER BY f)
                         FROM unnest(current_setting('ops_m0039.executor_fns')::text[] || ARRAY['autorun_state']) f)
     OR current_setting('ops_m0039.executor_fns') IS DISTINCT FROM
        ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log', 'log_work',
              'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now']::text THEN
    RAISE EXCEPTION '0039: ops_executor EXECUTE set is not the 0038 set plus autorun_state (before %)',
      current_setting('ops_m0039.executor_fns');
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND (has_table_privilege('ops_planner', c.oid, p) OR has_table_privilege('ops_executor', c.oid, p));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0039: ops_planner or ops_executor holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules)
     IS DISTINCT FROM current_setting('ops_m0039.rules_md5') THEN
    RAISE EXCEPTION '0039: protocol_rules changed';
  END IF;
  RAISE NOTICE '0039 checks passed';
END $$;

-- ── 8. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0039_autorun_gate');

COMMIT;
