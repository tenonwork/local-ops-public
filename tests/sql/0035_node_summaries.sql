-- tests/sql/0035_node_summaries.sql
-- Tests for migrations/0035_node_summaries.sql. Run as the schema owner against a non-production database
-- where 0035 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0035_node_summaries.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own projects global.t0035a (component ca, archived node old) and
-- global.t0035b, and global.t0035c / global.t0035d for the positional calls, a session on each project and one on
-- ca, and asserts only on rows it creates; block f reads the three framework nodes only when they are present.
-- Grants are checked at catalog level (b28e2660): ops_dev is not a member of ops_planner.

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
    'nodes', (SELECT count(*) FROM ops.nodes), 'projects', (SELECT count(*) FROM ops.projects),
    'components', (SELECT count(*) FROM ops.components), 'sessions', (SELECT count(*) FROM ops.sessions),
    'summaries', (SELECT md5(string_agg(id::text || coalesce(summary, '-') || coalesce(summary_updated_at::text, '-')
                                        || coalesce(summary_session_id::text, '-'), '|' ORDER BY id)) FROM ops.nodes)))::text, false);
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

-- summary / stamp state of a node: 'summary|time is now()|session' with '-' for NULL
CREATE FUNCTION pg_temp.state(p_path text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(summary, '-') || '|' || coalesce((summary_updated_at = now())::text, '-') || '|'
         || coalesce(summary_session_id::text, '-')
    FROM ops.nodes WHERE path::text = p_path;
$$;

-- set_node_summary through pg_temp.err with p_summary as an SQL expression and the session a setting name or NULL
CREATE FUNCTION pg_temp.set_err(p_path text, p_summary_sql text, p_session text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT * FROM ops.set_node_summary(%L::public.ltree, %s, %s)', p_path, p_summary_sql,
                            coalesce(quote_literal(current_setting('ops_test.' || p_session, true)) || '::uuid', 'NULL')));
$$;

-- 0. fixtures
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0035a', p_name => 'T0035 A');
  c := ops.create_component(p_parent_path => 'global.t0035a'::public.ltree, p_key => 'ca', p_kind => 'service');
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0035b', p_name => 'T0035 B');
  INSERT INTO ops.nodes (parent_id, key, kind, title, status)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0035a'), 'old', 'node', 'T0035 archived', 'archived');
  PERFORM set_config('ops_test.sa', ops.open_session(p_node_path => 'global.t0035a'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.sca', ops.open_session(p_node_path => 'global.t0035a.ca'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.sb', ops.open_session(p_node_path => 'global.t0035b'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.snone', gen_random_uuid()::text, true);
  RAISE NOTICE 'ok   0 fixtures (global.t0035a/ca/old, global.t0035b, sessions)';
END $$;

-- a. catalog 0035 establishes (bounded: asserted while 0035 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text; f record;
BEGIN
  IF NOT (newest >= '0035' AND newest < '0036') THEN
    RAISE NOTICE 'skip a catalog of 0035 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  -- catalog text is rendered with schema-qualified names: no ops on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);

  -- columns and constraints
  PERFORM pg_temp.check((SELECT string_agg(attname || ' ' || format_type(atttypid, atttypmod)
                                           || CASE WHEN attnotnull THEN ' not null' ELSE '' END, ', ' ORDER BY attnum)
                           FROM pg_attribute WHERE attrelid = 'ops.nodes'::regclass AND attnum > 0 AND NOT attisdropped)
                        = 'id uuid not null, parent_id uuid, key text not null, path public.ltree not null, kind ops.node_kind not null, title text not null, summary text, component_id uuid, status ops.node_status not null, created_at timestamp with time zone not null, summary_updated_at timestamp with time zone, summary_session_id uuid',
                        'a nodes columns: summary nullable, summary_updated_at and summary_session_id added, nullable');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) FROM pg_constraint
                          WHERE conrelid = 'ops.nodes'::regclass AND conname = 'nodes_summary_shape')
                        = 'CHECK (((summary IS NULL) OR ((btrim(summary) <> ''''::text) AND (summary !~ ''[\r\n]''::text) AND (char_length(summary) <= 200))))',
                        'a nodes_summary_shape');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) FROM pg_constraint
                          WHERE conrelid = 'ops.nodes'::regclass AND conname = 'nodes_summary_stamp')
                        = 'CHECK (((summary_session_id IS NULL) OR (summary_updated_at IS NOT NULL)))', 'a nodes_summary_stamp');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.nodes'::regclass AND contype = 'f'
                                  AND pg_get_constraintdef(oid) = 'FOREIGN KEY (summary_session_id) REFERENCES ops.sessions(id)'),
                        'a summary_session_id references ops.sessions');

  -- functions
  FOR f IN SELECT * FROM (VALUES
      ('create_project', 'ops.create_project(public.ltree,text,text,jsonb,text)',
       'p_parent_path public.ltree, p_key text, p_name text, p_params jsonb DEFAULT ''{}''::jsonb, p_summary text DEFAULT NULL::text',
       'ops.projects',
       'Node summary release (dd73af1f): node-keyed create_project; the parent must be the global node.'),
      ('create_component', 'ops.create_component(public.ltree,text,text,text,text,jsonb,text)',
       'p_parent_path public.ltree, p_key text, p_kind text, p_repo_ref text DEFAULT NULL::text, p_verify_cmd text DEFAULT NULL::text, p_params jsonb DEFAULT ''{}''::jsonb, p_summary text DEFAULT NULL::text',
       'ops.components',
       'Node summary release (dd73af1f): node-keyed create_component; the parent is a project node or a plain node outside any component (not the global node); project_id from the depth-2 ancestor, else NULL; duplicate = a node with that key under the parent.'),
      ('set_node_summary', 'ops.set_node_summary(public.ltree,text,uuid)',
       'p_node_path public.ltree, p_summary text, p_session uuid',
       'TABLE(node_path public.ltree, summary text, summary_updated_at timestamp with time zone, summary_session_id uuid)',
       'Node summary release (dd73af1f): planner writer for nodes.summary; stamps time and session.')
    ) AS t(name, sig, args, result, cmt) LOOP
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = f.name) = 1,
                          'a one overload of ' || f.name);
    PERFORM pg_temp.check(to_regprocedure(f.sig) IS NOT NULL, 'a exists ' || f.sig);
    PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = f.args AND pg_get_function_result(oid) = f.result
                             FROM pg_proc WHERE oid = to_regprocedure(f.sig)), 'a arguments, defaults and result of ' || f.name);
    PERFORM pg_temp.check((SELECT provolatile = 'v' AND prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                                  AND pg_get_userbyid(proowner) = v_owner AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
                             FROM pg_proc WHERE oid = to_regprocedure(f.sig)),
                          'a VOLATILE, plpgsql, SECURITY DEFINER, search_path, owner of ' || f.name);
    PERFORM pg_temp.check(obj_description(to_regprocedure(f.sig), 'pg_proc') = f.cmt, 'a comment of ' || f.name);
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                             FROM pg_proc p, aclexplode(p.proacl) a
                            WHERE p.oid = to_regprocedure(f.sig) AND a.grantee <> p.proowner)
                          = ARRAY['ops_planner'], 'a ACL owner plus ops_planner on ' || f.name);
  END LOOP;
  RAISE NOTICE 'ok   a catalog: nodes columns and constraints; create_project, create_component, set_node_summary signatures, VOLATILE, definer, ACL, comments, one overload each';
END $$;

-- b. grants (always asserted): planner executes the three; executor and PUBLIC get nothing
DO $$
DECLARE v_bad text; f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['ops.create_project(public.ltree,text,text,jsonb,text)',
                           'ops.create_component(public.ltree,text,text,text,text,jsonb,text)',
                           'ops.set_node_summary(public.ltree,text,uuid)'] LOOP
    PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'b planner EXECUTE on ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f, 'EXECUTE'), 'b executor no EXECUTE on ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'b PUBLIC no EXECUTE on ' || f);
  END LOOP;
  PERFORM pg_temp.check((SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                            AND has_table_privilege('ops_executor', c.oid, 'SELECT'))
                        = ARRAY['components', 'context_documents', 'dispatch_types', 'doc_types', 'entry_types', 'node_paths',
                                'nodes', 'projects', 'protocol_rules', 'window_state'], 'b ops_executor SELECT set unchanged');
  -- 0038 grants ops_executor EXECUTE on record_usage and usage_now (usage reader): from 0038 on they join the set
  IF (SELECT max(version) FROM ops.schema_migrations) < '0038' THEN
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log', 'log_work',
                                'record_gate', 'resolve_context', 'tick'], 'b ops_executor EXECUTE set unchanged');
  ELSIF (SELECT max(version) FROM ops.schema_migrations) < '0039' THEN
    RAISE NOTICE 'skip b executor EXECUTE set pre-0038 (newest migration is %)', (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                            WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                          = ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log', 'log_work',
                                  'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now'],
                          'b ops_executor EXECUTE set (0038)');
  -- 0039 grants ops_executor EXECUTE on autorun_state (autorun gate): from 0039 on it joins the set
  ELSE
    RAISE NOTICE 'skip b executor EXECUTE set pre-0039 (newest migration is %)', (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                            WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                          = ARRAY['autorun_state', 'claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending',
                                  'get_work_log', 'log_work', 'record_gate', 'record_usage', 'resolve_context', 'tick',
                                  'usage_now'],
                          'b ops_executor EXECUTE set (0039)');
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  PERFORM pg_temp.check(v_bad IS NULL, 'b no table writes for ops_planner: ' || coalesce(v_bad, ''));
  RAISE NOTICE 'ok   b grants: planner EXECUTE on the three; executor and PUBLIC none; executor sets unchanged; no planner table writes';
END $$;

-- c. create_project / create_component: p_summary stored and time-stamped (no session); absent -> NULLs; old calls hold
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0035c', p_name => 'T0035 C',
                          p_summary => 'T0035 project summary.');
  PERFORM pg_temp.check(pg_temp.state('global.t0035c') = 'T0035 project summary.|true|-',
                        'c create_project with p_summary: ' || coalesce(pg_temp.state('global.t0035c'), 'no node'));
  c := ops.create_component(p_parent_path => 'global.t0035c'::public.ltree, p_key => 'cc', p_kind => 'service',
                            p_summary => 'T0035 component summary.');
  PERFORM pg_temp.check(pg_temp.state('global.t0035c.cc') = 'T0035 component summary.|true|-'
                        AND (SELECT component_id = c.id FROM ops.nodes WHERE path::text = 'global.t0035c.cc'),
                        'c create_component with p_summary: ' || coalesce(pg_temp.state('global.t0035c.cc'), 'no node'));
  -- fixtures from block 0 were created without p_summary
  PERFORM pg_temp.check(pg_temp.state('global.t0035a') = '-|-|-' AND pg_temp.state('global.t0035a.ca') = '-|-|-',
                        'c without p_summary: summary and stamps NULL');
  -- positional calls with the pre-0035 argument counts
  p := ops.create_project('global'::public.ltree, 't0035d', 'T0035 D', '{}'::jsonb);
  PERFORM pg_temp.check(p.key = 't0035d' AND pg_temp.state('global.t0035d') = '-|-|-', 'c create_project, 4 positional arguments');
  p := ops.create_project('global'::public.ltree, 't0035e', 'T0035 E');
  PERFORM pg_temp.check(p.key = 't0035e', 'c create_project, 3 positional arguments');
  c := ops.create_component('global.t0035d'::public.ltree, 'dc', 'service', NULL, 'npm test', '{}'::jsonb);
  PERFORM pg_temp.check(c.key = 'dc' AND c.verify_cmd = 'npm test' AND pg_temp.state('global.t0035d.dc') = '-|-|-',
                        'c create_component, 6 positional arguments');
  c := ops.create_component('global.t0035d'::public.ltree, 'dd', 'service');
  PERFORM pg_temp.check(c.key = 'dd', 'c create_component, 3 positional arguments');
  -- refusals unchanged, including create_project's project-parent text
  PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.create_project('global.t0035c'::public.ltree, 'x', 'x')$q$)
                        = 'P0001 parent of project "x" must be the global node, not global.t0035c (deeper parents wait for release 2)',
                        'c create_project project-parent refusal unchanged');
  PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.create_component('global.t0035d'::public.ltree, 'dc', 'service')$q$)
                        = '23514 component "t0035d/dc" already exists', 'c create_component duplicate refusal unchanged');
  -- a shape violation in p_summary is the CHECK
  PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.create_project(p_parent_path => 'global', p_key => 't0035f', p_name => 'F', p_summary => '  ')$q$)
                        = '23514 new row for relation "nodes" violates check constraint "nodes_summary_shape"',
                        'c create_project with a blank p_summary refused by the CHECK');
  RAISE NOTICE 'ok   c create_project / create_component: p_summary stored and stamped (session NULL), absent -> NULL, 3/4 and 3/6 positional calls, refusals unchanged';
END $$;

-- d. set_node_summary: stores, stamps time and session, overwrites; refusals as _doc_session plus NULL summary
DO $$
DECLARE r record; e text;
BEGIN
  SELECT * INTO r FROM ops.set_node_summary('global.t0035a.ca', 'T0035 first.', pg_temp.id('sa'));
  PERFORM pg_temp.check(r.node_path::text = 'global.t0035a.ca' AND r.summary = 'T0035 first.' AND r.summary_updated_at = now()
                        AND r.summary_session_id = pg_temp.id('sa'), 'd result row');
  PERFORM pg_temp.check(pg_temp.state('global.t0035a.ca') = 'T0035 first.|true|' || pg_temp.id('sa'), 'd stored and stamped');
  SELECT * INTO r FROM ops.set_node_summary('global.t0035a.ca', 'T0035 second.', pg_temp.id('sca'));
  PERFORM pg_temp.check(pg_temp.state('global.t0035a.ca') = 'T0035 second.|true|' || pg_temp.id('sca'),
                        'd overwrite replaces summary and session stamp');
  -- one row only: the parent is untouched
  PERFORM pg_temp.check(pg_temp.state('global.t0035a') = '-|-|-', 'd only the target node changes');
  -- archived node
  PERFORM ops.set_node_summary('global.t0035a.old', 'T0035 archived summary.', pg_temp.id('sa'));
  PERFORM pg_temp.check(pg_temp.state('global.t0035a.old') = 'T0035 archived summary.|true|' || pg_temp.id('sa'),
                        'd archived node accepted');
  -- refusals
  e := pg_temp.set_err('global.t0035nosuch', quote_literal('x'), 'sa');
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0035nosuch', 'd unknown node: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('global.t0035a', quote_literal('x'), NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'd NULL session: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('global.t0035a', quote_literal('x'), 'snone');
  PERFORM pg_temp.check(e = '23514 session ' || pg_temp.id('snone') || ' does not exist', 'd unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('global.t0035a.ca', quote_literal('x'), 'sb');
  PERFORM pg_temp.check(e = '23514 session ' || pg_temp.id('sb') || ' is outside global.t0035a (the scope of global.t0035a.ca)',
                        'd out-of-scope session: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('global.t0035a', 'NULL', 'sa');
  PERFORM pg_temp.check(e = '23514 summary is required', 'd NULL summary: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.state('global.t0035a') = '-|-|-' AND pg_temp.state('global.t0035a.ca') = 'T0035 second.|true|' || pg_temp.id('sca'),
                        'd refusals changed nothing');
  RAISE NOTICE 'ok   d set_node_summary: stores, stamps, overwrites, archived node; unknown node, NULL / unknown / out-of-scope session, NULL summary refused';
END $$;

-- e. shape: 200 characters accepted; 201, empty, blank, LF and CR refused 23514, through the writer and a direct UPDATE
DO $$
DECLARE s text; e text; v_check text := '23514 new row for relation "nodes" violates check constraint "nodes_summary_shape"';
BEGIN
  PERFORM pg_temp.check(pg_temp.set_err('global.t0035b', quote_literal(repeat('w', 200)), 'sb') IS NULL
                        AND pg_temp.state('global.t0035b') = repeat('w', 200) || '|true|' || pg_temp.id('sb'),
                        'e 200 characters accepted through set_node_summary');
  UPDATE ops.nodes SET summary = repeat('u', 200), summary_updated_at = now() WHERE path::text = 'global.t0035c';
  PERFORM pg_temp.check(pg_temp.state('global.t0035c') = repeat('u', 200) || '|true|-', 'e 200 characters accepted by a direct UPDATE');
  FOREACH s IN ARRAY ARRAY['repeat(''x'', 201)', '''''', '''   ''', '''a'' || chr(10) || ''b''', '''a'' || chr(13) || ''b'''] LOOP
    e := pg_temp.set_err('global.t0035b', s, 'sb');
    PERFORM pg_temp.check(e = v_check, 'e set_node_summary ' || s || ': ' || coalesce(e, 'success'));
    e := pg_temp.err(format('UPDATE ops.nodes SET summary = %s, summary_updated_at = now() WHERE path::text = %L', s, 'global.t0035c'));
    PERFORM pg_temp.check(e = v_check, 'e direct UPDATE ' || s || ': ' || coalesce(e, 'success'));
  END LOOP;
  e := pg_temp.err(format('UPDATE ops.nodes SET summary_updated_at = NULL, summary_session_id = %L WHERE path::text = %L',
                          pg_temp.id('sa'), 'global.t0035a'));
  PERFORM pg_temp.check(e = '23514 new row for relation "nodes" violates check constraint "nodes_summary_stamp"',
                        'e session stamp without a time stamp refused: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.state('global.t0035b') = repeat('w', 200) || '|true|' || pg_temp.id('sb')
                        AND pg_temp.state('global.t0035c') = repeat('u', 200) || '|true|-', 'e refusals changed nothing');
  RAISE NOTICE 'ok   e shape: 200 accepted; 201, empty, blank, LF, CR refused 23514 (writer and direct UPDATE as %); stamp CHECK', current_user;
END $$;

-- f. backfill (always asserted): the three framework nodes, when present, hold the 0035 text
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('global', 'Root of the local-ops tree: framework-wide decisions, the MANUAL, and the rules every project inherits.'),
      ('global.local-ops', 'The local-ops framework itself: planning, decisions, backlog and vision for building and running it.'),
      ('global.local-ops.core', 'Core repo: Postgres ops schema, numbered migrations, the local_ops MCP server and their tests.')
    ) AS t(path, summary) LOOP
    IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = r.path) THEN
      PERFORM pg_temp.check((SELECT summary = r.summary AND summary_updated_at IS NOT NULL FROM ops.nodes WHERE path::text = r.path),
                            'f backfilled summary of ' || r.path);
    END IF;
  END LOOP;
  RAISE NOTICE 'ok   f backfill: framework node summaries hold the 0035 text';
END $$;

ROLLBACK;

-- g. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'nodes', (SELECT count(*) FROM ops.nodes), 'projects', (SELECT count(*) FROM ops.projects),
    'components', (SELECT count(*) FROM ops.components), 'sessions', (SELECT count(*) FROM ops.sessions),
    'summaries', (SELECT md5(string_agg(id::text || coalesce(summary, '-') || coalesce(summary_updated_at::text, '-')
                                        || coalesce(summary_session_id::text, '-'), '|' ORDER BY id)) FROM ops.nodes)))
     <> current_setting('ops_test.counts_before')::jsonb
     OR EXISTS (SELECT 1 FROM ops.nodes WHERE path::text LIKE 'global.t0035%') THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   g no leftover rows; 0035 tests passed';
END $$;
