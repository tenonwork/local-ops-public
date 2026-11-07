-- 0018_node_keyed_functions
-- Dispatch 96f67692. Spine M5b release 1, database side: node-keyed overloads of the project-keyed functions plus
-- three owner-only helpers. Additive only: every existing function keeps its signature, body and ACL (step 6 checks
-- against step 1); the MCP layer is untouched and keeps calling the text versions, which stay as shims until
-- release 2. Rehearse only; promoted later as a release together with the planner_evidence migration.
-- Decisions (inlined in the dispatch):
--   e1dea446 the overloads keep the existing names; the node-path parameter is public.ltree, never text, with NO
--            DEFAULT (p_node_path, or p_parent_path for create_project / create_component), so the named
--            create_project(p_key =>, p_name =>, p_params =>) call and the positional text calls (unknown literals
--            and untyped $n select the string category, which ltree is not in) keep resolving to the old
--            functions. close_session and adopt_orphans are not overloaded. ops._node raises P0001
--            'unknown node <path>'; the path-based component lookup raises P0001 'unknown component <path>'.
--   43992f43 get_pending covers exactly one component; get_unreviewed_reports is a subtree (dispatch component's
--            node <@ path); resolve_context takes the nearest ancestor-or-self, two matches at that depth raise.
--   9c94a9fd the node open_session stale-closes only active stale sessions whose derived node equals the opened
--            node; task_status 'unfinished' as in 0014.
--   cd187cd6 derived node = component's node, else project's node, else the global node (ops._derived_node);
--            project_id comes from the path's depth-2 ancestor (NULL on the global path where nullable);
--            session / supersedes / source-dispatch checks compare nodes: the other row's derived node must be
--            <@ the scope root (the path's depth-2 ancestor, or the global node on the global path).
--            create_project's parent must be the global node; create_component's parent a project node.
--   3d64c0f3 open_session refuses the global path ('global-path sessions wait for release 2'): the unchanged
--            close_session cannot home the decisions of a session with neither project nor component.
--   55bf4998 scope default: 'global' if the path <@ global.local-ops, else 'project'.
-- ltree types, operators and functions are schema-qualified throughout (8faeee76; search_path = ops, pg_temp).
-- Writes: none to existing rows (step 6 checks the row count of every ops table).
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── 1. guard; catalog state of every existing ops function and row counts of every ops table
DO $$
DECLARE v_newest text; t text; v_counts jsonb := '{}'; n bigint;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0017_promote_dispatch_type' THEN
    RAISE EXCEPTION '0018: expected newest ledger version 0017_promote_dispatch_type, found %', v_newest;
  END IF;
  PERFORM set_config('ops_m0018.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object('src', md5(p.prosrc), 'acl', p.proacl::text))
      FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace)::text, true);
  FOR t IN SELECT c.relname FROM pg_class c WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'p')
            ORDER BY c.relname LOOP
    EXECUTE format('SELECT count(*) FROM ops.%I', t) INTO n;
    v_counts := v_counts || jsonb_build_object(t, n);
  END LOOP;
  PERFORM set_config('ops_m0018.counts_before', v_counts::text, true);
  RAISE NOTICE 'functions before: %', (SELECT count(*) FROM jsonb_object_keys(current_setting('ops_m0018.fn_before')::jsonb));
  RAISE NOTICE 'row counts before: %', v_counts;
END $$;

-- ── 2. owner-only helpers
CREATE FUNCTION ops._node(p_path public.ltree)
RETURNS ops.nodes LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes;
BEGIN
  SELECT * INTO n FROM ops.nodes WHERE path OPERATOR(public.=) p_path;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown node %', p_path;
  END IF;
  RETURN n;
END $$;

CREATE FUNCTION ops._component(p_node_path public.ltree)
RETURNS ops.components LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components;
BEGIN
  SELECT cm.* INTO c FROM ops.nodes n JOIN ops.components cm ON cm.id = n.component_id
   WHERE n.path OPERATOR(public.=) p_node_path;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown component %', p_node_path;
  END IF;
  RETURN c;
END $$;

CREATE FUNCTION ops._derived_node(p_component_id uuid, p_project_id uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT coalesce((SELECT node_id FROM ops.components WHERE id = p_component_id),
                  (SELECT node_id FROM ops.projects WHERE id = p_project_id),
                  (SELECT id FROM ops.nodes WHERE kind = 'global'));
$$;

-- ── 3a. open_session (0014:361-402): node instead of project/component; global path refused
CREATE FUNCTION ops.open_session(p_node_path public.ltree, p_kind text, p_scope ops.segment_scope DEFAULT NULL,
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
         summary = coalesce(summary, 'auto-closed: stale'),
         task_status = 'unfinished'
   WHERE status = 'active' AND occurred_at < now() - make_interval(hours => v_stale_hours)
     AND ops._derived_node(component_id, project_id) = n.id;

  INSERT INTO ops.sessions (project_id, component_id, kind, scope, provenance, occurred_at)
  VALUES (v_project, n.component_id, p_kind, v_scope, p_provenance, coalesce(p_occurred_at, now()))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 3b. get_pending (0001:266-273): exactly the component at the path
CREATE FUNCTION ops.get_pending(p_node_path public.ltree)
RETURNS SETOF ops.dispatches LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components := ops._component(p_node_path);
BEGIN
  RETURN QUERY SELECT * FROM ops.dispatches
   WHERE component_id = c.id AND status = 'pending'
   ORDER BY priority, created_at;
END $$;

-- ── 3c. get_unreviewed_reports (0001:306-312): dispatches whose component's node is in the path's subtree
CREATE FUNCTION ops.get_unreviewed_reports(p_node_path public.ltree)
RETURNS SETOF ops.dispatches LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes := ops._node(p_node_path);
BEGIN
  RETURN QUERY SELECT d.* FROM ops.dispatches d
    JOIN ops.components c ON c.id = d.component_id
    JOIN ops.nodes cn ON cn.id = c.node_id
   WHERE cn.path OPERATOR(public.<@) n.path AND d.reviewed_at IS NULL
     AND d.status IN ('done', 'failed', 'refused_premise')
   ORDER BY d.completed_at;
END $$;

-- ── 3d. resolve_context (0001:347-371): nearest ancestor-or-self holding the doc_key
CREATE FUNCTION ops.resolve_context(p_node_path public.ltree, p_ref text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  n ops.nodes := ops._node(p_node_path);
  v_key text := split_part(p_ref, '#', 1);
  v_heading text := nullif(substr(p_ref, length(v_key) + 2), '');
  v_content text; v_line text; v_level int := 0; v_hlevel int; v_out text := ''; v_in boolean := false;
  v_depth int; v_matches int; v_at text;
BEGIN
  SELECT public.nlevel(dn.path), count(*), min(dn.path::text), min(cd.content)
    INTO v_depth, v_matches, v_at, v_content
    FROM ops.context_documents cd JOIN ops.nodes dn ON dn.id = cd.node_id
   WHERE dn.path OPERATOR(public.@>) n.path AND cd.doc_key = v_key
   GROUP BY public.nlevel(dn.path)
   ORDER BY public.nlevel(dn.path) DESC
   LIMIT 1;
  IF v_content IS NULL THEN RAISE EXCEPTION 'unknown context ref %', p_ref; END IF;
  IF v_matches > 1 THEN RAISE EXCEPTION 'ambiguous context ref % at %', p_ref, v_at; END IF;
  IF v_heading IS NULL THEN RETURN v_content; END IF;

  FOREACH v_line IN ARRAY string_to_array(v_content, E'\n') LOOP
    v_hlevel := length(substring(v_line from '^(#+)\s'));
    IF v_in AND v_hlevel IS NOT NULL AND v_hlevel <= v_level THEN EXIT; END IF;
    IF NOT v_in AND v_hlevel IS NOT NULL
       AND lower(btrim(regexp_replace(v_line, '^#+\s+', ''))) = lower(btrim(v_heading)) THEN
      v_in := true; v_level := v_hlevel;
    END IF;
    IF v_in THEN v_out := v_out || v_line || E'\n'; END IF;
  END LOOP;
  IF NOT v_in THEN RAISE EXCEPTION 'heading "%" not found in %', v_heading, v_key; END IF;
  RETURN rtrim(v_out, E'\n');
END $$;

-- ── 3e. create_project (0014:57-86): the parent must be the global node
CREATE FUNCTION ops.create_project(p_parent_path public.ltree, p_key text, p_name text, p_params jsonb DEFAULT '{}')
RETURNS ops.projects LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_parent ops.nodes; v_node uuid; r ops.projects;
BEGIN
  v_parent := ops._node(p_parent_path);
  IF v_parent.kind <> 'global' THEN
    RAISE EXCEPTION 'parent of project "%" must be the global node, not % (deeper parents wait for release 2)',
      p_key, v_parent.path;
  END IF;
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
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under the global node', p_key USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.projects (key, name, params) VALUES (p_key, p_name, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_parent.id, p_key, 'project', p_name)
  RETURNING id INTO v_node;
  UPDATE ops.projects SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 3f. create_component (0014:89-125): the parent must be a project node; the project is its projects row
CREATE FUNCTION ops.create_component(p_parent_path public.ltree, p_key text, p_kind text, p_repo_ref text DEFAULT NULL,
                                     p_verify_cmd text DEFAULT NULL, p_params jsonb DEFAULT '{}')
RETURNS ops.components LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_parent ops.nodes; p ops.projects; v_node uuid; r ops.components;
BEGIN
  v_parent := ops._node(p_parent_path);
  SELECT * INTO p FROM ops.projects WHERE node_id = v_parent.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parent % of component "%" is not a project node (deeper parents wait for release 2)',
      v_parent.path, p_key;
  END IF;
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid component key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_kind, ''))) = 0 THEN
    RAISE EXCEPTION 'component "%/%" needs a kind', p.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of component "%/%" must be a JSON object', p.key, p_key
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.components WHERE project_id = p.id AND key = p_key) THEN
    RAISE EXCEPTION 'component "%/%" already exists', p.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = p.node_id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under the node of project "%"', p_key, p.key
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.components (project_id, key, kind, repo_ref, verify_cmd, params)
  VALUES (p.id, p_key, p_kind, p_repo_ref, p_verify_cmd, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title, component_id) VALUES (p.node_id, p_key, 'node', p_key, r.id)
  RETURNING id INTO v_node;
  UPDATE ops.components SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 3g. create_dispatch (0014:128-180): component at the path; refs through the node resolve_context;
--        the session's derived node must be in the scope root's subtree
CREATE FUNCTION ops.create_dispatch(p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text,
                                    p_context_refs text[] DEFAULT '{}', p_priority integer DEFAULT 100,
                                    p_session uuid DEFAULT NULL)
RETURNS ops.dispatches LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components; t ops.dispatch_types; v_ref text; s ops.sessions; v_root ops.nodes; v_project uuid;
        r ops.dispatches;
BEGIN
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

-- ── 3h. log_decision (0014:183-231): home node is the path's node; project_id from the depth-2 ancestor
CREATE FUNCTION ops.log_decision(p_node_path public.ltree, p_decision text, p_rationale text DEFAULT NULL,
                                 p_rejected_alternatives jsonb DEFAULT '[]', p_revisit_condition text DEFAULT NULL,
                                 p_scope text DEFAULT NULL, p_supersedes uuid DEFAULT NULL, p_session uuid DEFAULT NULL)
RETURNS ops.decisions LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; v_root ops.nodes; v_project uuid; x ops.decisions; s ops.sessions; r ops.decisions;
BEGIN
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

-- ── 3i. add_backlog_item (0014:234-274): home_node_id is the path's node; legacy source format kept
CREATE FUNCTION ops.add_backlog_item(p_node_path public.ltree, p_kind ops.backlog_kind, p_title text,
                                     p_detail text DEFAULT NULL, p_source_dispatch uuid DEFAULT NULL,
                                     p_severity ops.backlog_severity DEFAULT 'untriaged')
RETURNS ops.backlog_items LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; v_root ops.nodes; v_project uuid; x ops.dispatches; r ops.backlog_items;
BEGIN
  n := ops._node(p_node_path);
  v_root := ops._node(public.subpath(n.path, 0, least(2, public.nlevel(n.path))));
  SELECT id INTO v_project FROM ops.projects WHERE node_id = v_root.id;
  IF p_kind IS NULL THEN
    RAISE EXCEPTION 'backlog item kind is required' USING ERRCODE = 'check_violation';
  END IF;
  IF p_severity IS NULL THEN
    RAISE EXCEPTION 'backlog item severity is required (default untriaged)' USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_title, ''))) = 0 THEN
    RAISE EXCEPTION 'backlog item title is empty' USING ERRCODE = 'check_violation';
  END IF;
  IF p_source_dispatch IS NOT NULL THEN
    SELECT * INTO x FROM ops.dispatches WHERE id = p_source_dispatch;
    IF NOT FOUND OR NOT (SELECT path FROM ops.nodes WHERE id = ops._derived_node(x.component_id, x.project_id))
                        OPERATOR(public.<@) v_root.path THEN
      RAISE EXCEPTION 'source dispatch % does not exist in % (the scope of %)', p_source_dispatch, v_root.path,
        p_node_path USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  INSERT INTO ops.backlog_items (project_id, component_id, title, detail, source, kind, severity, home_node_id)
  VALUES (v_project, n.component_id, p_title, p_detail,
          'kind:' || p_kind::text || coalesce('|dispatch:' || p_source_dispatch::text, ''),
          p_kind, p_severity, n.id)
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ── 4. grants: nothing to PUBLIC; helpers owner-only; planner a, c-i; executor b, d
REVOKE ALL ON FUNCTION
  ops._node(public.ltree),
  ops._component(public.ltree),
  ops._derived_node(uuid, uuid),
  ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance),
  ops.get_pending(public.ltree),
  ops.get_unreviewed_reports(public.ltree),
  ops.resolve_context(public.ltree, text),
  ops.create_project(public.ltree, text, text, jsonb),
  ops.create_component(public.ltree, text, text, text, text, jsonb),
  ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid),
  ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid),
  ops.add_backlog_item(public.ltree, ops.backlog_kind, text, text, uuid, ops.backlog_severity)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance),
  ops.get_unreviewed_reports(public.ltree),
  ops.resolve_context(public.ltree, text),
  ops.create_project(public.ltree, text, text, jsonb),
  ops.create_component(public.ltree, text, text, text, text, jsonb),
  ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid),
  ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid),
  ops.add_backlog_item(public.ltree, ops.backlog_kind, text, text, uuid, ops.backlog_severity)
TO ops_planner;
GRANT EXECUTE ON FUNCTION
  ops.get_pending(public.ltree),
  ops.resolve_context(public.ltree, text)
TO ops_executor;

-- ── 5. comments
COMMENT ON FUNCTION ops._node(public.ltree) IS
  'M5b release 1 (e1dea446): owner-only; the node at a path (OPERATOR(public.=)), else P0001 ''unknown node <path>''.';
COMMENT ON FUNCTION ops._component(public.ltree) IS
  'M5b release 1 (e1dea446): owner-only; the component at a node path, else P0001 ''unknown component <path>''.';
COMMENT ON FUNCTION ops._derived_node(uuid, uuid) IS
  'M5b release 1 (cd187cd6): owner-only; a row''s node = its component''s node, else its project''s node, else the global node.';
COMMENT ON FUNCTION ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance) IS
  'M5b release 1 (e1dea446, 9c94a9fd, 3d64c0f3): node-keyed open_session; stale close by exact derived node; global path refused.';
COMMENT ON FUNCTION ops.get_pending(public.ltree) IS
  'M5b release 1 (43992f43): node-keyed get_pending; exactly the component at the path.';
COMMENT ON FUNCTION ops.get_unreviewed_reports(public.ltree) IS
  'M5b release 1 (43992f43): node-keyed get_unreviewed_reports; dispatches whose component node is in the path subtree.';
COMMENT ON FUNCTION ops.resolve_context(public.ltree, text) IS
  'M5b release 1 (43992f43): node-keyed resolve_context; nearest ancestor-or-self wins, two matches at that depth raise.';
COMMENT ON FUNCTION ops.create_project(public.ltree, text, text, jsonb) IS
  'M5b release 1 (cd187cd6): node-keyed create_project; the parent must be the global node.';
COMMENT ON FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb) IS
  'M5b release 1 (cd187cd6): node-keyed create_component; the parent must be a project node.';
COMMENT ON FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid) IS
  'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.';
COMMENT ON FUNCTION ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid) IS
  'M5b release 1 (cd187cd6): node-keyed log_decision; home node = the path''s node, global path accepted.';
COMMENT ON FUNCTION ops.add_backlog_item(public.ltree, ops.backlog_kind, text, text, uuid, ops.backlog_severity) IS
  'M5b release 1 (cd187cd6): node-keyed add_backlog_item; home node = the path''s node, global path accepted.';

-- ── 6. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0018.fn_before')::jsonb; v_bad text; t text; n bigint;
        v_counts jsonb := '{}';
        -- new function -> the roles besides the owner that hold EXECUTE
        v_new jsonb := jsonb_build_object(
          'ops._node(public.ltree)', '[]'::jsonb,
          'ops._component(public.ltree)', '[]'::jsonb,
          'ops._derived_node(uuid, uuid)', '[]'::jsonb,
          'ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance)', '["ops_planner"]'::jsonb,
          'ops.get_pending(public.ltree)', '["ops_executor"]'::jsonb,
          'ops.get_unreviewed_reports(public.ltree)', '["ops_planner"]'::jsonb,
          'ops.resolve_context(public.ltree, text)', '["ops_executor", "ops_planner"]'::jsonb,
          'ops.create_project(public.ltree, text, text, jsonb)', '["ops_planner"]'::jsonb,
          'ops.create_component(public.ltree, text, text, text, text, jsonb)', '["ops_planner"]'::jsonb,
          'ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)', '["ops_planner"]'::jsonb,
          'ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid)', '["ops_planner"]'::jsonb,
          'ops.add_backlog_item(public.ltree, ops.backlog_kind, text, text, uuid, ops.backlog_severity)', '["ops_planner"]'::jsonb);
BEGIN
  -- every new function: SECURITY DEFINER, pinned search_path, exactly the ACL of step 4
  SELECT string_agg(f.key, ', ') INTO v_bad
    FROM jsonb_each(v_new) f LEFT JOIN pg_proc p ON p.oid = to_regprocedure(f.key)
   WHERE p.oid IS NULL OR NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
      OR p.proacl IS NULL
      OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.privilege_type <> 'EXECUTE')
      OR coalesce((SELECT jsonb_agg(g ORDER BY g)
                     FROM (SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END AS g
                             FROM aclexplode(p.proacl) a WHERE a.grantee <> p.proowner) x), '[]'::jsonb)
         <> (SELECT coalesce(jsonb_agg(e ORDER BY e), '[]'::jsonb) FROM jsonb_array_elements_text(f.value) e);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0018: new functions without SECURITY DEFINER, pinned search_path or the expected ACL: %', v_bad;
  END IF;

  -- every pre-existing ops function: same body and ACL
  SELECT string_agg(b.key, ', ') INTO v_bad
    FROM jsonb_each(v_before) b LEFT JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE p.oid IS NULL OR md5(p.prosrc) IS DISTINCT FROM b.value->>'src' OR p.proacl::text IS DISTINCT FROM b.value->>'acl';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0018: pre-existing functions changed: %', v_bad;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)
     <> (SELECT count(*) FROM jsonb_object_keys(v_before)) + 12 THEN
    RAISE EXCEPTION '0018: expected exactly 12 new ops functions';
  END IF;

  -- no rows written
  FOR t IN SELECT c.relname FROM pg_class c WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'p')
            ORDER BY c.relname LOOP
    EXECUTE format('SELECT count(*) FROM ops.%I', t) INTO n;
    v_counts := v_counts || jsonb_build_object(t, n);
  END LOOP;
  IF v_counts <> current_setting('ops_m0018.counts_before')::jsonb THEN
    RAISE EXCEPTION '0018 changed row counts: % -> %', current_setting('ops_m0018.counts_before'), v_counts;
  END IF;
  RAISE NOTICE '0018 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0018_node_keyed_functions');

COMMIT;
