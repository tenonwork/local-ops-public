-- 0023_node_anchor_drop_project_row
-- Dispatch 29a5b04f, completed by its redo 4b6c7575. Spine M5b release 2, migration 3 of 3 (0021-0023 are promoted together as one set by a separate
-- promote dispatch after planner review). Framework rows become node-keyed and the local-ops project row goes:
--   * ops.sessions.node_id (nullable, FK ops.nodes) anchors a session on a node. Every existing session is backfilled
--     from its component's node, else its project's node, before any project_id is nulled; open_session(ltree) sets
--     it to the opened node. Wherever a session's node is derived, coalesce(s.node_id, ops._derived_node(...)) is
--     used; ops._derived_node keeps its signature and body. A decision's node is its ops.decision_nodes row; a
--     dispatch's node stays its component node (every dispatch has a component).
--   * dispatches.project_id drops NOT NULL. components UNIQUE (project_id, key) and context_documents
--     UNIQUE (project_id, doc_key) are dropped; components gets UNIQUE (node_id) (NULLs distinct).
--   * open_session(ltree) accepts the global node and nodes outside any project (project_id = the depth-2 ancestor's
--     projects row, else NULL); the scope default is unchanged ('global' inside global.local-ops, else 'project', so
--     a session on the global node gets 'project'). The stale auto-close reaches sessions whose session node is the
--     opened node.
--   * create_component(ltree) accepts a project node or a plain node outside any component's subtree; the global
--     node and component subtrees are refused. project_id = the depth-2 ancestor's projects row, else NULL. The
--     duplicate check is a node with that key under the parent.
--   * close_session homes inline decisions on the session node; the supersedes check is node-based (the superseded
--     decision's node must lie under the session node's depth-2 ancestor).
--   * create_dispatch(ltree) and log_decision(ltree) change only their derivation calls (session node; log_decision's
--     supersedes check through decision_nodes). add_backlog_item(ltree) derives only a dispatch's node (component
--     node, unchanged), so it is not replaced.
--   * adopt_orphans is dropped (no null-session row can exist since 0022).
--   * The local-ops project's rows get project_id NULL (components first: the _component_scope trigger requires a
--     row's project_id to equal its component's), then the projects row is deleted (no CASCADE; any FK still
--     referencing it fails the migration). The nodes global.local-ops and global.local-ops.core stay.
--   * dispatches_pending_idx is re-keyed to (component_id, priority) WHERE status = 'pending'.
-- Replaced functions keep signature, result, owner, SECURITY DEFINER, search_path and ACL (step 9 checks that);
-- open_session, create_component and close_session get new comments.

BEGIN;

-- ── 1. guard; catalog state of the functions to replace; sessions that must end up with a node
DO $$
DECLARE v_newest text; v_lo ops.projects; v_bad text; v_n bigint;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0022_session_required_drop_task_status' THEN
    RAISE EXCEPTION '0023: expected newest ledger version 0022_session_required_drop_task_status, found %', v_newest;
  END IF;
  SELECT count(*) INTO v_n FROM ops.projects WHERE key = 'local-ops';
  IF v_n <> 1 THEN
    RAISE EXCEPTION '0023: expected exactly one projects row with key local-ops, found %', v_n;
  END IF;
  SELECT * INTO v_lo FROM ops.projects WHERE key = 'local-ops';
  IF (SELECT path::text FROM ops.nodes WHERE id = v_lo.node_id) IS DISTINCT FROM 'global.local-ops' THEN
    RAISE EXCEPTION '0023: the local-ops project is not on the node global.local-ops';
  END IF;
  -- framework rows (rows on the global.local-ops subtree) belong to the local-ops project only
  WITH sub AS (SELECT id FROM ops.nodes WHERE path OPERATOR(public.<@) 'global.local-ops'::public.ltree)
  SELECT string_agg(t, ', ') INTO v_bad FROM (
    SELECT 'projects' t WHERE EXISTS (SELECT 1 FROM ops.projects WHERE id <> v_lo.id AND node_id IN (SELECT id FROM sub))
    UNION ALL SELECT 'components' WHERE EXISTS (SELECT 1 FROM ops.components
                                       WHERE node_id IN (SELECT id FROM sub) AND project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'sessions' WHERE EXISTS (SELECT 1 FROM ops.sessions
                                     WHERE ops._derived_node(component_id, project_id) IN (SELECT id FROM sub)
                                       AND project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'decisions' WHERE EXISTS (SELECT 1 FROM ops.decisions d JOIN ops.decision_nodes dn ON dn.decision_id = d.id
                                      WHERE dn.node_id IN (SELECT id FROM sub) AND d.project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'dispatches' WHERE EXISTS (SELECT 1 FROM ops.dispatches d JOIN ops.dispatch_nodes dn ON dn.dispatch_id = d.id
                                       WHERE dn.node_id IN (SELECT id FROM sub) AND d.project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'backlog_items' WHERE EXISTS (SELECT 1 FROM ops.backlog_items
                                          WHERE home_node_id IN (SELECT id FROM sub) AND project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'context_documents' WHERE EXISTS (SELECT 1 FROM ops.context_documents
                                              WHERE node_id IN (SELECT id FROM sub) AND project_id IS DISTINCT FROM v_lo.id)
    UNION ALL SELECT 'dispatch_types' WHERE EXISTS (SELECT 1 FROM ops.dispatch_types WHERE project_id = v_lo.id)) x;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0023: framework rows outside the local-ops project, or project-owned dispatch types: %', v_bad;
  END IF;
  SELECT count(*) INTO v_n FROM ops.decisions d
   WHERE (SELECT count(*) FROM ops.decision_nodes dn WHERE dn.decision_id = d.id) <> 1;
  IF v_n > 0 THEN
    RAISE EXCEPTION '0023: % decisions without exactly one decision_nodes row', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM ops.dispatches WHERE component_id IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION '0023: % dispatches without a component', v_n;
  END IF;
  IF to_regprocedure('ops.adopt_orphans(uuid, timestamptz, timestamptz)') IS NULL THEN
    RAISE EXCEPTION '0023: ops.adopt_orphans(uuid, timestamptz, timestamptz) does not exist';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.sessions'::regclass AND attname = 'node_id'
                AND NOT attisdropped) THEN
    RAISE EXCEPTION '0023: column ops.sessions.node_id already exists';
  END IF;

  PERFORM set_config('ops_m0023.project', v_lo.id::text, true);
  PERFORM set_config('ops_m0023.fn_before', (
    SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc))
      FROM pg_proc p
     WHERE p.oid IN ('ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance)'::regprocedure,
                     'ops.create_component(public.ltree, text, text, text, text, jsonb)'::regprocedure,
                     'ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz)'::regprocedure,
                     'ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)'::regprocedure,
                     'ops.log_decision(public.ltree, text, text, jsonb, text, text, uuid, uuid)'::regprocedure,
                     'ops.add_backlog_item(public.ltree, ops.backlog_kind, text, text, uuid, ops.backlog_severity)'::regprocedure))::text,
    true);
  -- create_project(ltree) is not replaced (its '(deeper parents wait for release 2)' refusal stays); step 9 checks it
  PERFORM set_config('ops_m0023.create_project_before', (
    SELECT jsonb_build_object('src', p.prosrc, 'comment', obj_description(p.oid, 'pg_proc'))
      FROM pg_proc p WHERE p.oid = 'ops.create_project(public.ltree, text, text, jsonb)'::regprocedure)::text, true);
  PERFORM set_config('ops_m0023.fn_count_before',
    (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)::text, true);
  RAISE NOTICE 'local-ops rows before: components %, sessions % (% with a component), decisions % (% with supersedes), dispatches %, backlog_items %, context_documents %; ops functions %',
    (SELECT count(*) FROM ops.components WHERE project_id = v_lo.id),
    (SELECT count(*) FROM ops.sessions WHERE project_id = v_lo.id),
    (SELECT count(*) FROM ops.sessions WHERE project_id = v_lo.id AND component_id IS NOT NULL),
    (SELECT count(*) FROM ops.decisions WHERE project_id = v_lo.id),
    (SELECT count(*) FROM ops.decisions WHERE project_id = v_lo.id AND supersedes IS NOT NULL),
    (SELECT count(*) FROM ops.dispatches WHERE project_id = v_lo.id),
    (SELECT count(*) FROM ops.backlog_items WHERE project_id = v_lo.id),
    (SELECT count(*) FROM ops.context_documents WHERE project_id = v_lo.id),
    current_setting('ops_m0023.fn_count_before');
END $$;

-- the sessions that carry a component or a project now; each must have node_id after step 2
CREATE TEMP TABLE m0023_anchored ON COMMIT DROP AS
  SELECT id FROM ops.sessions WHERE component_id IS NOT NULL OR project_id IS NOT NULL;

-- ── 2. session node anchor; backfill from the component's node, else the project's node
ALTER TABLE ops.sessions ADD COLUMN node_id uuid REFERENCES ops.nodes(id);

UPDATE ops.sessions s
   SET node_id = coalesce((SELECT c.node_id FROM ops.components c WHERE c.id = s.component_id),
                          (SELECT p.node_id FROM ops.projects p WHERE p.id = s.project_id))
 WHERE s.component_id IS NOT NULL OR s.project_id IS NOT NULL;

DO $$
DECLARE v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM ops.sessions WHERE (component_id IS NOT NULL OR project_id IS NOT NULL) AND node_id IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION '0023: % sessions with a component or project have no node_id after the backfill', v_n;
  END IF;
  RAISE NOTICE 'sessions backfilled with node_id: %', (SELECT count(*) FROM ops.sessions WHERE node_id IS NOT NULL);
END $$;

-- ── 3. a dispatch's project may be NULL (framework dispatches after step 7)
ALTER TABLE ops.dispatches ALTER COLUMN project_id DROP NOT NULL;

-- ── 4. uniqueness by node
ALTER TABLE ops.components DROP CONSTRAINT components_project_id_key_key;
ALTER TABLE ops.context_documents DROP CONSTRAINT context_documents_project_id_doc_key_key;
ALTER TABLE ops.components ADD CONSTRAINT components_node_id_key UNIQUE (node_id);

-- ── 5a. open_session (0022 3a): global node and nodes outside a project accepted; session node; stale close by it
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
  -- the depth-2 ancestor's projects row, if any (none for the global node or a node outside a project)
  SELECT id INTO v_project FROM ops.projects
   WHERE node_id = (SELECT id FROM ops.nodes
                     WHERE path OPERATOR(public.=) public.subpath(n.path, 0, least(2, public.nlevel(n.path))));
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

  -- auto-close orphaned sessions whose session node is the opened node
  UPDATE ops.sessions
     SET status = 'closed', close_reason = 'stale', closed_at = now(),
         summary = coalesce(summary, 'auto-closed: stale')
   WHERE status = 'active' AND occurred_at < now() - make_interval(hours => v_stale_hours)
     AND coalesce(node_id, ops._derived_node(component_id, project_id)) = n.id;

  INSERT INTO ops.sessions (project_id, component_id, node_id, kind, scope, provenance, occurred_at)
  VALUES (v_project, n.component_id, n.id, p_kind, v_scope, p_provenance, coalesce(p_occurred_at, now()))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
COMMENT ON FUNCTION ops.open_session(public.ltree, text, ops.segment_scope, timestamptz, ops.provenance) IS
  'M5b release 2 (29a5b04f): node-keyed open_session; the session is anchored on the opened node (sessions.node_id); the global node and nodes outside a project are accepted (project_id NULL); stale close by session node.';

-- ── 5b. create_component (0018 3f): project node or plain node outside any component; project from the depth-2 ancestor
CREATE OR REPLACE FUNCTION ops.create_component(p_parent_path public.ltree, p_key text, p_kind text,
                                     p_repo_ref text DEFAULT NULL, p_verify_cmd text DEFAULT NULL,
                                     p_params jsonb DEFAULT '{}')
RETURNS ops.components LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_parent ops.nodes; v_project uuid; v_node uuid; r ops.components;
BEGIN
  v_parent := ops._node(p_parent_path);
  IF v_parent.kind = 'global'
     OR EXISTS (SELECT 1 FROM ops.nodes a
                 WHERE a.component_id IS NOT NULL AND v_parent.path OPERATOR(public.<@) a.path) THEN
    RAISE EXCEPTION 'parent % of component "%" must be a project or plain node outside any component',
      v_parent.path, p_key;
  END IF;
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid component key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_kind, ''))) = 0 THEN
    RAISE EXCEPTION 'component "%/%" needs a kind', v_parent.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of component "%/%" must be a JSON object', v_parent.key, p_key
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key AND component_id IS NOT NULL) THEN
    RAISE EXCEPTION 'component "%/%" already exists', v_parent.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under %', p_key, v_parent.path USING ERRCODE = 'check_violation';
  END IF;
  -- the depth-2 ancestor's projects row, if any
  SELECT id INTO v_project FROM ops.projects
   WHERE node_id = (SELECT id FROM ops.nodes
                     WHERE path OPERATOR(public.=) public.subpath(v_parent.path, 0, least(2, public.nlevel(v_parent.path))));

  INSERT INTO ops.components (project_id, key, kind, repo_ref, verify_cmd, params)
  VALUES (v_project, p_key, p_kind, p_repo_ref, p_verify_cmd, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title, component_id) VALUES (v_parent.id, p_key, 'node', p_key, r.id)
  RETURNING id INTO v_node;
  UPDATE ops.components SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;
COMMENT ON FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb) IS
  'M5b release 2 (29a5b04f): node-keyed create_component; the parent is a project node or a plain node outside any component (not the global node); project_id from the depth-2 ancestor, else NULL; duplicate = a node with that key under the parent.';

-- ── 5c. close_session (0022 3b): inline decisions on the session node; node-based supersedes check
CREATE OR REPLACE FUNCTION ops.close_session(p_session uuid, p_summary text, p_next_step text,
                                  p_decisions jsonb, p_reason ops.close_reason DEFAULT 'normal',
                                  p_closed_at timestamptz DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE s ops.sessions; d jsonb; n integer := 0; v_home uuid; v_root public.ltree; v_dec uuid; v_sup uuid;
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
  -- home of inline decisions: the session node; the scope of supersedes: the subtree of its depth-2 ancestor
  v_home := coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id));
  SELECT public.subpath(path, 0, least(2, public.nlevel(path))) INTO v_root FROM ops.nodes WHERE id = v_home;

  FOR d IN SELECT * FROM jsonb_array_elements(p_decisions) LOOP
    v_sup := (d->>'supersedes')::uuid;
    IF v_sup IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn JOIN ops.nodes x ON x.id = dn.node_id
                        WHERE dn.decision_id = v_sup AND x.path OPERATOR(public.<@) v_root) THEN
      RAISE EXCEPTION 'superseded decision % does not exist in % (the scope of session %)', v_sup, v_root, p_session
        USING ERRCODE = 'check_violation';
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
COMMENT ON FUNCTION ops.close_session(uuid, text, text, jsonb, ops.close_reason, timestamptz) IS
  'M5b release 2 (29a5b04f): inline decisions home on the session node (sessions.node_id, else derived) and carry the session''s project and component; a superseded decision must lie in the subtree of the session node''s depth-2 ancestor.';

-- ── 5d. create_dispatch (0022 2a): the session's node is its session node; the body is otherwise unchanged
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
    IF NOT (SELECT path FROM ops.nodes WHERE id = coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id)))
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

-- ── 5e. log_decision (0022 2b): supersedes through decision_nodes, the session's node is its session node
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
    IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn JOIN ops.nodes dnn ON dnn.id = dn.node_id
                                 WHERE dn.decision_id = x.id AND dnn.path OPERATOR(public.<@) v_root.path) THEN
      RAISE EXCEPTION 'superseded decision % does not exist in % (the scope of %)', p_supersedes, v_root.path,
        p_node_path USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_session IS NOT NULL THEN
    SELECT * INTO s FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (SELECT path FROM ops.nodes WHERE id = coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id)))
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

-- ── 6. adopt_orphans: nothing left to adopt since 0022
DROP FUNCTION ops.adopt_orphans(uuid, timestamptz, timestamptz);

-- ── 7. the local-ops project's rows lose their project (components first), then the projects row goes
UPDATE ops.components SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
UPDATE ops.sessions SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
UPDATE ops.decisions SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
UPDATE ops.dispatches SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
UPDATE ops.backlog_items SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
UPDATE ops.context_documents SET project_id = NULL WHERE project_id = current_setting('ops_m0023.project')::uuid;
DELETE FROM ops.projects WHERE id = current_setting('ops_m0023.project')::uuid;

-- ── 8. pending index keyed by component
DROP INDEX ops.dispatches_pending_idx;
CREATE INDEX dispatches_pending_idx ON ops.dispatches (component_id, priority) WHERE status = 'pending';

-- ── 9. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0023.fn_before')::jsonb; v_lo uuid := current_setting('ops_m0023.project')::uuid;
        v_bad text; v_n bigint; v_s uuid; v_ok boolean;
        v_sess_old text := 'ops._derived_node(s.component_id, s.project_id)';
        v_sess_new text := 'coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id))';
        v_sup_old text := E'IF NOT FOUND OR NOT (SELECT path FROM ops.nodes WHERE id = ops._derived_node(x.component_id, x.project_id))\n                        OPERATOR(public.<@) v_root.path THEN';
        v_sup_new text := E'IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn JOIN ops.nodes dnn ON dnn.id = dn.node_id\n                                 WHERE dn.decision_id = x.id AND dnn.path OPERATOR(public.<@) v_root.path) THEN';
BEGIN
  IF EXISTS (SELECT 1 FROM ops.projects WHERE key = 'local-ops' OR id = v_lo) THEN
    RAISE EXCEPTION '0023: the local-ops projects row still exists';
  END IF;
  SELECT string_agg(t, ', ') INTO v_bad FROM (
    SELECT 'components' t WHERE EXISTS (SELECT 1 FROM ops.components WHERE project_id = v_lo)
    UNION ALL SELECT 'sessions' WHERE EXISTS (SELECT 1 FROM ops.sessions WHERE project_id = v_lo)
    UNION ALL SELECT 'decisions' WHERE EXISTS (SELECT 1 FROM ops.decisions WHERE project_id = v_lo)
    UNION ALL SELECT 'dispatches' WHERE EXISTS (SELECT 1 FROM ops.dispatches WHERE project_id = v_lo)
    UNION ALL SELECT 'backlog_items' WHERE EXISTS (SELECT 1 FROM ops.backlog_items WHERE project_id = v_lo)
    UNION ALL SELECT 'context_documents' WHERE EXISTS (SELECT 1 FROM ops.context_documents WHERE project_id = v_lo)) x;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0023: rows still carry the local-ops project: %', v_bad;
  END IF;
  SELECT count(*) INTO v_n FROM pg_temp.m0023_anchored a JOIN ops.sessions s ON s.id = a.id WHERE s.node_id IS NULL;
  IF v_n > 0 OR (SELECT count(*) FROM pg_temp.m0023_anchored a JOIN ops.sessions s ON s.id = a.id)
                <> (SELECT count(*) FROM pg_temp.m0023_anchored) THEN
    RAISE EXCEPTION '0023: % sessions that had a component or project have no node_id', v_n;
  END IF;
  IF (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'ops.dispatches'::regclass AND attname = 'project_id') THEN
    RAISE EXCEPTION '0023: dispatches.project_id is still NOT NULL';
  END IF;
  IF (SELECT attnotnull FROM pg_attribute WHERE attrelid = 'ops.sessions'::regclass AND attname = 'node_id') THEN
    RAISE EXCEPTION '0023: sessions.node_id is NOT NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname IN ('components_project_id_key_key', 'context_documents_project_id_doc_key_key')
                AND connamespace = 'ops'::regnamespace) THEN
    RAISE EXCEPTION '0023: an old (project_id, ...) unique constraint still exists';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.components'::regclass AND contype = 'u'
                    AND pg_get_constraintdef(oid) = 'UNIQUE (node_id)') THEN
    RAISE EXCEPTION '0023: components UNIQUE (node_id) is missing';
  END IF;
  IF (SELECT pg_get_indexdef('ops.dispatches_pending_idx'::regclass))
     <> 'CREATE INDEX dispatches_pending_idx ON ops.dispatches USING btree (component_id, priority) WHERE (status = ''pending''::ops.dispatch_status)' THEN
    RAISE EXCEPTION '0023: dispatches_pending_idx is %', pg_get_indexdef('ops.dispatches_pending_idx'::regclass);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'adopt_orphans') THEN
    RAISE EXCEPTION '0023: adopt_orphans still exists';
  END IF;
  -- create_project keeps its project-parent refusal '(deeper parents wait for release 2)': 0023 does not lift it
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_bad
    FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace
     AND ((p.prosrc LIKE '%wait for release 2%' AND p.proname <> 'create_project')
          OR p.prosrc LIKE '%in the project of session%');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0023: function bodies still carry release-1 refusals: %', v_bad;
  END IF;
  IF (SELECT jsonb_build_object('src', p.prosrc, 'comment', obj_description(p.oid, 'pg_proc'))
        FROM pg_proc p WHERE p.oid = to_regprocedure('ops.create_project(public.ltree, text, text, jsonb)'))
     IS DISTINCT FROM current_setting('ops_m0023.create_project_before')::jsonb THEN
    RAISE EXCEPTION '0023: create_project(ltree) body or comment changed';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)
     <> current_setting('ops_m0023.fn_count_before')::bigint - 1 THEN
    RAISE EXCEPTION '0023: the number of ops functions is not the old count minus adopt_orphans';
  END IF;

  -- replaced functions: same signature, result, security, search_path, owner and ACL; comment unchanged except on
  -- open_session, create_component and close_session ('M5b release 2 (' from 0023); add_backlog_item untouched
  SELECT string_agg(b.key, ', ') INTO v_bad
    FROM jsonb_each(v_before) b LEFT JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE p.oid IS NULL
      OR jsonb_build_object('args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
                            'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
                            'acl', p.proacl::text)
         IS DISTINCT FROM b.value - 'src' - 'comment'
      OR CASE WHEN p.proname IN ('open_session', 'create_component', 'close_session')
              THEN coalesce(obj_description(p.oid, 'pg_proc') NOT LIKE 'M5b release 2 (%', true)
              ELSE obj_description(p.oid, 'pg_proc') IS DISTINCT FROM b.value->>'comment' END;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0023: signature, ACL or comment changed: %', v_bad;
  END IF;
  -- create_dispatch / log_decision: the old body with only the derivation calls changed; add_backlog_item unchanged
  SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM jsonb_each(v_before) b JOIN pg_proc p ON p.oid = to_regprocedure(b.key)
   WHERE (p.proname = 'create_dispatch'
          AND (strpos(b.value->>'src', v_sess_old) = 0
               OR p.prosrc IS DISTINCT FROM replace(b.value->>'src', v_sess_old, v_sess_new)))
      OR (p.proname = 'log_decision'
          AND (strpos(b.value->>'src', v_sess_old) = 0 OR strpos(b.value->>'src', v_sup_old) = 0
               OR p.prosrc IS DISTINCT FROM replace(replace(b.value->>'src', v_sup_old, v_sup_new), v_sess_old, v_sess_new)))
      OR (p.proname = 'add_backlog_item' AND p.prosrc IS DISTINCT FROM b.value->>'src');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0023: bodies differ from the old bodies with the derivation change: %', v_bad;
  END IF;

  -- a framework session and dispatch, rolled back: open_session on global.local-ops anchors the session there with
  -- no project, and create_dispatch on global.local-ops.core accepts it
  BEGIN
    v_s := ops.open_session(p_node_path => 'global.local-ops'::public.ltree, p_kind => 'planning');
    v_ok := (SELECT node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.local-ops') AND project_id IS NULL
                    AND component_id IS NULL
               FROM ops.sessions WHERE id = v_s)
            AND (SELECT project_id IS NULL AND session_id = v_s
                   FROM ops.create_dispatch(p_node_path => 'global.local-ops.core'::public.ltree, p_dispatch_type => 'investigation',
                                            p_title => '0023 probe', p_prompt => 'p', p_session => v_s));
    RAISE EXCEPTION USING ERRCODE = 'P0923', MESSAGE = coalesce(v_ok::text, 'null');
  EXCEPTION WHEN SQLSTATE 'P0923' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0023: framework session / dispatch probe failed (%)', v_bad;
  END IF;
  RAISE NOTICE 'rows after: components % with no project, sessions with node_id %, projects %',
    (SELECT count(*) FROM ops.components WHERE project_id IS NULL),
    (SELECT count(*) FROM ops.sessions WHERE node_id IS NOT NULL), (SELECT count(*) FROM ops.projects);
  RAISE NOTICE '0023 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0023_node_anchor_drop_project_row');

COMMIT;
