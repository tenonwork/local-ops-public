-- tests/sql/0015_spine_m4b_enforcement.sql
-- Tests for migrations/0015_spine_m4b_enforcement.sql. Run as the schema owner against a non-production database
-- where 0015 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0015_spine_m4b_enforcement.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400 / 7eb6746f): the file creates its own projects t0015a / t0015b (through
-- create_project / create_component, so their nodes sit under their project nodes, never on the global node),
-- asserts only on rows it creates, and counts relative to the starting state.
-- Grants are checked at catalog level (b28e2660): the tests connect as ops_dev, which is not a member of
-- ops_planner, so SET ROLE is not available; the planner checks the tool path live after promote.

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

-- runs an INSERT ... RETURNING id and returns the id (raises on failure)
CREATE FUNCTION pg_temp.ins_id(p_sql text, p_what text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  EXECUTE p_sql || ' RETURNING id' INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'FAIL: % (got % %)', p_what, SQLSTATE, SQLERRM;
END $$;

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- an INSERT into one of the four component-scoped tables; p_node is the home node (backlog_items) or node
-- (context_documents) and is ignored for sessions and decisions. A decision carries the block 0 fixture session of
-- its project (session_id NOT NULL from 0022): t0015a's, or the project-less one when p_project is NULL
CREATE FUNCTION pg_temp.ins(p_table text, p_project uuid, p_component uuid, p_node uuid) RETURNS text LANGUAGE sql AS $$
  SELECT CASE p_table
    WHEN 'sessions' THEN format($q$INSERT INTO ops.sessions (project_id, component_id, kind) VALUES (%L, %L, 'planning')$q$,
                                p_project, p_component)
    WHEN 'decisions' THEN format($q$INSERT INTO ops.decisions (project_id, component_id, session_id, decision) VALUES (%L, %L, %L, 't0015')$q$,
                                 p_project, p_component,
                                 CASE WHEN p_project IS NULL THEN pg_temp.id('s_none') ELSE pg_temp.id('s_pa') END)
    WHEN 'context_documents' THEN format(
      $q$INSERT INTO ops.context_documents (project_id, component_id, doc_key, title, content, node_id, doc_type)
         VALUES (%L, %L, %L, 't0015', 'c', %L, 'manual')$q$,
      p_project, p_component, 'T0015_' || upper(replace(gen_random_uuid()::text, '-', '_')), p_node)
    WHEN 'backlog_items' THEN format(
      $q$INSERT INTO ops.backlog_items (project_id, component_id, title, kind, home_node_id)
         VALUES (%L, %L, 't0015', 'task', %L)$q$, p_project, p_component, p_node)
  END;
$$;

-- 0. fixtures: two projects, a component in each, a node below component ca
DO $$
DECLARE p ops.projects; c ops.components; v_sub uuid; v_n uuid;
BEGIN
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0015a', p_name => 'T0015 A');
  PERFORM set_config('ops_test.pa', p.id::text, true), set_config('ops_test.pa_node', p.node_id::text, true);
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0015b', p_name => 'T0015 B');
  PERFORM set_config('ops_test.pb', p.id::text, true), set_config('ops_test.pb_node', p.node_id::text, true);
  c := ops.create_component(p_parent_path => 'global.t0015a'::public.ltree, p_key => 'ca', p_kind => 'service', p_verify_cmd => 'npm test');
  PERFORM set_config('ops_test.ca', c.id::text, true), set_config('ops_test.ca_node', c.node_id::text, true);
  c := ops.create_component(p_parent_path => 'global.t0015b'::public.ltree, p_key => 'cb', p_kind => 'service', p_verify_cmd => 'npm test');
  PERFORM set_config('ops_test.cb', c.id::text, true), set_config('ops_test.cb_node', c.node_id::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.id('ca_node'), 'sub', 'node', 'sub')
  RETURNING id INTO v_sub;
  PERFORM set_config('ops_test.sub_node', v_sub::text, true);
  -- a second descendant of ca and a free node under the project node, so documents never share (node_id, doc_type)
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.id('ca_node'), 'sub2', 'node', 'sub2') RETURNING id INTO v_n;
  PERFORM set_config('ops_test.sub2_node', v_n::text, true);
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.id('pa_node'), 'free', 'node', 'free') RETURNING id INTO v_n;
  PERFORM set_config('ops_test.free_node', v_n::text, true);
  -- sessions for the decisions pg_temp.ins writes: one in t0015a, one without a project
  INSERT INTO ops.sessions (project_id, kind) VALUES (pg_temp.id('pa'), 'planning') RETURNING id INTO v_n;
  PERFORM set_config('ops_test.s_pa', v_n::text, true);
  INSERT INTO ops.sessions (kind) VALUES ('planning') RETURNING id INTO v_n;
  PERFORM set_config('ops_test.s_none', v_n::text, true);
  PERFORM pg_temp.check((SELECT path::text FROM ops.nodes WHERE id = v_sub) = 'global.t0015a.ca.sub', 'descendant node path');
  PERFORM pg_temp.check((SELECT path::text FROM ops.nodes WHERE id = pg_temp.id('pa_node')) = 'global.t0015a',
                        'project node directly under global');
  RAISE NOTICE 'ok   0 fixtures (t0015a/ca with node global.t0015a.ca.sub, t0015b/cb)';
END $$;

-- 1. backlog_items home_node_id and kind NOT NULL; the backfill helper is gone
DO $$
DECLARE v_pa uuid := pg_temp.id('pa'); v_node uuid := pg_temp.id('pa_node');
BEGIN
  PERFORM pg_temp.check((SELECT array_agg(column_name || ':' || is_nullable || ':' || coalesce(column_default, '-')
                                          ORDER BY column_name)
                           FROM information_schema.columns
                          WHERE table_schema = 'ops' AND table_name = 'backlog_items'
                            AND column_name IN ('home_node_id', 'kind'))
                        = ARRAY['home_node_id:NO:-', 'kind:NO:-'], 'home_node_id and kind NOT NULL, no default');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.backlog_items (project_id, title, home_node_id) VALUES (%L, 't', %L)$q$,
                                 v_pa, v_node), '23502', 'kind', 'backlog without kind');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.backlog_items (project_id, title, kind) VALUES (%L, 't', 'task')$q$, v_pa),
                          '23502', 'home_node_id', 'backlog without home_node_id');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.backlog_items SET kind = NULL WHERE id = %L$q$,
                                 pg_temp.ins_id(pg_temp.ins('backlog_items', v_pa, NULL, v_node), 'backlog fixture')),
                          '23502', 'kind', 'UPDATE kind to NULL');
  PERFORM pg_temp.check(to_regprocedure('ops._spine_backfill()') IS NULL, 'ops._spine_backfill() dropped');
  RAISE NOTICE 'ok   1 NOT NULL on backlog home_node_id / kind; helper dropped';
END $$;

-- 2. component-scope trigger, project rule, on each of the four tables
DO $$
DECLARE t text; v_id uuid;
        v_pa uuid := pg_temp.id('pa'); v_pb uuid := pg_temp.id('pb'); v_ca uuid := pg_temp.id('ca'); v_cb uuid := pg_temp.id('cb');
        v_pa_node uuid := pg_temp.id('pa_node'); v_ca_node uuid := pg_temp.id('ca_node'); v_cb_node uuid := pg_temp.id('cb_node');
BEGIN
  FOREACH t IN ARRAY ARRAY['sessions', 'decisions', 'context_documents', 'backlog_items'] LOOP
    PERFORM pg_temp.rejects(pg_temp.ins(t, NULL, v_ca, v_ca_node), '23514',
                            format('component %s does not belong to project null (%s)', v_ca, t), t || ': null project_id');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_cb, v_cb_node), '23514',
                            format('component %s does not belong to project %s (%s)', v_cb, v_pa, t), t || ': component of another project');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, gen_random_uuid(), v_ca_node), '23514', 'does not exist',
                            t || ': unknown component');
    v_id := pg_temp.ins_id(pg_temp.ins(t, v_pa, v_ca, v_ca_node), t || ': correct project accepted');
    PERFORM pg_temp.ins_id(pg_temp.ins(t, v_pa, NULL, v_pa_node), t || ': component_id NULL accepted');
    PERFORM pg_temp.ins_id(pg_temp.ins(t, NULL, NULL, pg_temp.id('free_node')), t || ': no project, no component accepted');
    PERFORM pg_temp.rejects(format('UPDATE ops.%I SET component_id = %L WHERE id = %L', t, v_cb, v_id), '23514',
                            'does not belong to project', t || ': UPDATE to a component of another project');
    PERFORM pg_temp.rejects(format('UPDATE ops.%I SET project_id = %L WHERE id = %L', t, v_pb, v_id), '23514',
                            'does not belong to project', t || ': UPDATE of project_id away from the component');
    PERFORM pg_temp.rejects(format('UPDATE ops.%I SET project_id = NULL WHERE id = %L', t, v_id), '23514',
                            'does not belong to project null', t || ': UPDATE of project_id to NULL');
    PERFORM pg_temp.check((SELECT (project_id, component_id) = (v_pa, v_ca) FROM ops.sessions WHERE id = v_id
                           UNION ALL SELECT (project_id, component_id) = (v_pa, v_ca) FROM ops.decisions WHERE id = v_id
                           UNION ALL SELECT (project_id, component_id) = (v_pa, v_ca) FROM ops.context_documents WHERE id = v_id
                           UNION ALL SELECT (project_id, component_id) = (v_pa, v_ca) FROM ops.backlog_items WHERE id = v_id),
                          t || ': refused updates left the row unchanged');
  END LOOP;
  RAISE NOTICE 'ok   2 project rule on sessions, decisions, context_documents, backlog_items (insert and update)';
END $$;

-- 3. component-scope trigger, node rule, on backlog_items (home_node_id) and context_documents (node_id)
DO $$
DECLARE t text; c text; v_id uuid;
        v_pa uuid := pg_temp.id('pa'); v_ca uuid := pg_temp.id('ca');
        v_pa_node uuid := pg_temp.id('pa_node'); v_pb_node uuid := pg_temp.id('pb_node');
        v_ca_node uuid := pg_temp.id('ca_node'); v_sub uuid := pg_temp.id('sub_node'); v_cb_node uuid := pg_temp.id('cb_node');
        v_global uuid := (SELECT id FROM ops.nodes WHERE kind = 'global');
BEGIN
  FOREACH t IN ARRAY ARRAY['context_documents', 'backlog_items'] LOOP
    c := CASE t WHEN 'backlog_items' THEN 'home_node_id' ELSE 'node_id' END;
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_ca, v_pa_node), '23514',
                            format('node global.t0015a of %s is outside the subtree of component %s (node global.t0015a.ca)', t, v_ca),
                            t || ': project root node');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_ca, v_pb_node), '23514', 'node global.t0015b of', t || ': another project''s node');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_ca, v_cb_node), '23514', 'node global.t0015b.cb of',
                            t || ': another component''s node');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_ca, v_global), '23514', 'node global of', t || ': global node (refused)');
    PERFORM pg_temp.rejects(pg_temp.ins(t, v_pa, v_ca, gen_random_uuid()), '23514', '(missing)', t || ': unknown node');
    v_id := pg_temp.ins_id(pg_temp.ins(t, v_pa, v_ca, v_sub), t || ': descendant of the component node accepted');
    PERFORM pg_temp.rejects(format('UPDATE ops.%I SET %I = %L WHERE id = %L', t, c, v_pa_node, v_id), '23514',
                            'is outside the subtree', t || ': UPDATE of the node out of the subtree');
    PERFORM pg_temp.check(pg_temp.err(format('UPDATE ops.%I SET %I = %L WHERE id = %L', t, c, pg_temp.id('sub2_node'), v_id)) IS NULL,
                          t || ': UPDATE to another descendant accepted');
  END LOOP;
  RAISE NOTICE 'ok   3 node rule on backlog_items and context_documents (component node and descendant only)';
END $$;

-- 4. writer functions still work under the trigger and NOT NULL
DO $$
DECLARE b ops.backlog_items; d ops.decisions; x ops.dispatches; v_s uuid; v_n integer;
BEGIN
  b := ops.add_backlog_item(p_node_path => 'global.t0015a.ca'::public.ltree, p_kind => 'followup', p_title => 't0015 writer');
  PERFORM pg_temp.check(b.kind = 'followup' AND b.home_node_id = pg_temp.id('ca_node') AND b.component_id = pg_temp.id('ca'),
                        'add_backlog_item component item: ' || to_jsonb(b)::text);
  b := ops.add_backlog_item(p_node_path => 'global.t0015a'::public.ltree, p_kind => 'task', p_title => 't0015 writer project');
  PERFORM pg_temp.check(b.kind = 'task' AND b.home_node_id = pg_temp.id('pa_node') AND b.component_id IS NULL,
                        'add_backlog_item project item: ' || to_jsonb(b)::text);
  b := ops.update_backlog_item(b.id, 'done', 'closed by t0015');
  PERFORM pg_temp.check(b.status = 'done' AND b.kind = 'task' AND b.home_node_id = pg_temp.id('pa_node'), 'update_backlog_item');
  v_s := ops.open_session(p_node_path => 'global.t0015a.ca'::public.ltree, p_kind => 'execution');
  PERFORM pg_temp.check((SELECT (project_id, component_id, status) = (pg_temp.id('pa'), pg_temp.id('ca'), 'active')
                           FROM ops.sessions WHERE id = v_s), 'open_session');
  d := ops.log_decision(p_node_path => 'global.t0015a.ca'::public.ltree, p_decision => 't0015 decision', p_session => v_s);
  PERFORM pg_temp.check(d.component_id = pg_temp.id('ca') AND d.session_id = v_s, 'log_decision');
  x := ops.create_dispatch(p_node_path => 'global.t0015a.ca'::public.ltree, p_dispatch_type => 'addition', p_title => 't0015',
                           p_prompt => 'p', p_context_refs => '{}', p_priority => 100, p_session => v_s);
  PERFORM pg_temp.check(x.status = 'pending' AND x.session_id = v_s, 'create_dispatch');
  v_n := ops.close_session(v_s, 's', 'n', '[{"decision": "t0015 inline"}]');
  PERFORM pg_temp.check(v_n = 1 AND (SELECT status = 'closed' FROM ops.sessions WHERE id = v_s), 'close_session');
  PERFORM pg_temp.check((SELECT component_id = pg_temp.id('ca') FROM ops.decisions WHERE session_id = v_s AND decision = 't0015 inline'),
                        'close_session inline decision on the component');
  RAISE NOTICE 'ok   4 add_backlog_item, update_backlog_item, open_session, log_decision, create_dispatch, close_session';
END $$;

-- 5. trigger catalog: one invoker function, owner-only EXECUTE, four row triggers
DO $$
DECLARE f oid := to_regprocedure('ops._component_scope()'); newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest > '0015_spine_m4b_enforcement' THEN
    -- 0016 adds dispatches_component_scope; check the four 0015 triggers unchanged among the rest
    RAISE NOTICE 'skip 5 exactly four triggers, check the four 0015 triggers unchanged instead (newest migration is %)', newest;
  END IF;
  PERFORM pg_temp.check((SELECT NOT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] FROM pg_proc WHERE oid = f),
                        'SECURITY INVOKER with search_path = ops, pg_temp');
  PERFORM pg_temp.check(NOT has_function_privilege(r, f, 'EXECUTE'), r || ' cannot execute ops._component_scope()')
     FROM unnest(ARRAY['public', 'ops_planner', 'ops_executor']) r;
  PERFORM pg_temp.check(obj_description(f, 'pg_proc') LIKE '%011b32a8%', 'comment names backlog 011b32a8');
  PERFORM pg_temp.check(-- definitions without the schema prefix, which pg_get_triggerdef omits under search_path = ops
                         (SELECT array_agg(replace(pg_get_triggerdef(oid), ' ops.', ' ') ORDER BY tgname) FROM pg_trigger
                          WHERE tgfoid = f AND NOT tgisinternal
                            AND (newest <= '0015_spine_m4b_enforcement' OR tgname <> 'dispatches_component_scope'))
    = ARRAY[
      'CREATE TRIGGER backlog_items_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id, home_node_id ON backlog_items FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER context_documents_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id, node_id ON context_documents FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER decisions_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id ON decisions FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER sessions_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id ON sessions FOR EACH ROW EXECUTE FUNCTION _component_scope()'],
    'four component-scope triggers');
  RAISE NOTICE 'ok   5 trigger function and triggers';
END $$;

-- 6. grants (b28e2660): ops_planner writes no ops table, keeps SELECT and its function EXECUTE; ops_executor unchanged
DO $$
DECLARE v_bad text;
        -- every ops table and view ops_planner could SELECT before 0015
        v_planner_reads text[] := ARRAY['backlog_blocks', 'backlog_items', 'components', 'context_documents', 'decision_nodes',
          'decisions', 'dispatch_costs', 'dispatch_nodes', 'dispatch_types', 'dispatches', 'doc_types', 'document_versions',
          'entry_types', 'finding_nodes', 'findings', 'gate_events', 'node_links', 'node_paths', 'nodes', 'path_log',
          'projects', 'protocol_changelog', 'protocol_rules', 'schema_migrations', 'session_docs', 'sessions', 'tick_daily',
          'ticks', 'window_state', 'windows', 'work_log', 'work_log_nodes'];
        v_planner_fns text[] := ARRAY['add_backlog_item', 'adopt_orphans', 'cancel_dispatch', 'close_session', 'create_component',
          'create_dispatch', 'create_project', 'log_decision', 'mark_reviewed', 'open_session', 'record_gate',
          'resolve_context', 'tick', 'update_backlog_item', 'window_link_event'];
        v_executor_reads text[] := ARRAY['components', 'context_documents', 'dispatch_types', 'doc_types', 'entry_types',
          'node_paths', 'nodes', 'projects', 'protocol_rules', 'window_state'];
        v_executor_fns text[] := ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'record_gate',
          'resolve_context', 'tick'];
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0023 drops adopt_orphans (M5b release 2): from 0023 on it is left out of the planner list and asserted absent
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 6 ops_planner EXECUTE on adopt_orphans (newest migration is %)', newest;
    PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                                       AND proname = 'adopt_orphans'), 'adopt_orphans absent');
    v_planner_fns := array_remove(v_planner_fns, 'adopt_orphans');
  END IF;
  -- 0028 grants ops_executor EXECUTE on get_work_log and log_work (work-log release): from 0028 on they join the set
  IF newest >= '0028' THEN
    RAISE NOTICE 'skip 6 executor EXECUTE set pre-0028 (newest is %)', newest;
    v_executor_fns := ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log',
      'log_work', 'record_gate', 'resolve_context', 'tick'];
  END IF;
  -- 0038 grants ops_executor EXECUTE on record_usage and usage_now (usage reader): from 0038 on they join the set
  IF newest >= '0038' THEN
    RAISE NOTICE 'skip 6 executor EXECUTE set pre-0038 (newest is %)', newest;
    v_executor_fns := ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log',
      'log_work', 'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now'];
  END IF;
  -- 0039 grants ops_executor EXECUTE on autorun_state (autorun gate): from 0039 on it joins the set
  IF newest >= '0039' THEN
    RAISE NOTICE 'skip 6 executor EXECUTE set pre-0039 (newest is %)', newest;
    v_executor_fns := ARRAY['autorun_state', 'claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending',
      'get_work_log', 'log_work', 'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now'];
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ' ORDER BY c.relname, p) INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  PERFORM pg_temp.check(v_bad IS NULL, 'ops_planner table writes left: ' || coalesce(v_bad, ''));
  SELECT string_agg(t, ', ') INTO v_bad FROM unnest(v_planner_reads) t
   WHERE to_regclass('ops.' || t) IS NULL OR NOT has_table_privilege('ops_planner', 'ops.' || t, 'SELECT');
  PERFORM pg_temp.check(v_bad IS NULL, 'ops_planner lost SELECT on: ' || coalesce(v_bad, ''));
  SELECT string_agg(f, ', ') INTO v_bad FROM unnest(v_planner_fns) f
   WHERE NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = f)
      OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = f
                    AND NOT has_function_privilege('ops_planner', oid, 'EXECUTE'));
  PERFORM pg_temp.check(v_bad IS NULL, 'ops_planner lost EXECUTE on: ' || coalesce(v_bad, ''));

  PERFORM pg_temp.check((SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                            AND has_table_privilege('ops_executor', c.oid, 'SELECT')) = v_executor_reads,
                        'ops_executor SELECT set unchanged');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
                                     WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                                       AND has_table_privilege('ops_executor', c.oid, p)), 'ops_executor writes no table');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = v_executor_fns, 'ops_executor EXECUTE set unchanged');
  RAISE NOTICE 'ok   6 grants: planner writes revoked, SELECT and EXECUTE kept; executor unchanged';
END $$;

-- 7. investigation execution rules: additive "queries" key (147e71ce)
DO $$
DECLARE r jsonb := (SELECT execution_rules FROM ops.dispatch_types WHERE type = 'investigation');
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0033 adds resolve_context to the queries text (writer release): from 0033 on the new text is asserted
  IF newest < '0033' THEN
  PERFORM pg_temp.check(r->>'queries' = 'executor queue tools only (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type); no other database queries',
                        'queries rule: ' || coalesce(r::text, 'NULL'));
  ELSE
    RAISE NOTICE 'skip 7 five-tool queries text (newest migration is %)', newest;
    PERFORM pg_temp.check(r->>'queries' = 'executor queue tools (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type) plus resolve_context for read-first context; no other database queries',
                          'queries rule (0033): ' || coalesce(r::text, 'NULL'));
  END IF;
  PERFORM pg_temp.check(r - 'queries' = '{"phases": ["read", "analyse", "report"], "writes": "none (report only)"}'::jsonb,
                        'phases and writes unchanged: ' || r::text);
  RAISE NOTICE 'ok   7 investigation queries rule';
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
  RAISE NOTICE 'ok   8 no leftover rows; 0015 tests passed';
END $$;
