-- tests/sql/0022_session_required_drop_task_status.sql
-- Tests for migrations/0022_session_required_drop_task_status.sql. Run as the schema owner against a non-production
-- database where 0022 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0022_session_required_drop_task_status.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0022a (through the node-keyed writers), asserts
-- only on rows it creates and counts relative to the starting state.

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
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes)))::text,
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

-- asserts p_sql raises p_state with a message containing p_like
CREATE FUNCTION pg_temp.rejects(p_sql text, p_state text, p_like text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  PERFORM pg_temp.check(e LIKE p_state || ' %' || p_like || '%', p_what || ': ' || coalesce(e, 'success'));
END $$;

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- fixtures: project t0022a with component ca (verify_cmd set) and a project-level session
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0022a', p_name => 'T0022 A');
  PERFORM set_config('ops_test.pa', p.id::text, true);
  c := ops.create_component(p_parent_path => 'global.t0022a'::public.ltree, p_key => 'ca', p_kind => 'service',
                            p_verify_cmd => 'npm test');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  PERFORM set_config('ops_test.session',
    ops.open_session(p_node_path => 'global.t0022a'::public.ltree, p_kind => 'planning')::text, true);
END $$;

-- 1. catalog: both session_id columns NOT NULL; sessions.task_status and ops.task_status gone; no body mentions it
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT array_agg(table_name || ':' || is_nullable ORDER BY table_name) FROM information_schema.columns
                          WHERE table_schema = 'ops' AND column_name = 'session_id' AND table_name IN ('decisions', 'dispatches'))
                        = ARRAY['decisions:NO', 'dispatches:NO'], 'decisions / dispatches session_id NOT NULL');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM information_schema.columns
                                     WHERE table_schema = 'ops' AND table_name = 'sessions' AND column_name = 'task_status'),
                        'sessions.task_status dropped');
  PERFORM pg_temp.check(to_regtype('ops.task_status') IS NULL, 'type ops.task_status dropped');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND prosrc LIKE '%task_status%'),
                        'no ops function body mentions task_status');
  -- sessions keep status and close_reason
  PERFORM pg_temp.check((SELECT array_agg(column_name::text || ':' || udt_name::text ORDER BY column_name) FROM information_schema.columns
                          WHERE table_schema = 'ops' AND table_name = 'sessions' AND column_name IN ('status', 'close_reason'))
                        = ARRAY['close_reason:close_reason', 'status:session_status'], 'sessions status / close_reason kept');
  RAISE NOTICE 'ok   1 catalog: session_id NOT NULL; task_status column and enum gone';
END $$;

-- 2. a direct insert without a session is refused by NOT NULL (23502); with the session it is accepted
DO $$
DECLARE v_pa uuid := pg_temp.id('pa'); v_ca uuid := pg_temp.id('ca');
BEGIN
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.decisions (project_id, decision) VALUES (%L, 't0022')$q$, v_pa),
                          '23502', 'session_id', 'decision without a session');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, title, prompt)
                                    VALUES (%L, %L, 'investigation', 't0022', 'p')$q$, v_pa, v_ca),
                          '23502', 'session_id', 'dispatch without a session');
  PERFORM pg_temp.check(pg_temp.err(format($q$INSERT INTO ops.decisions (project_id, session_id, decision) VALUES (%L, %L, 't0022')$q$,
                                           v_pa, pg_temp.id('session'))) IS NULL, 'decision with a session accepted');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.dispatches SET session_id = NULL WHERE id = %L$q$,
                                 (ops.create_dispatch(p_node_path => 'global.t0022a.ca'::public.ltree, p_dispatch_type => 'investigation',
                                                      p_title => 't0022', p_prompt => 'p', p_session => pg_temp.id('session'))).id),
                          '23502', 'session_id', 'UPDATE dispatch session_id to NULL');
  RAISE NOTICE 'ok   2 NOT NULL refuses session-less inserts and updates (23502)';
END $$;

-- 3. create_dispatch / log_decision refuse a null session first (23514), positional and named, writing nothing;
--    the null check precedes every other one (an unknown path is not reached)
DO $$
DECLARE v_counts jsonb := (SELECT jsonb_build_object('d', (SELECT count(*) FROM ops.dispatches), 'x', (SELECT count(*) FROM ops.decisions),
                                                     'dn', (SELECT count(*) FROM ops.dispatch_nodes), 'xn', (SELECT count(*) FROM ops.decision_nodes)));
        e text; r ops.dispatches; d ops.decisions;
BEGIN
  e := pg_temp.err($q$SELECT ops.create_dispatch(p_node_path => 'global.t0022a.ca'::public.ltree, p_dispatch_type => 'investigation',
                                                 p_title => 't', p_prompt => 'p')$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'create_dispatch named, no session: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.create_dispatch('global.t0022a.ca'::public.ltree, 'investigation', 't', 'p', '{}', 100, NULL)$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'create_dispatch positional, NULL session: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.create_dispatch('global.t0022nosuch'::public.ltree, 'investigation', 't', 'p')$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'create_dispatch checks the session first: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.log_decision(p_node_path => 'global.t0022a'::public.ltree, p_decision => 'x')$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'log_decision named, no session: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.log_decision('global.t0022a'::public.ltree, 'x', NULL, '[]', NULL, NULL, NULL, NULL)$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'log_decision positional, NULL session: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.log_decision('global.t0022nosuch'::public.ltree, 'x')$q$);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'log_decision checks the session first: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check((SELECT jsonb_build_object('d', (SELECT count(*) FROM ops.dispatches), 'x', (SELECT count(*) FROM ops.decisions),
                                                   'dn', (SELECT count(*) FROM ops.dispatch_nodes), 'xn', (SELECT count(*) FROM ops.decision_nodes)))
                        = v_counts, 'refusals wrote nothing');

  -- with a session both still write, linked to the session
  r := ops.create_dispatch(p_node_path => 'global.t0022a.ca'::public.ltree, p_dispatch_type => 'investigation',
                           p_title => 't0022 ok', p_prompt => 'p', p_session => pg_temp.id('session'));
  PERFORM pg_temp.check(r.session_id = pg_temp.id('session') AND r.status = 'pending' AND r.component_id = pg_temp.id('ca'),
                        'create_dispatch with a session: ' || to_jsonb(r)::text);
  d := ops.log_decision(p_node_path => 'global.t0022a'::public.ltree, p_decision => 't0022 ok', p_session => pg_temp.id('session'));
  PERFORM pg_temp.check(d.session_id = pg_temp.id('session') AND d.project_id = pg_temp.id('pa'), 'log_decision with a session');
  RAISE NOTICE 'ok   3 create_dispatch / log_decision refuse a null session first (23514) and write nothing';
END $$;

-- 4. open_session stale auto-close and close_session still close sessions through status / close_reason
DO $$
DECLARE v_hours integer := coalesce(
          (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
        v_stale uuid; v_fresh uuid; v_new uuid; v_s uuid; s ops.sessions; v_n integer;
BEGIN
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), 'planning', now() - make_interval(hours => v_hours + 1)) RETURNING id INTO v_stale;
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), 'planning', now() - make_interval(hours => v_hours - 1)) RETURNING id INTO v_fresh;
  v_new := ops.open_session(p_node_path => 'global.t0022a'::public.ltree, p_kind => 'execution');
  SELECT * INTO s FROM ops.sessions WHERE id = v_stale;
  PERFORM pg_temp.check((s.status, s.close_reason, s.summary, s.closed_at) = ('closed', 'stale', 'auto-closed: stale', now()),
                        'stale session auto-closed: ' || to_jsonb(s)::text);
  PERFORM pg_temp.check(NOT (to_jsonb(s) ? 'task_status'), 'session row has no task_status');
  PERFORM pg_temp.check((SELECT status = 'active' AND close_reason IS NULL FROM ops.sessions WHERE id = v_fresh), 'fresh session untouched');
  PERFORM pg_temp.check((SELECT status = 'active' AND close_reason IS NULL FROM ops.sessions WHERE id = v_new), 'new session active');

  v_n := ops.close_session(v_new, 's', 'n', '[{"decision": "t0022 inline"}]');
  SELECT * INTO s FROM ops.sessions WHERE id = v_new;
  PERFORM pg_temp.check(v_n = 1 AND (s.status, s.close_reason, s.summary, s.next_step, s.closed_at) = ('closed', 'normal', 's', 'n', now()),
                        'close_session normal: ' || to_jsonb(s)::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.decisions WHERE session_id = v_new AND decision = 't0022 inline') = 1,
                        'inline decision linked to the session');
  v_s := ops.open_session(p_node_path => 'global.t0022a.ca'::public.ltree, p_kind => 'execution');
  PERFORM ops.close_session(v_s, 's', 'n', '[]', 'erosion');
  PERFORM pg_temp.check((SELECT (status, close_reason) = ('closed', 'erosion') FROM ops.sessions WHERE id = v_s), 'close_session erosion');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'stale')$q$,
                                 ops.open_session(p_node_path => 'global.t0022a'::public.ltree, p_kind => 'planning')),
                          'P0001', 'stale closure is automatic only', 'stale closure still refused');
  RAISE NOTICE 'ok   4 stale auto-close and close_session set status / close_reason only';
END $$;

-- 5. the four replaced functions keep signature, result, SECURITY DEFINER, search_path, owner, ACL and comment
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops'); v_bad text;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0023 replaces open_session and close_session with new comments (M5b release 2): from 0023 on their comments are
  -- asserted to start 'M5b release 2 ('; args, result, security, search_path, owner and ACL are asserted unchanged
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 5 open_session / close_session comments (newest migration is %)', newest;
  END IF;
  PERFORM set_config('search_path', 'pg_catalog', true);   -- type names print schema-qualified
  SELECT string_agg(e.sig || ' ' || coalesce(to_jsonb(p)::text, 'missing'), '; ') INTO v_bad
    FROM (VALUES
      -- 0029 adds the trailing p_task_files text[] (the function is replaced, not overloaded); the comment stays
      (CASE WHEN newest >= '0029' THEN 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid,text[])'
            ELSE 'ops.create_dispatch(public.ltree,text,text,text,text[],integer,uuid)' END,
       'p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text, p_context_refs text[] DEFAULT ''{}''::text[], '
       || 'p_priority integer DEFAULT 100, p_session uuid DEFAULT NULL::uuid'
       || CASE WHEN newest >= '0029' THEN ', p_task_files text[] DEFAULT ''{}''::text[]' ELSE '' END, 'ops.dispatches',
       'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.'),
      ('ops.log_decision(public.ltree,text,text,jsonb,text,text,uuid,uuid)',
       'p_node_path public.ltree, p_decision text, p_rationale text DEFAULT NULL::text, p_rejected_alternatives jsonb DEFAULT ''[]''::jsonb, '
       || 'p_revisit_condition text DEFAULT NULL::text, p_scope text DEFAULT NULL::text, p_supersedes uuid DEFAULT NULL::uuid, '
       || 'p_session uuid DEFAULT NULL::uuid', 'ops.decisions',
       'M5b release 1 (cd187cd6): node-keyed log_decision; home node = the path''s node, global path accepted.'),
      ('ops.open_session(public.ltree,text,ops.segment_scope,timestamptz,ops.provenance)',
       'p_node_path public.ltree, p_kind text, p_scope ops.segment_scope DEFAULT NULL::ops.segment_scope, '
       || 'p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, '
       || 'p_provenance ops.provenance DEFAULT ''recorded''::ops.provenance', 'uuid',
       'M5b release 1 (e1dea446, 9c94a9fd, 3d64c0f3): node-keyed open_session; stale close by exact derived node; global path refused.'),
      ('ops.close_session(uuid,text,text,jsonb,ops.close_reason,timestamptz)',
       'p_session uuid, p_summary text, p_next_step text, p_decisions jsonb, p_reason ops.close_reason DEFAULT ''normal''::ops.close_reason, '
       || 'p_closed_at timestamp with time zone DEFAULT NULL::timestamp with time zone', 'integer', NULL)) e(sig, args, res, cmt)
    LEFT JOIN LATERAL (
      SELECT pg_get_function_arguments(oid) args, pg_get_function_result(oid) res, prosecdef, proconfig,
             pg_get_userbyid(proowner) owner, proacl::text acl, obj_description(oid, 'pg_proc') cmt
        FROM pg_proc WHERE oid = to_regprocedure(e.sig)) p ON true
   WHERE p IS NULL OR p.args <> e.args OR p.res <> e.res OR NOT p.prosecdef
      OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp'] OR p.owner <> v_owner
      OR p.acl <> format('{%1$s=X/%1$s,ops_planner=X/%1$s}', v_owner)
      OR CASE WHEN newest >= '0023' AND e.sig ~ '^ops\.(open_session|close_session)\('
              THEN coalesce(p.cmt NOT LIKE 'M5b release 2 (%', true)
              ELSE p.cmt IS DISTINCT FROM e.cmt END;
  PERFORM set_config('search_path', 'ops, pg_temp', true);
  PERFORM pg_temp.check(v_bad IS NULL, 'function catalog: ' || coalesce(v_bad, ''));
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                          AND proname IN ('create_dispatch', 'log_decision', 'open_session', 'close_session')) = 4,
                        'one overload each');
  RAISE NOTICE 'ok   5 signatures, security, search_path, owner %, ACL (ops_planner only) and comments unchanged', v_owner;
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   6 no leftover rows; 0022 tests passed';
END $$;
