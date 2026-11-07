-- tests/sql/0021_drop_project_keyed_functions.sql
-- Tests for migrations/0021_drop_project_keyed_functions.sql. Run as the schema owner against a non-production
-- database where 0021 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0021_drop_project_keyed_functions.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0021a (through the node-keyed create_project /
-- create_component), asserts only on rows it creates and counts relative to the starting state.
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

-- asserts p_sql does not raise 42725 (ambiguous function): it succeeds or raises another error
CREATE FUNCTION pg_temp.not_ambiguous(p_sql text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  PERFORM pg_temp.check(e IS NULL OR e NOT LIKE '42725 %', p_what || ': ' || coalesce(e, 'success'));
  RAISE NOTICE '     % -> %', p_what, coalesce(e, 'success');
END $$;

-- 1. the ten project-keyed signatures are gone; each name has exactly one overload, its first parameter public.ltree
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[
      'ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
      'ops.get_pending(text,text)',
      'ops.get_unreviewed_reports(text)',
      'ops.resolve_context(text,text)',
      'ops.create_project(text,text,jsonb)',
      'ops.create_component(text,text,text,text,text,jsonb)',
      'ops.create_dispatch(text,text,text,text,text,text[],integer,uuid)',
      'ops.log_decision(text,text,text,text,jsonb,text,text,uuid,uuid)',
      'ops.add_backlog_item(text,ops.backlog_kind,text,text,text,uuid,ops.backlog_severity)',
      'ops._component(text,text)']) s
   WHERE to_regprocedure(s) IS NOT NULL;
  PERFORM pg_temp.check(v_bad IS NULL, 'project-keyed signatures present: ' || coalesce(v_bad, ''));
  SELECT string_agg(n || ' ' || coalesce(x.sigs, 'none'), '; ') INTO v_bad
    FROM unnest(ARRAY['open_session', 'get_pending', 'get_unreviewed_reports', 'resolve_context', 'create_project',
                      'create_component', 'create_dispatch', 'log_decision', 'add_backlog_item', '_component']) n
    LEFT JOIN LATERAL (
      SELECT count(*) AS overloads, bool_and(p.proargtypes[0] = 'public.ltree'::regtype) AS ltree_first,
             string_agg(p.oid::regprocedure::text, ', ') AS sigs
        FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = n) x ON true
   WHERE coalesce(x.overloads, 0) <> 1 OR NOT coalesce(x.ltree_first, false);
  PERFORM pg_temp.check(v_bad IS NULL, 'names without exactly one node-keyed overload: ' || coalesce(v_bad, ''));
  RAISE NOTICE 'ok   1 ten project-keyed signatures absent; one node-keyed overload per name';
END $$;

-- 2. per-name EXECUTE unchanged: planner a, c-i / executor b, d (0018 step 4); _component neither; PUBLIC none
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT * FROM (VALUES
      ('open_session', true, false), ('get_pending', false, true), ('get_unreviewed_reports', true, false),
      ('resolve_context', true, true), ('create_project', true, false), ('create_component', true, false),
      ('create_dispatch', true, false), ('log_decision', true, false), ('add_backlog_item', true, false),
      ('_component', false, false)) AS t(name, planner, executor) LOOP
    PERFORM pg_temp.check(
      (SELECT bool_and(has_function_privilege('ops_planner', p.oid, 'EXECUTE') = f.planner
                       AND has_function_privilege('ops_executor', p.oid, 'EXECUTE') = f.executor
                       AND NOT has_function_privilege('public', p.oid, 'EXECUTE'))
         FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = f.name),
      format('EXECUTE on %s: planner %s, executor %s, PUBLIC none', f.name, f.planner, f.executor));
  END LOOP;
  RAISE NOTICE 'ok   2 per-name EXECUTE for ops_planner / ops_executor / PUBLIC unchanged';
END $$;

-- fixtures: a project and a component through the node-keyed writers
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0021a', p_name => 'T0021 A');
  c := ops.create_component(p_parent_path => 'global.t0021a'::public.ltree, p_key => 'ca', p_kind => 'service',
                            p_verify_cmd => 'npm test');
  -- the dispatch and decision carry a session of their own (required from 0022)
  PERFORM set_config('ops_test.session',
    ops.open_session(p_node_path => 'global.t0021a'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.dispatch',
    (ops.create_dispatch(p_node_path => 'global.t0021a.ca'::public.ltree, p_dispatch_type => 'investigation',
                         p_title => 't0021', p_prompt => 'p',
                         p_session => current_setting('ops_test.session')::uuid)).id::text, true);
  PERFORM set_config('ops_test.decision',
    (ops.log_decision(p_node_path => 'global.t0021a'::public.ltree, p_decision => 't0021',
                      p_session => current_setting('ops_test.session')::uuid)).id::text, true);
END $$;

-- 3. the five 0018 block-10 positional shapes no longer raise 42725 (they resolve to the node-keyed version)
DO $$ BEGIN
  PERFORM pg_temp.not_ambiguous($q$SELECT ops.create_project('global', 't0021amb', '{"x": 1}')$q$,
                                'create_project 3 unknown literals');
  PERFORM pg_temp.not_ambiguous($q$SELECT ops.open_session('global.t0021a', 'planning', 'global', NULL)$q$,
                                'open_session 4 unknown literals with a scope');
  PERFORM pg_temp.not_ambiguous(format($q$SELECT ops.log_decision('global.t0021a', 'x', NULL, '[]', NULL, NULL, %L, NULL)$q$,
                                       current_setting('ops_test.decision')), 'log_decision 8 unknown literals');
  PERFORM pg_temp.not_ambiguous(format($q$SELECT ops.add_backlog_item('global.t0021a', 'task', 'x', NULL, %L, 'low')$q$,
                                       current_setting('ops_test.dispatch')), 'add_backlog_item 6 unknown literals');
  PERFORM pg_temp.not_ambiguous($q$SELECT ops.create_dispatch('global.t0021a.ca', 'investigation', 't', 'p', '{}', 100)$q$,
                                'create_dispatch 6 unknown literals');
  RAISE NOTICE 'ok   3 five positional unknown-literal shapes no longer raise 42725';
END $$;

-- 4. untyped $n parameters (as node-postgres sends them) resolve to the node-keyed parameter types
PREPARE t0021_pending AS SELECT id FROM ops.get_pending($1);
PREPARE t0021_unreviewed AS SELECT id FROM ops.get_unreviewed_reports($1);
PREPARE t0021_resolve AS SELECT ops.resolve_context($1, $2) AS content;
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT parameter_types FROM pg_prepared_statements WHERE name = 't0021_pending')
                        = ARRAY['public.ltree'::regtype], 'get_pending($1) -> ltree');
  PERFORM pg_temp.check((SELECT parameter_types FROM pg_prepared_statements WHERE name = 't0021_unreviewed')
                        = ARRAY['public.ltree'::regtype], 'get_unreviewed_reports($1) -> ltree');
  PERFORM pg_temp.check((SELECT parameter_types FROM pg_prepared_statements WHERE name = 't0021_resolve')
                        = ARRAY['public.ltree'::regtype, 'text'::regtype], 'resolve_context($1, $2) -> ltree, text');
  RAISE NOTICE 'ok   4 untyped $n parameters resolve to the node-keyed functions';
END $$;
DEALLOCATE t0021_pending;
DEALLOCATE t0021_unreviewed;
DEALLOCATE t0021_resolve;

ROLLBACK;

-- 5. no leftover rows
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
  RAISE NOTICE 'ok   5 no leftover rows; 0021 tests passed';
END $$;
