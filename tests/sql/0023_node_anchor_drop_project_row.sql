-- tests/sql/0023_node_anchor_drop_project_row.sql
-- Tests for migrations/0023_node_anchor_drop_project_row.sql. Run as the schema owner against a non-production
-- database where 0023 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0023_node_anchor_drop_project_row.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0023a, plain node t0023loose and their
-- components, asserts only on rows it creates (plus catalog state and invariants 0023 establishes), and counts
-- relative to the starting state. Opens on framework nodes can auto-close other stale sessions there; the ROLLBACK
-- undoes that.

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
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents)))::text, false);
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

-- asserts p_sql raises p_state with a message containing p_like
CREATE FUNCTION pg_temp.rejects(p_sql text, p_state text, p_like text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  PERFORM pg_temp.check(e LIKE p_state || ' %' || p_like || '%', p_what || ': ' || coalesce(e, 'success'));
END $$;

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

CREATE FUNCTION pg_temp.node(p_path text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ops.nodes WHERE path::text = p_path;
$$;

-- project / component / session node (path) / scope / status of a session
CREATE FUNCTION pg_temp.sess(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(p.key, '-') || '/' || coalesce(c.key, '-') || '/' || coalesce(n.path::text, '-') || '/'
         || s.scope::text || '/' || s.status
    FROM ops.sessions s LEFT JOIN ops.projects p ON p.id = s.project_id LEFT JOIN ops.components c ON c.id = s.component_id
         LEFT JOIN ops.nodes n ON n.id = s.node_id
   WHERE s.id = p_id;
$$;

-- 0. fixtures: project t0023a (component ca, plain node free, sub-node ca.sub), plain node t0023loose under global
--    (component lc, created under a plain parent outside any project)
DO $$
DECLARE p ops.projects; c ops.components; v_id uuid;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  p := ops.create_project('global'::public.ltree, 't0023a', 'T0023 A');
  PERFORM set_config('ops_test.pa', p.id::text, true);
  PERFORM set_config('ops_test.pa_node', p.node_id::text, true);
  c := ops.create_component('global.t0023a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM pg_temp.check(c.project_id = p.id, 'component under a project node carries the project');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  PERFORM set_config('ops_test.ca_node', c.node_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (p.node_id, 'free', 'node', 'free') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.free_node', v_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (c.node_id, 'sub', 'node', 'sub');
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.node('global'), 't0023loose', 'node', 'loose')
  RETURNING id INTO v_id;
  PERFORM set_config('ops_test.loose_node', v_id::text, true);
  c := ops.create_component('global.t0023loose'::public.ltree, 'lc', 'service', NULL, 'npm test');
  PERFORM pg_temp.check(c.project_id IS NULL AND (SELECT path::text = 'global.t0023loose.lc' AND component_id = c.id
                                                   FROM ops.nodes WHERE id = c.node_id),
                        'component under a plain node outside any project: project NULL, node under the parent');
  PERFORM set_config('ops_test.lc', c.id::text, true);
  RAISE NOTICE 'ok   0 fixtures (t0023a/ca, free, ca.sub; t0023loose/lc)';
END $$;

-- 1. catalog and invariants 0023 establishes
DO $$
DECLARE v_bad text; v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  PERFORM pg_temp.check((SELECT max(version) FROM ops.schema_migrations) >= '0023_node_anchor_drop_project_row',
                        '0023 is applied');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.projects WHERE key = 'local-ops'), 'no local-ops projects row');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.projects p JOIN ops.nodes n ON n.id = p.node_id
                                     WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree),
                        'no project on the global.local-ops subtree');
  PERFORM pg_temp.check((SELECT string_agg(path::text, ',' ORDER BY path::text) FROM ops.nodes
                          WHERE path::text IN ('global.local-ops', 'global.local-ops.core')) = 'global.local-ops,global.local-ops.core',
                        'framework nodes kept');
  -- framework rows carry no project
  SELECT string_agg(t, ', ') INTO v_bad FROM (
    SELECT 'components' t WHERE EXISTS (SELECT 1 FROM ops.components c JOIN ops.nodes n ON n.id = c.node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND c.project_id IS NOT NULL)
    UNION ALL SELECT 'sessions' WHERE EXISTS (SELECT 1 FROM ops.sessions s JOIN ops.nodes n ON n.id = s.node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND s.project_id IS NOT NULL)
    UNION ALL SELECT 'decisions' WHERE EXISTS (SELECT 1 FROM ops.decisions d JOIN ops.decision_nodes dn ON dn.decision_id = d.id
                                         JOIN ops.nodes n ON n.id = dn.node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND d.project_id IS NOT NULL)
    UNION ALL SELECT 'dispatches' WHERE EXISTS (SELECT 1 FROM ops.dispatches d JOIN ops.dispatch_nodes dn ON dn.dispatch_id = d.id
                                         JOIN ops.nodes n ON n.id = dn.node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND d.project_id IS NOT NULL)
    UNION ALL SELECT 'backlog_items' WHERE EXISTS (SELECT 1 FROM ops.backlog_items b JOIN ops.nodes n ON n.id = b.home_node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND b.project_id IS NOT NULL)
    UNION ALL SELECT 'context_documents' WHERE EXISTS (SELECT 1 FROM ops.context_documents d JOIN ops.nodes n ON n.id = d.node_id
                                         WHERE n.path OPERATOR(public.<@) 'global.local-ops'::public.ltree AND d.project_id IS NOT NULL)) x;
  PERFORM pg_temp.check(v_bad IS NULL, 'framework rows with a project: ' || coalesce(v_bad, ''));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.sessions
                                     WHERE (component_id IS NOT NULL OR project_id IS NOT NULL) AND node_id IS NULL
                                       AND recorded_at < now()),
                        'every session with a component or project has node_id');

  PERFORM pg_temp.check((SELECT NOT attnotnull FROM pg_attribute WHERE attrelid = 'ops.dispatches'::regclass AND attname = 'project_id'),
                        'dispatches.project_id nullable');
  PERFORM pg_temp.check((SELECT NOT attnotnull AND atttypid = 'uuid'::regtype FROM pg_attribute
                          WHERE attrelid = 'ops.sessions'::regclass AND attname = 'node_id' AND NOT attisdropped),
                        'sessions.node_id uuid, nullable');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.sessions'::regclass AND contype = 'f'
                                  AND confrelid = 'ops.nodes'::regclass AND pg_get_constraintdef(oid) LIKE 'FOREIGN KEY (node_id) %'),
                        'sessions.node_id references ops.nodes');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE connamespace = 'ops'::regnamespace
                                     AND conname IN ('components_project_id_key_key', 'context_documents_project_id_doc_key_key')),
                        'old (project_id, key) and (project_id, doc_key) uniques absent');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.components'::regclass AND contype = 'u'
                                  AND pg_get_constraintdef(oid) = 'UNIQUE (node_id)'), 'components UNIQUE (node_id)');
  PERFORM pg_temp.check((SELECT NOT attnotnull FROM pg_attribute WHERE attrelid = 'ops.components'::regclass AND attname = 'node_id'),
                        'components.node_id stays nullable');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'context_documents_node_id_doc_type_key')
                        = 'UNIQUE (node_id, doc_type)', 'context_documents UNIQUE (node_id, doc_type) kept');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.nodes'::regclass AND contype = 'u'
                                  AND pg_get_constraintdef(oid) = 'UNIQUE (parent_id, key)'), 'nodes UNIQUE (parent_id, key) kept');
  -- under search_path = ops, pg_get_indexdef prints the enum type without its schema
  PERFORM pg_temp.check(replace(pg_get_indexdef('ops.dispatches_pending_idx'::regclass), '::dispatch_status', '::ops.dispatch_status')
                        = 'CREATE INDEX dispatches_pending_idx ON ops.dispatches USING btree (component_id, priority) WHERE (status = ''pending''::ops.dispatch_status)',
                        'dispatches_pending_idx: ' || pg_get_indexdef('ops.dispatches_pending_idx'::regclass));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'adopt_orphans'),
                        'adopt_orphans absent');
  SELECT string_agg(oid::regprocedure::text, ', ') INTO v_bad FROM pg_proc
   WHERE pronamespace = 'ops'::regnamespace
     -- create_project keeps its project-parent refusal '(deeper parents wait for release 2)': 0023 does not lift it
     AND ((prosrc LIKE '%wait for release 2%' AND proname <> 'create_project') OR prosrc LIKE '%in the project of session%');
  PERFORM pg_temp.check(v_bad IS NULL, 'bodies with release-1 refusals: ' || coalesce(v_bad, ''));
  -- create_project(ltree) is not replaced by 0023 (4b6c7575): its release-1 comment and refusal stay
  -- 0035 replaces it with a trailing p_summary and a 'Node summary release (' comment; the refusal text stays
  IF newest >= '0035' THEN
    RAISE NOTICE 'skip 1 release-1 comment of create_project(ltree) (newest migration is %)', newest;
    PERFORM pg_temp.check(
      (SELECT obj_description(oid, 'pg_proc') LIKE 'Node summary release (%'
              AND strpos(prosrc, 'parent of project "%" must be the global node, not % (deeper parents wait for release 2)') > 0
         FROM pg_proc WHERE oid = to_regprocedure('ops.create_project(public.ltree,text,text,jsonb,text)')),
      'create_project(ltree) carries the 0035 comment and keeps its project-parent refusal');
  ELSE
  PERFORM pg_temp.check(
    (SELECT obj_description(oid, 'pg_proc') = 'M5b release 1 (cd187cd6): node-keyed create_project; the parent must be the global node.'
            AND strpos(prosrc, 'parent of project "%" must be the global node, not % (deeper parents wait for release 2)') > 0
       FROM pg_proc WHERE oid = to_regprocedure('ops.create_project(public.ltree,text,text,jsonb)')),
    'create_project(ltree) keeps its release-1 comment and project-parent refusal');
  END IF;

  -- replaced functions: one overload, SECURITY DEFINER, search_path, owner, ACL (ops_planner only), comments
  SELECT string_agg(e.sig, ', ') INTO v_bad
    FROM (VALUES
      ('ops.open_session(public.ltree,text,ops.segment_scope,timestamptz,ops.provenance)', 'M5b release 2 (%'),
      -- 0035 adds the trailing p_summary text with a 'Node summary release (' comment
      (CASE WHEN newest >= '0035' THEN 'ops.create_component(public.ltree,text,text,text,text,jsonb,text)'
            ELSE 'ops.create_component(public.ltree,text,text,text,text,jsonb)' END,
       CASE WHEN newest >= '0035' THEN 'Node summary release (%' ELSE 'M5b release 2 (%' END),
      ('ops.close_session(uuid,text,text,jsonb,ops.close_reason,timestamptz)', 'M5b release 2 (%'),
      -- 0029 adds the trailing p_task_files text[] (the function is replaced, not overloaded)
      (CASE WHEN newest >= '0029' THEN 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid,text[])'
            ELSE 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid)' END,
       'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.'),
      ('ops.log_decision(public.ltree,text,text,jsonb,text,text,uuid,uuid)',
       'M5b release 1 (cd187cd6): node-keyed log_decision; home node = the path''s node, global path accepted.'),
      ('ops.add_backlog_item(public.ltree,ops.backlog_kind,text,text,uuid,ops.backlog_severity)',
       'M5b release 1 (cd187cd6): node-keyed add_backlog_item; home node = the path''s node, global path accepted.')) e(sig, cmt)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE p.oid IS NULL OR NOT p.prosecdef OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
      OR pg_get_userbyid(p.proowner) <> v_owner OR p.proacl::text <> format('{%1$s=X/%1$s,ops_planner=X/%1$s}', v_owner)
      OR coalesce(obj_description(p.oid, 'pg_proc') NOT LIKE e.cmt, true)
      OR (SELECT count(*) FROM pg_proc q WHERE q.pronamespace = 'ops'::regnamespace AND q.proname = p.proname) <> 1;
  PERFORM pg_temp.check(v_bad IS NULL, 'replaced functions catalog: ' || coalesce(v_bad, ''));
  RAISE NOTICE 'ok   1 catalog: no local-ops project, framework rows without project, node_id, uniques, index, adopt_orphans gone, functions';
END $$;

-- 2. open_session: project from the depth-2 ancestor, session node = the opened node, scope default unchanged
DO $$
DECLARE v_s uuid;
BEGIN
  v_s := ops.open_session('global'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/-/global/project/active', 'global node: ' || pg_temp.sess(v_s));
  PERFORM set_config('ops_test.s_global', v_s::text, true);
  v_s := ops.open_session('global.t0023loose'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/-/global.t0023loose/project/active', 'plain node outside a project: ' || pg_temp.sess(v_s));
  v_s := ops.open_session('global.t0023loose.lc'::public.ltree, 'execution');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/lc/global.t0023loose.lc/project/active', 'component outside a project: ' || pg_temp.sess(v_s));
  PERFORM set_config('ops_test.s_lc', v_s::text, true);
  v_s := ops.open_session('global.local-ops'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/-/global.local-ops/global/active', 'global.local-ops: ' || pg_temp.sess(v_s));
  PERFORM set_config('ops_test.s_fw', v_s::text, true);
  v_s := ops.open_session('global.local-ops.core'::public.ltree, 'execution');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/core/global.local-ops.core/global/active', 'global.local-ops.core: ' || pg_temp.sess(v_s));
  PERFORM set_config('ops_test.s_core', v_s::text, true);
  v_s := ops.open_session('global.t0023a'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = 't0023a/-/global.t0023a/project/active', 'project node: ' || pg_temp.sess(v_s));
  PERFORM set_config('ops_test.s_pa', v_s::text, true);
  v_s := ops.open_session('global.t0023a.ca'::public.ltree, 'execution');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = 't0023a/ca/global.t0023a.ca/project/active', 'project component: ' || pg_temp.sess(v_s));
  v_s := ops.open_session('global.t0023a.ca.sub'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = 't0023a/-/global.t0023a.ca.sub/project/active', 'sub-node: ' || pg_temp.sess(v_s));
  v_s := ops.open_session('global'::public.ltree, 'planning', 'global');
  PERFORM pg_temp.check(pg_temp.sess(v_s) = '-/-/global/global/active', 'explicit scope wins on the global node');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0023nosuch'::public.ltree, 'planning')$q$, 'P0001',
                          'unknown node global.t0023nosuch', 'unknown node still refused');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global'::public.ltree, 'planning', NULL, now() - interval '1 hour')$q$,
                          '23514', 'occurred_at must be given exactly when provenance is reconstructed', 'validations unchanged');
  RAISE NOTICE 'ok   2 open_session: global (scope project), loose node, local-ops nodes (scope global), project nodes';
END $$;

-- 3. stale auto-close by session node (node_id, else derived)
DO $$
DECLARE v_hours integer := coalesce(
          (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
        v_stale timestamptz := now() - make_interval(hours => v_hours + 1);
        v_loose uuid; v_fw uuid; v_derived uuid; v_free uuid; v_fresh uuid; v_s uuid;
BEGIN
  INSERT INTO ops.sessions (node_id, kind, occurred_at) VALUES (pg_temp.id('loose_node'), 'planning', v_stale)
  RETURNING id INTO v_loose;                                                      -- node set, no project
  INSERT INTO ops.sessions (node_id, kind, occurred_at) VALUES (pg_temp.node('global.local-ops'), 'planning', v_stale)
  RETURNING id INTO v_fw;                                                         -- framework node, no project
  INSERT INTO ops.sessions (project_id, kind, occurred_at) VALUES (pg_temp.id('pa'), 'planning', v_stale)
  RETURNING id INTO v_derived;                                                    -- no node: derived = project node
  INSERT INTO ops.sessions (project_id, node_id, kind, occurred_at) VALUES (pg_temp.id('pa'), pg_temp.id('free_node'), 'planning', v_stale)
  RETURNING id INTO v_free;                                                       -- node wins over the derived project node
  INSERT INTO ops.sessions (node_id, kind, occurred_at)
  VALUES (pg_temp.id('loose_node'), 'planning', now() - make_interval(hours => v_hours - 1)) RETURNING id INTO v_fresh;

  v_s := ops.open_session('global.t0023loose'::public.ltree, 'planning');
  PERFORM pg_temp.check((SELECT (status, close_reason, summary) = ('closed', 'stale', 'auto-closed: stale') FROM ops.sessions WHERE id = v_loose),
                        'stale session on the loose node closed');
  PERFORM pg_temp.check((SELECT status = 'active' FROM ops.sessions WHERE id = v_fresh), 'fresh session on the loose node untouched');
  PERFORM pg_temp.check((SELECT bool_and(status = 'active') FROM ops.sessions WHERE id IN (v_fw, v_derived, v_free)),
                        'sessions on other nodes untouched by the loose open');
  v_s := ops.open_session('global.local-ops'::public.ltree, 'planning');
  PERFORM pg_temp.check((SELECT status = 'closed' AND close_reason = 'stale' FROM ops.sessions WHERE id = v_fw),
                        'stale framework session (node_id set, project NULL) closed');
  v_s := ops.open_session('global.t0023a'::public.ltree, 'planning');
  PERFORM pg_temp.check((SELECT status = 'closed' FROM ops.sessions WHERE id = v_derived), 'derived project-node session closed');
  PERFORM pg_temp.check((SELECT status = 'active' FROM ops.sessions WHERE id = v_free),
                        'session anchored on free (same project) untouched by the project open');
  v_s := ops.open_session('global.t0023a.free'::public.ltree, 'planning');
  PERFORM pg_temp.check((SELECT status = 'closed' FROM ops.sessions WHERE id = v_free), 'session anchored on free closed by the free open');
  RAISE NOTICE 'ok   3 stale auto-close by session node (node_id first, derived fallback)';
END $$;

-- 4. create_dispatch / log_decision with a framework session (node global.local-ops, no project)
DO $$
DECLARE d ops.dispatches; x ops.decisions; v_fw_dec uuid; v_pa_dec uuid; v_before bigint;
        v_fw uuid := pg_temp.id('s_fw'); v_core uuid := pg_temp.id('s_core'); v_pa uuid := pg_temp.id('s_pa');
BEGIN
  PERFORM pg_temp.check((SELECT project_id IS NULL AND node_id = pg_temp.node('global.local-ops') FROM ops.sessions WHERE id = v_fw),
                        'framework session fixture');
  d := ops.create_dispatch('global.local-ops.core'::public.ltree, 'investigation', 't0023 fw', 'p', '{}', 100, v_fw);
  PERFORM pg_temp.check(d.project_id IS NULL AND d.session_id = v_fw AND d.status = 'pending'
                        AND d.component_id = (SELECT component_id FROM ops.nodes WHERE path::text = 'global.local-ops.core'),
                        'framework dispatch: ' || to_jsonb(d)::text);
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.dispatch_nodes WHERE dispatch_id = d.id) = ARRAY[pg_temp.node('global.local-ops.core')],
                        'framework dispatch on the core node');
  d := ops.create_dispatch('global.local-ops.core'::public.ltree, 'investigation', 't0023 core', 'p', '{}', 100, v_core);
  PERFORM pg_temp.check(d.project_id IS NULL AND d.session_id = v_core, 'core session dispatch');
  d := ops.create_dispatch('global.t0023loose.lc'::public.ltree, 'investigation', 't0023 lc', 'p', '{}', 100, pg_temp.id('s_lc'));
  PERFORM pg_temp.check(d.project_id IS NULL AND d.component_id = pg_temp.id('lc'), 'dispatch on a component outside a project');

  x := ops.log_decision('global.local-ops'::public.ltree, 't0023 fw decision', p_session => v_fw);
  PERFORM pg_temp.check(x.project_id IS NULL AND x.component_id IS NULL AND x.session_id = v_fw
                        AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = x.id) = ARRAY[pg_temp.node('global.local-ops')],
                        'framework decision on global.local-ops: ' || to_jsonb(x)::text);
  v_fw_dec := x.id;
  x := ops.log_decision('global.local-ops.core'::public.ltree, 't0023 core decision', NULL, '[]', NULL, NULL, v_fw_dec, v_fw);
  PERFORM pg_temp.check(x.project_id IS NULL AND x.supersedes = v_fw_dec
                        AND x.component_id = (SELECT component_id FROM ops.nodes WHERE path::text = 'global.local-ops.core'),
                        'superseding a framework decision (component NULL, project NULL) from global.local-ops.core');
  v_pa_dec := (ops.log_decision('global.t0023a'::public.ltree, 't0023 pa decision', p_session => v_pa)).id;
  PERFORM set_config('ops_test.fw_dec', v_fw_dec::text, true);
  PERFORM set_config('ops_test.pa_dec', v_pa_dec::text, true);

  v_before := (SELECT count(*) FROM ops.dispatches) + (SELECT count(*) FROM ops.decisions);
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.local-ops.core'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$, v_pa),
                          '23514', format('session %s is outside global.local-ops (the scope of global.local-ops.core)', v_pa),
                          'project session on a framework path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.local-ops.core'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('s_global')), '23514', 'is outside global.local-ops', 'global session on a framework path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0023a.ca'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$, v_fw),
                          '23514', 'is outside global.t0023a (the scope of global.t0023a.ca)', 'framework session on a project path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.local-ops'::public.ltree, 'x', NULL, '[]', NULL, NULL, NULL, %L)$q$, v_pa),
                          '23514', 'is outside global.local-ops (the scope of global.local-ops)', 'log_decision: project session on a framework path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.local-ops'::public.ltree, 'x', NULL, '[]', NULL, NULL, %L, %L)$q$, v_pa_dec, v_fw),
                          '23514', format('superseded decision %s does not exist in global.local-ops', v_pa_dec),
                          'superseding a project decision from a framework path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0023a'::public.ltree, 'x', NULL, '[]', NULL, NULL, %L, %L)$q$, v_fw_dec, v_pa),
                          '23514', format('superseded decision %s does not exist in global.t0023a', v_fw_dec),
                          'superseding a framework decision from a project path');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) + (SELECT count(*) FROM ops.decisions) = v_before, 'refusals wrote nothing');
  -- a global session may supersede any decision from the global path
  x := ops.log_decision('global'::public.ltree, 't0023 global', NULL, '[]', NULL, NULL, v_fw_dec, pg_temp.id('s_global'));
  PERFORM pg_temp.check(x.project_id IS NULL AND x.supersedes = v_fw_dec, 'global decision superseding a framework decision');
  RAISE NOTICE 'ok   4 create_dispatch / log_decision: framework session accepted on framework paths, refused elsewhere';
END $$;

-- 5. close_session: inline decisions on the session node; node-based supersedes check
DO $$
DECLARE v_s uuid; v_n integer;
BEGIN
  v_s := ops.open_session('global.t0023a.free'::public.ltree, 'planning');
  v_n := ops.close_session(v_s, 's', 'n', format('[{"decision": "t0023 free", "supersedes": "%s"}]', pg_temp.id('pa_dec'))::jsonb);
  PERFORM pg_temp.check(v_n = 1 AND (SELECT d.project_id = pg_temp.id('pa') AND d.component_id IS NULL AND d.supersedes = pg_temp.id('pa_dec')
                                            AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.id('free_node')]
                                       FROM ops.decisions d WHERE d.session_id = v_s),
                        'inline decision on the free node, project kept, supersedes in the project');

  v_s := ops.open_session('global.local-ops.core'::public.ltree, 'execution');
  v_n := ops.close_session(v_s, 's', 'n', format('[{"decision": "t0023 core", "supersedes": "%s"}]', pg_temp.id('fw_dec'))::jsonb);
  PERFORM pg_temp.check(v_n = 1 AND (SELECT d.project_id IS NULL
                                            AND d.component_id = (SELECT component_id FROM ops.nodes WHERE path::text = 'global.local-ops.core')
                                            AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id)
                                                = ARRAY[pg_temp.node('global.local-ops.core')]
                                       FROM ops.decisions d WHERE d.session_id = v_s),
                        'framework inline decision on the core node, no project, superseding a framework decision');

  -- a session with node_id NULL falls back to the derived node (project node here)
  INSERT INTO ops.sessions (project_id, kind) VALUES (pg_temp.id('pa'), 'planning') RETURNING id INTO v_s;
  v_n := ops.close_session(v_s, 's', 'n', '[{"decision": "t0023 derived"}]');
  PERFORM pg_temp.check((SELECT array_agg(dn.node_id) FROM ops.decision_nodes dn JOIN ops.decisions d ON d.id = dn.decision_id
                          WHERE d.session_id = v_s) = ARRAY[pg_temp.id('pa_node')], 'node_id NULL: decision on the derived project node');

  v_s := ops.open_session('global.t0023a'::public.ltree, 'planning');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[{"decision": "x", "supersedes": "%s"}]')$q$, v_s, pg_temp.id('fw_dec')),
                          '23514', format('superseded decision %s does not exist in global.t0023a (the scope of session %s)', pg_temp.id('fw_dec'), v_s),
                          'supersedes outside the session root');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[{"decision": "x", "supersedes": "%s"}]')$q$, v_s, gen_random_uuid()),
                          '23514', 'does not exist in global.t0023a (the scope of session', 'unknown supersedes');
  PERFORM pg_temp.check((SELECT status = 'active' FROM ops.sessions WHERE id = v_s)
                        AND NOT EXISTS (SELECT 1 FROM ops.decisions WHERE session_id = v_s), 'refusal wrote nothing, session active');

  v_s := ops.open_session('global'::public.ltree, 'planning');
  v_n := ops.close_session(v_s, 's', 'n', format('[{"decision": "t0023 g", "supersedes": "%s"}]', pg_temp.id('pa_dec'))::jsonb);
  PERFORM pg_temp.check(v_n = 1 AND (SELECT d.project_id IS NULL
                                            AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.node('global')]
                                       FROM ops.decisions d WHERE d.session_id = v_s),
                        'global session: inline decision on the global node, any supersedes');
  RAISE NOTICE 'ok   5 close_session: session node home, node-based supersedes, new refusal message';
END $$;

-- 6. create_component: parents, project derivation, refusals, duplicates
DO $$
DECLARE c ops.components;
BEGIN
  c := ops.create_component('global.t0023a.free'::public.ltree, 'ca', 'service');
  PERFORM pg_temp.check(c.project_id = pg_temp.id('pa') AND (SELECT path::text FROM ops.nodes WHERE id = c.node_id) = 'global.t0023a.free.ca',
                        'plain parent inside a project: project from the depth-2 ancestor; same key as t0023a/ca accepted');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'parent global of component "cx" must be a project or plain node outside any component', 'global parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023a.ca'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'parent global.t0023a.ca of component "cx" must be a project or plain node outside any component', 'component parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023a.ca.sub'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'parent global.t0023a.ca.sub of component "cx" must be a project or plain node outside any component',
                          'parent inside a component subtree');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.local-ops.core'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'must be a project or plain node outside any component', 'framework component parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023nosuch'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'unknown node global.t0023nosuch', 'unknown parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023a'::public.ltree, 'ca', 'service')$q$, '23514',
                          'component "t0023a/ca" already exists', 'duplicate under a project parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023loose'::public.ltree, 'lc', 'service')$q$, '23514',
                          'component "t0023loose/lc" already exists', 'duplicate under a plain parent');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023a'::public.ltree, 'free', 'service')$q$, '23514',
                          'a node "free" already exists under global.t0023a', 'non-component node with that key');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0023loose'::public.ltree, 'cx', '')$q$, '23514',
                          'component "t0023loose/cx" needs a kind', 'kind still required');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.components SET node_id = %L WHERE id = %L$q$, pg_temp.id('ca_node'), pg_temp.id('lc')),
                          '23505', 'components_node_id_key', 'components UNIQUE (node_id)');
  RAISE NOTICE 'ok   6 create_component: plain parents, project derivation, refusals, duplicates, UNIQUE (node_id)';
END $$;

-- 7. a dispatch may carry no project; context_documents (project_id, doc_key) is no longer unique
DO $$
DECLARE v_t text := 'investigation';  -- a commit_policy none type
BEGIN
  PERFORM pg_temp.check(pg_temp.err(format($q$INSERT INTO ops.dispatches (component_id, dispatch_type, session_id, title, prompt)
                                             VALUES (%L, %L, %L, 't0023 direct', 'p')$q$, pg_temp.id('lc'), v_t, pg_temp.id('s_lc'))) IS NULL,
                        'dispatch insert with project_id NULL accepted');
  INSERT INTO ops.context_documents (project_id, doc_key, title, content, node_id, doc_type) VALUES
    (pg_temp.id('pa'), 'T0023_DOC', 'a', 'a', pg_temp.id('pa_node'), 'manual'),
    (pg_temp.id('pa'), 'T0023_DOC', 'b', 'b', pg_temp.id('free_node'), 'manual');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.context_documents WHERE doc_key = 'T0023_DOC') = 2,
                        'same (project_id, doc_key) on two nodes accepted');
  RAISE NOTICE 'ok   7 dispatch without project; (project_id, doc_key) not unique';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   8 no leftover rows; 0023 tests passed';
END $$;
