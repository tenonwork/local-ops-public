-- 0010_spine_b_backfill
-- Dispatch f1feabda. B of the staged spine (685cce74): backfill only. M1 (0008) created the new tables, M2
-- (0009) the nullable columns; M3 adds defaults, NOT NULL and UNIQUE after checks, M4 adds functions with
-- shims, M5 cleans up.
-- Decisions:
--   48f736f7 / 685cce74 B is a numbered migration through the runner (tests/sql/0009 block 3 skips once a
--            newer migration exists).
--   5ecda01f the local-ops project row is not deleted here and no project_id is changed or nulled; B only
--            fills node columns and links. M5 deletes the row later.
--   Public edition: creates the local-ops project and core component when absent, so a fresh database can
--            apply from zero.
--   f0102925 nodes global (root, kind global), global.local-ops (kind node, title "local-ops framework"),
--            global.local-ops.core (kind node, component_id = the core component). projects.node_id of
--            local-ops -> local-ops node; components.node_id of core -> core node. Home rule: component_id =
--            core -> core node; no component -> local-ops node. Applies to backlog_items.home_node_id,
--            decision_nodes and dispatch_nodes (dispatches always have a component).
--   2eecc405 sessions.scope = global for all rows. task_status: active -> open; closed with close_reason
--            stale -> unfinished; other closed -> closed. window_id only where occurred_at is in
--            [windows.started_at, windows.resets_at), otherwise NULL permanently. resumed_from, usage_open,
--            usage_close and path_id stay NULL.
--   06f63f0b decisions.trust_status = approved; backlog_items.severity = untriaged; backlog_items.kind from
--            the 'kind:<value>' prefix of source (task, followup, proposal, discussion, allowed_bug; any
--            other or missing prefix raises). dispatch_types.project_id stays NULL. The fill lives in the
--            owner-only helper ops._spine_backfill(), which only fills NULLs and inserts missing nodes and
--            links, so it is idempotent. 0010 calls it once; M3 calls it again and then drops it.
--   context_documents has 0 rows; doc types for existing docs need an operator-reviewed mapping that does
--            not exist yet, so the helper raises on any row with node_id or doc_type NULL instead of guessing.
--   8faeee76 ltree lives in public; paths are compared as text here, never with a plain = on ltree.
-- Writes: INSERT into nodes, decision_nodes, dispatch_nodes; UPDATE of M2 columns only where NULL. No
-- pre-existing column value changes; the md5 fingerprint check below proves it.
-- No owner role is named: the helper belongs to the applying role (local_ops in production, ops_dev in
-- rehearsal) and nobody else can execute it.

BEGIN;

CREATE FUNCTION ops._spine_backfill()
RETURNS jsonb LANGUAGE plpgsql SET search_path = ops, pg_temp AS $$
DECLARE
  v_project uuid; v_component uuid;
  g ops.nodes; lo ops.nodes; co ops.nodes;
  v_nodes int := 0; n int;
  r jsonb := '{}';
  v_bad text;
BEGIN
  -- a. framework nodes
  SELECT id INTO v_project FROM ops.projects WHERE key = 'local-ops';
  IF NOT FOUND THEN
    INSERT INTO ops.projects (key, name) VALUES ('local-ops', 'local-ops') RETURNING id INTO v_project;
  END IF;
  SELECT id INTO v_component FROM ops.components WHERE key = 'core' AND project_id = v_project;
  IF NOT FOUND THEN
    INSERT INTO ops.components (project_id, key, kind) VALUES (v_project, 'core', 'framework')
    RETURNING id INTO v_component;
  END IF;

  SELECT * INTO g FROM ops.nodes WHERE kind = 'global';
  IF NOT FOUND THEN
    INSERT INTO ops.nodes (key, kind, title) VALUES ('global', 'global', 'Global') RETURNING * INTO g;
    v_nodes := v_nodes + 1;
  END IF;
  SELECT * INTO lo FROM ops.nodes WHERE parent_id = g.id AND key = 'local-ops';
  IF NOT FOUND THEN
    INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (g.id, 'local-ops', 'node', 'local-ops framework')
    RETURNING * INTO lo;
    v_nodes := v_nodes + 1;
  END IF;
  SELECT * INTO co FROM ops.nodes WHERE parent_id = lo.id AND key = 'core';
  IF NOT FOUND THEN
    INSERT INTO ops.nodes (parent_id, key, kind, title, component_id) VALUES (lo.id, 'core', 'node', 'core', v_component)
    RETURNING * INTO co;
    v_nodes := v_nodes + 1;
  END IF;
  IF g.path::text <> 'global' OR lo.path::text <> 'global.local-ops' OR lo.kind <> 'node'
     OR co.path::text <> 'global.local-ops.core' OR co.kind <> 'node'
     OR co.component_id IS DISTINCT FROM v_component THEN
    RAISE EXCEPTION 'spine backfill: framework nodes do not match (global %, local-ops % %, core % % %)',
      g.path::text, lo.path::text, lo.kind, co.path::text, co.kind, co.component_id USING ERRCODE = 'check_violation';
  END IF;
  r := r || jsonb_build_object('nodes_inserted', v_nodes);

  -- g. context_documents: no guessing of node or doc type (checked early; any raise aborts the whole call)
  SELECT string_agg(doc_key, ', ' ORDER BY doc_key) INTO v_bad
    FROM ops.context_documents WHERE node_id IS NULL OR doc_type IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'spine backfill: context_documents without node_id or doc_type need the operator mapping: %', v_bad
      USING ERRCODE = 'check_violation';
  END IF;

  -- home rule guard: every component referenced by a row to fill must be core
  SELECT string_agg(DISTINCT t || ':' || component_id::text, ', ') INTO v_bad FROM (
    SELECT 'decisions' AS t, d.component_id FROM ops.decisions d
     WHERE d.component_id IS NOT NULL AND d.component_id <> v_component
       AND NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn WHERE dn.decision_id = d.id)
    UNION ALL
    SELECT 'backlog_items', b.component_id FROM ops.backlog_items b
     WHERE b.home_node_id IS NULL AND b.component_id IS NOT NULL AND b.component_id <> v_component
    UNION ALL
    SELECT 'dispatches', x.component_id FROM ops.dispatches x
     WHERE x.component_id <> v_component
       AND NOT EXISTS (SELECT 1 FROM ops.dispatch_nodes xn WHERE xn.dispatch_id = x.id)) s;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'spine backfill: no home rule for component(s) %', v_bad USING ERRCODE = 'check_violation';
  END IF;

  -- b. registry node columns
  UPDATE ops.projects SET node_id = lo.id WHERE id = v_project AND node_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('projects_node_id', n);
  UPDATE ops.components SET node_id = co.id WHERE id = v_component AND node_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('components_node_id', n);

  -- c. sessions (segments)
  UPDATE ops.sessions SET scope = 'global' WHERE scope IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('sessions_scope', n);
  UPDATE ops.sessions
     SET task_status = CASE WHEN status = 'active' THEN 'open'
                            WHEN close_reason = 'stale' THEN 'unfinished'
                            ELSE 'closed' END::ops.task_status
   WHERE task_status IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('sessions_task_status', n);
  UPDATE ops.sessions s SET window_id = w.id
    FROM ops.windows w
   WHERE s.window_id IS NULL AND s.occurred_at >= w.started_at AND s.occurred_at < w.resets_at;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('sessions_window_id', n);

  -- d. decisions
  UPDATE ops.decisions SET trust_status = 'approved' WHERE trust_status IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('decisions_trust_status', n);
  INSERT INTO ops.decision_nodes (decision_id, node_id)
  SELECT d.id, CASE WHEN d.component_id IS NULL THEN lo.id ELSE co.id END
    FROM ops.decisions d
   WHERE NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn WHERE dn.decision_id = d.id);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('decision_nodes_inserted', n);

  -- e. backlog items
  SELECT string_agg(id::text || ' (' || coalesce(source, 'NULL') || ')', ', ' ORDER BY id) INTO v_bad
    FROM ops.backlog_items
   WHERE kind IS NULL
     AND coalesce(substring(source FROM '^kind:([a-z_]+)(?:\||$)'), '')
         NOT IN ('task', 'followup', 'proposal', 'discussion', 'allowed_bug');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'spine backfill: backlog_items without a valid kind:<value> source prefix: %', v_bad
      USING ERRCODE = 'check_violation';
  END IF;
  UPDATE ops.backlog_items SET severity = 'untriaged' WHERE severity IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('backlog_severity', n);
  UPDATE ops.backlog_items SET kind = substring(source FROM '^kind:([a-z_]+)(?:\||$)')::ops.backlog_kind
   WHERE kind IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('backlog_kind', n);
  UPDATE ops.backlog_items SET home_node_id = CASE WHEN component_id IS NULL THEN lo.id ELSE co.id END
   WHERE home_node_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('backlog_home_node_id', n);

  -- f. dispatches (component_id is NOT NULL)
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id)
  SELECT x.id, co.id FROM ops.dispatches x
   WHERE NOT EXISTS (SELECT 1 FROM ops.dispatch_nodes xn WHERE xn.dispatch_id = x.id);
  GET DIAGNOSTICS n = ROW_COUNT; r := r || jsonb_build_object('dispatch_nodes_inserted', n);

  -- h. counts per step
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION ops._spine_backfill() FROM PUBLIC;

-- Public edition: a fresh database has no framework project or component. Create them before the
-- fingerprint below, so the fingerprint covers them and the helper only fills node_id on them.
DO $$
DECLARE v_project uuid;
BEGIN
  INSERT INTO ops.projects (key, name) VALUES ('local-ops', 'local-ops') ON CONFLICT DO NOTHING;
  SELECT id INTO v_project FROM ops.projects WHERE key = 'local-ops';
  INSERT INTO ops.components (project_id, key, kind) VALUES (v_project, 'core', 'framework')
    ON CONFLICT DO NOTHING;
END $$;

-- fingerprint of the pre-M2 columns, before the fill
DO $$ BEGIN
  PERFORM set_config('ops_spine_b.fp_before', (
    SELECT jsonb_build_object(
      'sessions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['window_id', 'scope', 'task_status', 'usage_open',
                     'usage_close', 'resumed_from', 'path_id'])::text, E'\n' ORDER BY t.id), '')) FROM ops.sessions t),
      'decisions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'trust_status')::text, E'\n' ORDER BY t.id), ''))
                      FROM ops.decisions t),
      'backlog_items', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['home_node_id', 'severity', 'kind',
                          'resolved_by'])::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
      'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
      'projects', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.projects t),
      'components', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                       FROM ops.components t))::text), true);
  RAISE NOTICE 'fingerprint before: %', current_setting('ops_spine_b.fp_before');
END $$;

DO $$ BEGIN
  RAISE NOTICE 'spine backfill: %', ops._spine_backfill();
END $$;

-- checks: any failure aborts the migration
DO $$
DECLARE v_after text; v_bad text;
BEGIN
  SELECT jsonb_build_object(
      'sessions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['window_id', 'scope', 'task_status', 'usage_open',
                     'usage_close', 'resumed_from', 'path_id'])::text, E'\n' ORDER BY t.id), '')) FROM ops.sessions t),
      'decisions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'trust_status')::text, E'\n' ORDER BY t.id), ''))
                      FROM ops.decisions t),
      'backlog_items', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['home_node_id', 'severity', 'kind',
                          'resolved_by'])::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
      'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
      'projects', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.projects t),
      'components', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                       FROM ops.components t))::text
    INTO v_after;
  RAISE NOTICE 'fingerprint after:  %', v_after;
  IF v_after::jsonb <> current_setting('ops_spine_b.fp_before')::jsonb THEN
    RAISE EXCEPTION 'spine backfill changed pre-existing columns';
  END IF;

  SELECT string_agg(c, ', ') INTO v_bad FROM (
    SELECT 'projects.node_id' AS c WHERE EXISTS (SELECT 1 FROM ops.projects WHERE node_id IS NULL)
    UNION ALL SELECT 'components.node_id' WHERE EXISTS (SELECT 1 FROM ops.components WHERE node_id IS NULL)
    UNION ALL SELECT 'sessions.scope' WHERE EXISTS (SELECT 1 FROM ops.sessions WHERE scope IS NULL)
    UNION ALL SELECT 'sessions.task_status' WHERE EXISTS (SELECT 1 FROM ops.sessions WHERE task_status IS NULL)
    UNION ALL SELECT 'decisions.trust_status' WHERE EXISTS (SELECT 1 FROM ops.decisions WHERE trust_status IS NULL)
    UNION ALL SELECT 'backlog_items.severity' WHERE EXISTS (SELECT 1 FROM ops.backlog_items WHERE severity IS NULL)
    UNION ALL SELECT 'backlog_items.kind' WHERE EXISTS (SELECT 1 FROM ops.backlog_items WHERE kind IS NULL)
    UNION ALL SELECT 'backlog_items.home_node_id' WHERE EXISTS (SELECT 1 FROM ops.backlog_items WHERE home_node_id IS NULL)) s;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'spine backfill left NULLs in %', v_bad;
  END IF;

  IF (SELECT count(*) FROM ops.decision_nodes) <> (SELECT count(*) FROM ops.decisions) THEN
    RAISE EXCEPTION 'decision_nodes % <> decisions %', (SELECT count(*) FROM ops.decision_nodes), (SELECT count(*) FROM ops.decisions);
  END IF;
  IF (SELECT count(*) FROM ops.dispatch_nodes) <> (SELECT count(*) FROM ops.dispatches) THEN
    RAISE EXCEPTION 'dispatch_nodes % <> dispatches %', (SELECT count(*) FROM ops.dispatch_nodes), (SELECT count(*) FROM ops.dispatches);
  END IF;
  IF (SELECT array_agg(path::text || ':' || kind ORDER BY path::text COLLATE "C") FROM ops.nodes)
     IS DISTINCT FROM ARRAY['global:global', 'global.local-ops:node', 'global.local-ops.core:node'] THEN
    RAISE EXCEPTION 'nodes are not exactly global, global.local-ops, global.local-ops.core: %',
      (SELECT array_agg(path::text ORDER BY path::text COLLATE "C") FROM ops.nodes);
  END IF;
  RAISE NOTICE 'spine backfill checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0010_spine_b_backfill');

COMMIT;
