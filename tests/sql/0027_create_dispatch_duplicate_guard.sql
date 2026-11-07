-- tests/sql/0027_create_dispatch_duplicate_guard.sql
-- Tests for migrations/0027_create_dispatch_duplicate_guard.sql. Run as the schema owner against a non-production
-- database where 0027 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0027_create_dispatch_duplicate_guard.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own project t0027a, components ca and cb and a session through
-- the node-keyed writers, and asserts only on rows it creates (plus catalog state 0027 establishes).

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

-- a new modification dispatch on global.t0027a.<p_comp> with the test session
CREATE FUNCTION pg_temp.dispatch(p_comp text, p_title text, p_prompt text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.create_dispatch(p_node_path => ('global.t0027a.' || p_comp)::public.ltree, p_dispatch_type => 'modification',
                              p_title => p_title, p_prompt => p_prompt, p_session => pg_temp.id('s'))).id;
$$;

-- the same create, as 'SQLSTATE message' or NULL on success
CREATE FUNCTION pg_temp.create_err(p_comp text, p_title text, p_prompt text, p_type text DEFAULT 'modification',
                                   p_session uuid DEFAULT pg_temp.id('s')) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.create_dispatch(p_node_path => %L::public.ltree, p_dispatch_type => %L, '
                            'p_title => %L, p_prompt => %L, p_session => %L::uuid)',
                            'global.t0027a.' || p_comp, p_type, p_title, p_prompt, p_session));
$$;

CREATE FUNCTION pg_temp.dup_msg(p_status text, p_dispatch uuid, p_comp text) RETURNS text LANGUAGE sql AS $$
  SELECT '23514 duplicate of ' || p_status || ' dispatch ' || left(p_dispatch::text, 8) || ' on global.t0027a.' || p_comp
         || ': same title and prompt';
$$;

CREATE FUNCTION pg_temp.n(p_comp text, p_title text, p_prompt text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id
   WHERE c.node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0027a.' || p_comp)
     AND d.title = p_title AND d.prompt = p_prompt;
$$;

CREATE FUNCTION pg_temp.claim(p_dispatch uuid) RETURNS void LANGUAGE sql AS $$
  SELECT ops.claim_dispatch(p_dispatch, 't0027-agent');
$$;

-- 0. fixtures: project t0027a, components ca and cb, a session on t0027a
DO $$
DECLARE p ops.projects; c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  p := ops.create_project('global'::public.ltree, 't0027a', 'T0027 A');
  c := ops.create_component('global.t0027a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  c := ops.create_component('global.t0027a'::public.ltree, 'cb', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0027a'::public.ltree,
                                                     p_kind => 'planning')::text, true);
  RAISE NOTICE 'ok   0 fixtures (t0027a/ca, cb, session)';
END $$;

-- a. catalog 0027 establishes (bounded: asserted while 0027 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
        v_proc regprocedure := to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)');
BEGIN
  IF NOT (newest >= '0027' AND newest < '0028') THEN
    RAISE NOTICE 'skip a catalog of 0027 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) =
                                  'p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text, '
                                  'p_context_refs text[] DEFAULT ''{}''::text[], p_priority integer DEFAULT 100, '
                                  'p_session uuid DEFAULT NULL::uuid'
                                AND prorettype = 'ops.dispatches'::regtype AND NOT proretset AND prosecdef
                                AND provolatile = 'v' AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner
                           FROM pg_proc WHERE oid = v_proc),
                        'create_dispatch arguments, result, secdef, search_path, owner: '
                        || (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE oid = v_proc));
  PERFORM pg_temp.check(has_function_privilege('ops_planner', v_proc, 'EXECUTE')
                        AND NOT has_function_privilege('ops_executor', v_proc, 'EXECUTE')
                        AND NOT has_function_privilege('public', v_proc, 'EXECUTE'),
                        'create_dispatch ACL: planner only');
  PERFORM pg_temp.check(obj_description(v_proc, 'pg_proc')
                        = 'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.',
                        'create_dispatch comment unchanged');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_dispatch') = 1,
                        'one create_dispatch overload');
  PERFORM pg_temp.check((SELECT strpos(prosrc, 'release 3 (cceaf074)') > 0
                                AND strpos(prosrc, 'release 3 (cceaf074)') < strpos(prosrc, 'INSERT INTO ops.dispatches')
                           FROM pg_proc WHERE oid = v_proc),
                        'duplicate guard sits before the INSERT');
  RAISE NOTICE 'ok   a catalog: create_dispatch signature, result, security, search_path, owner, ACL, comment, one overload';
END $$;

-- b. identical (title, prompt) on ca while the first is pending: refused 23514, the second row not written
DO $$
DECLARE v_d uuid := pg_temp.dispatch('ca', 't0027 b', 'p b'); e text;
BEGIN
  PERFORM set_config('ops_test.b', v_d::text, true);
  e := pg_temp.create_err('ca', 't0027 b', 'p b');
  PERFORM pg_temp.check(e = pg_temp.dup_msg('pending', v_d, 'ca'), 'b pending duplicate: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('ca', 't0027 b', 'p b') = 1, 'b second row not written');
  RAISE NOTICE 'ok   b pending duplicate refused 23514, names id8 and status pending, no second row';
END $$;

-- c. same title and prompt while the first is claimed: refused, message names claimed
DO $$
DECLARE v_d uuid := pg_temp.id('b'); e text;
BEGIN
  PERFORM pg_temp.claim(v_d);
  PERFORM pg_temp.check((SELECT status = 'claimed' FROM ops.dispatches WHERE id = v_d), 'c first is claimed');
  e := pg_temp.create_err('ca', 't0027 b', 'p b');
  PERFORM pg_temp.check(e = pg_temp.dup_msg('claimed', v_d, 'ca'), 'c claimed duplicate: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('ca', 't0027 b', 'p b') = 1, 'c second row not written');
  RAISE NOTICE 'ok   c claimed duplicate refused 23514, names status claimed';
END $$;

-- d. done, failed, refused_premise and cancelled do not block
DO $$
DECLARE v_d uuid; e text;
BEGIN
  v_d := pg_temp.dispatch('ca', 't0027 d done', 'p d');
  PERFORM pg_temp.claim(v_d);
  -- 0028: a local-policy dispatch needs a work_log row before complete_dispatch
  IF (SELECT max(version) FROM ops.schema_migrations) >= '0028' THEN
    PERFORM ops.log_work(v_d, 'chore', 't0027 d done');
  END IF;
  PERFORM ops.complete_dispatch(v_d, 'r', 'report');
  PERFORM pg_temp.check((SELECT status = 'done' FROM ops.dispatches WHERE id = v_d), 'd first is done');
  e := pg_temp.create_err('ca', 't0027 d done', 'p d');
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('ca', 't0027 d done', 'p d') = 2, 'd after done: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 't0027 d failed', 'p d');
  PERFORM pg_temp.claim(v_d);
  PERFORM ops.fail_dispatch(v_d, 'stopped at t0027');
  PERFORM pg_temp.check((SELECT status = 'failed' FROM ops.dispatches WHERE id = v_d), 'd first is failed');
  e := pg_temp.create_err('ca', 't0027 d failed', 'p d');
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('ca', 't0027 d failed', 'p d') = 2, 'd after failed: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 't0027 d refused', 'p d');
  PERFORM pg_temp.claim(v_d);
  PERFORM ops.fail_dispatch(v_d, 'false premise at t0027', true);
  PERFORM pg_temp.check((SELECT status = 'refused_premise' FROM ops.dispatches WHERE id = v_d), 'd first is refused_premise');
  e := pg_temp.create_err('ca', 't0027 d refused', 'p d');
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('ca', 't0027 d refused', 'p d') = 2, 'd after refused_premise: ' || coalesce(e, 'success'));

  v_d := pg_temp.dispatch('ca', 't0027 d cancelled', 'p d');
  PERFORM ops.cancel_dispatch(v_d, 't0027');
  PERFORM pg_temp.check((SELECT status = 'cancelled' FROM ops.dispatches WHERE id = v_d), 'd first is cancelled');
  e := pg_temp.create_err('ca', 't0027 d cancelled', 'p d');
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('ca', 't0027 d cancelled', 'p d') = 2, 'd after cancelled: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   d done, failed, refused_premise, cancelled do not block an identical create';
END $$;

-- e. the key is title and prompt on the component
DO $$
DECLARE v_d uuid := pg_temp.dispatch('ca', 't0027 e', 'p e'); e text;
BEGIN
  PERFORM set_config('ops_test.e', v_d::text, true);
  e := pg_temp.create_err('ca', 't0027 e', 'p e other');
  PERFORM pg_temp.check(e IS NULL, 'e same title, different prompt: ' || coalesce(e, 'success'));
  e := pg_temp.create_err('ca', 't0027 e other', 'p e');
  PERFORM pg_temp.check(e IS NULL, 'e different title, same prompt: ' || coalesce(e, 'success'));
  e := pg_temp.create_err('cb', 't0027 e', 'p e');
  PERFORM pg_temp.check(e IS NULL AND pg_temp.n('cb', 't0027 e', 'p e') = 1, 'e identical on cb: ' || coalesce(e, 'success'));
  -- and the original is still the only one of its kind on ca
  PERFORM pg_temp.check(pg_temp.n('ca', 't0027 e', 'p e') = 1, 'e one identical row on ca');
  RAISE NOTICE 'ok   e different prompt, different title, other component all succeed';
END $$;

-- f. an earlier validation still wins over the duplicate check
DO $$
DECLARE e text;
BEGIN
  PERFORM pg_temp.check(pg_temp.create_err('ca', 't0027 e', 'p e') = pg_temp.dup_msg('pending', pg_temp.id('e'), 'ca'),
                        'f the identical create is a duplicate');
  e := pg_temp.create_err('ca', 't0027 e', 'p e', 'modification', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'f null session: ' || coalesce(e, 'success'));
  e := pg_temp.create_err('ca', 't0027 e', 'p e', 't0027nosuch');
  PERFORM pg_temp.check(e = '23514 unknown dispatch type "t0027nosuch"', 'f unknown type: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.n('ca', 't0027 e', 'p e') = 1, 'f no row written');
  RAISE NOTICE 'ok   f null session and unknown type refused with their own messages before the duplicate check';
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
  RAISE NOTICE 'ok   g no leftover rows; 0027 tests passed';
END $$;
