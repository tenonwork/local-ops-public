-- 0012_session_task_status_on_close
-- Dispatch 820b96df. Backlog bc2cc2db. Repair before M4: since 0011 sessions.task_status is NOT NULL DEFAULT
-- 'open', but ops.close_session and the stale auto-close in ops.open_session set status = 'closed' without
-- touching task_status, so every close leaves a closed session at task_status 'open'.
-- Decisions:
--   2eecc405 / 6b29db79 task_status mapping on close: close_reason 'stale' -> 'unfinished'; any other
--            close_reason (normal, erosion) -> 'closed'. A closed session with task_status 'open' is drift.
--   e066c400 + 7eb6746f tests use only rows they create and count relative to the starting state.
--   8faeee76 both functions keep SET search_path = ops, pg_temp.
-- Changes: both functions are replaced with identical signatures, return types, defaults, SECURITY DEFINER and
-- search_path; only the closing UPDATEs also set task_status. Every other line is byte-identical to 0001.
-- Writes: the one-time step 4 correction of rows closed between 0011 and 0012. The md5 fingerprint of every
-- sessions column except task_status (0010/0011 method) proves nothing else changed.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).
-- CREATE OR REPLACE keeps the owner and ACL; step 5 checks both against the values captured in step 0.

BEGIN;

-- ── 0. catalog state of both functions and sessions fingerprint, before any change
DO $$ BEGIN
  PERFORM set_config('ops_m0012.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text))
      FROM pg_proc p
     WHERE p.oid IN ('ops.open_session(text, text, text)'::regprocedure,
                     'ops.close_session(uuid, text, text, jsonb, ops.close_reason)'::regprocedure))::text, true);
  PERFORM set_config('ops_m0012.fp_before', (
    SELECT md5(coalesce(string_agg((to_jsonb(t) - 'task_status')::text, E'\n' ORDER BY t.id), ''))
      FROM ops.sessions t), true);
  RAISE NOTICE 'functions before: %', current_setting('ops_m0012.fn_before');
  RAISE NOTICE 'sessions fingerprint before: %', current_setting('ops_m0012.fp_before');
END $$;

-- ── 2. close_session: the final UPDATE also sets task_status (2eecc405 mapping stated in one place)
CREATE OR REPLACE FUNCTION ops.close_session(p_session uuid, p_summary text, p_next_step text,
                                  p_decisions jsonb, p_reason ops.close_reason DEFAULT 'normal')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE s ops.sessions; d jsonb; n integer := 0;
BEGIN
  IF p_decisions IS NULL OR jsonb_typeof(p_decisions) <> 'array' THEN
    RAISE EXCEPTION 'decisions must be an explicit JSON array (use [] if none were made)';
  END IF;
  IF p_reason = 'stale' THEN
    RAISE EXCEPTION 'stale closure is automatic only';
  END IF;
  SELECT * INTO s FROM ops.sessions WHERE id = p_session FOR UPDATE;
  IF NOT FOUND OR s.status <> 'active' THEN
    RAISE EXCEPTION 'session % is not active', p_session;
  END IF;

  FOR d IN SELECT * FROM jsonb_array_elements(p_decisions) LOOP
    INSERT INTO ops.decisions (project_id, component_id, session_id, decision, rationale,
                               rejected_alternatives, revisit_condition, scope)
    VALUES (s.project_id, s.component_id, s.id, d->>'decision', d->>'rationale',
            coalesce(d->'rejected_alternatives', '[]'), d->>'revisit_condition', d->>'scope');
    n := n + 1;
  END LOOP;

  UPDATE ops.sessions
     SET status = 'closed', close_reason = p_reason, closed_at = now(),
         summary = p_summary, next_step = p_next_step,
         task_status = CASE WHEN p_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status
   WHERE id = p_session;
  RETURN n;
END $$;

-- ── 3. open_session: the stale auto-close also sets task_status 'unfinished'
CREATE OR REPLACE FUNCTION ops.open_session(p_project_key text, p_component_key text, p_kind text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_project uuid; v_component uuid; v_id uuid;
  v_stale_hours integer := coalesce(
    (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
BEGIN
  SELECT id INTO v_project FROM ops.projects WHERE key = p_project_key;
  IF v_project IS NULL THEN RAISE EXCEPTION 'unknown project %', p_project_key; END IF;
  IF p_component_key IS NOT NULL THEN
    v_component := (ops._component(p_project_key, p_component_key)).id;
  END IF;

  -- auto-close orphaned sessions for this project
  UPDATE ops.sessions
     SET status = 'closed', close_reason = 'stale', closed_at = now(),
         summary = coalesce(summary, 'auto-closed: stale'),
         task_status = 'unfinished'
   WHERE project_id = v_project AND status = 'active'
     AND occurred_at < now() - make_interval(hours => v_stale_hours);

  INSERT INTO ops.sessions (project_id, component_id, kind)
  VALUES (v_project, v_component, p_kind) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 4. one-time correction: rows closed between 0011 and 0012
DO $$
DECLARE v_n bigint;
BEGIN
  UPDATE ops.sessions
     SET task_status = CASE WHEN close_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status
   WHERE status = 'closed' AND task_status = 'open';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RAISE NOTICE 'task_status corrected on % closed sessions', v_n;
END $$;

-- ── 5. checks: any failure aborts the migration
DO $$
DECLARE v_fn text; v_fp text; v_bad bigint;
BEGIN
  SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
           'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text))::text
    INTO v_fn
    FROM pg_proc p
   WHERE p.oid IN ('ops.open_session(text, text, text)'::regprocedure,
                   'ops.close_session(uuid, text, text, jsonb, ops.close_reason)'::regprocedure);
  IF v_fn::jsonb <> current_setting('ops_m0012.fn_before')::jsonb THEN
    RAISE EXCEPTION 'function signature, security, search_path, owner or ACL changed: % -> %',
      current_setting('ops_m0012.fn_before'), v_fn;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE oid IN ('ops.open_session(text, text, text)'::regprocedure,
                            'ops.close_session(uuid, text, text, jsonb, ops.close_reason)'::regprocedure)
                AND (NOT prosecdef OR proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp'])) THEN
    RAISE EXCEPTION 'functions must be SECURITY DEFINER with search_path = ops, pg_temp';
  END IF;

  IF EXISTS (SELECT 1 FROM ops.sessions WHERE status = 'closed' AND task_status = 'open') THEN
    RAISE EXCEPTION 'closed sessions with task_status open remain';
  END IF;
  SELECT count(*) INTO v_bad FROM ops.sessions
   WHERE status = 'closed'
     AND task_status <> CASE WHEN close_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status;
  IF v_bad > 0 THEN
    RAISE EXCEPTION '% closed sessions off the closed/stale mapping', v_bad;
  END IF;

  SELECT md5(coalesce(string_agg((to_jsonb(t) - 'task_status')::text, E'\n' ORDER BY t.id), ''))
    INTO v_fp FROM ops.sessions t;
  RAISE NOTICE 'sessions fingerprint after:  %', v_fp;
  IF v_fp <> current_setting('ops_m0012.fp_before') THEN
    RAISE EXCEPTION '0012 changed sessions columns other than task_status';
  END IF;
  RAISE NOTICE '0012 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0012_session_task_status_on_close');

COMMIT;
