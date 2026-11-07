-- tests/sql/0034_decision_read_path.sql
-- Tests for migrations/0034_decision_read_path.sql. Run as the schema owner against a non-production database
-- where 0034 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0034_decision_read_path.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own nodes global.t0034g (gist and supersede fixtures) and global.t0034a
-- (with child sub, grandchild sub.leaf and sibling sib), a session on each and its own decisions; it asserts only on
-- decisions it creates, and compares ancestor rows on global with the view rather than with fixed counts. Grants are
-- checked at catalog level (b28e2660): ops_dev is not a member of ops_planner.

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
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules)))::text, false);
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

-- logs a decision on p_path with session p_session (a setting name) and keeps its id in ops_test.<p_name>
CREATE FUNCTION pg_temp.dec(p_name text, p_path text, p_text text, p_session text, p_supersedes uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  v := (ops.log_decision(p_node_path => p_path::public.ltree, p_decision => p_text, p_supersedes => p_supersedes,
                         p_session => pg_temp.id(p_session))).id;
  PERFORM set_config('ops_test.' || p_name, v::text, true);
  RETURN v;
END $$;

CREATE FUNCTION pg_temp.gist(p_name text) RETURNS text LANGUAGE sql AS $$
  SELECT gist FROM ops.current_decisions WHERE id = pg_temp.id(p_name);
$$;

CREATE FUNCTION pg_temp.g_err(p_path text, p_limit text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT * FROM ops.get_decisions(%L::public.ltree, %s)', p_path, p_limit));
$$;

-- 0. fixtures
DO $$
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0034g', 'node', 'T0034 G'),
         ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0034a', 'node', 'T0034 A');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0034a'), 'sub', 'node', 'T0034 sub'),
         ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0034a'), 'sib', 'node', 'T0034 sib');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0034a.sub'), 'leaf', 'node', 'T0034 leaf');
  PERFORM set_config('ops_test.sg', ops.open_session(p_node_path => 'global.t0034g'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.sa', ops.open_session(p_node_path => 'global.t0034a'::public.ltree, p_kind => 'planning')::text, true);
  RAISE NOTICE 'ok   0 fixtures (global.t0034g, global.t0034a/sub/sub.leaf/sib, sessions)';
END $$;

-- a. catalog 0034 establishes (bounded: asserted while 0034 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
BEGIN
  IF NOT (newest >= '0034' AND newest < '0035') THEN
    RAISE NOTICE 'skip a catalog of 0034 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  -- catalog text is rendered with schema-qualified names: no ops on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);

  -- view
  PERFORM pg_temp.check((SELECT relkind = 'v' AND pg_get_userbyid(relowner) = v_owner FROM pg_class
                          WHERE oid = 'ops.current_decisions'::regclass), 'a current_decisions is a plain view of the schema owner');
  PERFORM pg_temp.check((SELECT string_agg(attname || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
                           FROM pg_attribute WHERE attrelid = 'ops.current_decisions'::regclass AND attnum > 0 AND NOT attisdropped)
                        = 'id uuid, id8 text, gist text, decision text, rationale text, revisit_condition text, supersedes uuid, node_id uuid, node_path public.ltree, session_id uuid, occurred_at timestamp with time zone',
                        'a current_decisions columns');
  PERFORM pg_temp.check(obj_description('ops.current_decisions'::regclass, 'pg_class')
                        = 'Decision read path (3dae01c4): current decisions with derived gists.', 'a current_decisions comment');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                          || ' ' || a.privilege_type)
                           FROM pg_class c, aclexplode(c.relacl) a
                          WHERE c.oid = 'ops.current_decisions'::regclass AND a.grantee <> c.relowner)
                        = ARRAY['ops_planner SELECT'], 'a current_decisions ACL owner plus ops_planner SELECT');

  -- function
  PERFORM pg_temp.check((SELECT array_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ') '
                                          || pg_get_function_result(p.oid) || ' ' || p.provolatile::text)
                           FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = 'get_decisions')
                        = ARRAY['get_decisions(p_node_path public.ltree, p_limit integer DEFAULT 50) TABLE(id uuid, id8 text, gist text, node_path public.ltree, distance integer, occurred_at timestamp with time zone) s'],
                        'a get_decisions: one overload, signature, result columns, STABLE');
  PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') = 'Decision read path (c4840eb8, 8e4d46a9): current decisions at a node and its ancestors, nearest first, as gists. Planner-only until claim-time delivery.'
                           FROM pg_proc WHERE oid = 'ops.get_decisions(public.ltree, integer)'::regprocedure),
                        'a get_decisions: SECURITY DEFINER, search_path, owner, comment');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                           FROM pg_proc p, aclexplode(p.proacl) a
                          WHERE p.oid = 'ops.get_decisions(public.ltree, integer)'::regprocedure AND a.grantee <> p.proowner)
                        = ARRAY['ops_planner'], 'a get_decisions ACL owner plus ops_planner');
  RAISE NOTICE 'ok   a catalog: current_decisions columns, comment, ACL; get_decisions signature, STABLE, definer, ACL, comment';
END $$;

-- b. grants (always asserted): planner reads the view and executes the reader; executor and PUBLIC get nothing
DO $$
DECLARE v_bad text;
BEGIN
  PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.current_decisions', 'SELECT'), 'b planner SELECT on current_decisions');
  PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', 'ops.current_decisions', 'SELECT'), 'b executor no SELECT on current_decisions');
  PERFORM pg_temp.check(NOT has_table_privilege('public', 'ops.current_decisions', 'SELECT'), 'b PUBLIC no SELECT on current_decisions');
  PERFORM pg_temp.check(has_function_privilege('ops_planner', 'ops.get_decisions(public.ltree, integer)', 'EXECUTE'), 'b planner EXECUTE on get_decisions');
  PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', 'ops.get_decisions(public.ltree, integer)', 'EXECUTE'), 'b executor no EXECUTE on get_decisions');
  PERFORM pg_temp.check(NOT has_function_privilege('public', 'ops.get_decisions(public.ltree, integer)', 'EXECUTE'), 'b PUBLIC no EXECUTE on get_decisions');
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
  RAISE NOTICE 'ok   b grants: planner SELECT on the view and EXECUTE on the reader; executor and PUBLIC none; executor sets unchanged; no planner table writes';
END $$;

-- c. gist: first sentence, whitespace collapsed, 200-character cap
DO $$
DECLARE v_long text := repeat('a', 249) || '.'; v_200 text := repeat('b', 199) || '.';
BEGIN
  PERFORM pg_temp.dec('g_two', 'global.t0034g', 'First sentence. Second one.', 'sg');
  PERFORM pg_temp.dec('g_none', 'global.t0034g', 'no terminator here', 'sg');
  PERFORM pg_temp.dec('g_q', 'global.t0034g', 'Is it? Yes.', 'sg');
  PERFORM pg_temp.dec('g_x', 'global.t0034g', 'Stop! Now.', 'sg');
  PERFORM pg_temp.dec('g_nl', 'global.t0034g', E'Line one\n  continues  here. Next.', 'sg');
  PERFORM pg_temp.dec('g_long', 'global.t0034g', v_long || ' Next.', 'sg');
  PERFORM pg_temp.dec('g_200', 'global.t0034g', v_200 || ' Next.', 'sg');
  PERFORM pg_temp.dec('g_eg', 'global.t0034g', 'e.g. x', 'sg');
  PERFORM pg_temp.dec('g_dot', 'global.t0034g', 'v1.2 is out. Next', 'sg');
  PERFORM pg_temp.dec('g_lead', 'global.t0034g', E'  \tLead. x', 'sg');
  PERFORM pg_temp.check(pg_temp.gist('g_two') = 'First sentence.', 'c two sentences -> first: ' || coalesce(pg_temp.gist('g_two'), 'null'));
  PERFORM pg_temp.check(pg_temp.gist('g_none') = 'no terminator here', 'c no terminator -> whole text');
  PERFORM pg_temp.check(pg_temp.gist('g_q') = 'Is it?', 'c ? terminator');
  PERFORM pg_temp.check(pg_temp.gist('g_x') = 'Stop!', 'c ! terminator');
  PERFORM pg_temp.check(pg_temp.gist('g_nl') = 'Line one continues here.', 'c newline and whitespace runs collapse: ' || coalesce(pg_temp.gist('g_nl'), 'null'));
  PERFORM pg_temp.check(pg_temp.gist('g_long') = left(v_long, 199) || '…' AND length(pg_temp.gist('g_long')) = 200,
                        'c 250-character first sentence -> 199 characters plus …');
  PERFORM pg_temp.check(pg_temp.gist('g_200') = v_200, 'c a 200-character first sentence is kept whole');
  PERFORM pg_temp.check(pg_temp.gist('g_eg') = 'e.g.', 'c e.g. ends the sentence (accepted limitation)');
  PERFORM pg_temp.check(pg_temp.gist('g_dot') = 'v1.2 is out.', 'c a period not followed by whitespace does not end the sentence');
  PERFORM pg_temp.check(pg_temp.gist('g_lead') = 'Lead.', 'c leading whitespace trimmed');
  PERFORM pg_temp.check((SELECT id8 = left(id::text, 8) AND decision = 'First sentence. Second one.'
                                AND node_path::text = 'global.t0034g' AND session_id = pg_temp.id('sg')
                                AND node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0034g')
                           FROM ops.current_decisions WHERE id = pg_temp.id('g_two')), 'c id8, decision, node and session columns');
  RAISE NOTICE 'ok   c gist: first sentence, no terminator, ? and !, whitespace collapsed, 199 + … cap, 200 kept, e.g., inner period, trim';
END $$;

-- d. current: a superseded decision is absent, its superseder present
DO $$
BEGIN
  PERFORM pg_temp.dec('d_old', 'global.t0034g', 'T0034 old decision.', 'sg');
  PERFORM pg_temp.dec('d_new', 'global.t0034g', 'T0034 new decision.', 'sg', pg_temp.id('d_old'));
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.current_decisions WHERE id = pg_temp.id('d_old')), 'd superseded decision absent');
  PERFORM pg_temp.check((SELECT supersedes FROM ops.current_decisions WHERE id = pg_temp.id('d_new')) = pg_temp.id('d_old'),
                        'd superseder present with supersedes');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.get_decisions('global.t0034g', 200) g WHERE g.id = pg_temp.id('d_old'))
                        AND EXISTS (SELECT 1 FROM ops.get_decisions('global.t0034g', 200) g WHERE g.id = pg_temp.id('d_new')),
                        'd get_decisions excludes the superseded decision');
  RAISE NOTICE 'ok   d current: superseded absent, superseder present (view and reader)';
END $$;

-- e. get_decisions: nearest first, ancestors only, limit and node refusals
DO $$
DECLARE v_ids uuid[]; v_dist int[]; v_paths text[]; v_exp uuid[]; v_global uuid[]; e text;
BEGIN
  PERFORM pg_temp.dec('a1', 'global.t0034a', 'T0034 a one.', 'sa');
  PERFORM pg_temp.dec('s1', 'global.t0034a.sub', 'T0034 sub one.', 'sa');
  PERFORM pg_temp.dec('s2', 'global.t0034a.sub', 'T0034 sub two.', 'sa');
  PERFORM pg_temp.dec('l1', 'global.t0034a.sub.leaf', 'T0034 leaf one.', 'sa');
  PERFORM pg_temp.dec('x1', 'global.t0034a.sib', 'T0034 sibling one.', 'sa');
  -- s1 is older than s2: within a distance, occurred_at DESC
  UPDATE ops.decisions SET occurred_at = now() - interval '1 hour' WHERE id = pg_temp.id('s1');

  SELECT array_agg(g.id ORDER BY g.ord), array_agg(g.distance ORDER BY g.ord), array_agg(g.node_path::text ORDER BY g.ord)
    INTO v_ids, v_dist, v_paths
    FROM ops.get_decisions('global.t0034a.sub', 200) WITH ORDINALITY g(id, id8, gist, node_path, distance, occurred_at, ord);
  PERFORM pg_temp.check(v_ids[1:3] = ARRAY[pg_temp.id('s2'), pg_temp.id('s1'), pg_temp.id('a1')], 'e nearest first: s2, s1, a1');
  PERFORM pg_temp.check(v_dist[1:3] = ARRAY[0, 0, 1] AND v_paths[1:3] = ARRAY['global.t0034a.sub', 'global.t0034a.sub', 'global.t0034a'],
                        'e distance and node_path of own rows');
  PERFORM pg_temp.check(NOT (pg_temp.id('l1') = ANY (v_ids)) AND NOT (pg_temp.id('x1') = ANY (v_ids)),
                        'e descendant and sibling excluded');
  SELECT array_agg(cd.id ORDER BY cd.occurred_at DESC, cd.id) INTO v_global
    FROM ops.current_decisions cd WHERE cd.node_path::text = 'global';
  PERFORM pg_temp.check(v_ids[4:] IS NOT DISTINCT FROM (coalesce(v_global, '{}'))[1:197]
                        AND (cardinality(v_dist) = 3 OR (SELECT bool_and(x = 2) FROM unnest(v_dist[4:]) x)),
                        'e ancestor rows on global follow at distance 2, newest first');
  PERFORM pg_temp.check((SELECT bool_and(g.gist = cd.gist AND g.id8 = cd.id8 AND g.occurred_at = cd.occurred_at)
                           FROM ops.get_decisions('global.t0034a.sub', 200) g JOIN ops.current_decisions cd ON cd.id = g.id),
                        'e gist, id8 and occurred_at equal the view');
  -- default limit 50, limit bounds
  PERFORM pg_temp.check((SELECT count(*) FROM ops.get_decisions('global.t0034a.sub')) = least(50, cardinality(v_ids)), 'e default limit 50');
  PERFORM pg_temp.check((SELECT array_agg(g.id) FROM ops.get_decisions('global.t0034a.sub', 1) g) = ARRAY[pg_temp.id('s2')], 'e limit 1');
  PERFORM pg_temp.check(pg_temp.g_err('global.t0034a.sub', '200') IS NULL, 'e limit 200 accepted');
  FOREACH e IN ARRAY ARRAY['0', '201', 'NULL', '-1'] LOOP
    PERFORM pg_temp.check(pg_temp.g_err('global.t0034a.sub', e) = '23514 limit must be between 1 and 200',
                          'e limit ' || e || ' refused: ' || coalesce(pg_temp.g_err('global.t0034a.sub', e), 'success'));
  END LOOP;
  e := pg_temp.g_err('global.t0034nosuch', '10');
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0034nosuch', 'e unknown node refused: ' || coalesce(e, 'success'));
  -- leaf sees sub, a and global; sib sees only a and global
  PERFORM pg_temp.check((SELECT array_agg(g.id ORDER BY g.distance, g.occurred_at DESC, g.id) FILTER (WHERE g.distance < 3)
                           FROM ops.get_decisions('global.t0034a.sub.leaf', 200) g)
                        = ARRAY[pg_temp.id('l1'), pg_temp.id('s2'), pg_temp.id('s1'), pg_temp.id('a1')], 'e leaf: own, sub, a');
  PERFORM pg_temp.check((SELECT array_agg(g.id ORDER BY g.distance) FILTER (WHERE g.distance < 2)
                           FROM ops.get_decisions('global.t0034a.sib', 200) g)
                        = ARRAY[pg_temp.id('x1'), pg_temp.id('a1')], 'e sib: own, a');
  RAISE NOTICE 'ok   e get_decisions: nearest first with distance, ancestors only, global follows, limits 1/50/200, refusals 0/201/NULL/-1, unknown node';
END $$;

ROLLBACK;

-- f. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules)))
     <> current_setting('ops_test.counts_before')::jsonb
     OR EXISTS (SELECT 1 FROM ops.nodes WHERE path::text LIKE 'global.t0034%') THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   f no leftover rows; 0034 tests passed';
END $$;
