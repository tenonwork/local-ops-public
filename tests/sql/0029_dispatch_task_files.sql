-- tests/sql/0029_dispatch_task_files.sql
-- Tests for migrations/0029_dispatch_task_files.sql. Run as the schema owner against a non-production database where
-- 0029 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0029_dispatch_task_files.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0029a, a component ca and a session through the
-- node-keyed writers, and asserts only on rows it creates (plus catalog state 0029 establishes and the rows that
-- existed before 0029 was applied).

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
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes)))::text,
    false);
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

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- a create on global.t0029a.ca with the test session (or p_session) and p_files as an SQL text[] expression,
-- as 'SQLSTATE message' or NULL on success
CREATE FUNCTION pg_temp.create_err(p_title text, p_files text, p_session uuid DEFAULT pg_temp.id('s')) RETURNS text
LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.create_dispatch(p_node_path => %L::public.ltree, p_dispatch_type => %L, '
                            'p_title => %L, p_prompt => %L, p_session => %L::uuid, p_task_files => %s::text[])',
                            'global.t0029a.ca', 'modification', p_title, 'p', p_session, p_files));
$$;

CREATE FUNCTION pg_temp.n(p_title text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id
   WHERE c.node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0029a.ca') AND d.title = p_title;
$$;

CREATE FUNCTION pg_temp.msg() RETURNS text LANGUAGE sql AS $$
  SELECT '23514 task_files must be an array of non-blank paths (use {} for none)';
$$;

-- 0. fixtures: project t0029a, component ca, a session on t0029a
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  p := ops.create_project('global'::public.ltree, 't0029a', 'T0029 A');
  c := ops.create_component('global.t0029a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0029a'::public.ltree,
                                                     p_kind => 'planning')::text, true);
  RAISE NOTICE 'ok   0 fixtures (t0029a/ca, session)';
END $$;

-- a. catalog 0029 establishes (bounded: asserted while 0029 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
        v_proc regprocedure := to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[])');
BEGIN
  IF NOT (newest >= '0029' AND newest < '0030') THEN
    RAISE NOTICE 'skip a catalog of 0029 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM pg_temp.check(to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)') IS NULL,
                        'the 7-argument create_dispatch is gone');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) =
                                  'p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text, '
                                  'p_context_refs text[] DEFAULT ''{}''::text[], p_priority integer DEFAULT 100, '
                                  'p_session uuid DEFAULT NULL::uuid, p_task_files text[] DEFAULT ''{}''::text[]'
                                AND prorettype = 'ops.dispatches'::regtype AND NOT proretset AND prosecdef
                                AND provolatile = 'v' AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner
                                AND proacl::text = format('{%1$s=X/%1$s,ops_planner=X/%1$s}', v_owner)
                           FROM pg_proc WHERE oid = v_proc),
                        'create_dispatch arguments, result, secdef, search_path, owner, ACL: '
                        || coalesce((SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE oid = v_proc), 'missing'));
  PERFORM pg_temp.check(obj_description(v_proc, 'pg_proc')
                        = 'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.',
                        'create_dispatch comment unchanged');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_dispatch') = 1,
                        'one create_dispatch overload');
  PERFORM pg_temp.check((SELECT strpos(prosrc, 'context_refs must be an array') < strpos(prosrc, 'work-log release (f66fda07)')
                                AND strpos(prosrc, 'work-log release (f66fda07)') < strpos(prosrc, 'FOREACH v_ref')
                                AND strpos(prosrc, 'priority, status, task_files)') > 0
                                AND strpos(prosrc, '''pending'', p_task_files)') > 0
                           FROM pg_proc WHERE oid = v_proc),
                        'task_files check after the context_refs check, column in the INSERT');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) LIKE 'CHECK (%array_position(task_files, NULL::text) IS NULL%'
                           FROM pg_constraint WHERE conrelid = 'ops.dispatches'::regclass AND conname = 'dispatches_task_files_clean'),
                        'dispatches_task_files_clean definition');
  RAISE NOTICE 'ok   a catalog: create_dispatch 8 arguments, result, security, search_path, owner, ACL, comment, body, one overload';
END $$;

-- b. the column: text[], NOT NULL, default '{}', CHECK; direct writes with a NULL or blank element are rejected
DO $$
DECLARE c ops.components := (SELECT c FROM ops.components c
                                WHERE node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0029a.ca'));
        e text;
        v_ins text := format('INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt, task_files) '
                             'VALUES (%L, %L, %L, %L, %L, %L, %%s)',
                             c.project_id, c.id, 'modification', pg_temp.id('s'), 't0029 b direct', 'p');
BEGIN
  PERFORM pg_temp.check((SELECT a.atttypid = 'text[]'::regtype AND a.attnotnull
                                AND pg_get_expr(d.adbin, d.adrelid) = '''{}''::text[]'
                           FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                          WHERE a.attrelid = 'ops.dispatches'::regclass AND a.attname = 'task_files'),
                        'b task_files text[] NOT NULL DEFAULT {}');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.dispatches'::regclass
                                   AND conname = 'dispatches_task_files_clean' AND contype = 'c' AND convalidated),
                        'b CHECK dispatches_task_files_clean present and validated');
  e := pg_temp.err(format(v_ins, 'ARRAY[''a.ts'', ''  '']'));
  PERFORM pg_temp.check(e LIKE '23514 %dispatches_task_files_clean%', 'b direct blank element: ' || coalesce(e, 'success'));
  e := pg_temp.err(format(v_ins, 'ARRAY[''''] '));
  PERFORM pg_temp.check(e LIKE '23514 %dispatches_task_files_clean%', 'b direct empty-string element: ' || coalesce(e, 'success'));
  e := pg_temp.err(format(v_ins, 'ARRAY[''a.ts'', NULL]'));
  PERFORM pg_temp.check(e LIKE '23514 %dispatches_task_files_clean%', 'b direct NULL element: ' || coalesce(e, 'success'));
  e := pg_temp.err(format(v_ins, 'NULL'));
  PERFORM pg_temp.check(e LIKE '23502 %task_files%', 'b direct NULL array: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('t0029 b direct') = 0, 'b no direct row written');
  RAISE NOTICE 'ok   b column text[] NOT NULL DEFAULT {}, CHECK rejects NULL / blank elements on direct insert';
END $$;

-- c. create_dispatch: default, stored value, refusals, duplicate guard, session first
DO $$
DECLARE r ops.dispatches; e text;
BEGIN
  r := ops.create_dispatch(p_node_path => 'global.t0029a.ca'::public.ltree, p_dispatch_type => 'modification',
                           p_title => 't0029 c default', p_prompt => 'p', p_session => pg_temp.id('s'));
  PERFORM pg_temp.check(r.task_files = '{}'::text[], 'c default task_files: ' || r.task_files::text);
  r := ops.create_dispatch(p_node_path => 'global.t0029a.ca'::public.ltree, p_dispatch_type => 'modification',
                           p_title => 't0029 c files', p_prompt => 'p', p_session => pg_temp.id('s'),
                           p_task_files => ARRAY['a/b.ts', 'c.sql']);
  PERFORM pg_temp.check((SELECT task_files FROM ops.dispatches WHERE id = r.id) = ARRAY['a/b.ts', 'c.sql'],
                        'c stored task_files');
  PERFORM set_config('ops_test.c', r.id::text, true);
  e := pg_temp.create_err('t0029 c refused', 'NULL');
  PERFORM pg_temp.check(e = pg_temp.msg(), 'c NULL array: ' || coalesce(e, 'success'));
  e := pg_temp.create_err('t0029 c refused', 'ARRAY[''a.ts'', NULL]');
  PERFORM pg_temp.check(e = pg_temp.msg(), 'c NULL element: ' || coalesce(e, 'success'));
  e := pg_temp.create_err('t0029 c refused', 'ARRAY[''a.ts'', ''  '']');
  PERFORM pg_temp.check(e = pg_temp.msg(), 'c blank element: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('t0029 c refused') = 0, 'c refused creates wrote nothing');
  e := pg_temp.create_err('t0029 c files', 'ARRAY[''x.ts'']');
  PERFORM pg_temp.check(e = '23514 duplicate of pending dispatch ' || left(pg_temp.id('c')::text, 8)
                            || ' on global.t0029a.ca: same title and prompt', 'c duplicate guard: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('t0029 c files') = 1, 'c duplicate not written');
  e := pg_temp.create_err('t0029 c refused', 'NULL', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'c session checked first: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   c default {}, stored value, three refusals 23514, duplicate guard, session first';
END $$;

-- d. old-style calls resolve to the one function (no 42725)
DO $$
DECLARE e text; r ops.dispatches;
BEGIN
  r := ops.create_dispatch('global.t0029a.ca'::public.ltree, 'modification', 't0029 d positional', 'p', '{}'::text[], 100,
                           pg_temp.id('s'));
  PERFORM pg_temp.check(r.task_files = '{}'::text[] AND pg_temp.n('t0029 d positional') = 1, 'd 7 positional typed');
  e := pg_temp.err(format($q$SELECT ops.create_dispatch('global.t0029a.ca', 'modification', 't0029 d unknown', 'p', '{}', 100, %L)$q$,
                          pg_temp.id('s')));
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('t0029 d unknown') = 1, 'd 7 unknown literals: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.create_dispatch('global.t0029a.ca', 'modification', 't0029 d six', 'p', '{}', 100)$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'd 6 unknown literals: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   d 7-positional (typed and unknown) and 6-unknown-literal calls resolve, no 42725';
END $$;

-- e. ACL: ops_planner only
DO $$
DECLARE v_proc regprocedure := to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[])');
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_planner', v_proc, 'EXECUTE')
                        AND NOT has_function_privilege('ops_executor', v_proc, 'EXECUTE')
                        AND NOT has_function_privilege('public', v_proc, 'EXECUTE'),
                        'create_dispatch EXECUTE: planner only');
  PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', 'ops.dispatches', 'SELECT, INSERT, UPDATE, DELETE')
                        AND has_table_privilege('ops_planner', 'ops.dispatches', 'SELECT'),
                        'dispatches table: planner SELECT, executor none');
  RAISE NOTICE 'ok   e create_dispatch EXECUTE planner only; executor has no table privilege';
END $$;

-- f. rows created before 0029 was applied all have task_files '{}'; no row outside t0029a was added
DO $$
DECLARE v_applied timestamptz := (SELECT applied_at FROM ops.schema_migrations WHERE version = '0029_dispatch_task_files');
BEGIN
  PERFORM pg_temp.check(v_applied IS NOT NULL, 'f 0029 in the ledger');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.dispatches WHERE created_at < v_applied AND task_files <> '{}'),
                        'f pre-0029 rows keep task_files {}');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id
                          WHERE c.node_id IS DISTINCT FROM (SELECT id FROM ops.nodes WHERE path::text = 'global.t0029a.ca'))
                        = (current_setting('ops_test.counts_before')::jsonb->>'dispatches')::bigint,
                        'f dispatch count outside t0029a unchanged');
  RAISE NOTICE 'ok   f pre-existing dispatches keep task_files {}, count unchanged';
END $$;

ROLLBACK;

-- g. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   g no leftover rows; 0029 tests passed';
END $$;
