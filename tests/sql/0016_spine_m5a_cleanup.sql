-- tests/sql/0016_spine_m5a_cleanup.sql
-- Tests for migrations/0016_spine_m5a_cleanup.sql. Run as the schema owner against a non-production database
-- where 0016 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0016_spine_m5a_cleanup.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own projects t0016a / t0016b (through create_project / create_component,
-- so their nodes sit under their project nodes, never on the global node), asserts only on rows it creates, and
-- counts relative to the starting state.
-- Grants are checked at catalog level: the tests connect as ops_dev, which is not a member of ops_planner.

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

-- the dispatch carries the block 0 fixture session of t0016a, the only project the file's dispatches name
-- (session_id NOT NULL from 0022)
CREATE FUNCTION pg_temp.dispatch(p_project uuid, p_component uuid) RETURNS text LANGUAGE sql AS $$
  SELECT format($q$INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
                   VALUES (%L, %L, 'investigation', %L, 't0016', 'p')$q$, p_project, p_component, pg_temp.id('s_pa'));
$$;

-- 0. fixtures: two projects with a component each, and a component with no project
DO $$
DECLARE p ops.projects; c ops.components; v_id uuid;
BEGIN
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0016a', p_name => 'T0016 A');
  PERFORM set_config('ops_test.pa', p.id::text, true), set_config('ops_test.pa_node', p.node_id::text, true);
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0016b', p_name => 'T0016 B');
  PERFORM set_config('ops_test.pb', p.id::text, true);
  c := ops.create_component(p_parent_path => 'global.t0016a'::public.ltree, p_key => 'ca', p_kind => 'service', p_verify_cmd => 'npm test');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  c := ops.create_component(p_parent_path => 'global.t0016b'::public.ltree, p_key => 'cb', p_kind => 'service', p_verify_cmd => 'npm test');
  PERFORM set_config('ops_test.cb', c.id::text, true);
  INSERT INTO ops.components (project_id, key, kind) VALUES (NULL, 't0016-orphan', 'service') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.cn', v_id::text, true);
  -- a session in t0016a for the file's decisions and dispatches
  INSERT INTO ops.sessions (project_id, kind) VALUES (pg_temp.id('pa'), 'planning') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.s_pa', v_id::text, true);
  PERFORM pg_temp.check((SELECT path::text FROM ops.nodes WHERE id = pg_temp.id('pa_node')) = 'global.t0016a',
                        'project node directly under global');
  RAISE NOTICE 'ok   0 fixtures (t0016a/ca, t0016b/cb, project-less component)';
END $$;

-- 1. catalog: composite FKs and backing key gone, single-column FKs kept, index dropped, five triggers
DO $$
DECLARE f oid := to_regprocedure('ops._component_scope()'); v_bad text;
BEGIN
  SELECT string_agg(x, ', ') INTO v_bad
    FROM unnest(ARRAY['sessions_component_id_project_id_fkey', 'decisions_component_id_project_id_fkey',
                      'dispatches_component_id_project_id_fkey', 'context_documents_component_id_project_id_fkey',
                      'backlog_items_component_id_project_id_fkey', 'components_id_project_id_key']) x
   WHERE EXISTS (SELECT 1 FROM pg_constraint WHERE connamespace = 'ops'::regnamespace AND conname = x);
  PERFORM pg_temp.check(v_bad IS NULL, 'constraints still present: ' || coalesce(v_bad, ''));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_constraint WHERE connamespace = 'ops'::regnamespace
                                     AND contype = 'f' AND confrelid = 'ops.components'::regclass AND cardinality(conkey) > 1),
                        'no multi-column FK references ops.components');

  SELECT string_agg(t, ', ') INTO v_bad
    FROM unnest(ARRAY['sessions', 'decisions', 'dispatches', 'context_documents', 'backlog_items']) t
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = t || '_project_id_fkey' AND conrelid = ('ops.' || t)::regclass
                        AND contype = 'f' AND confrelid = 'ops.projects'::regclass
                        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                             WHERE attrelid = ('ops.' || t)::regclass AND attname = 'project_id')]);
  PERFORM pg_temp.check(v_bad IS NULL, 'single-column project_id FK missing on: ' || coalesce(v_bad, ''));
  SELECT string_agg(t, ', ') INTO v_bad
    FROM unnest(ARRAY['sessions', 'decisions', 'dispatches', 'context_documents', 'backlog_items']) t
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = t || '_component_id_fkey' AND conrelid = ('ops.' || t)::regclass
                        AND contype = 'f' AND confrelid = 'ops.components'::regclass
                        AND confdeltype = 'a' AND confupdtype = 'a' AND convalidated
                        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                             WHERE attrelid = ('ops.' || t)::regclass AND attname = 'component_id')]);
  PERFORM pg_temp.check(v_bad IS NULL, 'single-column component_id FK (no action) missing on: ' || coalesce(v_bad, ''));
  -- 0023 drops components UNIQUE (project_id, key) and adds UNIQUE (node_id) (M5b release 2)
  IF (SELECT max(version) FROM ops.schema_migrations) >= '0023' THEN
    RAISE NOTICE 'skip 1 components UNIQUE (project_id, key) kept (newest migration is %)',
      (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_constraint
                                       WHERE conname = 'components_project_id_key_key' AND conrelid = 'ops.components'::regclass),
                          'components UNIQUE (project_id, key) absent');
    PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.components'::regclass AND contype = 'u'
                                    AND pg_get_constraintdef(oid) = 'UNIQUE (node_id)'), 'components UNIQUE (node_id) present');
  ELSE
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) FROM pg_constraint
                          WHERE conname = 'components_project_id_key_key' AND conrelid = 'ops.components'::regclass)
                        = 'UNIQUE (project_id, key)', 'components UNIQUE (project_id, key) kept');
  END IF;

  PERFORM pg_temp.check(to_regclass('ops.context_documents_node_idx') IS NULL, 'context_documents_node_idx dropped');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) FROM pg_constraint
                          WHERE conname = 'context_documents_node_id_doc_type_key')
                        = 'UNIQUE (node_id, doc_type)', 'context_documents_node_id_doc_type_key kept');

  PERFORM pg_temp.check(-- definitions without the schema prefix, which pg_get_triggerdef omits under search_path = ops
                         (SELECT array_agg(replace(pg_get_triggerdef(oid), ' ops.', ' ') ORDER BY tgname) FROM pg_trigger
                          WHERE tgfoid = f AND NOT tgisinternal)
    = ARRAY[
      'CREATE TRIGGER backlog_items_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id, home_node_id ON backlog_items FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER context_documents_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id, node_id ON context_documents FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER decisions_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id ON decisions FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER dispatches_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id ON dispatches FOR EACH ROW EXECUTE FUNCTION _component_scope()',
      'CREATE TRIGGER sessions_component_scope BEFORE INSERT OR UPDATE OF component_id, project_id ON sessions FOR EACH ROW EXECUTE FUNCTION _component_scope()'],
    'five component-scope triggers (four from 0015 unchanged, dispatches added)');
  PERFORM pg_temp.check((SELECT obj_description(oid, 'pg_trigger') LIKE '%011b32a8%' FROM pg_trigger
                          WHERE tgname = 'dispatches_component_scope'), 'trigger comment names backlog 011b32a8');
  RAISE NOTICE 'ok   1 catalog: composite FKs and backing key dropped, project FKs kept, node_idx dropped, five triggers';
END $$;

-- 2. dispatches under the trigger; one other table still refuses a foreign component without its FK
DO $$
DECLARE v_id uuid;
        v_pa uuid := pg_temp.id('pa'); v_ca uuid := pg_temp.id('ca'); v_cb uuid := pg_temp.id('cb'); v_cn uuid := pg_temp.id('cn');
BEGIN
  PERFORM pg_temp.rejects(pg_temp.dispatch(v_pa, v_cb), '23514',
                          format('component %s does not belong to project %s (dispatches)', v_cb, v_pa),
                          'dispatch: component of another project');
  PERFORM pg_temp.rejects(pg_temp.dispatch(v_pa, v_cn), '23514',
                          format('component %s does not belong to project %s (dispatches)', v_cn, v_pa),
                          'dispatch: component with project_id NULL');
  PERFORM pg_temp.rejects(pg_temp.dispatch(v_pa, gen_random_uuid()), '23514', 'does not exist (dispatches)',
                          'dispatch: unknown component');
  v_id := pg_temp.ins_id(pg_temp.dispatch(v_pa, v_ca), 'dispatch: matching project accepted');
  PERFORM pg_temp.rejects(format('UPDATE ops.dispatches SET component_id = %L WHERE id = %L', v_cb, v_id), '23514',
                          'does not belong to project', 'dispatch: UPDATE to a component of another project');
  PERFORM pg_temp.rejects(format('UPDATE ops.dispatches SET project_id = %L WHERE id = %L', pg_temp.id('pb'), v_id), '23514',
                          'does not belong to project', 'dispatch: UPDATE of project_id away from the component');
  PERFORM pg_temp.check((SELECT (project_id, component_id) = (v_pa, v_ca) FROM ops.dispatches WHERE id = v_id),
                        'refused updates left the dispatch unchanged');

  -- decisions: the composite FK is gone, the trigger still refuses
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.decisions (project_id, component_id, session_id, decision) VALUES (%L, %L, %L, 't0016')$q$,
                                 v_pa, v_cb, pg_temp.id('s_pa')), '23514',
                          format('component %s does not belong to project %s (decisions)', v_cb, v_pa),
                          'decision: component of another project');
  RAISE NOTICE 'ok   2 dispatches component scope (insert and update); decisions still refused without the FK';
END $$;

-- 2a. component_id FKs: a referenced component cannot be deleted or re-keyed. Each table gets its own fresh
-- component with no node (so nodes_component_id_fkey cannot fire, and the trigger's node rule does not apply) and
-- exactly one referencing row, so the violated constraint must be that table's <table>_component_id_fkey.
CREATE FUNCTION pg_temp.fk_case(p_sql text, p_fk text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text; v_con text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_con = CONSTRAINT_NAME;
  END;
  PERFORM pg_temp.check(v_state = '23503' AND v_con = p_fk,
                        format('%s: expected 23503 on %s, got %s on %s', p_what, p_fk,
                               coalesce(v_state, 'success'), coalesce(v_con, '-')));
END $$;

DO $$
DECLARE t text; v_c uuid; v_sql text; v_pa uuid := pg_temp.id('pa'); v_pa_node uuid := pg_temp.id('pa_node');
BEGIN
  FOREACH t IN ARRAY ARRAY['sessions', 'decisions', 'dispatches', 'context_documents', 'backlog_items'] LOOP
    INSERT INTO ops.components (project_id, key, kind) VALUES (v_pa, 'fk-' || replace(t, '_', '-'), 'service')
    RETURNING id INTO v_c;
    v_sql := CASE t
      WHEN 'sessions' THEN format($q$INSERT INTO ops.sessions (project_id, component_id, kind) VALUES (%L, %L, 'planning')$q$, v_pa, v_c)
      WHEN 'decisions' THEN format($q$INSERT INTO ops.decisions (project_id, component_id, session_id, decision) VALUES (%L, %L, %L, 't0016')$q$,
                                   v_pa, v_c, pg_temp.id('s_pa'))
      WHEN 'dispatches' THEN pg_temp.dispatch(v_pa, v_c)
      WHEN 'context_documents' THEN format(
        $q$INSERT INTO ops.context_documents (project_id, component_id, doc_key, title, content, node_id, doc_type)
           VALUES (%L, %L, 'T0016_FK', 't0016', 'c', %L, 'manual')$q$, v_pa, v_c, v_pa_node)
      WHEN 'backlog_items' THEN format(
        $q$INSERT INTO ops.backlog_items (project_id, component_id, title, kind, home_node_id)
           VALUES (%L, %L, 't0016', 'task', %L)$q$, v_pa, v_c, v_pa_node)
    END;
    PERFORM pg_temp.ins_id(v_sql, t || ': referencing row');
    PERFORM pg_temp.fk_case(format('DELETE FROM ops.components WHERE id = %L', v_c), t || '_component_id_fkey',
                            t || ': DELETE of the referenced component');
    PERFORM pg_temp.fk_case(format('UPDATE ops.components SET id = gen_random_uuid() WHERE id = %L', v_c),
                            t || '_component_id_fkey', t || ': UPDATE of the referenced component id');
    PERFORM pg_temp.check(EXISTS (SELECT 1 FROM ops.components WHERE id = v_c), t || ': component still there');
  END LOOP;
  RAISE NOTICE 'ok  2a component_id FKs refuse DELETE and re-key of a referenced component on all five tables';
END $$;

-- 3. update_backlog_item p_severity
DO $$
DECLARE b ops.backlog_items; b0 ops.backlog_items;
BEGIN
  b0 := ops.add_backlog_item(p_node_path => 'global.t0016a.ca'::public.ltree, p_kind => 'task', p_title => 't0016 item',
                             p_detail => 'detail', p_severity => 'low');
  b := ops.update_backlog_item(b0.id, b0.status, p_severity => 'high');
  PERFORM pg_temp.check(b.severity = 'high' AND b.status = b0.status AND b.detail = b0.detail
                        AND b.closed_at IS NOT DISTINCT FROM b0.closed_at, 'severity only: ' || to_jsonb(b)::text);
  b := ops.update_backlog_item(p_id => b0.id, p_status => 'done', p_detail => 'closed');
  PERFORM pg_temp.check(b.severity = 'high' AND b.status = 'done' AND b.closed_at = now() AND b.detail = 'closed',
                        'p_severity omitted keeps severity: ' || to_jsonb(b)::text);
  b := ops.update_backlog_item(b0.id, 'open');
  PERFORM pg_temp.check(b.status = 'open' AND b.closed_at IS NULL AND b.severity = 'high' AND b.detail = 'closed',
                        'positional 2-argument call');
  b := ops.update_backlog_item(b0.id, 'dropped', 'gone');
  PERFORM pg_temp.check(b.status = 'dropped' AND b.closed_at = now() AND b.severity = 'high' AND b.detail = 'gone',
                        'positional 3-argument call');
  b := ops.update_backlog_item(b0.id, 'open', NULL, 'low');
  PERFORM pg_temp.check(b.status = 'open' AND b.severity = 'low' AND b.detail = 'gone', 'positional 4-argument call');
  PERFORM pg_temp.rejects(format($q$SELECT ops.update_backlog_item(%L, 'closed', NULL, 'high')$q$, b0.id), '23514',
                          'invalid backlog status "closed"', 'invalid status');
  PERFORM pg_temp.check((SELECT severity FROM ops.backlog_items WHERE id = b0.id) = 'low', 'refused call left severity');
  RAISE NOTICE 'ok   3 update_backlog_item severity, omitted severity, positional calls, invalid status';
END $$;

-- 4. security of the re-created update_backlog_item
DO $$
DECLARE f regprocedure := to_regprocedure('ops.update_backlog_item(uuid,text,text,ops.backlog_severity)');
BEGIN
  PERFORM pg_temp.check(f IS NOT NULL, 'new signature exists');
  PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] FROM pg_proc WHERE oid = f),
                        'SECURITY DEFINER with search_path = ops, pg_temp');
  PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'ops_planner executes');
  PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f, 'EXECUTE'), 'ops_executor does not execute');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'PUBLIC does not execute');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                          AND proname = 'update_backlog_item') = 1, 'exactly one overload');
  PERFORM pg_temp.check(obj_description(f, 'pg_proc') LIKE '%p_severity%', 'comment names p_severity');
  RAISE NOTICE 'ok   4 update_backlog_item security, grants, one overload';
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
  RAISE NOTICE 'ok   5 no leftover rows; 0016 tests passed';
END $$;
