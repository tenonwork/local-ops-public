-- 0022_session_required_drop_task_status
-- Dispatch 25562775. Spine M5b release 2, migration 2 of 3 (0021-0023 are promoted together as one set by a separate
-- promote dispatch after planner review). Sessions are mandatory and single-status:
--   * decisions.session_id and dispatches.session_id become NOT NULL. Every legacy null-session row in production was
--     adopted into a session on 2026-10-12; the guard refuses to run while any null-session row exists. Plain NOT
--     NULL, no exemption CHECK, no cutoff.
--   * create_dispatch(ltree, ...) and log_decision(ltree, ...) keep their signatures (p_session DEFAULT NULL) and
--     refuse a null session first, with check_violation (23514) 'session is required (segment_id)': the MCP layer
--     classifies 23514 as a validation error, a bare 23502 it does not.
--   * sessions.task_status and the enum ops.task_status are dropped. Since 0012 every row satisfied task_status =
--     CASE WHEN status = 'active' THEN 'open' WHEN close_reason = 'stale' THEN 'unfinished' ELSE 'closed' END, so the
--     column carried nothing that status and close_reason do not. open_session(ltree) (stale auto-close) and
--     close_session stop writing it; nothing else changes in them (0023 replaces close_session's body later).
-- The four functions are CREATE OR REPLACE'd: owner, ACL, comment, signature, SECURITY DEFINER and search_path stay;
-- step 6 checks that, and that each new body is exactly the old body with the one change.
-- Changes nothing else: no other table, function or grant, no row.

BEGIN;

-- ── 1. guard; catalog state of the four functions to replace
DO $$
DECLARE v_newest text; v_dec bigint; v_dis bigint;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0021_drop_project_keyed_functions' THEN
    RAISE EXCEPTION '0022: expected newest ledger version 0021_drop_project_keyed_functions, found %', v_newest;
  END IF;
  SELECT count(*) INTO v_dec FROM ops.decisions WHERE session_id IS NULL;
  SELECT count(*) INTO v_dis FROM ops.dispatches WHERE session_id IS NULL;
  IF v_dec + v_dis > 0 THEN
    RAISE EXCEPTION '0022: null-session rows remain (decisions %, dispatches %)', v_dec, v_dis;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.sessions'::regclass AND attname = 'task_status'
                    AND NOT attisdropped) THEN
    RAISE EXCEPTION '0022: column ops.sessions.task_status does not exist';
  END IF;
  IF to_regtype('ops.task_status') IS NULL THEN
    RAISE EXCEPTION '0022: type ops.task_status does not exist';
  END IF;
  PERFORM set_config('ops_m0022.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc))
      FROM pg_proc p
     WHERE p.oid IN ('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)'::regprocedure,
                     'ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid)'::regprocedure,
                     'ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance)'::regprocedure,
                     'ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)'::regprocedure))::text, true);
  PERFORM set_config('ops_m0022.fn_count_before',
    (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)::text, true);
  RAISE NOTICE 'null-session rows: decisions %, dispatches %; ops functions before: %', v_dec, v_dis,
    current_setting('ops_m0022.fn_count_before');
END $$;

-- ── 2a. create_dispatch (0018 3g): the null-session refusal first; the body is otherwise unchanged
CREATE OR REPLACE FUNCTION ops.create_dispatch(p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text,
                                    p_context_refs text[] DEFAULT '{}', p_priority integer DEFAULT 100,
                                    p_session uuid DEFAULT NULL)
RETURNS ops.dispatches LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components; t ops.dispatch_types; v_ref text; s ops.sessions; v_root ops.nodes; v_project uuid;
        r ops.dispatches;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  c := ops._component(p_node_path);
  IF NOT c.active THEN
    RAISE EXCEPTION 'component % is not active', p_node_path USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO t FROM ops.dispatch_types WHERE type = p_dispatch_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown dispatch type "%"', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF NOT t.active THEN
    RAISE EXCEPTION 'dispatch type "%" is not active', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF t.commit_policy <> 'none' AND length(btrim(coalesce(c.verify_cmd, ''))) = 0 THEN
    RAISE EXCEPTION 'dispatch type "%" has commit policy % but component % has no verify_cmd',
      p_dispatch_type, t.commit_policy, p_node_path USING ERRCODE = 'check_violation';
  END IF;
  IF p_context_refs IS NULL THEN
    RAISE EXCEPTION 'context_refs must be an array (use {} for none)' USING ERRCODE = 'check_violation';
  END IF;
  -- a miss is the node ops.resolve_context raising P0001 ('unknown context ref' / 'heading ... not found' / 'ambiguous')
  FOREACH v_ref IN ARRAY p_context_refs LOOP
    BEGIN
      PERFORM ops.resolve_context(p_node_path, v_ref);
    EXCEPTION WHEN raise_exception THEN
      RAISE EXCEPTION 'context ref "%" does not resolve: %', v_ref, SQLERRM USING ERRCODE = 'check_violation';
    END;
  END LOOP;
  v_root := ops._node(public.subpath(p_node_path, 0, least(2, public.nlevel(p_node_path))));
  SELECT id INTO v_project FROM ops.projects WHERE node_id = v_root.id;
  IF p_session IS NOT NULL THEN
    SELECT * INTO s FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (SELECT path FROM ops.nodes WHERE id = ops._derived_node(s.component_id, s.project_id))
           OPERATOR(public.<@) v_root.path THEN
      RAISE EXCEPTION 'session % is outside % (the scope of %)', p_session, v_root.path, p_node_path
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF c.node_id IS NULL THEN
    RAISE EXCEPTION 'component % has no node', p_node_path USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt, context_refs,
                              priority, status)
  VALUES (v_project, c.id, p_dispatch_type, p_session, p_title, p_prompt, p_context_refs, p_priority, 'pending')
  RETURNING * INTO r;
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id) VALUES (r.id, c.node_id);
  RETURN r;
END $$;

-- ── 2b. log_decision (0018 3h): the null-session refusal first; the body is otherwise unchanged
CREATE OR REPLACE FUNCTION ops.log_decision(p_node_path public.ltree, p_decision text, p_rationale text DEFAULT NULL,
                                 p_rejected_alternatives jsonb DEFAULT '[]', p_revisit_condition text DEFAULT NULL,
                                 p_scope text DEFAULT NULL, p_supersedes uuid DEFAULT NULL, p_session uuid DEFAULT NULL)
RETURNS ops.decisions LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; v_root ops.nodes; v_project uuid; x ops.decisions; s ops.sessions; r ops.decisions;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  n := ops._node(p_node_path);
  v_root := ops._node(public.subpath(n.path, 0, least(2, public.nlevel(n.path))));
  SELECT id INTO v_project FROM ops.projects WHERE node_id = v_root.id;
  IF length(btrim(coalesce(p_decision, ''))) = 0 THEN
    RAISE EXCEPTION 'decision text is empty' USING ERRCODE = 'check_violation';
  END IF;
  IF p_rejected_alternatives IS NULL OR jsonb_typeof(p_rejected_alternatives) <> 'array' THEN
    RAISE EXCEPTION 'rejected_alternatives must be a JSON array (use [] for none)' USING ERRCODE = 'check_violation';
  END IF;
  IF p_supersedes IS NOT NULL THEN
    SELECT * INTO x FROM ops.decisions WHERE id = p_supersedes;
    IF NOT FOUND OR NOT (SELECT path FROM ops.nodes WHERE id = ops._derived_node(x.component_id, x.project_id))
                        OPERATOR(public.<@) v_root.path THEN
      RAISE EXCEPTION 'superseded decision % does not exist in % (the scope of %)', p_supersedes, v_root.path,
        p_node_path USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_session IS NOT NULL THEN
    SELECT * INTO s FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (SELECT path FROM ops.nodes WHERE id = ops._derived_node(s.component_id, s.project_id))
           OPERATOR(public.<@) v_root.path THEN
      RAISE EXCEPTION 'session % is outside % (the scope of %)', p_session, v_root.path, p_node_path
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  INSERT INTO ops.decisions (project_id, component_id, session_id, decision, rationale, rejected_alternatives,
                             revisit_condition, scope, supersedes)
  VALUES (v_project, n.component_id, p_session, p_decision, p_rationale, p_rejected_alternatives, p_revisit_condition,
          p_scope, p_supersedes)
  RETURNING * INTO r;
  INSERT INTO ops.decision_nodes (decision_id, node_id) VALUES (r.id, n.id);
  RETURN r;
END $$;

-- ── 3a. open_session (0018 3a): the stale auto-close no longer sets task_status
CREATE OR REPLACE FUNCTION ops.open_session(p_node_path public.ltree, p_kind text, p_scope ops.segment_scope DEFAULT NULL,
                                 p_occurred_at timestamptz DEFAULT NULL, p_provenance ops.provenance DEFAULT 'recorded')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  n ops.nodes; v_project uuid; v_id uuid;
  v_stale_hours integer := coalesce(
    (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
  v_scope ops.segment_scope;
BEGIN
  n := ops._node(p_node_path);
  IF n.kind = 'global' THEN
    RAISE EXCEPTION 'global-path sessions wait for release 2';
  END IF;
  SELECT id INTO v_project FROM ops.projects
   WHERE node_id = (SELECT id FROM ops.nodes WHERE path OPERATOR(public.=) public.subpath(n.path, 0, 2));
  IF v_project IS NULL THEN
    RAISE EXCEPTION 'unknown project for node % (sessions outside a project wait for release 2)', n.path;
  END IF;
  IF p_provenance IS NULL OR (p_occurred_at IS NOT NULL) <> (p_provenance = 'reconstructed') THEN
    RAISE EXCEPTION 'occurred_at must be given exactly when provenance is reconstructed (occurred_at %, provenance %)',
      p_occurred_at, p_provenance USING ERRCODE = 'check_violation';
  END IF;
  IF p_occurred_at > now() THEN
    RAISE EXCEPTION 'occurred_at % is in the future', p_occurred_at USING ERRCODE = 'check_violation';
  END IF;
  -- 55bf4998 default applied to the path: 'global' inside global.local-ops (inclusive), else 'project'
  v_scope := coalesce(p_scope,
    CASE WHEN n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree
         THEN 'global' ELSE 'project' END::ops.segment_scope);

  -- auto-close orphaned sessions whose derived node is the opened node
  UPDATE ops.sessions
     SET status = 'closed', close_reason = 'stale', closed_at = now(),
         summary = coalesce(summary, 'auto-closed: stale')
   WHERE status = 'active' AND occurred_at < now() - make_interval(hours => v_stale_hours)
     AND ops._derived_node(component_id, project_id) = n.id;

  INSERT INTO ops.sessions (project_id, component_id, kind, scope, provenance, occurred_at)
  VALUES (v_project, n.component_id, p_kind, v_scope, p_provenance, coalesce(p_occurred_at, now()))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 3b. close_session (0014 step 7): the closing UPDATE no longer sets task_status
CREATE OR REPLACE FUNCTION ops.close_session(p_session uuid, p_summary text, p_next_step text,
                                  p_decisions jsonb, p_reason ops.close_reason DEFAULT 'normal',
                                  p_closed_at timestamptz DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE s ops.sessions; d jsonb; n integer := 0; v_home uuid; v_dec uuid; v_sup uuid;
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
  IF p_closed_at IS NOT NULL THEN
    IF s.provenance <> 'reconstructed' THEN
      RAISE EXCEPTION 'closed_at may only be given for a reconstructed session (session % is %)', p_session,
        s.provenance USING ERRCODE = 'check_violation';
    END IF;
    IF p_closed_at < s.occurred_at OR p_closed_at > now() THEN
      RAISE EXCEPTION 'closed_at % is outside occurred_at % .. now() of session %', p_closed_at, s.occurred_at,
        p_session USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  -- home rule for inline decisions: the session's component node, else its project node
  v_home := CASE WHEN s.component_id IS NULL THEN (SELECT node_id FROM ops.projects WHERE id = s.project_id)
                 ELSE (SELECT node_id FROM ops.components WHERE id = s.component_id) END;

  FOR d IN SELECT * FROM jsonb_array_elements(p_decisions) LOOP
    v_sup := (d->>'supersedes')::uuid;
    IF v_sup IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM ops.decisions WHERE id = v_sup AND project_id = s.project_id) THEN
      RAISE EXCEPTION 'superseded decision % does not exist in the project of session %', v_sup, p_session
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_home IS NULL THEN
      RAISE EXCEPTION 'no home node for the decisions of session %', p_session USING ERRCODE = 'check_violation';
    END IF;
    INSERT INTO ops.decisions (project_id, component_id, session_id, decision, rationale,
                               rejected_alternatives, revisit_condition, scope, supersedes)
    VALUES (s.project_id, s.component_id, s.id, d->>'decision', d->>'rationale',
            coalesce(d->'rejected_alternatives', '[]'), d->>'revisit_condition', d->>'scope', v_sup)
    RETURNING id INTO v_dec;
    INSERT INTO ops.decision_nodes (decision_id, node_id) VALUES (v_dec, v_home);
    n := n + 1;
  END LOOP;

  UPDATE ops.sessions
     SET status = 'closed', close_reason = p_reason, closed_at = coalesce(p_closed_at, now()),
         summary = p_summary, next_step = p_next_step
   WHERE id = p_session;
  RETURN n;
END $$;

-- ── 4. sessions are mandatory
ALTER TABLE ops.decisions ALTER COLUMN session_id SET NOT NULL;
ALTER TABLE ops.dispatches ALTER COLUMN session_id SET NOT NULL;

-- ── 5. single status: drop the column, then its enum (no CASCADE)
ALTER TABLE ops.sessions DROP COLUMN task_status;
DROP TYPE ops.task_status;

-- ── 6. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0022.fn_before')::jsonb; v_bad text; v_msg text;
        -- the top-level BEGIN of 2a / 2b (the only one at the start of a line) followed by the null-session refusal
        v_check text := E'BEGIN\n  IF p_session IS NULL THEN\n    RAISE EXCEPTION ''session is required (segment_id)'' USING ERRCODE = ''check_violation'';\n  END IF;\n';
BEGIN
  SELECT string_agg(t || '.session_id', ', ') INTO v_bad
    FROM unnest(ARRAY['decisions', 'dispatches']) t
   WHERE NOT (SELECT attnotnull FROM pg_attribute WHERE attrelid = ('ops.' || t)::regclass AND attname = 'session_id');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0022: still nullable: %', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.sessions'::regclass AND attname = 'task_status') THEN
    RAISE EXCEPTION '0022: column ops.sessions.task_status still exists';
  END IF;
  IF to_regtype('ops.task_status') IS NOT NULL THEN
    RAISE EXCEPTION '0022: type ops.task_status still exists';
  END IF;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.prosrc LIKE '%task_status%';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0022: function bodies still mention task_status: %', v_bad;
  END IF;

  -- the four replaced functions: same signature, result, security, search_path, owner, ACL and comment
  SELECT string_agg(b.key, ', ') INTO v_bad
    FROM jsonb_each(v_before) b LEFT JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE p.oid IS NULL
      OR jsonb_build_object('args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
                            'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
                            'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'))
         IS DISTINCT FROM b.value - 'src';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0022: signature, ACL or comment changed: %', v_bad;
  END IF;
  -- and each body is the old body with exactly this migration's change (old text present, replaced, nothing else)
  SELECT string_agg(f.key, ', ') INTO v_bad
    FROM (VALUES
      ('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)', E'\nBEGIN\n', E'\n' || v_check),
      ('ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid)', E'\nBEGIN\n', E'\n' || v_check),
      ('ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance)',
       E',\n         task_status = ''unfinished''', ''),
      ('ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)',
       E',\n         task_status = CASE WHEN p_reason = ''stale'' THEN ''unfinished'' ELSE ''closed'' END::ops.task_status', ''))
      f(key, old_text, new_text)
    JOIN pg_proc p ON p.oid = to_regprocedure(f.key)
   WHERE strpos((SELECT b.value->>'src' FROM jsonb_each(v_before) b WHERE to_regprocedure(b.key) = p.oid), f.old_text) = 0
      OR p.prosrc IS DISTINCT FROM
         replace((SELECT b.value->>'src' FROM jsonb_each(v_before) b WHERE to_regprocedure(b.key) = p.oid), f.old_text, f.new_text);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0022: bodies differ from the old bodies with the one change: %', v_bad;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)
     <> current_setting('ops_m0022.fn_count_before')::bigint THEN
    RAISE EXCEPTION '0022: the number of ops functions changed';
  END IF;

  -- a null session is refused with 23514 before anything is written (each call in a subtransaction)
  BEGIN
    PERFORM ops.create_dispatch(p_node_path => 'global.local-ops.core'::public.ltree, p_dispatch_type => 'investigation',
                                p_title => '0022 probe', p_prompt => 'p');
    RAISE EXCEPTION '0022: create_dispatch without a session was accepted';
  EXCEPTION WHEN check_violation THEN
    v_msg := SQLERRM;
  END;
  IF v_msg IS DISTINCT FROM 'session is required (segment_id)' THEN
    RAISE EXCEPTION '0022: create_dispatch refusal message: %', v_msg;
  END IF;
  v_msg := NULL;
  BEGIN
    PERFORM ops.log_decision(p_node_path => 'global.local-ops'::public.ltree, p_decision => '0022 probe');
    RAISE EXCEPTION '0022: log_decision without a session was accepted';
  EXCEPTION WHEN check_violation THEN
    v_msg := SQLERRM;
  END;
  IF v_msg IS DISTINCT FROM 'session is required (segment_id)' THEN
    RAISE EXCEPTION '0022: log_decision refusal message: %', v_msg;
  END IF;
  RAISE NOTICE '0022 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0022_session_required_drop_task_status');

COMMIT;
