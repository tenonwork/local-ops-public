-- tests/sql/0018_node_keyed_functions.sql
-- Tests for migrations/0018_node_keyed_functions.sql. Run as the schema owner against a non-production database
-- where 0018 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0018_node_keyed_functions.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own projects t0018a / t0018b through the NEW create_project /
-- create_component, its own nodes, documents (only on nodes it creates) and doc types, asserts only on rows it
-- creates, and counts relative to the starting state. Calls on local-ops only open sessions (the stale auto-close
-- can reach other stale sessions there; the ROLLBACK undoes that).
-- Grants are checked at catalog level (b28e2660): ops_dev is not a member of ops_planner / ops_executor.

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
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'doc_types', (SELECT count(*) FROM ops.doc_types)))::text, false);
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

-- status/close_reason/task_status; 0022 drops sessions.task_status (M5b release 2), so the column is read through
-- to_jsonb and, when absent, the 2eecc405 mapping stands in (every row satisfied it since 0012)
CREATE FUNCTION pg_temp.state(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT s.status || '/' || coalesce(s.close_reason::text, '-') || '/'
         || coalesce(to_jsonb(s)->>'task_status',
                     CASE WHEN s.status = 'active' THEN 'open' WHEN s.close_reason = 'stale' THEN 'unfinished'
                          ELSE 'closed' END)
    FROM ops.sessions s WHERE s.id = p_id;
$$;

-- 0. create_project / create_component (new overloads); fixtures for the rest of the file
DO $$
DECLARE p ops.projects; c ops.components; n ops.nodes; v_global ops.nodes; v_id uuid;
        v_nodes bigint := (SELECT count(*) FROM ops.nodes);
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  SELECT * INTO v_global FROM ops.nodes WHERE kind = 'global';
  PERFORM set_config('ops_test.global_node', v_global.id::text, true);

  p := ops.create_project('global'::public.ltree, 't0018a', 'T0018 A', '{"x": 1}');
  SELECT * INTO n FROM ops.nodes WHERE id = p.node_id;
  PERFORM pg_temp.check(p.key = 't0018a' AND p.name = 'T0018 A' AND p.params = '{"x": 1}', 'project row');
  PERFORM pg_temp.check(n.kind = 'project' AND n.parent_id = v_global.id AND n.path::text = 'global.t0018a'
                        AND n.title = 'T0018 A' AND n.component_id IS NULL, 'project node under global');
  PERFORM set_config('ops_test.pa', p.id::text, true);
  PERFORM set_config('ops_test.pa_node', p.node_id::text, true);
  p := ops.create_project('global'::public.ltree, 't0018b', 'T0018 B');
  PERFORM pg_temp.check(p.params = '{}' AND p.node_id IS NOT NULL, 'params default {}');
  PERFORM set_config('ops_test.pb', p.id::text, true);
  PERFORM set_config('ops_test.pb_node', p.node_id::text, true);

  c := ops.create_component('global.t0018a'::public.ltree, 'ca', 'service', 'repo-a', 'npm test', '{"y": 2}');
  SELECT * INTO n FROM ops.nodes WHERE id = c.node_id;
  PERFORM pg_temp.check(c.project_id = pg_temp.id('pa') AND c.key = 'ca' AND c.kind = 'service' AND c.repo_ref = 'repo-a'
                        AND c.verify_cmd = 'npm test' AND c.params = '{"y": 2}' AND c.active, 'component row');
  PERFORM pg_temp.check(n.kind = 'node' AND n.parent_id = pg_temp.id('pa_node') AND n.component_id = c.id
                        AND n.path::text = 'global.t0018a.ca', 'component node under the project node');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  PERFORM set_config('ops_test.ca_node', c.node_id::text, true);
  c := ops.create_component('global.t0018a'::public.ltree, 'ca2', 'service');           -- no verify_cmd
  PERFORM pg_temp.check(c.repo_ref IS NULL AND c.verify_cmd IS NULL AND c.params = '{}', 'component defaults');
  PERFORM set_config('ops_test.ca2', c.id::text, true);
  c := ops.create_component('global.t0018a'::public.ltree, 'cz', 'service', NULL, 'npm test');   -- deactivated
  UPDATE ops.components SET active = false WHERE id = c.id;
  c := ops.create_component('global.t0018b'::public.ltree, 'cb', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.cb', c.id::text, true);
  PERFORM set_config('ops_test.cb_node', c.node_id::text, true);

  -- plain nodes: below ca (sub, sub.leaf), under the project node (free), directly under global (t0018loose)
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.id('ca_node'), 'sub', 'node', 'sub') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.sub_node', v_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_id, 'leaf', 'node', 'leaf') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.leaf_node', v_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.id('pa_node'), 'free', 'node', 'free') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.free_node', v_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_global.id, 't0018loose', 'node', 'loose');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.nodes) = v_nodes + 10, 'ten nodes created');

  -- refusals
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('global.t0018a'::public.ltree, 't0018x', 'x')$q$, 'P0001',
                          'parent of project "t0018x" must be the global node, not global.t0018a', 'project under a project');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('t0018nosuch'::public.ltree, 't0018x', 'x')$q$, 'P0001',
                          'unknown node t0018nosuch', 'project under an unknown node');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('global'::public.ltree, 't0018a', 'dup')$q$, '23514',
                          'already exists', 'duplicate project');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('global'::public.ltree, 'Bad Key', 'x')$q$, '23514',
                          'invalid project key', 'bad project key');
  -- 0023 accepts a plain parent outside any component, with a new refusal message (M5b release 2)
  IF (SELECT max(version) FROM ops.schema_migrations) >= '0023' THEN
    RAISE NOTICE 'skip 0 create_component project-node-only refusals (newest migration is %)',
      (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.rejects($q$SELECT ops.create_component('global'::public.ltree, 'cx', 'service')$q$, 'P0001',
                            'parent global of component "cx" must be a project or plain node outside any component',
                            'component under global (0023 message)');
    PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018a.ca'::public.ltree, 'cx', 'service')$q$, 'P0001',
                            'parent global.t0018a.ca of component "cx" must be a project or plain node outside any component',
                            'component under a component (0023 message)');
    c := ops.create_component('global.t0018loose'::public.ltree, 'cx', 'service');
    PERFORM pg_temp.check(c.project_id IS NULL AND (SELECT path::text = 'global.t0018loose.cx' AND component_id = c.id
                                                     FROM ops.nodes WHERE id = c.node_id),
                          'component under a plain node outside any project: no project, node under the loose node');
  ELSE
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'parent global of component "cx" is not a project node', 'component under global');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018a.ca'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'parent global.t0018a.ca of component "cx" is not a project node', 'component under a component');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018loose'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'is not a project node', 'component under a non-project node');
  END IF;
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018nosuch'::public.ltree, 'cx', 'service')$q$, 'P0001',
                          'unknown node global.t0018nosuch', 'component under an unknown node');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018a'::public.ltree, 'ca', 'service')$q$, '23514',
                          'component "t0018a/ca" already exists', 'duplicate component');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('global.t0018a'::public.ltree, 'cx', '')$q$, '23514',
                          'component "t0018a/cx" needs a kind', 'component without kind');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('bad path!'::public.ltree, 't0018x', 'x')$q$, '42601', '',
                          'bad path literal is ltree''s own syntax error');
  RAISE NOTICE 'ok   0 create_project / create_component: nodes, parents, refusals';
END $$;

-- 1. catalog: signatures, SECURITY DEFINER, search_path, exact ACLs, comments, no default on the path parameter
DO $$
DECLARE f record; v_grantees text[]; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0023 replaces open_session and create_component with 'M5b release 2 (' comments and drops adopt_orphans
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 1 release-1 comments of open_session / create_component, adopt_orphans one (newest migration is %)', newest;
  END IF;
  FOR f IN SELECT * FROM (VALUES
      ('ops._node(public.ltree)', '{}'::text[], 'p_path'),
      ('ops._component(public.ltree)', '{}', 'p_node_path'),
      ('ops._derived_node(uuid,uuid)', '{}', NULL),
      ('ops.open_session(public.ltree,text,ops.segment_scope,timestamptz,ops.provenance)', '{ops_planner}', 'p_node_path'),
      ('ops.get_pending(public.ltree)', '{ops_executor}', 'p_node_path'),
      ('ops.get_unreviewed_reports(public.ltree)', '{ops_planner}', 'p_node_path'),
      ('ops.resolve_context(public.ltree,text)', '{ops_executor,ops_planner}', 'p_node_path'),
      -- 0035 adds the trailing p_summary text to both (the functions are replaced, not overloaded)
      (CASE WHEN newest >= '0035' THEN 'ops.create_project(public.ltree,text,text,jsonb,text)'
            ELSE 'ops.create_project(public.ltree,text,text,jsonb)' END, '{ops_planner}', 'p_parent_path'),
      (CASE WHEN newest >= '0035' THEN 'ops.create_component(public.ltree,text,text,text,text,jsonb,text)'
            ELSE 'ops.create_component(public.ltree,text,text,text,text,jsonb)' END, '{ops_planner}', 'p_parent_path'),
      -- 0029 adds the trailing p_task_files text[] (the function is replaced, not overloaded)
      (CASE WHEN newest >= '0029' THEN 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid,text[])'
            ELSE 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid)' END, '{ops_planner}', 'p_node_path'),
      ('ops.log_decision(public.ltree,text,text,jsonb,text,text,uuid,uuid)', '{ops_planner}', 'p_node_path'),
      ('ops.add_backlog_item(public.ltree,ops.backlog_kind,text,text,uuid,ops.backlog_severity)', '{ops_planner}', 'p_node_path')
    ) AS t(sig, grantees, path_arg) LOOP
    PERFORM pg_temp.check(to_regprocedure(f.sig) IS NOT NULL, 'exists ' || f.sig);
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND proacl IS NOT NULL
                             FROM pg_proc WHERE oid = to_regprocedure(f.sig)), 'secdef, search_path, explicit ACL ' || f.sig);
    SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END), '{}')
      INTO v_grantees
      FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = to_regprocedure(f.sig) AND a.grantee <> p.proowner;
    PERFORM pg_temp.check(v_grantees = f.grantees, f.sig || ' grantees ' || v_grantees::text || ', expected ' || f.grantees::text);
    PERFORM pg_temp.check(has_function_privilege('ops_planner', f.sig, 'EXECUTE') = ('ops_planner' = ANY (f.grantees))
                          AND has_function_privilege('ops_executor', f.sig, 'EXECUTE') = ('ops_executor' = ANY (f.grantees))
                          AND NOT has_function_privilege('public', f.sig, 'EXECUTE'), 'has_function_privilege ' || f.sig);
    -- 0035 replaces create_project and create_component with 'Node summary release (' comments
    IF newest >= '0035' AND f.sig ~ '^ops\.create_(project|component)\(' THEN
      RAISE NOTICE 'skip 1 release-1/2 comment of % (newest migration is %)', f.sig, newest;
      PERFORM pg_temp.check(obj_description(to_regprocedure(f.sig), 'pg_proc') LIKE 'Node summary release (%', 'comment (0035) ' || f.sig);
    ELSIF newest >= '0023' AND f.sig ~ '^ops\.(open_session|create_component)\(' THEN
      PERFORM pg_temp.check(obj_description(to_regprocedure(f.sig), 'pg_proc') LIKE 'M5b release 2 (%', 'comment (0023) ' || f.sig);
    -- 0033 replaces resolve_context with a 'Writer release (' comment
    ELSIF newest >= '0033' AND f.sig = 'ops.resolve_context(public.ltree,text)' THEN
      RAISE NOTICE 'skip 1 release-1 comment of resolve_context (newest migration is %)', newest;
      PERFORM pg_temp.check(obj_description(to_regprocedure(f.sig), 'pg_proc') LIKE 'Writer release (%', 'comment (0033) ' || f.sig);
    ELSE
    PERFORM pg_temp.check(obj_description(to_regprocedure(f.sig), 'pg_proc') LIKE 'M5b release 1 (%', 'comment ' || f.sig);
    END IF;
    IF f.path_arg IS NOT NULL THEN
      -- defaults are trailing, so pronargs - pronargdefaults >= 1 means the first (path) parameter has none
      PERFORM pg_temp.check((SELECT proargnames[1] = f.path_arg AND proargtypes[0] = 'public.ltree'::regtype
                                    AND pronargs - pronargdefaults >= 1
                               FROM pg_proc WHERE oid = to_regprocedure(f.sig)), 'path parameter without default ' || f.sig);
    END IF;
  END LOOP;
  -- close_session and adopt_orphans are not overloaded
  IF newest >= '0023' THEN
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname = 'close_session') = 1, 'close_session one (0023)');
    PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                                       AND proname = 'adopt_orphans'), 'adopt_orphans none (0023)');
  ELSE
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                          AND proname IN ('close_session', 'adopt_orphans')) = 2, 'close_session / adopt_orphans one each');
  END IF;
  RAISE NOTICE 'ok   1 catalog: 12 functions, ACLs, comments, path parameters without default';
END $$;

-- 2. open_session
DO $$
DECLARE v_s uuid; s ops.sessions; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  v_s := ops.open_session('global.t0018a.ca'::public.ltree, 'execution');
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.project_id = pg_temp.id('pa') AND s.component_id = pg_temp.id('ca') AND s.kind = 'execution'
                        AND s.scope = 'project' AND s.provenance = 'recorded' AND s.status = 'active'
                        -- task_status through to_jsonb, the 2eecc405 mapping once 0022 has dropped the column
                        AND coalesce(to_jsonb(s)->>'task_status',
                                     CASE WHEN s.status = 'active' THEN 'open' WHEN s.close_reason = 'stale' THEN 'unfinished'
                                          ELSE 'closed' END) = 'open'
                        AND s.occurred_at = now(), 'component session: ' || to_jsonb(s)::text);
  PERFORM set_config('ops_test.sa_comp', v_s::text, true);
  v_s := ops.open_session('global.t0018a'::public.ltree, 'planning');
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.project_id = pg_temp.id('pa') AND s.component_id IS NULL AND s.scope = 'project',
                        'project session: ' || to_jsonb(s)::text);
  PERFORM set_config('ops_test.sa_proj', v_s::text, true);
  v_s := ops.open_session('global.t0018a.ca.sub'::public.ltree, 'planning');
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.project_id = pg_temp.id('pa') AND s.component_id IS NULL, 'sub-node session: project, no component');
  v_s := ops.open_session('global.t0018b'::public.ltree, 'planning');
  PERFORM set_config('ops_test.sb_proj', v_s::text, true);

  -- 55bf4998 scope default on the path; explicit scope wins
  v_s := ops.open_session('global.local-ops'::public.ltree, 'planning');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'global', 'global.local-ops -> global');
  v_s := ops.open_session('global.local-ops.core'::public.ltree, 'execution');
  PERFORM pg_temp.check((SELECT (sessions.scope, sessions.component_id) = ('global'::ops.segment_scope, c.id)
                           FROM ops.sessions, ops.components c JOIN ops.nodes cn ON cn.id = c.node_id
                          WHERE sessions.id = v_s AND cn.path::text = 'global.local-ops.core'), 'global.local-ops.core -> global, core');
  v_s := ops.open_session('global.t0018a'::public.ltree, 'planning', 'global');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'global', 'explicit global wins');
  v_s := ops.open_session('global.local-ops'::public.ltree, 'planning', 'project');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'project', 'explicit project wins');

  v_s := ops.open_session('global.t0018b'::public.ltree, 'execution', NULL, now() - interval '2 hours', 'reconstructed');
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.provenance = 'reconstructed' AND s.occurred_at = now() - interval '2 hours'
                        AND s.recorded_at = now() AND s.status = 'active', 'reconstructed occurred_at / recorded_at');

  -- 0023 lifts the global-path and outside-a-project refusals (M5b release 2): from 0023 on both opens succeed
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 2 global path and node outside any project refused (newest migration is %)', newest;
    v_s := ops.open_session('global'::public.ltree, 'planning');
    SELECT * INTO s FROM ops.sessions WHERE id = v_s;
    PERFORM pg_temp.check(s.project_id IS NULL AND s.component_id IS NULL AND to_jsonb(s)->>'node_id' = pg_temp.id('global_node')::text
                          AND s.scope = 'project' AND s.status = 'active', 'global session (0023): ' || to_jsonb(s)::text);
  ELSE
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global'::public.ltree, 'planning')$q$, 'P0001',
                          'global-path sessions wait for release 2', 'global path refused');
  END IF;
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0018nosuch'::public.ltree, 'planning')$q$, 'P0001',
                          'unknown node global.t0018nosuch', 'unknown node');
  IF newest >= '0023' THEN
    v_s := ops.open_session('global.t0018loose'::public.ltree, 'planning');
    SELECT * INTO s FROM ops.sessions WHERE id = v_s;
    PERFORM pg_temp.check(s.project_id IS NULL AND s.component_id IS NULL
                          AND to_jsonb(s)->>'node_id' = (SELECT id::text FROM ops.nodes WHERE path::text = 'global.t0018loose')
                          AND s.scope = 'project', 'session outside any project (0023): ' || to_jsonb(s)::text);
  ELSE
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0018loose'::public.ltree, 'planning')$q$, 'P0001',
                          'unknown project for node global.t0018loose', 'node outside any project');
  END IF;
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0018a'::public.ltree, 'planning', NULL, now() - interval '1 hour')$q$,
                          '23514', 'occurred_at must be given exactly when provenance is reconstructed', 'occurred_at without reconstructed');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0018a'::public.ltree, 'planning', NULL, NULL, 'reconstructed')$q$,
                          '23514', 'occurred_at must be given exactly when provenance is reconstructed', 'reconstructed without occurred_at');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('global.t0018a'::public.ltree, 'planning', NULL, now() + interval '1 minute', 'reconstructed')$q$,
                          '23514', 'is in the future', 'future occurred_at');
  RAISE NOTICE 'ok   2 open_session: component / project / sub-node, scope default and override, reconstructed, refusals';
END $$;

-- 3. open_session stale auto-close by exact derived node
DO $$
DECLARE v_hours integer := coalesce(
          (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
        v_stale timestamptz := now() - make_interval(hours => v_hours + 1);
        v_comp uuid; v_proj uuid; v_proj2 uuid; v_fresh uuid; v_b uuid; v_ca2 uuid; v_s uuid;
BEGIN
  INSERT INTO ops.sessions (project_id, component_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), pg_temp.id('ca'), 'execution', v_stale) RETURNING id INTO v_comp;
  INSERT INTO ops.sessions (project_id, component_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), pg_temp.id('ca2'), 'execution', v_stale) RETURNING id INTO v_ca2;
  INSERT INTO ops.sessions (project_id, kind, occurred_at) VALUES (pg_temp.id('pa'), 'planning', v_stale) RETURNING id INTO v_proj;
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), 'planning', now() - make_interval(hours => v_hours - 1)) RETURNING id INTO v_fresh;
  INSERT INTO ops.sessions (project_id, kind, occurred_at) VALUES (pg_temp.id('pb'), 'planning', v_stale) RETURNING id INTO v_b;

  -- a project-level open closes the stale project-level session only
  v_s := ops.open_session('global.t0018a'::public.ltree, 'planning');
  PERFORM pg_temp.check(pg_temp.state(v_proj) = 'closed/stale/unfinished', 'stale project session closed: ' || pg_temp.state(v_proj));
  PERFORM pg_temp.check((SELECT summary = 'auto-closed: stale' AND closed_at = now() FROM ops.sessions WHERE id = v_proj),
                        'stale summary and closed_at');
  PERFORM pg_temp.check(pg_temp.state(v_comp) = 'active/-/open', 'project open leaves the stale component session');
  PERFORM pg_temp.check(pg_temp.state(v_ca2) = 'active/-/open', 'project open leaves the stale ca2 session');
  PERFORM pg_temp.check(pg_temp.state(v_fresh) = 'active/-/open', 'fresh project session untouched');
  PERFORM pg_temp.check(pg_temp.state(v_b) = 'active/-/open', 'other project untouched');
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'active/-/open', 'new session active/open');

  -- a component-level open closes the stale session on that component only
  INSERT INTO ops.sessions (project_id, kind, occurred_at) VALUES (pg_temp.id('pa'), 'planning', v_stale) RETURNING id INTO v_proj2;
  v_s := ops.open_session('global.t0018a.ca'::public.ltree, 'execution');
  PERFORM pg_temp.check(pg_temp.state(v_comp) = 'closed/stale/unfinished', 'stale component session closed: ' || pg_temp.state(v_comp));
  PERFORM pg_temp.check(pg_temp.state(v_proj2) = 'active/-/open', 'component open leaves the stale project session');
  PERFORM pg_temp.check(pg_temp.state(v_ca2) = 'active/-/open', 'component open leaves the sibling component session');
  PERFORM pg_temp.check(pg_temp.state(v_b) = 'active/-/open', 'other project still untouched');
  RAISE NOTICE 'ok   3 stale auto-close by exact derived node (project vs component, both directions)';
END $$;

-- 4. get_pending: exactly one component
DO $$
DECLARE d1 uuid; d2 uuid; d3 uuid; d_ca2 uuid; d_cb uuid; v_ids uuid[];
BEGIN
  -- the fixtures carry the block 2 project sessions (session required from 0022)
  d1 := (ops.create_dispatch('global.t0018a.ca'::public.ltree, 'investigation', 't0018 p50', 'p', '{}', 50, pg_temp.id('sa_proj'))).id;
  d2 := (ops.create_dispatch('global.t0018a.ca'::public.ltree, 'investigation', 't0018 p10', 'p', '{}', 10, pg_temp.id('sa_proj'))).id;
  d3 := (ops.create_dispatch('global.t0018a.ca'::public.ltree, 'investigation', 't0018 claimed', 'p', '{}', 1, pg_temp.id('sa_proj'))).id;
  PERFORM ops.claim_dispatch(d3, 't0018');
  d_ca2 := (ops.create_dispatch('global.t0018a.ca2'::public.ltree, 'investigation', 't0018 ca2', 'p', '{}', 100, pg_temp.id('sa_proj'))).id;
  d_cb := (ops.create_dispatch('global.t0018b.cb'::public.ltree, 'investigation', 't0018 cb', 'p', '{}', 100, pg_temp.id('sb_proj'))).id;

  SELECT array_agg(id) INTO v_ids FROM ops.get_pending('global.t0018a.ca'::public.ltree);
  PERFORM pg_temp.check(v_ids = ARRAY[d2, d1], 'pending on ca by priority: ' || coalesce(v_ids::text, 'none'));
  SELECT array_agg(id) INTO v_ids FROM ops.get_pending('global.t0018a.ca2'::public.ltree);
  PERFORM pg_temp.check(v_ids = ARRAY[d_ca2], 'pending on ca2 only');
  SELECT array_agg(id) INTO v_ids FROM ops.get_pending('global.t0018b.cb'::public.ltree);
  PERFORM pg_temp.check(v_ids = ARRAY[d_cb], 'pending on cb only');

  PERFORM pg_temp.rejects($q$SELECT ops.get_pending('global.t0018a'::public.ltree)$q$, 'P0001',
                          'unknown component global.t0018a', 'project path is not a component');
  PERFORM pg_temp.rejects($q$SELECT ops.get_pending('global.t0018a.ca.sub'::public.ltree)$q$, 'P0001',
                          'unknown component global.t0018a.ca.sub', 'node below a component is not a component');
  PERFORM pg_temp.rejects($q$SELECT ops.get_pending('global.t0018a.nosuch'::public.ltree)$q$, 'P0001',
                          'unknown component global.t0018a.nosuch', 'unknown path');
  PERFORM set_config('ops_test.d_ca2', d_ca2::text, true);
  PERFORM set_config('ops_test.d_cb', d_cb::text, true);
  RAISE NOTICE 'ok   4 get_pending: one component, priority order, claimed excluded, unknown component';
END $$;

-- 5. get_unreviewed_reports: subtree of the component's node
DO $$
DECLARE r_ca uuid; r_ca2 uuid; r_cb uuid; r_rev uuid; v_ids uuid[]; v_old uuid[]; v_all bigint;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- the fixtures carry the block 2 project sessions (session required from 0022)
  r_ca := (ops.create_dispatch('global.t0018a.ca'::public.ltree, 'investigation', 't0018 r ca', 'p', '{}', 100, pg_temp.id('sa_proj'))).id;
  PERFORM ops.claim_dispatch(r_ca, 't0018'), ops.complete_dispatch(r_ca, 'r', 'report');
  r_ca2 := (ops.create_dispatch('global.t0018a.ca2'::public.ltree, 'investigation', 't0018 r ca2', 'p', '{}', 100, pg_temp.id('sa_proj'))).id;
  PERFORM ops.claim_dispatch(r_ca2, 't0018'), ops.fail_dispatch(r_ca2, 'stopped');
  r_cb := (ops.create_dispatch('global.t0018b.cb'::public.ltree, 'investigation', 't0018 r cb', 'p', '{}', 100, pg_temp.id('sb_proj'))).id;
  PERFORM ops.claim_dispatch(r_cb, 't0018'), ops.fail_dispatch(r_cb, 'premise', true);
  r_rev := (ops.create_dispatch('global.t0018a.ca'::public.ltree, 'investigation', 't0018 r reviewed', 'p', '{}', 100, pg_temp.id('sa_proj'))).id;
  PERFORM ops.claim_dispatch(r_rev, 't0018'), ops.complete_dispatch(r_rev, 'r', 'report'), ops.mark_reviewed(ARRAY[r_rev]);

  SELECT array_agg(id ORDER BY id) INTO v_ids FROM ops.get_unreviewed_reports('global.t0018a.ca'::public.ltree);
  PERFORM pg_temp.check(v_ids = ARRAY[r_ca], 'component path: ca only');
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM ops.get_unreviewed_reports('global.t0018a'::public.ltree);
  PERFORM pg_temp.check(v_ids = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[r_ca, r_ca2]) x), 'project path: ca and ca2');
  -- 0021 drops the project-keyed get_unreviewed_reports(text) (M5b release 2)
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 5 project path vs get_unreviewed_reports(text) (newest migration is %)', newest;
  ELSE
    SELECT array_agg(id ORDER BY id) INTO v_old FROM ops.get_unreviewed_reports('t0018a');
    PERFORM pg_temp.check(v_ids = v_old, 'project path reproduces the project-keyed result');
  END IF;
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM ops.get_unreviewed_reports('global.local-ops'::public.ltree);
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 5 local-ops path vs get_unreviewed_reports(text) (newest migration is %)', newest;
  ELSE
    SELECT array_agg(id ORDER BY id) INTO v_old FROM ops.get_unreviewed_reports('local-ops');
    PERFORM pg_temp.check(v_ids IS NOT DISTINCT FROM v_old, 'local-ops path reproduces the project-keyed result');
  END IF;
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM ops.get_unreviewed_reports('global'::public.ltree);
  SELECT count(*) INTO v_all FROM ops.dispatches WHERE reviewed_at IS NULL AND status IN ('done', 'failed', 'refused_premise');
  PERFORM pg_temp.check(cardinality(v_ids) = v_all AND ARRAY[r_ca, r_ca2, r_cb] <@ v_ids AND NOT (r_rev = ANY (v_ids)),
                        'global path: every unreviewed report');
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM ops.get_unreviewed_reports('global.t0018a.ca.sub'::public.ltree);
  PERFORM pg_temp.check(v_ids IS NULL, 'node below a component: no component in its subtree');
  PERFORM pg_temp.rejects($q$SELECT ops.get_unreviewed_reports('global.t0018nosuch'::public.ltree)$q$, 'P0001',
                          'unknown node global.t0018nosuch', 'unknown path');
  RAISE NOTICE 'ok   5 get_unreviewed_reports: component, project and global paths; unknown node';
END $$;

-- 6. resolve_context: nearest ancestor-or-self, ambiguity, '#Heading'
DO $$
DECLARE v_pa_node uuid := pg_temp.id('pa_node'); v_ca_node uuid := pg_temp.id('ca_node');
        v_sub uuid := pg_temp.id('sub_node'); v_leaf uuid := pg_temp.id('leaf_node');
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  INSERT INTO ops.doc_types (key, label, description) VALUES ('t0018_a', 't0018 a', 't0018 test doc type');
  -- (node_id, doc_type) is unique (and (project_id, doc_key) was unique until 0023), so the documents carry no
  -- project and every document on one node has its own doc type
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type) VALUES
    ('T0018_NEAR', 'near p', E'# Top\nproject\n## Part\nproject part', v_pa_node, 'manual'),
    ('T0018_UP',   'up',     'project only',                            v_pa_node, 't0018_a'),
    ('T0018_NEAR', 'near c', E'# Top\ncomponent\n## Part\ncomponent part\n## Next\nnext', v_ca_node, 'manual'),
    ('T0018_AMB',  'amb 1',  'amb one',                                 v_sub,     'manual'),
    ('T0018_AMB',  'amb l',  'amb leaf',                                v_leaf,    'manual');
  -- 0033 adds UNIQUE (node_id, doc_key): from 0033 on the same-node pair is refused instead of inserted
  IF newest < '0033' THEN
    INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type) VALUES
      ('T0018_AMB',  'amb 2',  'amb two',                                 v_sub,     't0018_a');
  ELSE
    PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
                                      VALUES ('T0018_AMB', 'amb 2', 'amb two', %L, 't0018_a')$q$, v_sub), '23505',
                            'context_documents_node_id_doc_key_key', 'same-node pair refused by UNIQUE (node_id, doc_key)');
  END IF;

  PERFORM pg_temp.check(ops.resolve_context('global.t0018a'::public.ltree, 'T0018_NEAR') LIKE '%project part', 'project path: own doc');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca'::public.ltree, 'T0018_NEAR') LIKE '%component part%',
                        'self wins over ancestor');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca.sub'::public.ltree, 'T0018_NEAR') LIKE '%component part%',
                        'nearest ancestor wins');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca.sub'::public.ltree, 'T0018_UP') = 'project only',
                        'only ancestor two levels up');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca.sub.leaf'::public.ltree, 'T0018_AMB') = 'amb leaf',
                        'deepest match wins over an ambiguous ancestor');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca'::public.ltree, 'T0018_NEAR#Part') = E'## Part\ncomponent part',
                        'heading extraction stops at the next same-level heading');
  PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca'::public.ltree, 'T0018_NEAR#top')
                          = E'# Top\ncomponent\n## Part\ncomponent part\n## Next\nnext', 'heading match is case-insensitive');
  IF newest < '0033' THEN
  PERFORM pg_temp.rejects($q$SELECT ops.resolve_context('global.t0018a.ca.sub'::public.ltree, 'T0018_AMB')$q$, 'P0001',
                          'ambiguous context ref T0018_AMB at global.t0018a.ca.sub', 'two matches at the deepest depth');
  ELSE
    RAISE NOTICE 'skip 6 same-node ambiguity, refused by UNIQUE (node_id, doc_key) (newest migration is %)', newest;
    PERFORM pg_temp.check(ops.resolve_context('global.t0018a.ca.sub'::public.ltree, 'T0018_AMB') = 'amb one',
                          'single document on the node is served (0033)');
  END IF;
  PERFORM pg_temp.rejects($q$SELECT ops.resolve_context('global.t0018a.ca'::public.ltree, 'T0018_NEAR#Nope')$q$, 'P0001',
                          'heading "Nope" not found in T0018_NEAR', 'heading miss');
  PERFORM pg_temp.rejects($q$SELECT ops.resolve_context('global.t0018b'::public.ltree, 'T0018_NEAR')$q$, 'P0001',
                          'unknown context ref T0018_NEAR', 'other subtree does not see it');
  PERFORM pg_temp.rejects($q$SELECT ops.resolve_context('global.t0018a'::public.ltree, 'T0018_AMB')$q$, 'P0001',
                          'unknown context ref T0018_AMB', 'descendants are not searched');
  PERFORM pg_temp.rejects($q$SELECT ops.resolve_context('global.t0018nosuch'::public.ltree, 'T0018_NEAR')$q$, 'P0001',
                          'unknown node global.t0018nosuch', 'unknown path');
  RAISE NOTICE 'ok   6 resolve_context: self, nearest ancestor, ambiguous same-node pair, heading, misses';
END $$;

-- 7. create_dispatch
DO $$
DECLARE d ops.dispatches; v_before bigint := (SELECT count(*) FROM ops.dispatches);
BEGIN
  d := ops.create_dispatch('global.t0018a.ca'::public.ltree, 'addition', 't0018 add', 'prompt',
                           '{T0018_UP,T0018_NEAR#Part}', 7, pg_temp.id('sa_proj'));
  PERFORM pg_temp.check(d.status = 'pending' AND d.project_id = pg_temp.id('pa') AND d.component_id = pg_temp.id('ca')
                        AND d.session_id = pg_temp.id('sa_proj') AND d.priority = 7
                        AND d.context_refs = '{T0018_UP,T0018_NEAR#Part}', 'dispatch row: ' || to_jsonb(d)::text);
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.dispatch_nodes WHERE dispatch_id = d.id) = ARRAY[pg_temp.id('ca_node')],
                        'dispatch_nodes = component node');
  d := ops.create_dispatch('global.t0018a.ca2'::public.ltree, 'investigation', 't0018 inv', 'p', '{}', 100, pg_temp.id('sa_comp'));
  PERFORM pg_temp.check(d.session_id = pg_temp.id('sa_comp') AND d.context_refs = '{}', 'session on a sibling component accepted');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) = v_before + 2, 'two dispatches written');

  -- the refusals carry a session of the path's project, so each call reaches the refusal under test (session
  -- required from 0022; the null-session refusal itself is asserted in tests/sql/0022)
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')), 'P0001',
                          'unknown component global.t0018a', 'project path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.nosuch'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')), 'P0001',
                          'unknown component global.t0018a.nosuch', 'unknown path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.cz'::public.ltree, 'investigation', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')), '23514',
                          'component global.t0018a.cz is not active', 'inactive component');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca'::public.ltree, 'no_such_type_t0018', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')), '23514',
                          'unknown dispatch type', 'unknown type');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca2'::public.ltree, 'addition', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')), '23514',
                          'has commit policy local but component global.t0018a.ca2 has no verify_cmd', 'policy without verify_cmd');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca'::public.ltree, 'addition', 't', 'p', '{T0018_NONE}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')),
                          '23514', 'context ref "T0018_NONE" does not resolve: unknown context ref T0018_NONE', 'unknown ref');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca'::public.ltree, 'addition', 't', 'p', '{T0018_NEAR#Nope}', 100, %L)$q$,
                                 pg_temp.id('sa_proj')),
                          '23514', 'context ref "T0018_NEAR#Nope" does not resolve', 'heading miss');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018b.cb'::public.ltree, 'addition', 't', 'p', '{T0018_UP}', 100, %L)$q$,
                                 pg_temp.id('sb_proj')),
                          '23514', 'context ref "T0018_UP" does not resolve', 'ref outside the path''s ancestors');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca'::public.ltree, 'addition', 't', 'p', '{}', 100, %L)$q$,
                                 pg_temp.id('sb_proj')), '23514', 'is outside global.t0018a (the scope of global.t0018a.ca)',
                          'session of another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('global.t0018a.ca'::public.ltree, 'addition', 't', 'p', '{}', 100, %L)$q$,
                                 gen_random_uuid()), '23514', 'does not exist', 'unknown session');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) = v_before + 2, 'refusals wrote nothing');
  PERFORM set_config('ops_test.dispatch_a', d.id::text, true);
  RAISE NOTICE 'ok   7 create_dispatch: component, node refs, node-based session check, refusals';
END $$;

-- 8. log_decision
DO $$
DECLARE d ops.decisions; v_da uuid; v_db uuid; v_dg uuid;
BEGIN
  d := ops.log_decision('global.t0018a.ca'::public.ltree, 't0018 component', 'why', '["alt"]', 'when', 'scope-x', NULL,
                        pg_temp.id('sa_comp'));
  PERFORM pg_temp.check(d.project_id = pg_temp.id('pa') AND d.component_id = pg_temp.id('ca') AND d.session_id = pg_temp.id('sa_comp')
                        AND d.rationale = 'why' AND d.rejected_alternatives = '["alt"]' AND d.revisit_condition = 'when'
                        AND d.scope = 'scope-x', 'component decision: ' || to_jsonb(d)::text);
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.id('ca_node')],
                        'component decision on the component node');
  v_da := d.id;
  d := ops.log_decision('global.t0018a'::public.ltree, 't0018 project', NULL, '[]', NULL, NULL, v_da, pg_temp.id('sa_proj'));
  PERFORM pg_temp.check(d.project_id = pg_temp.id('pa') AND d.component_id IS NULL AND d.supersedes = v_da
                        AND d.rejected_alternatives = '[]', 'project decision superseding a component decision');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.id('pa_node')],
                        'project decision on the project node');
  d := ops.log_decision('global.t0018a.ca.sub'::public.ltree, 't0018 sub', p_session => pg_temp.id('sa_proj'));
  PERFORM pg_temp.check(d.project_id = pg_temp.id('pa') AND d.component_id IS NULL
                        AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.id('sub_node')],
                        'sub-node decision: home = sub node, project kept, no component');
  v_db := (ops.log_decision('global.t0018b'::public.ltree, 't0018 b', p_session => pg_temp.id('sb_proj'))).id;
  d := ops.log_decision('global'::public.ltree, 't0018 global', NULL, '[]', NULL, NULL, v_db, pg_temp.id('sb_proj'));
  PERFORM pg_temp.check(d.project_id IS NULL AND d.component_id IS NULL AND d.supersedes = v_db AND d.session_id = pg_temp.id('sb_proj'),
                        'global decision: no project, supersedes and session of any project accepted');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id) = ARRAY[pg_temp.id('global_node')],
                        'global decision on the global node');
  v_dg := d.id;

  -- the refusals carry a session of the path's project, so each call reaches the refusal under test (session
  -- required from 0022; the null-session refusal itself is asserted in tests/sql/0022)
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0018a'::public.ltree, 'x', NULL, '[]', NULL, NULL, %L, %L)$q$, v_db,
                                 pg_temp.id('sa_proj')),
                          '23514', 'superseded decision ' || v_db || ' does not exist in global.t0018a', 'supersedes from another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0018a.ca'::public.ltree, 'x', NULL, '[]', NULL, NULL, %L, %L)$q$, v_dg,
                                 pg_temp.id('sa_proj')),
                          '23514', 'does not exist in global.t0018a', 'supersedes of a global decision from a project path');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0018a'::public.ltree, 'x', NULL, '[]', NULL, NULL, %L, %L)$q$,
                                 gen_random_uuid(), pg_temp.id('sa_proj')), '23514', 'does not exist in', 'unknown supersedes');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0018a.ca'::public.ltree, 'x', NULL, '[]', NULL, NULL, NULL, %L)$q$,
                                 pg_temp.id('sb_proj')), '23514', 'is outside global.t0018a', 'session from another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision(p_node_path => 'global.t0018a'::public.ltree, p_decision => '  ', p_session => %L)$q$,
                                 pg_temp.id('sa_proj')), '23514', 'decision text is empty',
                          'empty decision');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('global.t0018a'::public.ltree, 'x', NULL, '{}', NULL, NULL, NULL, %L)$q$,
                                 pg_temp.id('sa_proj')), '23514',
                          'rejected_alternatives must be a JSON array', 'rejected_alternatives not an array');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision(p_node_path => 'global.t0018nosuch'::public.ltree, p_decision => 'x', p_session => %L)$q$,
                                 pg_temp.id('sa_proj')), 'P0001',
                          'unknown node global.t0018nosuch', 'unknown path');
  PERFORM set_config('ops_test.decision_b', v_db::text, true);
  RAISE NOTICE 'ok   8 log_decision: component / project / sub / global homes, node-based supersedes and session checks';
END $$;

-- 9. add_backlog_item
DO $$
DECLARE b ops.backlog_items; v_da uuid := pg_temp.id('dispatch_a'); v_dcb uuid := pg_temp.id('d_cb');
BEGIN
  b := ops.add_backlog_item('global.t0018a.ca'::public.ltree, 'task', 't0018 item', 'detail', v_da, 'high');
  PERFORM pg_temp.check(b.project_id = pg_temp.id('pa') AND b.component_id = pg_temp.id('ca') AND b.home_node_id = pg_temp.id('ca_node')
                        AND b.kind = 'task' AND b.severity = 'high' AND b.detail = 'detail' AND b.status = 'open',
                        'component item: ' || to_jsonb(b)::text);
  PERFORM pg_temp.check(b.source = 'kind:task|dispatch:' || v_da, 'source with dispatch: ' || coalesce(b.source, 'NULL'));
  b := ops.add_backlog_item('global.t0018a'::public.ltree, 'followup', 't0018 project item');
  PERFORM pg_temp.check(b.project_id = pg_temp.id('pa') AND b.component_id IS NULL AND b.home_node_id = pg_temp.id('pa_node')
                        AND b.severity = 'untriaged' AND b.source = 'kind:followup', 'project item with defaults');
  b := ops.add_backlog_item('global.t0018a.ca.sub'::public.ltree, 'task', 't0018 sub item');
  PERFORM pg_temp.check(b.project_id = pg_temp.id('pa') AND b.component_id IS NULL AND b.home_node_id = pg_temp.id('sub_node'),
                        'sub-node item');
  b := ops.add_backlog_item('global'::public.ltree, 'proposal', 't0018 global item', NULL, v_dcb);
  PERFORM pg_temp.check(b.project_id IS NULL AND b.component_id IS NULL AND b.home_node_id = pg_temp.id('global_node')
                        AND b.source = 'kind:proposal|dispatch:' || v_dcb, 'global item, source dispatch of any project');

  PERFORM pg_temp.rejects(format($q$SELECT ops.add_backlog_item('global.t0018a'::public.ltree, 'task', 'x', NULL, %L)$q$, v_dcb),
                          '23514', 'source dispatch ' || v_dcb || ' does not exist in global.t0018a', 'source dispatch from another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.add_backlog_item('global.t0018a'::public.ltree, 'task', 'x', NULL, %L)$q$, gen_random_uuid()),
                          '23514', 'does not exist in', 'unknown source dispatch');
  PERFORM pg_temp.rejects($q$SELECT ops.add_backlog_item('global.t0018a'::public.ltree, 'task', ' ')$q$, '23514',
                          'backlog item title is empty', 'empty title');
  PERFORM pg_temp.rejects($q$SELECT ops.add_backlog_item('global.t0018a'::public.ltree, 'task', 'x', NULL, NULL, NULL)$q$, '23514',
                          'backlog item severity is required', 'null severity');
  PERFORM pg_temp.rejects($q$SELECT ops.add_backlog_item('global.t0018nosuch'::public.ltree, 'task', 'x')$q$, 'P0001',
                          'unknown node global.t0018nosuch', 'unknown path');
  RAISE NOTICE 'ok   9 add_backlog_item: component / project / sub / global homes, source format, node-based source check';
END $$;

-- 10. old-signature resolution (fix A): unknown-literal positional calls either reach the OLD functions or, where the
--     old and new signatures put different non-string types at a later position, raise 42725 (accepted until release 2,
--     which drops the old functions); each ambiguous shape reaches the OLD function in named notation
--     0021 drops the old functions (M5b release 2): from 0021 on the block skips; tests/sql/0021 asserts the new state
DO $$
DECLARE p ops.projects; c ops.components; d ops.decisions; b ops.backlog_items; x ops.dispatches; v_s uuid; v_ids uuid[];
        v_txt text; c2 ops.components; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 10 old-signature shapes (newest migration is %)', newest;
    RETURN;
  END IF;
  -- 0014:74 shape: ambiguous; named notation reaches the old function
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('t0018amb', 'T0018 AMB', '{"x": 1}')$q$, '42725',
                          'function ops.create_project(unknown, unknown, unknown) is not unique', 'create_project 3 unknown literals');
  p := ops.create_project(p_key => 't0018old', p_name => 'T0018 OLD', p_params => '{"x": 1}');
  PERFORM pg_temp.check(p.key = 't0018old' AND p.params = '{"x": 1}'
                        AND (SELECT path::text FROM ops.nodes WHERE id = p.node_id) = 'global.t0018old',
                        'named create_project(p_key, p_name, p_params) -> old');
  -- named call without a path (mcp planner.ts:225)
  p := ops.create_project(p_key => 't0018named', p_name => 'T0018 NAMED', p_params => '{}');
  PERFORM pg_temp.check(p.key = 't0018named', 'named create_project -> old');
  -- 0014:88 shape
  c := ops.create_component('t0018old', 'cold', 'service', NULL, 'npm test');
  PERFORM pg_temp.check(c.project_id = (SELECT id FROM ops.projects WHERE key = 't0018old'), 'create_component positional -> old');
  -- 0014:134 shape
  v_s := ops.open_session('t0018old', 'cold', 'planning');
  PERFORM pg_temp.check((SELECT component_id FROM ops.sessions WHERE id = v_s) = c.id, 'open_session(text,text,text) -> old');
  v_s := ops.open_session('t0018old', NULL, 'planning');
  PERFORM pg_temp.check((SELECT component_id IS NULL FROM ops.sessions WHERE id = v_s), 'open_session(text,NULL,text) -> old');
  -- 0014:246 / 0014:248 shape: ambiguous; named notation reaches the old function
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('t0018old', NULL, 'planning', 'global')$q$, '42725',
                          'function ops.open_session(unknown, unknown, unknown, unknown) is not unique',
                          'open_session 4 unknown literals with a scope');
  v_s := ops.open_session(p_project_key => 't0018old', p_component_key => NULL, p_kind => 'planning', p_scope => 'global');
  PERFORM pg_temp.check((SELECT (project_id, component_id, scope) IS NOT DISTINCT FROM (c.project_id, NULL::uuid, 'global'::ops.segment_scope)
                           FROM ops.sessions WHERE id = v_s), 'named open_session(p_project_key, ..., p_scope) -> old');
  -- 0014:172 and 0014:185 shapes
  d := ops.log_decision('t0018old', 't0018 old project-level');
  PERFORM pg_temp.check(d.project_id = c.project_id AND d.component_id IS NULL, 'log_decision(text,text) -> old');
  PERFORM pg_temp.check((ops.log_decision('t0018old', 't0018 old b')).id IS NOT NULL, '(log_decision(text,text)).id -> old');
  -- 0014:189 shape: ambiguous; named notation reaches the old function
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('t0018old', 'x', NULL, NULL, '[]', NULL, NULL, %L)$q$, d.id), '42725',
                          'function ops.log_decision(unknown, unknown, unknown, unknown, unknown, unknown, unknown, unknown) is not unique',
                          'log_decision 8 unknown literals');
  PERFORM pg_temp.check((ops.log_decision(p_project_key => 't0018old', p_decision => 't0018 old named', p_component_key => NULL,
                                          p_rationale => NULL, p_rejected_alternatives => '[]', p_revisit_condition => NULL,
                                          p_scope => NULL, p_supersedes => d.id)).supersedes = d.id,
                        'named log_decision(p_project_key, ..., p_supersedes) -> old');
  -- 0014:200 / 0015:202 shapes
  b := ops.add_backlog_item('t0018old', 'followup', 't0018 old item');
  PERFORM pg_temp.check(b.project_id = c.project_id AND b.source = 'kind:followup', 'add_backlog_item(text,kind,text) -> old');
  b := ops.add_backlog_item('t0018old', 'task', 't0018 old writer project');
  PERFORM pg_temp.check(b.project_id = c.project_id AND b.kind = 'task', 'add_backlog_item 0015:202 shape -> old');
  -- create_dispatch positional (0014:128 shape)
  x := ops.create_dispatch('t0018old', 'cold', 'investigation', 't0018 old', 'p');
  PERFORM pg_temp.check(x.component_id = c.id, 'create_dispatch(text,text,...) -> old');
  -- 0014:212 shape: ambiguous; named notation reaches the old function
  PERFORM pg_temp.rejects(format($q$SELECT ops.add_backlog_item('t0018old', 'task', 'x', NULL, NULL, %L)$q$, x.id), '42725',
                          'function ops.add_backlog_item(unknown, unknown, unknown, unknown, unknown, unknown) is not unique',
                          'add_backlog_item 6 unknown literals');
  b := ops.add_backlog_item(p_project_key => 't0018old', p_kind => 'task', p_title => 't0018 old named item',
                            p_component_key => NULL, p_detail => NULL, p_source_dispatch => x.id);
  PERFORM pg_temp.check(b.project_id = c.project_id AND b.source = 'kind:task|dispatch:' || x.id,
                        'named add_backlog_item(p_project_key, ..., p_source_dispatch) -> old');
  -- 0014:155 / 0014:157 shape: ambiguous; named notation reaches the old function (on cold2, so cold keeps one dispatch)
  c2 := ops.create_component('t0018old', 'cold2', 'service');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch('t0018old', 'cold2', 'investigation', 't', 'p', '{}')$q$, '42725',
                          'function ops.create_dispatch(unknown, unknown, unknown, unknown, unknown, unknown) is not unique',
                          'create_dispatch 6 unknown literals');
  PERFORM pg_temp.check((ops.create_dispatch(p_project_key => 't0018old', p_component_key => 'cold2', p_dispatch_type => 'investigation',
                                             p_title => 't0018 old named', p_prompt => 'p', p_context_refs => '{}')).component_id = c2.id,
                        'named create_dispatch(p_project_key, ..., p_context_refs) -> old');
  -- get_pending(text,text), get_unreviewed_reports(text), resolve_context(text,text)
  SELECT array_agg(id) INTO v_ids FROM ops.get_pending('t0018old', 'cold');
  PERFORM pg_temp.check(v_ids = ARRAY[x.id], 'get_pending(text,text) -> old');
  PERFORM ops.claim_dispatch(x.id, 't0018'), ops.complete_dispatch(x.id, 'r', 'report');
  SELECT array_agg(id) INTO v_ids FROM ops.get_unreviewed_reports('t0018old');
  PERFORM pg_temp.check(v_ids = ARRAY[x.id], 'get_unreviewed_reports(text) -> old');
  INSERT INTO ops.context_documents (project_id, doc_key, title, content, node_id, doc_type)
  VALUES (c.project_id, 'T0018_OLDDOC', 'old', 'old content', c.node_id, 'manual');
  v_txt := ops.resolve_context('t0018old', 'T0018_OLDDOC');
  PERFORM pg_temp.check(v_txt = 'old content', 'resolve_context(text,text) -> old (project-keyed lookup)');
  RAISE NOTICE 'ok  10 old-signature shapes: unknown-literal calls reach the old functions or raise 42725 (create_project 3, open_session 4 with scope, log_decision 8, add_backlog_item 6, create_dispatch 6); named notation reaches the old functions';
END $$;

-- untyped $n parameters (as node-postgres sends them): the prepared statements resolve to the text versions
-- 0021 drops the text versions (M5b release 2): from 0021 on the statements are skipped (psql \if, since a DO-level
-- skip cannot gate top-level PREPARE); tests/sql/0021 asserts that untyped $n now resolve to the node-keyed versions
SELECT (max(version) >= '0021') AS skip11 FROM ops.schema_migrations \gset
\if :skip11
DO $$ BEGIN
  RAISE NOTICE 'skip 11 untyped $n parameters on the text versions (newest migration is %)',
    (SELECT max(version) FROM ops.schema_migrations);
END $$;
\else
PREPARE t0018_pending AS SELECT id FROM ops.get_pending($1, $2);
PREPARE t0018_unreviewed AS SELECT id FROM ops.get_unreviewed_reports($1);
PREPARE t0018_resolve AS SELECT ops.resolve_context($1, $2) AS content;
CREATE TEMP TABLE t0018_r_unreviewed AS EXECUTE t0018_unreviewed('t0018old');
CREATE TEMP TABLE t0018_r_resolve AS EXECUTE t0018_resolve('t0018old', 'T0018_OLDDOC');
CREATE TEMP TABLE t0018_r_pending AS EXECUTE t0018_pending('t0018old', 'cold');
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT array_agg(parameter_types::text ORDER BY name) FROM pg_prepared_statements
                          WHERE name LIKE 't0018_%')
                        = ARRAY['{text,text}', '{text,text}', '{text}'], 'untyped parameters resolved as text');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_temp.t0018_r_unreviewed) = 1, 'get_unreviewed_reports($1) -> old');
  PERFORM pg_temp.check((SELECT content FROM pg_temp.t0018_r_resolve) = 'old content', 'resolve_context($1,$2) -> old');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_temp.t0018_r_pending) = 0, 'get_pending($1,$2) -> old (no pending left)');
  RAISE NOTICE 'ok  11 untyped $n parameters resolve to the old functions';
END $$;
DEALLOCATE t0018_pending;
DEALLOCATE t0018_unreviewed;
DEALLOCATE t0018_resolve;
\endif

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'doc_types', (SELECT count(*) FROM ops.doc_types)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok  12 no leftover rows; 0018 tests passed';
END $$;
