-- 0013_planner_only_apply_gate
-- Dispatch d2211977. Backlog 377fb8fe. Production applies move to the executor (migrate.ts promote), gated by a
-- recorded operator approval. That approval must come from the planner side, so the executor cannot approve
-- its own apply.
-- Decisions:
--   dd1b27d4 promote refuses unless the gate 'prod_apply_approved' is recorded for the dispatch.
--   0013 gate rule: only ops_planner may record gate_key 'prod_apply_approved'; ops.record_gate raises
--            (check_violation) for that key when session_user <> 'ops_planner'. Other gate keys unchanged.
--            session_user, not current_user: inside a SECURITY DEFINER function current_user is the owner,
--            and SET ROLE does not change session_user.
--   8faeee76 the function keeps SET search_path = ops, pg_temp.
-- Changes: ops.record_gate is replaced with the identical signature, defaults, return type, SECURITY DEFINER and
-- search_path. The language changes from sql to plpgsql (a sql function cannot raise); the INSERT is unchanged.
-- No other function, table or grant changes.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).
-- CREATE OR REPLACE keeps the owner and ACL; step 2 checks both against the values captured in step 0.

BEGIN;

-- ── 0. catalog state of record_gate, before any change
DO $$ BEGIN
  PERFORM set_config('ops_m0013.fn_before', (
    SELECT jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text)
      FROM pg_proc p
     WHERE p.oid = 'ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure)::text, true);
  RAISE NOTICE 'record_gate before: %', current_setting('ops_m0013.fn_before');
END $$;

-- ── 1. record_gate: 'prod_apply_approved' only from an ops_planner session
CREATE OR REPLACE FUNCTION ops.record_gate(p_gate_key text, p_result ops.gate_result,
                                p_dispatch uuid DEFAULT NULL, p_session uuid DEFAULT NULL,
                                p_overridden boolean DEFAULT false,
                                p_override_by text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF p_gate_key = 'prod_apply_approved' AND session_user <> 'ops_planner' THEN
    RAISE EXCEPTION 'gate prod_apply_approved may only be recorded by ops_planner (session user is %)', session_user
      USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO ops.gate_events (gate_key, result, dispatch_id, session_id, overridden, override_by, reason)
  VALUES (p_gate_key, p_result, p_dispatch, p_session, p_overridden, p_override_by, p_reason)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 2. checks: any failure aborts the migration
DO $$
DECLARE v_fn text;
BEGIN
  SELECT jsonb_build_object(
           'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text)::text
    INTO v_fn
    FROM pg_proc p
   WHERE p.oid = 'ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure;
  IF v_fn::jsonb <> current_setting('ops_m0013.fn_before')::jsonb THEN
    RAISE EXCEPTION 'record_gate signature, security, search_path, owner or ACL changed: % -> %',
      current_setting('ops_m0013.fn_before'), v_fn;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE oid = 'ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text)'::regprocedure
                AND (NOT prosecdef OR proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
                     OR prolang <> (SELECT oid FROM pg_language WHERE lanname = 'plpgsql'))) THEN
    RAISE EXCEPTION 'record_gate must be plpgsql, SECURITY DEFINER with search_path = ops, pg_temp';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'ops' AND p.proname = 'record_gate') <> 1 THEN
    RAISE EXCEPTION 'expected exactly one ops.record_gate overload';
  END IF;
  RAISE NOTICE '0013 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0013_planner_only_apply_gate');

COMMIT;
