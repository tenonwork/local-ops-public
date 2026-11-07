-- tests/sql/0028_work_log_functions.sql
-- Tests for migrations/0028_work_log_functions.sql. Run as the schema owner against a non-production database where
-- 0028 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0028_work_log_functions.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0028a, components ca and cb and a session through
-- the node-keyed writers, and asserts only on rows it creates (plus catalog state 0028 establishes). Rows it orders
-- or caps are dated after now() so that work_log rows tagged to the global node by other writers sort after them.

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
    'gate_events', (SELECT count(*) FROM ops.gate_events), 'work_log', (SELECT count(*) FROM ops.work_log),
    'work_log_nodes', (SELECT count(*) FROM ops.work_log_nodes)))::text,
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

-- a new dispatch of p_type on global.t0028a.<p_comp> with the test session
CREATE FUNCTION pg_temp.dispatch(p_comp text, p_type text, p_title text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.create_dispatch(p_node_path => ('global.t0028a.' || p_comp)::public.ltree, p_dispatch_type => p_type,
                              p_title => p_title, p_prompt => 'p', p_session => pg_temp.id('s'))).id;
$$;

CREATE FUNCTION pg_temp.claim(p_dispatch uuid) RETURNS void LANGUAGE sql AS $$
  SELECT ops.claim_dispatch(p_dispatch, 't0028-agent');
$$;

-- a new claimed dispatch of p_type on ca
CREATE FUNCTION pg_temp.claimed(p_type text, p_title text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_d uuid := pg_temp.dispatch('ca', p_type, p_title);
BEGIN
  PERFORM pg_temp.claim(v_d);
  RETURN v_d;
END $$;

CREATE FUNCTION pg_temp.log_err(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.log_work(%L::uuid, %L, %L)', p_dispatch, 'chore', 't0028 refused'));
$$;

CREATE FUNCTION pg_temp.complete_err(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.complete_dispatch(%L::uuid, %L, %L)', p_dispatch, 'r', 'report'));
$$;

CREATE FUNCTION pg_temp.nolog_msg(p_dispatch uuid, p_policy text) RETURNS text LANGUAGE sql AS $$
  SELECT '23514 dispatch ' || left(p_dispatch::text, 8) || ' (commit_policy ' || p_policy
         || ') has no work_log entry; call ops.log_work first';
$$;

CREATE FUNCTION pg_temp.status(p_dispatch uuid) RETURNS text LANGUAGE sql AS $$
  SELECT status::text FROM ops.dispatches WHERE id = p_dispatch;
$$;

CREATE FUNCTION pg_temp.node(p_path text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ops.nodes WHERE path::text = p_path;
$$;

-- a work_log row written as the owner, tagged to the node at p_path, dated now() + p_offset
CREATE FUNCTION pg_temp.row_at(p_path text, p_title text, p_files text[], p_offset interval) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO ops.work_log (origin, entry_type, title, files_changed, occurred_at)
  VALUES ('operator', 'chore', p_title, p_files, now() + p_offset) RETURNING id INTO v_id;
  INSERT INTO ops.work_log_nodes (work_log_id, node_id) VALUES (v_id, pg_temp.node(p_path));
  RETURN v_id;
END $$;

-- 0. fixtures: project t0028a, components ca and cb, a session on t0028a
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  p := ops.create_project('global'::public.ltree, 't0028a', 'T0028 A');
  c := ops.create_component('global.t0028a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  c := ops.create_component('global.t0028a'::public.ltree, 'cb', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0028a'::public.ltree,
                                                     p_kind => 'planning')::text, true);
  RAISE NOTICE 'ok   0 fixtures (t0028a/ca, cb, session)';
END $$;

-- a. catalog 0028 establishes (bounded: asserted while 0028 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
        v_log regprocedure := to_regprocedure('ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb)');
        v_get regprocedure := to_regprocedure('ops.get_work_log(public.ltree, text[], integer)');
        v_cd regprocedure := to_regprocedure('ops.complete_dispatch(uuid, text, text)');
        v_fn regprocedure;
BEGIN
  IF NOT (newest >= '0028' AND newest < '0029') THEN
    RAISE NOTICE 'skip a catalog of 0028 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) =
                                  'p_dispatch_id uuid, p_entry_type text, p_title text, p_description text DEFAULT NULL::text, '
                                  'p_files_changed text[] DEFAULT ''{}''::text[], p_follow_ups jsonb DEFAULT ''[]''::jsonb, '
                                  'p_test_summary text DEFAULT NULL::text, p_external_refs jsonb DEFAULT ''[]''::jsonb'
                                AND prorettype = 'uuid'::regtype AND NOT proretset AND provolatile = 'v'
                           FROM pg_proc WHERE oid = v_log),
                        'log_work arguments and result: ' || coalesce((SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE oid = v_log), 'missing'));
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) =
                                  'p_node_path public.ltree, p_files text[] DEFAULT ''{}''::text[], p_limit integer DEFAULT NULL::integer'
                                AND pg_get_function_result(oid) =
                                  'TABLE(id uuid, occurred_at timestamp with time zone, entry_type text, title text, '
                                  'description text, files_changed text[], follow_ups jsonb, test_summary text, '
                                  'external_refs jsonb, dispatch_id uuid, file_overlap boolean)'
                                AND proretset AND provolatile = 's'
                           FROM pg_proc WHERE oid = v_get),
                        'get_work_log arguments and result: ' || coalesce((SELECT pg_get_function_result(oid) FROM pg_proc WHERE oid = v_get), 'missing'));
  FOREACH v_fn IN ARRAY ARRAY[v_log, v_get] LOOP
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                                  AND pg_get_userbyid(proowner) = v_owner FROM pg_proc WHERE oid = v_fn),
                          v_fn::text || ' secdef, search_path, owner');
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                             FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner)
                          = ARRAY['ops_executor'], v_fn::text || ' ACL: ops_executor only');
    PERFORM pg_temp.check(obj_description(v_fn, 'pg_proc') LIKE 'Work-log release (e0636813): %', v_fn::text || ' comment');
  END LOOP;
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_id uuid, p_result text, p_report text'
                                AND prorettype = 'void'::regtype AND prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner AND obj_description(oid, 'pg_proc') IS NULL
                                AND strpos(prosrc, 'has no work_log entry; call ops.log_work first') > 0
                           FROM pg_proc WHERE oid = v_cd),
                        'complete_dispatch signature, security, search_path, owner, no comment, log check in body');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                           FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_cd AND a.grantee <> p.proowner)
                        = ARRAY['ops_executor'], 'complete_dispatch ACL: ops_executor only');
  PERFORM pg_temp.check((SELECT i.indisunique AND pg_get_expr(i.indpred, i.indrelid) IS NOT NULL
                                AND pg_get_indexdef(i.indexrelid) LIKE '%jsonb_path_query_first(external_refs, ''$[*]?(@."kind" == "claude_log")."line"''::jsonpath)%'
                           FROM pg_index i WHERE i.indexrelid = to_regclass('ops.work_log_claude_log_line_uq')),
                        'work_log_claude_log_line_uq: unique partial index on the claude_log line: '
                        || coalesce(pg_get_indexdef(to_regclass('ops.work_log_claude_log_line_uq')), 'missing'));
  PERFORM pg_temp.check((SELECT version = 1 AND value = jsonb_build_object('cap', 10, 'rule',
                                  'claim_dispatch delivers work_log rows tagged to the dispatch''s node or an ancestor: rows whose files_changed overlap the dispatch''s task files first, then newest; at most cap rows.')
                           FROM ops.protocol_rules WHERE key = 'work_log_delivery'),
                        'work_log_delivery rule at version 1 with cap 10 and the rule text');
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) = 9
                        AND EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 9 AND rule_keys = ARRAY['work_log_delivery']),
                        'protocol version 9 names work_log_delivery');
  RAISE NOTICE 'ok   a catalog: log_work, get_work_log, complete_dispatch, unique claude_log index, work_log_delivery rule';
END $$;

-- b. log_work: refused unless claimed; on a claimed dispatch one work_log row and one work_log_nodes row
DO $$
DECLARE v_d uuid; v_u uuid := gen_random_uuid(); e text; v_w uuid; w ops.work_log;
BEGIN
  e := pg_temp.log_err(v_u);
  PERFORM pg_temp.check(e = '23514 dispatch ' || v_u || ' does not exist', 'b unknown id: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 'modification', 't0028 b pending');
  e := pg_temp.log_err(v_d);
  PERFORM pg_temp.check(e = '23514 dispatch ' || left(v_d::text, 8) || ' is pending, not claimed', 'b pending: ' || coalesce(e, 'success'));

  v_d := pg_temp.claimed('investigation', 't0028 b done');
  PERFORM ops.complete_dispatch(v_d, 'r', 'report');
  e := pg_temp.log_err(v_d);
  PERFORM pg_temp.check(e = '23514 dispatch ' || left(v_d::text, 8) || ' is done, not claimed', 'b done: ' || coalesce(e, 'success'));

  v_d := pg_temp.claimed('modification', 't0028 b failed');
  PERFORM ops.fail_dispatch(v_d, 'stopped at t0028 b');
  e := pg_temp.log_err(v_d);
  PERFORM pg_temp.check(e = '23514 dispatch ' || left(v_d::text, 8) || ' is failed, not claimed', 'b failed: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 'modification', 't0028 b cancelled');
  PERFORM ops.cancel_dispatch(v_d, 't0028');
  e := pg_temp.log_err(v_d);
  PERFORM pg_temp.check(e = '23514 dispatch ' || left(v_d::text, 8) || ' is cancelled, not claimed', 'b cancelled: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.work_log WHERE title = 't0028 refused'), 'b refused calls wrote nothing');

  v_d := pg_temp.claimed('modification', 't0028 b claimed');
  v_w := ops.log_work(v_d, 'feature', 't0028 b logged', 'desc', ARRAY['x.sql', 'y.ts'], '["[discovery] f"]'::jsonb,
                      'tests 1 pass', '[{"kind": "commit", "sha": "abc1234"}]'::jsonb);
  SELECT * INTO w FROM ops.work_log WHERE id = v_w;
  PERFORM pg_temp.check(w.origin = 'code' AND w.provenance = 'recorded' AND w.session_id IS NULL AND w.dispatch_id = v_d
                        AND w.entry_type = 'feature' AND w.title = 't0028 b logged' AND w.description = 'desc'
                        AND w.files_changed = ARRAY['x.sql', 'y.ts'] AND w.follow_ups = '["[discovery] f"]'::jsonb
                        AND w.test_summary = 'tests 1 pass' AND w.external_refs = '[{"kind": "commit", "sha": "abc1234"}]'::jsonb,
                        'b work_log row: ' || coalesce(row_to_json(w)::text, 'missing'));
  PERFORM pg_temp.check((SELECT count(*) FROM ops.work_log WHERE dispatch_id = v_d) = 1, 'b one work_log row');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.work_log_nodes WHERE work_log_id = v_w)
                        = ARRAY[pg_temp.node('global.t0028a.ca')], 'b one work_log_nodes row on the ca node');
  v_w := ops.log_work(v_d, 'chore', 't0028 b defaults');
  SELECT * INTO w FROM ops.work_log WHERE id = v_w;
  PERFORM pg_temp.check(w.files_changed = '{}' AND w.follow_ups = '[]'::jsonb AND w.external_refs = '[]'::jsonb
                        AND w.description IS NULL AND w.test_summary IS NULL, 'b defaults');
  e := pg_temp.err(format('SELECT ops.log_work(%L::uuid, %L, %L)', v_d, 't0028nosuch', 't0028 b'));
  PERFORM pg_temp.check(e LIKE '23503 %', 'b unknown entry type is a foreign key violation: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   b log_work refused for unknown, pending, done, failed, cancelled; claimed writes one row and one node row';
END $$;

-- c. complete_dispatch: local and push need a log; none (investigation, promote) and fail_dispatch do not
DO $$
DECLARE v_d uuid; e text;
BEGIN
  v_d := pg_temp.claimed('modification', 't0028 c local');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e = pg_temp.nolog_msg(v_d, 'local'), 'c local without log: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(v_d) = 'claimed', 'c local stays claimed');
  PERFORM ops.log_work(v_d, 'fix', 't0028 c local');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e IS NULL AND pg_temp.status(v_d) = 'done', 'c local after log: ' || coalesce(e, 'success'));

  v_d := pg_temp.claimed('push', 't0028 c push');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e = pg_temp.nolog_msg(v_d, 'push'), 'c push without log: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.status(v_d) = 'claimed', 'c push stays claimed');
  PERFORM ops.log_work(v_d, 'chore', 't0028 c push');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e IS NULL AND pg_temp.status(v_d) = 'done', 'c push after log: ' || coalesce(e, 'success'));

  v_d := pg_temp.claimed('investigation', 't0028 c investigation');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e IS NULL AND pg_temp.status(v_d) = 'done', 'c investigation without log: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 'promote', 't0028 c promote');
  INSERT INTO ops.gate_events (dispatch_id, session_id, gate_key, result, reason, at)
  SELECT d.id, pg_temp.id('s'), 'prod_apply_approved', 'pass', 't0028 c', d.created_at + interval '1 second'
    FROM ops.dispatches d WHERE d.id = v_d;
  PERFORM pg_temp.claim(v_d);
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e IS NULL AND pg_temp.status(v_d) = 'done', 'c promote without log: ' || coalesce(e, 'success'));

  v_d := pg_temp.claimed('modification', 't0028 c fail');
  PERFORM ops.fail_dispatch(v_d, 'stopped at t0028 c');
  PERFORM pg_temp.check(pg_temp.status(v_d) = 'failed', 'c fail_dispatch without log');

  -- a non-claimed local dispatch keeps the old 'not claimed' error, not the log refusal
  v_d := pg_temp.dispatch('ca', 'modification', 't0028 c pending');
  e := pg_temp.complete_err(v_d);
  PERFORM pg_temp.check(e = 'P0001 dispatch ' || v_d || ' is not claimed', 'c pending: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   c local and push refused 23514 without a log and complete after log_work; none and fail need no log';
END $$;

-- d. get_work_log: the path and its ancestors, not siblings; overlap first, then newest; cap from rule and p_limit
DO $$
DECLARE v_ca uuid; v_proj uuid; v_cb uuid; v_old uuid; v_got uuid[]; i int; v_mine uuid[];
        v_project_rows bigint;
BEGIN
  v_ca := pg_temp.row_at('global.t0028a.ca', 't0028 d ca', ARRAY['f1'], interval '1 hour');
  v_proj := pg_temp.row_at('global.t0028a', 't0028 d project', ARRAY['f2'], interval '2 hours');
  v_cb := pg_temp.row_at('global.t0028a.cb', 't0028 d cb', ARRAY['f1'], interval '3 hours');
  v_old := pg_temp.row_at('global.t0028a.ca', 't0028 d old overlap', ARRAY['f9', 'f1'], interval '30 minutes');

  SELECT array_agg(g.id ORDER BY ord) INTO v_got
    FROM ops.get_work_log('global.t0028a.ca'::public.ltree, ARRAY['f1'], 1000) WITH ORDINALITY g(id, occurred_at, entry_type, title, description, files_changed, follow_ups, test_summary, external_refs, dispatch_id, file_overlap, ord)
   WHERE g.title LIKE 't0028 d %';
  PERFORM pg_temp.check(v_got = ARRAY[v_ca, v_old, v_proj], 'd order: overlap newest first, then the rest newest: ' || coalesce(v_got::text, 'none'));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.get_work_log('global.t0028a.ca'::public.ltree, '{}', 1000) WHERE id = v_cb),
                        'd cb row not delivered on ca');
  PERFORM pg_temp.check((SELECT bool_and(file_overlap = (id IN (v_ca, v_old)))
                           FROM ops.get_work_log('global.t0028a.ca'::public.ltree, ARRAY['f1'], 1000) WHERE title LIKE 't0028 d %'),
                        'd file_overlap true exactly for the f1 rows');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.get_work_log('global.t0028a.ca'::public.ltree) WHERE file_overlap),
                        'd no files: no overlap');
  SELECT array_agg(g.id ORDER BY ord) INTO v_got
    FROM ops.get_work_log('global.t0028a.ca'::public.ltree, '{}', 1000) WITH ORDINALITY g(id, occurred_at, entry_type, title, description, files_changed, follow_ups, test_summary, external_refs, dispatch_id, file_overlap, ord)
   WHERE g.title LIKE 't0028 d %';
  PERFORM pg_temp.check(v_got = ARRAY[v_proj, v_ca, v_old], 'd without files: newest first: ' || coalesce(v_got::text, 'none'));
  PERFORM pg_temp.check((SELECT count(*) FROM ops.get_work_log('global.t0028a.cb'::public.ltree, '{}', 1000)
                          WHERE id IN (v_cb, v_proj)) = 2
                        AND NOT EXISTS (SELECT 1 FROM ops.get_work_log('global.t0028a.cb'::public.ltree, '{}', 1000) WHERE id IN (v_ca, v_old)),
                        'd on cb: cb and project rows, not ca rows');
  SELECT count(*) INTO v_project_rows FROM ops.get_work_log('global.t0028a'::public.ltree, '{}', 1000) WHERE title LIKE 't0028 d %';
  PERFORM pg_temp.check(v_project_rows = 1, 'd on the project node: only the project row (no descendants), got ' || v_project_rows);
  PERFORM pg_temp.check(pg_temp.err('SELECT ops.get_work_log(''global.t0028a.nosuch''::public.ltree)')
                        = 'P0001 unknown node global.t0028a.nosuch', 'd unknown path refused');

  -- cap: twelve more ca rows, the newest of all; the rule's cap (10) and p_limit bound the result
  FOR i IN 1..12 LOOP
    v_mine := v_mine || pg_temp.row_at('global.t0028a.ca', 't0028 d cap ' || i, '{}', make_interval(days => 1, mins => i));
  END LOOP;
  SELECT array_agg(g.id ORDER BY ord) INTO v_got
    FROM ops.get_work_log('global.t0028a.ca'::public.ltree) WITH ORDINALITY g(id, occurred_at, entry_type, title, description, files_changed, follow_ups, test_summary, external_refs, dispatch_id, file_overlap, ord);
  PERFORM pg_temp.check(cardinality(v_got) = (SELECT (value->>'cap')::int FROM ops.protocol_rules WHERE key = 'work_log_delivery')
                        AND cardinality(v_got) = 10 AND v_got <@ v_mine, 'd cap from the rule: ' || coalesce(cardinality(v_got), 0));
  PERFORM pg_temp.check(v_got[1] = v_mine[12] AND v_got[10] = v_mine[3], 'd capped rows are the newest ten');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.get_work_log('global.t0028a.ca'::public.ltree, '{}', 3)) = 3, 'd p_limit 3');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.get_work_log('global.t0028a.ca'::public.ltree, '{}', 1000)
                          WHERE title LIKE 't0028 d %') = 15, 'd p_limit above the cap returns all fifteen ca-visible rows');
  RAISE NOTICE 'ok   d get_work_log: path and ancestors only, overlap first then newest, cap 10 from the rule, p_limit';
END $$;

-- e. the claude_log line is unique across work_log; rows without one are unconstrained
DO $$
DECLARE v_d uuid := pg_temp.claimed('modification', 't0028 e'); e text;
BEGIN
  PERFORM ops.log_work(v_d, 'docs', 't0028 e 1', p_external_refs => '[{"kind": "commit", "sha": "a"}, {"kind": "claude_log", "line": 987654321}]');
  e := pg_temp.err(format('SELECT ops.log_work(%L::uuid, %L, %L, p_external_refs => %L::jsonb)', v_d, 'docs', 't0028 e 2',
                          '[{"kind": "claude_log", "line": 987654321}]'));
  PERFORM pg_temp.check(e LIKE '23505 %work_log_claude_log_line_uq%', 'e duplicate claude_log line: ' || coalesce(e, 'success'));
  PERFORM ops.log_work(v_d, 'docs', 't0028 e 3', p_external_refs => '[{"kind": "claude_log", "line": 987654322}]');
  PERFORM ops.log_work(v_d, 'docs', 't0028 e 4');
  PERFORM ops.log_work(v_d, 'docs', 't0028 e 5', p_external_refs => '[{"kind": "commit", "sha": "a"}]');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.work_log WHERE dispatch_id = v_d) = 4, 'e four rows written');
  RAISE NOTICE 'ok   e duplicate claude_log line refused 23505; rows without one are fine';
END $$;

-- f. privileges: executor executes both functions, planner neither; no table privilege gained on work_log tables
DO $$
DECLARE v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb)',
                              'ops.get_work_log(public.ltree, text[], integer)'] LOOP
    PERFORM pg_temp.check(has_function_privilege('ops_executor', v_fn, 'EXECUTE'), 'f executor executes ' || v_fn);
    PERFORM pg_temp.check(NOT has_function_privilege('ops_planner', v_fn, 'EXECUTE'), 'f planner cannot execute ' || v_fn);
    PERFORM pg_temp.check(NOT has_function_privilege('public', v_fn, 'EXECUTE'), 'f PUBLIC cannot execute ' || v_fn);
  END LOOP;
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['ops.work_log', 'ops.work_log_nodes']) t,
                                         unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
                                     WHERE has_table_privilege('ops_executor', t, p)),
                        'f executor has no privilege on work_log, work_log_nodes');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['ops.work_log', 'ops.work_log_nodes']) t,
                                         unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p
                                     WHERE has_table_privilege('ops_planner', t, p))
                        AND has_table_privilege('ops_planner', 'ops.work_log', 'SELECT')
                        AND has_table_privilege('ops_planner', 'ops.work_log_nodes', 'SELECT'),
                        'f planner keeps SELECT only on work_log, work_log_nodes');
  RAISE NOTICE 'ok   f executor EXECUTE on log_work, get_work_log; planner and PUBLIC none; no table privileges gained';
END $$;

ROLLBACK;

-- g. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'gate_events', (SELECT count(*) FROM ops.gate_events), 'work_log', (SELECT count(*) FROM ops.work_log),
    'work_log_nodes', (SELECT count(*) FROM ops.work_log_nodes)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   g no leftover rows; 0028 tests passed';
END $$;
