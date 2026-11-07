-- tests/sql/0036_node_overview.sql
-- Tests for migrations/0036_node_overview.sql. Run as the schema owner against a non-production database
-- where 0036 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0036_node_overview.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own nodes under global (global.t0036d, e, f, g, h, x and the project
-- global.t0036p), doc types t0036_*, sessions, documents and backlog items, and asserts only on rows it creates. The
-- global node's own summary and documents, which every fixture inherits, are read from the tables, never assumed.
-- Block e drops UNIQUE (node_id, doc_key) inside the transaction to build a same-level ambiguity (the ROLLBACK
-- restores it; block i checks); it skips with a NOTICE when the current user does not own ops.context_documents.
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
    'sessions', (SELECT count(*) FROM ops.sessions), 'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions),
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

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

CREATE FUNCTION pg_temp.node(p_path text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ops.nodes WHERE path::text = p_path;
$$;

-- a plain node under p_parent (status active unless given)
CREATE FUNCTION pg_temp.mk(p_parent text, p_key text, p_summary text, p_status text DEFAULT 'active') RETURNS uuid
LANGUAGE sql AS $$
  INSERT INTO ops.nodes (parent_id, key, kind, title, summary, status)
  VALUES (pg_temp.node(p_parent), p_key, 'node', 'T0036 ' || p_key, p_summary, p_status::ops.node_status) RETURNING id;
$$;

-- a closed session on p_path (closed_at in UTC); returns its id
CREATE FUNCTION pg_temp.closed(p_path text, p_closed_at text, p_next text) RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO ops.sessions (kind, status, close_reason, closed_at, next_step, node_id)
  VALUES ('planning', 'closed', 'normal', p_closed_at::timestamptz, p_next, pg_temp.node(p_path)) RETURNING id;
$$;

-- an open backlog item (or of p_status) at p_path; created_at is a fixed day offset
CREATE FUNCTION pg_temp.item(p_path text, p_sev text, p_title text, p_day integer, p_status text DEFAULT 'open') RETURNS uuid
LANGUAGE sql AS $$
  INSERT INTO ops.backlog_items (home_node_id, severity, kind, title, status, created_at)
  VALUES (pg_temp.node(p_path), p_sev::ops.backlog_severity, 'task', p_title, p_status,
          '2026-01-01 00:00:00+00'::timestamptz + make_interval(days => p_day)) RETURNING id;
$$;

-- a document (no retirement); trust approved unless given
CREATE FUNCTION pg_temp.doc(p_path text, p_key text, p_type text, p_title text, p_summary text,
                            p_trust text DEFAULT 'approved') RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO ops.context_documents (node_id, doc_key, doc_type, title, content, summary, trust_status)
  VALUES (pg_temp.node(p_path), p_key, p_type, p_title, 'T0036CONTENTSENTINEL ' || p_key, p_summary,
          p_trust::ops.trust_status) RETURNING id;
$$;

-- line of p_text that starts with p_prefix (first), or NULL
CREATE FUNCTION pg_temp.line(p_text text, p_prefix text) RETURNS text LANGUAGE sql AS $$
  SELECT l FROM unnest(string_to_array(p_text, E'\n')) WITH ORDINALITY u(l, o) WHERE starts_with(l, p_prefix) ORDER BY o LIMIT 1;
$$;

-- the text after the line equal to p_header, up to (excluding) the next line equal to p_next, or to the end
CREATE FUNCTION pg_temp.section(p_text text, p_header text, p_next text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN p_next IS NULL THEN split_part(p_text, E'\n' || p_header || E'\n', 2)
              ELSE split_part(split_part(p_text, E'\n' || p_header || E'\n', 2), E'\n' || p_next, 1) END;
$$;

-- the CONTEXT lines the global node contributes to any fixture: its ancestor line, and its document lines when no
-- fixture document shadows them (computed from the tables; the fixtures never add documents at global)
CREATE FUNCTION pg_temp.global_line() RETURNS text LANGUAGE sql AS $$
  SELECT '  global — ' || coalesce(summary, '(no summary)') FROM ops.nodes WHERE path::text = 'global';
$$;
CREATE FUNCTION pg_temp.global_docs() RETURNS text[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg('  doc ' || cd.doc_key || ' (global, v' || cd.version || ') — ' || cd.title
                            || coalesce(': ' || left(cd.summary, 160), '')
                            || CASE WHEN cd.trust_status <> 'approved'
                                     AND NOT EXISTS (SELECT 1 FROM ops.document_versions dv
                                                      WHERE dv.document_id = cd.id AND dv.trust_status = 'approved')
                                    THEN ' [no approved version]' ELSE '' END ORDER BY cd.doc_key), '{}')
    FROM ops.context_documents cd JOIN ops.nodes n ON n.id = cd.node_id
   WHERE n.path::text = 'global' AND cd.retired_at IS NULL;
$$;

-- 0. fixtures
DO $$
DECLARE p ops.projects; t text;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  FOREACH t IN ARRAY ARRAY['t0036_a', 't0036_b', 't0036_c', 't0036_d', 't0036_e', 't0036_h1', 't0036_h2', 't0036_h3'] LOOP
    INSERT INTO ops.doc_types (key, label, description) VALUES (t, 'T0036 ' || t, 'T0036 test doc type');
  END LOOP;

  -- d: sections
  PERFORM pg_temp.mk('global', 't0036d', 'T0036 D.');
  PERFORM pg_temp.mk('global.t0036d', 'kb', 'T0036 kb.');
  PERFORM pg_temp.mk('global.t0036d', 'ka', NULL);
  PERFORM pg_temp.mk('global.t0036d.kb', 'deep', NULL);
  PERFORM pg_temp.mk('global.t0036d.kb', 'gone', NULL, 'archived');
  PERFORM pg_temp.mk('global.t0036d', 'kz', 'T0036 archived child.', 'archived');

  -- e: documents
  PERFORM pg_temp.mk('global', 't0036e', 'T0036 E.');
  PERFORM pg_temp.mk('global.t0036e', 'leaf', 'T0036 leaf.');

  -- f: next step
  PERFORM pg_temp.mk('global', 't0036f', 'T0036 F.');
  PERFORM pg_temp.mk('global.t0036f', 'c', NULL);
  PERFORM pg_temp.mk('global.t0036f', 'e', NULL);

  -- g: backlog; p: a project under global
  PERFORM pg_temp.mk('global', 't0036g', 'T0036 G.');
  PERFORM pg_temp.mk('global.t0036g', 'gc', NULL);
  p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0036p', p_name => 'T0036 P',
                          p_summary => 'T0036 P project.');

  -- h: budget; x: a next_step longer than the budget
  PERFORM pg_temp.mk('global', 't0036h', 'T0036 H.');
  PERFORM pg_temp.mk('global', 't0036x', 'T0036 X.');
  PERFORM pg_temp.mk('global.t0036x', 'c', NULL);

  PERFORM set_config('ops_test.s_retire', pg_temp.closed('global.t0036e', '2026-01-01 00:00+00', NULL)::text, true);
  RAISE NOTICE 'ok   0 fixtures (global.t0036d/e/f/g/h/x, project global.t0036p, doc types t0036_*)';
END $$;

-- a. catalog 0036 establishes (bounded: asserted while 0036 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
BEGIN
  IF NOT (newest >= '0036' AND newest < '0037') THEN
    RAISE NOTICE 'skip a catalog of 0036 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  -- catalog text is rendered with schema-qualified names: no ops on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'node_overview') = 1,
                        'a one overload of node_overview');
  PERFORM pg_temp.check(to_regprocedure('ops.node_overview(public.ltree,integer)') IS NOT NULL, 'a exists ops.node_overview(ltree, integer)');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_node_path public.ltree, p_max_chars integer DEFAULT 4000'
                                AND pg_get_function_identity_arguments(oid) = 'p_node_path public.ltree, p_max_chars integer'
                                AND pg_get_function_result(oid) = 'text'
                           FROM pg_proc WHERE oid = 'ops.node_overview(public.ltree,integer)'::regprocedure),
                        'a arguments, default 4000 and result text');
  PERFORM pg_temp.check((SELECT provolatile = 's' AND prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                                AND pg_get_userbyid(proowner) = v_owner AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
                           FROM pg_proc WHERE oid = 'ops.node_overview(public.ltree,integer)'::regprocedure),
                        'a STABLE, plpgsql, SECURITY DEFINER, search_path, owner');
  PERFORM pg_temp.check(obj_description('ops.node_overview(public.ltree,integer)'::regprocedure, 'pg_proc')
                        = 'Node overview release (c4db6ad1): bounded plain-text overview of a node for session opening; planner only.',
                        'a comment');
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                           FROM pg_proc p, aclexplode(p.proacl) a
                          WHERE p.oid = 'ops.node_overview(public.ltree,integer)'::regprocedure AND a.grantee <> p.proowner)
                        = ARRAY['ops_planner'], 'a ACL owner plus ops_planner');
  RAISE NOTICE 'ok   a catalog: node_overview(ltree, integer DEFAULT 4000) text, STABLE, plpgsql, definer, search_path, owner, ACL, comment, one overload';
END $$;

-- b. grants (always asserted): planner executes; executor and PUBLIC get nothing
DO $$
DECLARE v_bad text; f text := 'ops.node_overview(public.ltree,integer)';
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'b planner EXECUTE');
  PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f, 'EXECUTE'), 'b executor no EXECUTE');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'b PUBLIC no EXECUTE');
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
  RAISE NOTICE 'ok   b grants: planner EXECUTE; executor and PUBLIC none; executor sets unchanged; no planner table writes';
END $$;

-- c. refusals: unknown node (ops._node), p_max_chars below 500 or NULL; 500 and the default accepted
DO $$
DECLARE e text;
BEGIN
  e := pg_temp.err($q$SELECT ops.node_overview('global.t0036nosuch')$q$);
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0036nosuch', 'c unknown node: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.node_overview('global.t0036d', 499)$q$);
  PERFORM pg_temp.check(e = '22023 p_max_chars must be at least 500', 'c 499: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.node_overview('global.t0036d', NULL)$q$);
  PERFORM pg_temp.check(e = '22023 p_max_chars must be at least 500', 'c NULL: ' || coalesce(e, 'success'));
  e := pg_temp.err($q$SELECT ops.node_overview('global.t0036nosuch', NULL)$q$);
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0036nosuch', 'c node checked before the budget: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.node_overview('global.t0036d', 500)$q$) IS NULL
                        AND pg_temp.err($q$SELECT ops.node_overview('global.t0036d')$q$) IS NULL, 'c 500 and the default accepted');
  RAISE NOTICE 'ok   c refusals: unknown node P0001; p_max_chars 499 and NULL 22023 ''p_max_chars must be at least 500''';
END $$;

-- d. sections: exact rendering of the d fixture
DO $$
DECLARE v_out text; v_exp text;
BEGIN
  v_out := ops.node_overview('global.t0036d', 100000);
  v_exp := array_to_string(ARRAY['NODE global.t0036d (node) — T0036 D.', 'CONTEXT', pg_temp.global_line()]
                           || pg_temp.global_docs()
                           || ARRAY['CHILDREN', '  ka — (no summary) (+0 below)', '  kb — T0036 kb. (+1 below)',
                                    'NEXT STEP', '  none at this node', 'BACKLOG (open, subtree)', '  none'], E'\n');
  PERFORM pg_temp.check(v_out = v_exp, E'd global.t0036d rendering:\n' || v_out || E'\n--- expected:\n' || v_exp);
  RAISE NOTICE E'd rendering of global.t0036d (global lines elided):\n%',
    array_to_string(ARRAY(SELECT l FROM unnest(string_to_array(v_out, E'\n')) l
                           WHERE l <> pg_temp.global_line() AND NOT l = ANY (pg_temp.global_docs())), E'\n');

  v_out := ops.node_overview('global.t0036d.kb', 100000);
  v_exp := array_to_string(ARRAY['NODE global.t0036d.kb (node) — T0036 kb.', 'CONTEXT', pg_temp.global_line(),
                                 '  global.t0036d — T0036 D.']
                           || pg_temp.global_docs()
                           || ARRAY['CHILDREN', '  deep — (no summary) (+0 below)',
                                    'NEXT STEP', '  none at this node', 'BACKLOG (open, subtree)', '  none'], E'\n');
  PERFORM pg_temp.check(v_out = v_exp, E'd global.t0036d.kb rendering:\n' || v_out);

  v_out := ops.node_overview('global.t0036d.ka', 100000);
  v_exp := array_to_string(ARRAY['NODE global.t0036d.ka (node) — (no summary)', 'CONTEXT', pg_temp.global_line(),
                                 '  global.t0036d — T0036 D.']
                           || pg_temp.global_docs()
                           || ARRAY['CHILDREN', '  none', 'NEXT STEP', '  none at this node', 'BACKLOG (open, subtree)', '  none'], E'\n');
  PERFORM pg_temp.check(v_out = v_exp, E'd global.t0036d.ka rendering:\n' || v_out);

  -- archived nodes are readable; no trailing newline
  v_out := ops.node_overview('global.t0036d.kz', 100000);
  PERFORM pg_temp.check(starts_with(v_out, 'NODE global.t0036d.kz (node) — T0036 archived child.' || E'\nCONTEXT\n')
                        AND right(v_out, 1) <> E'\n', 'd archived node readable');
  -- the global node: no ancestor lines; its kind is global
  v_out := ops.node_overview('global', 100000);
  PERFORM pg_temp.check(starts_with(v_out, 'NODE global (global) — ') AND pg_temp.line(v_out, '  global') IS NULL,
                        'd global: no ancestor lines');
  RAISE NOTICE 'ok   d sections: NODE, CONTEXT ancestors root first, CHILDREN (+n below, archived excluded, none), (no summary), no trailing newline';
END $$;

-- e. document index: deepest per key, retired skipped, [no approved version], [ambiguous], summary cut, no content
DO $$
DECLARE v_out text; v_d uuid; v_docs text[];
BEGIN
  -- shadowed: T0036_SHADOW at global.t0036e and at the leaf
  PERFORM pg_temp.doc('global.t0036e', 'T0036_SHADOW', 't0036_a', 'T0036 shadow parent', 'Parent copy.');
  PERFORM pg_temp.doc('global.t0036e.leaf', 'T0036_SHADOW', 't0036_a', 'T0036 shadow leaf', 'S' || repeat('s', 199));
  -- retired at the leaf: the parent's copy is served
  PERFORM pg_temp.doc('global.t0036e', 'T0036_RETIRED', 't0036_b', 'T0036 retired parent', NULL);
  v_d := pg_temp.doc('global.t0036e.leaf', 'T0036_RETIRED', 't0036_b', 'T0036 retired leaf', 'Retired.');
  UPDATE ops.context_documents SET retired_at = now(), retired_reason = 'T0036 test', retired_by_session = pg_temp.id('s_retire')
   WHERE id = v_d;
  -- never approved
  PERFORM pg_temp.doc('global.t0036e.leaf', 'T0036_DRAFT', 't0036_c', 'T0036 draft', 'Draft.', 'draft');
  -- approved once, now a draft: served from document_versions, no flag
  v_d := pg_temp.doc('global.t0036e.leaf', 'T0036_OLDAPPR', 't0036_d', 'T0036 old approved', 'Was approved.');
  UPDATE ops.context_documents SET trust_status = 'draft', content = content || ' v2' WHERE id = v_d;

  v_out := ops.node_overview('global.t0036e.leaf', 100000);
  v_docs := ARRAY(SELECT l FROM unnest(string_to_array(v_out, E'\n')) WITH ORDINALITY u(l, o)
                   WHERE starts_with(l, '  doc T0036_') ORDER BY o);
  PERFORM pg_temp.check(v_docs = ARRAY[
      '  doc T0036_DRAFT (global.t0036e.leaf, v1) — T0036 draft: Draft. [no approved version]',
      '  doc T0036_OLDAPPR (global.t0036e.leaf, v2) — T0036 old approved: Was approved.',
      '  doc T0036_RETIRED (global.t0036e, v1) — T0036 retired parent',
      '  doc T0036_SHADOW (global.t0036e.leaf, v1) — T0036 shadow leaf: S' || repeat('s', 159)],
    E'e document lines at the leaf:\n' || array_to_string(v_docs, E'\n'));
  PERFORM pg_temp.check(pg_temp.section(v_out, 'CONTEXT', 'CHILDREN')
                        = array_to_string(ARRAY[pg_temp.global_line(), '  global.t0036e — T0036 E.']
                                          || ARRAY(SELECT l FROM unnest(pg_temp.global_docs() || v_docs) l ORDER BY split_part(l, ' ', 4)), E'\n'),
                        E'e CONTEXT section ordered by doc_key:\n' || v_out);
  PERFORM pg_temp.check(strpos(v_out, 'T0036CONTENTSENTINEL') = 0, 'e no document content in the output');

  v_out := ops.node_overview('global.t0036e', 100000);
  PERFORM pg_temp.check(pg_temp.line(v_out, '  doc T0036_SHADOW') = '  doc T0036_SHADOW (global.t0036e, v1) — T0036 shadow parent: Parent copy.'
                        AND pg_temp.line(v_out, '  doc T0036_DRAFT') IS NULL, 'e at the parent: its own copy, no leaf documents');

  -- same-level ambiguity needs two keys at one node: only reachable without UNIQUE (node_id, doc_key)
  IF (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'ops.context_documents'::regclass) <> current_user THEN
    RAISE NOTICE 'skip e [ambiguous]: % does not own ops.context_documents', current_user;
  ELSE
    ALTER TABLE ops.context_documents DROP CONSTRAINT context_documents_node_id_doc_key_key;
    PERFORM pg_temp.doc('global.t0036e.leaf', 'T0036_AMBIG', 't0036_e', 'T0036 ambig one', NULL);
    PERFORM pg_temp.doc('global.t0036e.leaf', 'T0036_AMBIG', 't0036_h1', 'T0036 ambig two', NULL);
    v_out := ops.node_overview('global.t0036e.leaf', 100000);
    PERFORM pg_temp.check((SELECT count(*) FROM unnest(string_to_array(v_out, E'\n')) l WHERE starts_with(l, '  doc T0036_AMBIG ')) = 1
                          AND pg_temp.line(v_out, '  doc T0036_AMBIG ') LIKE '  doc T0036_AMBIG (global.t0036e.leaf, v1) — T0036 ambig % [ambiguous]',
                          E'e [ambiguous]:\n' || v_out);
    PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.resolve_context('global.t0036e.leaf', 'T0036_AMBIG')$q$)
                          = 'P0001 ambiguous context ref T0036_AMBIG at global.t0036e.leaf', 'e resolve_context agrees: ambiguous');
    PERFORM pg_temp.check(pg_temp.err($q$SELECT ops.resolve_context('global.t0036e.leaf', 'T0036_DRAFT')$q$)
                          = 'P0001 context ref T0036_DRAFT has no approved version at global.t0036e.leaf',
                          'e resolve_context agrees: no approved version');
    RAISE NOTICE 'ok   e [ambiguous] (UNIQUE (node_id, doc_key) dropped inside the transaction)';
  END IF;
  RAISE NOTICE 'ok   e document index: deepest per key, retired skipped, [no approved version], summary cut at 160, ordered by key, no content';
END $$;

-- f. next step: latest closed session with a next_step at exactly the node
DO $$
DECLARE v_out text; v_s uuid; v_c uuid;
BEGIN
  PERFORM pg_temp.closed('global.t0036f', '2026-01-01 10:00+00', 'T0036 older step');
  v_s := pg_temp.closed('global.t0036f', '2026-01-03 10:07+00', E'T0036 latest step\nsecond line');
  PERFORM pg_temp.closed('global.t0036f', '2026-01-05 10:00+00', NULL);
  INSERT INTO ops.sessions (kind, status, next_step, node_id) VALUES ('planning', 'active', 'T0036 active step', pg_temp.node('global.t0036f'));
  v_c := pg_temp.closed('global.t0036f.c', '2026-01-07 10:00+00', 'T0036 child step');

  v_out := ops.node_overview('global.t0036f', 100000);
  PERFORM pg_temp.check(pg_temp.section(v_out, 'CHILDREN', 'BACKLOG')
                        = E'  c — (no summary) (+0 below)\n  e — (no summary) (+0 below)\nNEXT STEP ('
                          || left(v_s::text, 8) || E', closed 2026-01-03 10:07 UTC)\nT0036 latest step\nsecond line',
                        E'f at global.t0036f:\n' || v_out);
  v_out := ops.node_overview('global.t0036f.c', 100000);
  PERFORM pg_temp.check(strpos(v_out, E'\nNEXT STEP (' || left(v_c::text, 8) || E', closed 2026-01-07 10:00 UTC)\nT0036 child step\nBACKLOG') > 0,
                        E'f at the child: its own session:\n' || v_out);
  v_out := ops.node_overview('global.t0036f.e', 100000);
  PERFORM pg_temp.check(strpos(v_out, E'\nNEXT STEP\n  none at this node\nBACKLOG') > 0, E'f no fallback to the parent:\n' || v_out);
  RAISE NOTICE 'ok   f next step: latest closed with next_step at the node; older, NULL next_step, active and child sessions ignored; none at this node';
END $$;

-- g. backlog: subtree, project boundary, listed order, created_at, home path off-node, closed items excluded
DO $$
DECLARE v_out text; i uuid[]; v_long text := 'T0036 long ' || repeat('L', 150);
BEGIN
  i := ARRAY[
    pg_temp.item('global.t0036g', 'critical', 'T0036 crit late', 2),      -- 1
    pg_temp.item('global.t0036g', 'critical', 'T0036 crit early', 1),     -- 2
    pg_temp.item('global.t0036g', 'high', 'T0036 high', 3),               -- 3
    pg_temp.item('global.t0036g.gc', 'high', 'T0036 high child', 1),      -- 4
    pg_temp.item('global.t0036g', 'untriaged', v_long, 1),                -- 5
    pg_temp.item('global.t0036g', 'medium', 'T0036 medium', 5),           -- 6
    pg_temp.item('global.t0036g', 'low', 'T0036 low b', 6),               -- 7
    pg_temp.item('global.t0036g.gc', 'low', 'T0036 low a', 4),            -- 8
    pg_temp.item('global.t0036p', 'critical', 'T0036 project crit', 1),   -- 9
    pg_temp.item('global.t0036g', 'critical', 'T0036 done', 1, 'done'),   -- 10
    pg_temp.item('global.t0036g', 'high', 'T0036 dropped', 1, 'dropped')  -- 11
  ];
  v_out := ops.node_overview('global.t0036g', 100000);
  PERFORM pg_temp.check(pg_temp.section(v_out, 'BACKLOG (open, subtree)', NULL) = array_to_string(ARRAY[
      '  ' || left(i[2]::text, 8) || ' [critical/task] T0036 crit early',
      '  ' || left(i[1]::text, 8) || ' [critical/task] T0036 crit late',
      '  ' || left(i[4]::text, 8) || ' [high/task] T0036 high child (@global.t0036g.gc)',
      '  ' || left(i[3]::text, 8) || ' [high/task] T0036 high',
      '  ' || left(i[5]::text, 8) || ' [untriaged/task] ' || left(v_long, 100),
      '  ' || left(i[6]::text, 8) || ' [medium/task] T0036 medium',
      '  ' || left(i[8]::text, 8) || ' [low/task] T0036 low a (@global.t0036g.gc)',
      '  ' || left(i[7]::text, 8) || ' [low/task] T0036 low b'], E'\n'),
    E'g backlog at global.t0036g:\n' || v_out);
  -- the project boundary: the parent (global) omits the project's items; the project shows them
  v_out := ops.node_overview('global', 1000000);
  PERFORM pg_temp.check(strpos(v_out, left(i[9]::text, 8)) = 0
                        AND strpos(v_out, '  ' || left(i[2]::text, 8) || ' [critical/task] T0036 crit early (@global.t0036g)') > 0,
                        'g at global: project items excluded, others with their home');
  v_out := ops.node_overview('global.t0036p', 100000);
  PERFORM pg_temp.check(pg_temp.section(v_out, 'BACKLOG (open, subtree)', NULL) = '  ' || left(i[9]::text, 8) || ' [critical/task] T0036 project crit',
                        E'g at the project:\n' || v_out);
  v_out := ops.node_overview('global.t0036g.gc', 100000);
  PERFORM pg_temp.check(pg_temp.section(v_out, 'BACKLOG (open, subtree)', NULL)
                        = '  ' || left(i[4]::text, 8) || E' [high/task] T0036 high child\n  ' || left(i[8]::text, 8) || ' [low/task] T0036 low a',
                        E'g at the child: subtree only, no home shown on-node:\n' || v_out);
  PERFORM pg_temp.check(strpos(ops.node_overview('global', 1000000), 'T0036 done') = 0
                        AND strpos(ops.node_overview('global', 1000000), 'T0036 dropped') = 0, 'g done and dropped excluded');
  RAISE NOTICE 'ok   g backlog: subtree, project boundary both ways, critical/high/untriaged then medium/low, created_at, @home off-node, title cut at 100, done/dropped excluded';
END $$;

-- h. budget: trim steps (1)-(5) in order and cumulative; lengths within the budget; NEXT STEP never trimmed
DO $$
DECLARE v_out text; v_b integer := 1000000; v_next text := 'T0036 H next step ' || repeat('x', 150);
        v_hdr text; m boolean[]; v_seen boolean[] := ARRAY[false, false, false, false, false, false];
        v_child_one boolean := false; v_untriaged_one boolean := false; v_k integer; v_s uuid; v_n integer := 0;
        v_bad text;
BEGIN
  FOR v_k IN 1..5 LOOP
    PERFORM pg_temp.mk('global.t0036h', 'k' || v_k, 'T0036 child ' || v_k || ' summary padded to a longer line');
  END LOOP;
  PERFORM pg_temp.doc('global.t0036h', 'T0036_HDOC_ALPHA_PADDED_TO_A_LONG_DOCUMENT_KEY', 't0036_h1', 'T0036 H alpha', 'Alpha summary.');
  PERFORM pg_temp.doc('global.t0036h', 'T0036_HDOC_BRAVO_PADDED_TO_A_LONG_DOCUMENT_KEY', 't0036_h2', 'T0036 H bravo', 'Bravo summary.');
  PERFORM pg_temp.doc('global.t0036h', 'T0036_HDOC_CHARLIE_PADDED_TO_A_LONG_DOCUMENT_KEY', 't0036_h3', 'T0036 H charlie', 'Charlie summary.');
  v_s := pg_temp.closed('global.t0036h', '2026-02-01 08:30+00', v_next);
  v_hdr := 'NEXT STEP (' || left(v_s::text, 8) || ', closed 2026-02-01 08:30 UTC)';
  FOR v_k IN 1..2 LOOP
    PERFORM pg_temp.item('global.t0036h', 'critical', 'T0036 H critical item ' || v_k || ' with a moderately long title', v_k);
    PERFORM pg_temp.item('global.t0036h', 'high', 'T0036 H high item ' || v_k || ' with a moderately long title', v_k);
    PERFORM pg_temp.item('global.t0036h', 'untriaged', 'T0036 H untriaged item ' || v_k || ' with a moderately long title', v_k);
  END LOOP;
  FOR v_k IN 1..3 LOOP
    PERFORM pg_temp.item('global.t0036h', 'medium', 'T0036 H medium item ' || v_k || ' with a moderately long title', v_k);
    PERFORM pg_temp.item('global.t0036h', 'low', 'T0036 H low item ' || v_k || ' with a moderately long title', v_k);
  END LOOP;

  -- descend: each budget is one less than the previous output, so every reachable trim state is rendered in turn
  LOOP
    v_out := ops.node_overview('global.t0036h', v_b);
    v_n := v_n + 1;
    PERFORM pg_temp.check(length(v_out) <= v_b, 'h length ' || length(v_out) || ' within ' || v_b);
    PERFORM pg_temp.check(starts_with(v_out, E'NODE global.t0036h (node) — T0036 H.\nCONTEXT\n')
                          AND strpos(v_out, E'\n' || v_hdr || E'\n' || v_next || E'\nBACKLOG (open, subtree)\n') > 0,
                          'h NODE line and NEXT STEP intact at ' || v_b);
    m := ARRAY[strpos(v_out, E'\n  medium 3 · low 3') > 0,                                       -- (1)
               strpos(v_out, ' more children') > 0,                                              -- (2)
               strpos(v_out, E'\n  global\n') > 0 AND strpos(v_out, E'\n  global — ') = 0,        -- (3)
               strpos(v_out, ' not listed — list_backlog') > 0,                                  -- (4)
               strpos(v_out, E'\n  doc ') = 0,                                                   -- (5) key list
               strpos(v_out, ' (resolve_context)') > 0];                                         -- (5) count
    -- cumulative and in order: the applied steps are always a prefix of (1)..(5)
    PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM generate_series(2, 6) g WHERE m[g] AND NOT m[g - 1]),
                          'h steps applied out of order at ' || v_b || ': ' || m::text);
    FOR v_k IN 1..6 LOOP
      PERFORM pg_temp.check(NOT (v_seen[v_k] AND NOT m[v_k]), 'h step ' || v_k || ' undone at ' || v_b);
      v_seen[v_k] := v_seen[v_k] OR m[v_k];
    END LOOP;
    IF strpos(v_out, E'\n  +1 more children\n') > 0 AND strpos(v_out, E'\n  k4 — ') > 0 AND strpos(v_out, E'\n  k5 — ') = 0 THEN
      v_child_one := true;
    END IF;
    IF strpos(v_out, E'\n  +1 untriaged not listed — list_backlog') > 0 AND strpos(v_out, 'untriaged item 1') > 0 THEN
      v_untriaged_one := true;
    END IF;
    IF m[2] THEN
      PERFORM pg_temp.check(strpos(v_out, E'\n  medium 3 · low 3') > 0 AND strpos(v_out, 'medium item') = 0, 'h (1) stays applied');
    END IF;
    EXIT WHEN length(v_out) - 1 < 500 OR m[6];
    v_b := length(v_out) - 1;
  END LOOP;
  PERFORM pg_temp.check(v_seen = ARRAY[true, true, true, true, true, true], 'h every step observed above 500: ' || v_seen::text);
  PERFORM pg_temp.check(v_child_one AND v_untriaged_one, 'h children and listed lines dropped from the end one at a time');
  PERFORM pg_temp.check(strpos(v_out, E'\n  +5 more children\n') > 0
                        AND strpos(v_out, E'\n  +2 critical, +2 high, +2 untriaged not listed — list_backlog\n  medium 3 · low 3') > 0
                        AND strpos(v_out, E'\n  docs: ' || (cardinality(pg_temp.global_docs()) + 3) || E' (resolve_context)\nCHILDREN') > 0,
                        E'h most trimmed form:\n' || v_out);
  RAISE NOTICE 'ok   h budget: % renders from 1000000 down to %; steps (1)-(5) observed in order and cumulative', v_n, v_b;

  FOREACH v_k IN ARRAY ARRAY[500, 1000, 4000] LOOP
    FOREACH v_bad IN ARRAY ARRAY['global.t0036h', 'global.t0036g', 'global.t0036d', 'global.t0036e.leaf', 'global.t0036f', 'global'] LOOP
      v_out := ops.node_overview(v_bad::public.ltree, v_k);
      PERFORM pg_temp.check(length(v_out) <= v_k, 'h length of ' || v_bad || ' at ' || v_k || ': ' || length(v_out));
    END LOOP;
  END LOOP;
  PERFORM pg_temp.check(ops.node_overview('global.t0036h') = ops.node_overview('global.t0036h', 4000), 'h default budget is 4000');

  -- a next_step longer than the budget: the most trimmed form, next_step in full
  v_next := 'T0036 X ' || repeat('N', 600);
  v_s := pg_temp.closed('global.t0036x', '2026-03-01 00:00+00', v_next);
  PERFORM pg_temp.item('global.t0036x', 'critical', 'T0036 X critical', 1);
  PERFORM pg_temp.item('global.t0036x', 'medium', 'T0036 X medium', 1);
  v_out := ops.node_overview('global.t0036x', 500);
  PERFORM pg_temp.check(v_out = array_to_string(ARRAY['NODE global.t0036x (node) — T0036 X.', 'CONTEXT', '  global']
                                                || CASE WHEN cardinality(pg_temp.global_docs()) > 0
                                                        THEN ARRAY['  docs: ' || cardinality(pg_temp.global_docs()) || ' (resolve_context)']
                                                        ELSE '{}'::text[] END
                                                || ARRAY['CHILDREN', '  +1 more children',
                                                         'NEXT STEP (' || left(v_s::text, 8) || ', closed 2026-03-01 00:00 UTC)', v_next,
                                                         'BACKLOG (open, subtree)', '  +1 critical not listed — list_backlog', '  medium 1'], E'\n'),
                        E'h over-budget next_step, most trimmed form:\n' || v_out);
  RAISE NOTICE 'ok   h lengths within 500 / 1000 / 4000 on six nodes; default 4000; next_step over budget returns the most trimmed form (% chars)', length(v_out);
END $$;

ROLLBACK;

-- i. no leftover rows; the dropped constraint is back
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'nodes', (SELECT count(*) FROM ops.nodes), 'projects', (SELECT count(*) FROM ops.projects),
    'sessions', (SELECT count(*) FROM ops.sessions), 'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions),
    'doc_types', (SELECT count(*) FROM ops.doc_types)))
     <> current_setting('ops_test.counts_before')::jsonb
     OR EXISTS (SELECT 1 FROM ops.nodes WHERE path::text LIKE 'global.t0036%')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.context_documents'::regclass
                       AND conname = 'context_documents_node_id_doc_key_key') THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   i no leftover rows; UNIQUE (node_id, doc_key) present; 0036 tests passed';
END $$;
