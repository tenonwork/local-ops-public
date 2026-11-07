-- 0014_writer_functions
-- Dispatch 75d863c8 (redo of 423494a4). Spine M4a, dispatch 1 of 2: an ops.* writer function for each of the six
-- planner MCP tools that write tables directly (create_project, create_component, create_dispatch, log_decision,
-- add_backlog_item, update_backlog_item), session backdating on open_session / close_session, and adopt_orphans.
-- Dispatch 2 (MCP only) routes the tools through these functions; nothing calls them yet.
-- Backlog: 23dd7222, 64d43199, a31f84c2, 3b2d8d9d, c8bd931c, 09acfdd0, cebdc79a.
-- Decisions:
--   d57bf3a9 / deeb7ebc M4a = these writer functions (+ close_session keeps supersedes, 3b2d8d9d; + decision node
--            links). Node reader functions are out of scope.
--   ec1a8782 no REVOKE of direct table grants (M4b, after the MCP deploy); existing grants stay byte-identical.
--   55bf4998 create_project: node kind 'project' under the global node, key = project key, projects.node_id set.
--            create_component: child node (kind 'node', component_id) under the project's node, components.node_id
--            set. open_session scope when omitted: 'global' if the project's node path is inside global.local-ops
--            (inclusive), else 'project'. Home rule for every written row: the component's node if component_id
--            is set, else the project's node (same rule as ops._spine_backfill()).
--   275da438 backlog_items.home_node_id and kind stay nullable until M4b; _spine_backfill() is not touched.
--   4596a343 the component-in-node-scope rule (011b32a8) is an M4b trigger, not a check here.
--   8faeee76 / cebdc79a every function pins search_path = ops, pg_temp; ltree operators are OPERATOR(public.<op>).
--   a31f84c2 reconstructed sessions carry their real span (occurred_at / closed_at), provenance 'reconstructed',
--            recorded_at = now(). adopt_orphans sets session_id only where it is null.
--   64d43199 dispatches carry the creating session, which must belong to the same project.
--   c8bd931c create_dispatch always inserts status 'pending'.
--   24c61089 tests/sql/0012 blocks 5-6 assert the 0014 signatures once 0014 is applied.
-- Changes: new functions create_project, create_component, create_dispatch, log_decision, add_backlog_item,
-- update_backlog_item, adopt_orphans (SECURITY DEFINER, EXECUTE for ops_planner only). open_session and
-- close_session are dropped and re-created with defaulted trailing parameters only (leading parameters, return
-- type, SECURITY DEFINER, search_path, owner and ACL unchanged; step 9 checks against step 0).
-- Writes: none to existing rows; step 9 checks the row counts.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).
-- DROP + CREATE gives the new function the applying role as owner and the default PUBLIC EXECUTE, so the
-- re-grant revokes PUBLIC and grants ops_planner, which reproduces the captured ACL.

BEGIN;

-- ── 0. catalog state of the two session functions and row counts, before any change
DO $$ BEGIN
  PERFORM set_config('ops_m0014.fn_before', (
    SELECT jsonb_object_agg(p.proname, jsonb_build_object(
             'args', pg_get_function_identity_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text))
      FROM pg_proc p
     WHERE p.oid IN ('ops.open_session(text, text, text)'::regprocedure,
                     'ops.close_session(uuid, text, text, jsonb, ops.close_reason)'::regprocedure))::text, true);
  PERFORM set_config('ops_m0014.counts_before', (
    SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'nodes', (SELECT count(*) FROM ops.nodes), 'dispatches', (SELECT count(*) FROM ops.dispatches),
             'decisions', (SELECT count(*) FROM ops.decisions),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items),
             'sessions', (SELECT count(*) FROM ops.sessions)))::text, true);
  RAISE NOTICE 'functions before: %', current_setting('ops_m0014.fn_before');
  RAISE NOTICE 'row counts before: %', current_setting('ops_m0014.counts_before');
END $$;

-- ── 1. create_project: project row, its node under the global node, projects.node_id
CREATE FUNCTION ops.create_project(p_key text, p_name text, p_params jsonb DEFAULT '{}')
RETURNS ops.projects LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_global uuid; v_node uuid; r ops.projects;
BEGIN
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid project key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_name, ''))) = 0 THEN
    RAISE EXCEPTION 'project "%" needs a name', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of project "%" must be a JSON object', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.projects WHERE key = p_key) THEN
    RAISE EXCEPTION 'project "%" already exists', p_key USING ERRCODE = 'check_violation';
  END IF;
  SELECT id INTO v_global FROM ops.nodes WHERE kind = 'global';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'the global node does not exist' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_global AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under the global node', p_key USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.projects (key, name, params) VALUES (p_key, p_name, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_global, p_key, 'project', p_name)
  RETURNING id INTO v_node;
  UPDATE ops.projects SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 2. create_component: component row, its child node under the project's node, components.node_id
CREATE FUNCTION ops.create_component(p_project_key text, p_key text, p_kind text, p_repo_ref text DEFAULT NULL,
                                     p_verify_cmd text DEFAULT NULL, p_params jsonb DEFAULT '{}')
RETURNS ops.components LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE p ops.projects; v_node uuid; r ops.components;
BEGIN
  SELECT * INTO p FROM ops.projects WHERE key = p_project_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown project "%"', p_project_key USING ERRCODE = 'check_violation';
  END IF;
  IF p.node_id IS NULL THEN
    RAISE EXCEPTION 'project "%" has no node', p_project_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid component key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_kind, ''))) = 0 THEN
    RAISE EXCEPTION 'component "%/%" needs a kind', p_project_key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of component "%/%" must be a JSON object', p_project_key, p_key
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.components WHERE project_id = p.id AND key = p_key) THEN
    RAISE EXCEPTION 'component "%/%" already exists', p_project_key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = p.node_id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under the node of project "%"', p_key, p_project_key
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.components (project_id, key, kind, repo_ref, verify_cmd, params)
  VALUES (p.id, p_key, p_kind, p_repo_ref, p_verify_cmd, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title, component_id) VALUES (p.node_id, p_key, 'node', p_key, r.id)
  RETURNING id INTO v_node;
  UPDATE ops.components SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 3. create_dispatch: validated insert, always 'pending', plus its dispatch_nodes row (component's node)
CREATE FUNCTION ops.create_dispatch(p_project_key text, p_component_key text, p_dispatch_type text, p_title text,
                                    p_prompt text, p_context_refs text[] DEFAULT '{}', p_priority integer DEFAULT 100,
                                    p_session uuid DEFAULT NULL)
RETURNS ops.dispatches LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components; t ops.dispatch_types; v_ref text; v_sp uuid; r ops.dispatches;
BEGIN
  c := ops._component(p_project_key, p_component_key);
  IF NOT c.active THEN
    RAISE EXCEPTION 'component "%/%" is not active', p_project_key, p_component_key USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO t FROM ops.dispatch_types WHERE type = p_dispatch_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown dispatch type "%"', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF NOT t.active THEN
    RAISE EXCEPTION 'dispatch type "%" is not active', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF t.commit_policy <> 'none' AND length(btrim(coalesce(c.verify_cmd, ''))) = 0 THEN
    RAISE EXCEPTION 'dispatch type "%" has commit policy % but component "%/%" has no verify_cmd',
      p_dispatch_type, t.commit_policy, p_project_key, p_component_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_context_refs IS NULL THEN
    RAISE EXCEPTION 'context_refs must be an array (use {} for none)' USING ERRCODE = 'check_violation';
  END IF;
  -- a miss is ops.resolve_context raising P0001 ('unknown context ref' / 'heading ... not found')
  FOREACH v_ref IN ARRAY p_context_refs LOOP
    BEGIN
      PERFORM ops.resolve_context(p_project_key, v_ref);
    EXCEPTION WHEN raise_exception THEN
      RAISE EXCEPTION 'context ref "%" does not resolve: %', v_ref, SQLERRM USING ERRCODE = 'check_violation';
    END;
  END LOOP;
  IF p_session IS NOT NULL THEN
    SELECT project_id INTO v_sp FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF v_sp IS DISTINCT FROM c.project_id THEN
      RAISE EXCEPTION 'session % belongs to another project than "%"', p_session, p_project_key
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF c.node_id IS NULL THEN
    RAISE EXCEPTION 'component "%/%" has no node', p_project_key, p_component_key USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt, context_refs,
                              priority, status)
  VALUES (c.project_id, c.id, p_dispatch_type, p_session, p_title, p_prompt, p_context_refs, p_priority, 'pending')
  RETURNING * INTO r;
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id) VALUES (r.id, c.node_id);
  RETURN r;
END $$;

-- ── 4. log_decision: decision row plus its decision_nodes row (home rule)
CREATE FUNCTION ops.log_decision(p_project_key text, p_decision text, p_component_key text DEFAULT NULL,
                                 p_rationale text DEFAULT NULL, p_rejected_alternatives jsonb DEFAULT '[]',
                                 p_revisit_condition text DEFAULT NULL, p_scope text DEFAULT NULL,
                                 p_supersedes uuid DEFAULT NULL, p_session uuid DEFAULT NULL)
RETURNS ops.decisions LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE p ops.projects; c ops.components; v_home uuid; v_sp uuid; r ops.decisions;
BEGIN
  SELECT * INTO p FROM ops.projects WHERE key = p_project_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown project "%"', p_project_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_component_key IS NOT NULL THEN
    c := ops._component(p_project_key, p_component_key);
  END IF;
  IF length(btrim(coalesce(p_decision, ''))) = 0 THEN
    RAISE EXCEPTION 'decision text is empty' USING ERRCODE = 'check_violation';
  END IF;
  IF p_rejected_alternatives IS NULL OR jsonb_typeof(p_rejected_alternatives) <> 'array' THEN
    RAISE EXCEPTION 'rejected_alternatives must be a JSON array (use [] for none)' USING ERRCODE = 'check_violation';
  END IF;
  IF p_supersedes IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ops.decisions WHERE id = p_supersedes AND project_id = p.id) THEN
    RAISE EXCEPTION 'superseded decision % does not exist in project "%"', p_supersedes, p_project_key
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_session IS NOT NULL THEN
    SELECT project_id INTO v_sp FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF v_sp IS DISTINCT FROM p.id THEN
      RAISE EXCEPTION 'session % belongs to another project than "%"', p_session, p_project_key
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  v_home := CASE WHEN c.id IS NULL THEN p.node_id ELSE c.node_id END;
  IF v_home IS NULL THEN
    RAISE EXCEPTION 'no home node for project "%" component "%"', p_project_key, p_component_key
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.decisions (project_id, component_id, session_id, decision, rationale, rejected_alternatives,
                             revisit_condition, scope, supersedes)
  VALUES (p.id, c.id, p_session, p_decision, p_rationale, p_rejected_alternatives, p_revisit_condition, p_scope,
          p_supersedes)
  RETURNING * INTO r;
  INSERT INTO ops.decision_nodes (decision_id, node_id) VALUES (r.id, v_home);
  RETURN r;
END $$;

-- ── 5. add_backlog_item: kind, severity, home_node_id (home rule) and the legacy source string
CREATE FUNCTION ops.add_backlog_item(p_project_key text, p_kind ops.backlog_kind, p_title text,
                                     p_component_key text DEFAULT NULL, p_detail text DEFAULT NULL,
                                     p_source_dispatch uuid DEFAULT NULL,
                                     p_severity ops.backlog_severity DEFAULT 'untriaged')
RETURNS ops.backlog_items LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE p ops.projects; c ops.components; v_home uuid; r ops.backlog_items;
BEGIN
  SELECT * INTO p FROM ops.projects WHERE key = p_project_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown project "%"', p_project_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_component_key IS NOT NULL THEN
    c := ops._component(p_project_key, p_component_key);
  END IF;
  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'backlog item kind is required' USING ERRCODE = 'check_violation';
  END IF;
  IF p_severity IS NULL THEN
    RAISE EXCEPTION 'backlog item severity is required (default untriaged)' USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_title, ''))) = 0 THEN
    RAISE EXCEPTION 'backlog item title is empty' USING ERRCODE = 'check_violation';
  END IF;
  IF p_source_dispatch IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM ops.dispatches WHERE id = p_source_dispatch AND project_id = p.id) THEN
    RAISE EXCEPTION 'source dispatch % does not exist in project "%"', p_source_dispatch, p_project_key
      USING ERRCODE = 'check_violation';
  END IF;
  v_home := CASE WHEN c.id IS NULL THEN p.node_id ELSE c.node_id END;
  IF v_home IS NULL THEN
    RAISE EXCEPTION 'no home node for project "%" component "%"', p_project_key, p_component_key
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.backlog_items (project_id, component_id, title, detail, source, kind, severity, home_node_id)
  VALUES (p.id, c.id, p_title, p_detail,
          'kind:' || p_kind::text || coalesce('|dispatch:' || p_source_dispatch::text, ''),
          p_kind, p_severity, v_home)
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 6. update_backlog_item: status with closed_at bookkeeping; detail replaced only when given
CREATE FUNCTION ops.update_backlog_item(p_id uuid, p_status text, p_detail text DEFAULT NULL)
RETURNS ops.backlog_items LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE b ops.backlog_items;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('open', 'done', 'dropped') THEN
    RAISE EXCEPTION 'invalid backlog status "%" (open, done or dropped)', p_status USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO b FROM ops.backlog_items WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'backlog item % does not exist', p_id USING ERRCODE = 'check_violation';
  END IF;
  -- open clears closed_at; a status change to done or dropped stamps now(); an unchanged status keeps it
  UPDATE ops.backlog_items
     SET status = p_status,
         closed_at = CASE WHEN p_status = 'open' THEN NULL
                          WHEN p_status <> b.status THEN now()
                          ELSE b.closed_at END,
         detail = coalesce(p_detail, detail)
   WHERE id = p_id
  RETURNING * INTO b;
  RETURN b;
END $$;

-- ── 7. open_session / close_session: drop and re-create with defaulted trailing parameters
DROP FUNCTION ops.open_session(text, text, text);
DROP FUNCTION ops.close_session(uuid, text, text, jsonb, ops.close_reason);

CREATE FUNCTION ops.close_session(p_session uuid, p_summary text, p_next_step text,
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
         summary = p_summary, next_step = p_next_step,
         task_status = CASE WHEN p_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status
   WHERE id = p_session;
  RETURN n;
END $$;

CREATE FUNCTION ops.open_session(p_project_key text, p_component_key text, p_kind text,
                                 p_scope ops.segment_scope DEFAULT NULL, p_occurred_at timestamptz DEFAULT NULL,
                                 p_provenance ops.provenance DEFAULT 'recorded')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_project uuid; v_component uuid; v_id uuid;
  v_stale_hours integer := coalesce(
    (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
  v_scope ops.segment_scope;
BEGIN
  SELECT id INTO v_project FROM ops.projects WHERE key = p_project_key;
  IF v_project IS NULL THEN RAISE EXCEPTION 'unknown project %', p_project_key; END IF;
  IF p_component_key IS NOT NULL THEN
    v_component := (ops._component(p_project_key, p_component_key)).id;
  END IF;
  IF p_provenance IS NULL OR (p_occurred_at IS NOT NULL) <> (p_provenance = 'reconstructed') THEN
    RAISE EXCEPTION 'occurred_at must be given exactly when provenance is reconstructed (occurred_at %, provenance %)',
      p_occurred_at, p_provenance USING ERRCODE = 'check_violation';
  END IF;
  IF p_occurred_at > now() THEN
    RAISE EXCEPTION 'occurred_at % is in the future', p_occurred_at USING ERRCODE = 'check_violation';
  END IF;
  -- 55bf4998 default: 'global' inside global.local-ops (inclusive), else 'project' (no node: 'project')
  v_scope := coalesce(p_scope,
    (SELECT CASE WHEN n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree
                 THEN 'global' ELSE 'project' END::ops.segment_scope
       FROM ops.projects p JOIN ops.nodes n ON n.id = p.node_id WHERE p.id = v_project),
    'project');

  -- auto-close orphaned sessions for this project
  UPDATE ops.sessions
     SET status = 'closed', close_reason = 'stale', closed_at = now(),
         summary = coalesce(summary, 'auto-closed: stale'),
         task_status = 'unfinished'
   WHERE project_id = v_project AND status = 'active'
     AND occurred_at < now() - make_interval(hours => v_stale_hours);

  INSERT INTO ops.sessions (project_id, component_id, kind, scope, provenance, occurred_at)
  VALUES (v_project, v_component, p_kind, v_scope, p_provenance, coalesce(p_occurred_at, now()))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 8. adopt_orphans: attach null-session decisions and dispatches of the session's project in [p_from, p_to)
CREATE FUNCTION ops.adopt_orphans(p_session uuid, p_from timestamptz, p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE s ops.sessions; v_dec integer; v_dis integer;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
    RAISE EXCEPTION 'adopt range must satisfy from < to (from %, to %)', p_from, p_to USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO s FROM ops.sessions WHERE id = p_session;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
  END IF;
  IF s.project_id IS NULL THEN
    RAISE EXCEPTION 'session % has no project', p_session USING ERRCODE = 'check_violation';
  END IF;

  UPDATE ops.decisions SET session_id = p_session
   WHERE session_id IS NULL AND project_id = s.project_id AND recorded_at >= p_from AND recorded_at < p_to;
  GET DIAGNOSTICS v_dec = ROW_COUNT;
  UPDATE ops.dispatches SET session_id = p_session
   WHERE session_id IS NULL AND project_id = s.project_id AND created_at >= p_from AND created_at < p_to;
  GET DIAGNOSTICS v_dis = ROW_COUNT;
  RETURN jsonb_build_object('decisions', v_dec, 'dispatches', v_dis);
END $$;

-- ── 9. grants: nothing to PUBLIC; ops_planner executes every new and re-created function
REVOKE ALL ON FUNCTION
  ops.create_project(text, text, jsonb),
  ops.create_component(text, text, text, text, text, jsonb),
  ops.create_dispatch(text, text, text, text, text, text[], integer, uuid),
  ops.log_decision(text, text, text, text, jsonb, text, text, uuid, uuid),
  ops.add_backlog_item(text, ops.backlog_kind, text, text, text, uuid, ops.backlog_severity),
  ops.update_backlog_item(uuid, text, text),
  ops.adopt_orphans(uuid, timestamptz, timestamptz),
  ops.open_session(text, text, text, ops.segment_scope, timestamptz, ops.provenance),
  ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.create_project(text, text, jsonb),
  ops.create_component(text, text, text, text, text, jsonb),
  ops.create_dispatch(text, text, text, text, text, text[], integer, uuid),
  ops.log_decision(text, text, text, text, jsonb, text, text, uuid, uuid),
  ops.add_backlog_item(text, ops.backlog_kind, text, text, text, uuid, ops.backlog_severity),
  ops.update_backlog_item(uuid, text, text),
  ops.adopt_orphans(uuid, timestamptz, timestamptz),
  ops.open_session(text, text, text, ops.segment_scope, timestamptz, ops.provenance),
  ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)
TO ops_planner;

-- ── 10. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0014.fn_before')::jsonb; v_after jsonb; v_bad text; f text;
        v_new text[] := ARRAY[
          'ops.create_project(text, text, jsonb)',
          'ops.create_component(text, text, text, text, text, jsonb)',
          'ops.create_dispatch(text, text, text, text, text, text[], integer, uuid)',
          'ops.log_decision(text, text, text, text, jsonb, text, text, uuid, uuid)',
          'ops.add_backlog_item(text, ops.backlog_kind, text, text, text, uuid, ops.backlog_severity)',
          'ops.update_backlog_item(uuid, text, text)',
          'ops.adopt_orphans(uuid, timestamptz, timestamptz)'];
BEGIN
  -- the re-created session functions: one overload each, same owner / ACL / security / config / result,
  -- leading identity args unchanged
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
       AND proname IN ('open_session', 'close_session')) <> 2 THEN
    RAISE EXCEPTION 'expected exactly one overload each of open_session and close_session';
  END IF;
  SELECT jsonb_object_agg(p.proname, jsonb_build_object(
           'args', pg_get_function_identity_arguments(p.oid), 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text))
    INTO v_after
    FROM pg_proc p
   WHERE p.oid IN ('ops.open_session(text, text, text, ops.segment_scope, timestamptz, ops.provenance)'::regprocedure,
                   'ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)'::regprocedure);
  RAISE NOTICE 'functions after: %', v_after;
  FOREACH f IN ARRAY ARRAY['open_session', 'close_session'] LOOP
    IF (v_after->f) - 'args' <> (v_before->f) - 'args'
       OR left(v_after->f->>'args', length(v_before->f->>'args') + 2) <> (v_before->f->>'args') || ', ' THEN
      RAISE EXCEPTION '% changed beyond appended parameters: % -> %', f, v_before->f, v_after->f;
    END IF;
    IF NOT (v_after->f->>'secdef')::boolean
       OR v_after->f->'config' IS DISTINCT FROM '["search_path=ops, pg_temp"]'::jsonb THEN
      RAISE EXCEPTION '% must be SECURITY DEFINER with search_path = ops, pg_temp', f;
    END IF;
  END LOOP;

  -- every new function: SECURITY DEFINER, pinned search_path, planner yes, executor and PUBLIC no
  SELECT string_agg(x, ', ') INTO v_bad FROM unnest(v_new) x
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(x)
   WHERE p.oid IS NULL OR NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
      OR NOT has_function_privilege('ops_planner', p.oid, 'EXECUTE')
      OR has_function_privilege('ops_executor', p.oid, 'EXECUTE')
      OR has_function_privilege('public', p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'new functions without SECURITY DEFINER, pinned search_path or planner-only EXECUTE: %', v_bad;
  END IF;

  -- no rows written
  IF (SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'nodes', (SELECT count(*) FROM ops.nodes), 'dispatches', (SELECT count(*) FROM ops.dispatches),
             'decisions', (SELECT count(*) FROM ops.decisions),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items),
             'sessions', (SELECT count(*) FROM ops.sessions)))
     <> current_setting('ops_m0014.counts_before')::jsonb THEN
    RAISE EXCEPTION '0014 changed row counts (before %)', current_setting('ops_m0014.counts_before');
  END IF;
  RAISE NOTICE '0014 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0014_writer_functions');

COMMIT;
