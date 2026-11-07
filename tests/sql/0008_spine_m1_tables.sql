-- tests/sql/0008_spine_m1_tables.sql
-- Tests for migrations/0008_spine_m1_tables.sql. Run as the schema owner against a non-production
-- database where 0008 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0008_spine_m1_tables.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree types,
-- operators and functions must be reached schema-qualified.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in session settings so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.nodes_before', (SELECT count(*) FROM ops.nodes)::text, false),
          set_config('ops_test.findings_before', (SELECT count(*) FROM ops.findings)::text, false),
          set_config('ops_test.sessions_before', (SELECT count(*) FROM ops.sessions)::text, false),
          set_config('ops_test.dispatches_before', (SELECT count(*) FROM ops.dispatches)::text, false),
          set_config('ops_test.decisions_before', (SELECT count(*) FROM ops.decisions)::text, false);
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

CREATE FUNCTION pg_temp.rejects(p_sql text, p_state text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  IF e IS NULL OR e NOT LIKE p_state || ' %' THEN
    RAISE EXCEPTION 'FAIL: % (expected %, got %)', p_what, p_state, coalesce(e, 'success');
  END IF;
END $$;

CREATE FUNCTION pg_temp.node(p_parent text, p_key text, p_kind ops.node_kind DEFAULT 'node')
RETURNS ops.nodes LANGUAGE sql AS $$
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path OPERATOR(public.=) p_parent::public.ltree), p_key, p_kind, p_key)
  RETURNING *;
$$;

-- 1. extensions in public; ltree operators and functions work schema-qualified
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT count(*) FROM pg_extension
                          WHERE extname IN ('ltree', 'pg_trgm') AND extnamespace = 'public'::regnamespace) = 2,
                        'ltree and pg_trgm installed in public');
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  PERFORM pg_temp.check('a.b.c'::public.ltree OPERATOR(public.<@) 'a.b'::public.ltree, '<@ qualified');
  PERFORM pg_temp.check(public.nlevel('a.b.c'::public.ltree) = 3, 'nlevel qualified');
  PERFORM pg_temp.check(('a'::public.ltree OPERATOR(public.||) 'b'::public.ltree)::text = 'a.b', '|| qualified');
  PERFORM pg_temp.check('a.b'::public.ltree OPERATOR(public.@>) 'a.b.c'::public.ltree, '@> qualified');
  PERFORM pg_temp.check('a.b'::public.ltree OPERATOR(public.=) 'a.b'::public.ltree
                        AND 'a.b'::public.ltree OPERATOR(public.<>) 'a.c'::public.ltree, '= and <> qualified');
  PERFORM pg_temp.check('a.b.c'::public.ltree OPERATOR(public.~) 'a.*'::public.lquery, '~ qualified');
  PERFORM pg_temp.check(public.subpath('a.b.c'::public.ltree, 1)::text = 'b.c', 'subpath qualified');
  PERFORM pg_temp.check(public.similarity('spine', 'spines') > 0.5, 'pg_trgm similarity qualified');
  PERFORM pg_temp.check('spine' OPERATOR(public.%) 'spines', 'pg_trgm % qualified');
  PERFORM pg_temp.check(pg_temp.err($q$SELECT 'a'::public.ltree = 'a'::public.ltree$q$) LIKE '42883 %',
                        'unqualified ltree = fails on this search_path (why 0008 compares paths as text)');
  RAISE NOTICE 'ok   1 extensions and qualified ltree operators';
END $$;

-- 2. paths and tree rules
DO $$
DECLARE g ops.nodes; p ops.nodes; n ops.nodes; a ops.nodes;
BEGIN
  -- reuse the global node when one exists (0010 creates it); otherwise create it here
  SELECT * INTO g FROM ops.nodes WHERE kind = 'global';
  IF FOUND THEN
    PERFORM set_config('ops_test.global_created', '0', true);
    -- a supplied path is still overwritten with the key: the clash is on the path, not on the one-global index
    PERFORM pg_temp.check(pg_temp.err($q$INSERT INTO ops.nodes (key, kind, title, path) VALUES ('global', 'global', 'Global', 'ignored')$q$)
                          LIKE '23505 %"nodes_path_key"%', 'second global with supplied path clashes on path global');
  ELSE
    PERFORM set_config('ops_test.global_created', '1', true);
    INSERT INTO ops.nodes (key, kind, title, path) VALUES ('global', 'global', 'Global', 'ignored')
    RETURNING * INTO g;
  END IF;
  PERFORM pg_temp.check(g.path::text = 'global', 'global path is its key: ' || g.path::text);
  p := pg_temp.node('global', 'p1', 'project');
  PERFORM pg_temp.check(p.path::text = 'global.p1', 'project path: ' || p.path::text);
  n := pg_temp.node('global.p1', 'n1');
  PERFORM pg_temp.check(n.path::text = 'global.p1.n1', 'node path: ' || n.path::text);
  PERFORM pg_temp.node('global.p1.n1', 'leaf');

  PERFORM pg_temp.rejects($q$INSERT INTO ops.nodes (key, kind, title) VALUES ('global2', 'global', 'x')$q$,
                          '23505', 'second global node');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (%L, 'g2', 'global', 'x')$q$, p.id),
                          '23514', 'global with a parent');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.nodes (key, kind, title) VALUES ('orphan', 'node', 'x')$q$,
                          '23514', 'non-global without a parent');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.node('global.p1', 'p2', 'project')$q$,
                          '23514', 'project under a non-global node');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.node('global.p1', 'n1')$q$, '23505', 'duplicate sibling key');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.node('global.p1', 'Bad Key')$q$, '23514', 'key regex');

  a := pg_temp.node('global.p1', 'arch');
  UPDATE ops.nodes SET status = 'archived', title = 'archived' WHERE id = a.id;   -- status/title may change
  PERFORM pg_temp.rejects($q$SELECT pg_temp.node('global.p1.arch', 'child')$q$, '23514', 'child under archived parent');
  PERFORM pg_temp.check(pg_temp.err($q$SELECT pg_temp.node('global', 'p3', 'project')$q$) IS NULL,
                        'second project under global allowed');

  PERFORM pg_temp.rejects(format($q$UPDATE ops.nodes SET key = 'n9' WHERE id = %L$q$, n.id), '23514', 'update key');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.nodes SET parent_id = %L WHERE id = %L$q$, g.id, n.id), '23514', 'update parent_id');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.nodes SET path = 'global.x' WHERE id = %L$q$, n.id), '23514', 'update path');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.nodes SET kind = 'project' WHERE id = %L$q$, n.id), '23514', 'update kind');
  RAISE NOTICE 'ok   2 paths and tree rules';
END $$;

-- 2b. every trigger branch under search_path = ops, pg_temp, including updates of non-guarded columns
DO $$
DECLARE n ops.nodes; f ops.findings; v_cfg text;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  SELECT string_agg(p.proname || ':' || array_to_string(p.proconfig, ','), ' ' ORDER BY p.proname) INTO v_cfg
    FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace
     AND p.proname IN ('_nodes_before_insert', '_nodes_before_update', '_findings_before_update');
  PERFORM pg_temp.check(v_cfg = '_findings_before_update:search_path=ops, pg_temp '
                                || '_nodes_before_insert:search_path=ops, pg_temp '
                                || '_nodes_before_update:search_path=ops, pg_temp', 'trigger search_path pinned: ' || v_cfg);

  -- nodes_before_insert: missing parent (the other refusals are in block 2)
  PERFORM pg_temp.rejects($q$INSERT INTO ops.nodes (parent_id, key, kind, title)
                             VALUES (gen_random_uuid(), 'ghost', 'node', 'x')$q$, '23503', 'missing parent');

  -- nodes_before_update: non-guarded columns pass, one at a time and together
  n := pg_temp.node('global.p1', 'upd');
  UPDATE ops.nodes SET title = 'renamed' WHERE id = n.id;
  UPDATE ops.nodes SET summary = 'a summary' WHERE id = n.id;
  UPDATE ops.nodes SET title = 't2', summary = NULL, status = 'archived' WHERE id = n.id;
  UPDATE ops.nodes SET status = 'active' WHERE id = n.id;
  UPDATE ops.nodes SET key = key, path = path, parent_id = parent_id, kind = kind WHERE id = n.id;  -- same values pass
  SELECT * INTO n FROM ops.nodes WHERE id = n.id;
  PERFORM pg_temp.check(n.title = 't2' AND n.summary IS NULL AND n.status = 'active'
                        AND n.path::text = 'global.p1.upd', 'non-guarded updates applied, path kept');

  -- findings_before_update: non-guarded columns pass
  INSERT INTO ops.findings (claim, evidence, claim_class) VALUES ('c2', '["e"]', 'interpretive') RETURNING * INTO f;
  UPDATE ops.findings SET last_used_at = now(), use_count = 3, last_verified_at = now(), status = 'auto_verified'
   WHERE id = f.id;
  UPDATE ops.findings SET claim = claim, evidence = evidence WHERE id = f.id;                       -- same values pass
  PERFORM pg_temp.check((SELECT use_count = 3 AND status = 'auto_verified' FROM ops.findings WHERE id = f.id),
                        'finding non-guarded update applied');
  RAISE NOTICE 'ok   2b trigger branches under ops, pg_temp';
END $$;

-- 3. subtree query
DO $$ BEGIN
  PERFORM pg_temp.check(
    (SELECT array_agg(path::text ORDER BY path) FROM ops.nodes
      WHERE path OPERATOR(public.<@) 'global.p1'::public.ltree)
    = ARRAY['global.p1', 'global.p1.arch', 'global.p1.n1', 'global.p1.n1.leaf', 'global.p1.upd'], 'subtree of global.p1');
  -- relative to the start: every pre-existing node sits under global; the test adds 6 nodes plus global if it made it
  PERFORM pg_temp.check((SELECT count(*) FROM ops.nodes WHERE path OPERATOR(public.<@) 'global'::public.ltree)
                        = current_setting('ops_test.nodes_before')::bigint + 6
                          + current_setting('ops_test.global_created')::int,
                        'whole tree under global');
  RAISE NOTICE 'ok   3 subtree query';
END $$;

-- 4. findings
DO $$
DECLARE f ops.findings;
BEGIN
  INSERT INTO ops.findings (claim, evidence, claim_class)
  VALUES ('the sky is blue', '[{"ref": "obs"}]', 'mechanical') RETURNING * INTO f;
  PERFORM pg_temp.rejects(format($q$UPDATE ops.findings SET claim = 'changed' WHERE id = %L$q$, f.id), '23514', 'claim immutable');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.findings SET evidence = '[1]' WHERE id = %L$q$, f.id), '23514', 'evidence immutable');
  UPDATE ops.findings SET status = 'approved', use_count = use_count + 1 WHERE id = f.id;
  PERFORM pg_temp.check((SELECT status FROM ops.findings WHERE id = f.id) = 'approved', 'status update allowed');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.findings (claim, evidence, claim_class) VALUES ('c', '[]', 'mechanical')$q$,
                          '23514', 'empty evidence');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.findings (claim, evidence, claim_class) VALUES ('c', '{"a": 1}', 'mechanical')$q$,
                          '23514', 'non-array evidence');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.findings (claim, evidence, claim_class, status)
                             VALUES ('c', '[1]', 'interpretive', 'promoted')$q$, '23514', 'promoted without promoted_to');
  PERFORM pg_temp.rejects(format($q$UPDATE ops.findings SET status = 'promoted' WHERE id = %L$q$, f.id),
                          '23514', 'update to promoted without promoted_to');
  RAISE NOTICE 'ok   4 findings';
END $$;

-- 5. document_versions, session_docs, path_log (the test document sits on a node of its own, so it never meets
--    UNIQUE (node_id, doc_type) from 0011 against a real document; no project: the assertions do not depend on one)
DO $$
DECLARE v_project uuid := NULL;
        v_doc uuid; v_seg uuid; v_node uuid; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0008-doc', 'node', 't0008-doc') RETURNING id INTO v_node;
  INSERT INTO ops.context_documents (project_id, doc_key, title, content, node_id, doc_type)
  VALUES (v_project, 'TEST_0008_DOC', 'test', 'body', v_node, 'manual')
  RETURNING id INTO v_doc;
  IF newest >= '0026' THEN
    RAISE NOTICE 'skip 5 manual document_versions insert, the 0026 trigger writes version 1 (newest migration is %)', newest;
    PERFORM pg_temp.check((SELECT count(*) = 1 AND bool_and(version = 1 AND change_kind = 'addition')
                             FROM ops.document_versions WHERE document_id = v_doc),
                          'one document_versions row for the test document, version 1, addition');
  ELSE
    INSERT INTO ops.document_versions (document_id, version, content, trust_status, change_kind)
    VALUES (v_doc, 1, 'body', 'draft', 'addition');
  END IF;
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.document_versions (document_id, version, content, trust_status, change_kind)
                                    VALUES (%L, 1, 'again', 'draft', 'update')$q$, v_doc), '23505', 'duplicate document version');

  INSERT INTO ops.sessions (project_id, kind) VALUES (v_project, 'planning') RETURNING id INTO v_seg;
  INSERT INTO ops.session_docs (segment_id, version, content) VALUES (v_seg, 1, 'v1');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.session_docs (segment_id, version, content) VALUES (%L, 1, 'v1b')$q$, v_seg),
                          '23505', 'duplicate session_docs version');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.session_docs (segment_id, version, content) VALUES (%L, 0, 'v0')$q$, v_seg),
                          '23514', 'session_docs version 0');

  INSERT INTO ops.path_log (session_id, prompt_summary, proposed) VALUES (v_seg, 'p', '{}');
  INSERT INTO ops.path_log (session_id, prompt_summary, proposed, final, outcome) VALUES (v_seg, 'p', '{}', '{}', 'accepted');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.path_log (session_id, prompt_summary, proposed, outcome)
                                    VALUES (%L, 'p', '{}', 'accepted')$q$, v_seg), '23514', 'outcome without final');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.path_log (session_id, prompt_summary, proposed, final)
                                    VALUES (%L, 'p', '{}', '{}')$q$, v_seg), '23514', 'final without outcome');
  RAISE NOTICE 'ok   5 document_versions, session_docs, path_log';
END $$;

-- 6. node_links: one row per link across all four kinds (the component and finding are the block's own)
DO $$
DECLARE v_node uuid := (SELECT id FROM ops.nodes WHERE path OPERATOR(public.=) 'global.p1.n1'::public.ltree);
        c ops.components; v_cn uuid;
        v_wl uuid; v_f uuid; v_d uuid; v_x uuid; v_s uuid;
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0008-comp', 'node', 't0008-comp') RETURNING id INTO v_cn;
  INSERT INTO ops.components (key, kind, node_id) VALUES ('t0008-comp', 'test', v_cn) RETURNING * INTO c;
  INSERT INTO ops.work_log (origin, entry_type, title) VALUES ('code', 'feature', 'wl') RETURNING id INTO v_wl;
  INSERT INTO ops.findings (claim, evidence, claim_class) VALUES ('t0008 link', '["e"]', 'mechanical') RETURNING id INTO v_f;
  -- decisions and dispatches carry a session (NOT NULL from 0022)
  INSERT INTO ops.sessions (project_id, kind) VALUES (c.project_id, 'planning') RETURNING id INTO v_s;
  INSERT INTO ops.decisions (project_id, session_id, decision) VALUES (c.project_id, v_s, 'test decision') RETURNING id INTO v_d;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
  VALUES (c.project_id, c.id, 'addition', v_s, 't', 'p') RETURNING id INTO v_x;

  INSERT INTO ops.work_log_nodes (work_log_id, node_id) VALUES (v_wl, v_node);
  INSERT INTO ops.finding_nodes (finding_id, node_id) VALUES (v_f, v_node);
  INSERT INTO ops.decision_nodes (decision_id, node_id) VALUES (v_d, v_node);
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id) VALUES (v_x, v_node);

  PERFORM pg_temp.check(
    (SELECT array_agg(kind || ':' || (entry_id = CASE kind WHEN 'work_log' THEN v_wl WHEN 'finding' THEN v_f
                                                            WHEN 'decision' THEN v_d ELSE v_x END)::text ORDER BY kind)
       FROM ops.node_links WHERE node_id = v_node)
    = ARRAY['decision:true', 'dispatch:true', 'finding:true', 'work_log:true'], 'node_links one row per kind');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.work_log (origin, entry_type, title) VALUES ('code', 'nope', 'x')$q$,
                          '23503', 'unknown entry_type');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.work_log (origin, entry_type, title, follow_ups) VALUES ('code', 'fix', 'x', '{}')$q$,
                          '23514', 'follow_ups must be an array');
  RAISE NOTICE 'ok   6 node_links';
END $$;

-- 7. seeds
DO $$ BEGIN
  PERFORM pg_temp.check((SELECT array_agg(key ORDER BY key) FROM ops.entry_types WHERE created_in_session IS NULL)
                        = ARRAY['chore', 'config', 'data', 'docs', 'feature', 'fix', 'investigation', 'migration', 'refactor'],
                        'nine seeded entry_types');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.entry_types) = 9, '9 entry_types');
  PERFORM pg_temp.check((SELECT array_agg(key) FROM ops.doc_types) = ARRAY['manual'], '1 doc_type: manual');
  RAISE NOTICE 'ok   7 seeds';
END $$;

-- 8. grants
DO $$
DECLARE all_new text[] := ARRAY['ops.nodes', 'ops.doc_types', 'ops.entry_types', 'ops.document_versions', 'ops.work_log',
                                'ops.findings', 'ops.work_log_nodes', 'ops.finding_nodes', 'ops.decision_nodes',
                                'ops.dispatch_nodes', 'ops.node_links', 'ops.backlog_blocks', 'ops.node_paths',
                                'ops.path_log', 'ops.session_docs'];
        exec_reads text[] := ARRAY['ops.nodes', 'ops.doc_types', 'ops.entry_types', 'ops.node_paths'];
BEGIN
  PERFORM pg_temp.check(has_table_privilege('ops_planner', t, 'SELECT'), 'planner SELECT ' || t) FROM unnest(all_new) t;
  PERFORM pg_temp.check(has_table_privilege('ops_executor', t, 'SELECT') = (t = ANY (exec_reads)),
                        'executor SELECT ' || t || ' should be ' || (t = ANY (exec_reads)))
     FROM unnest(all_new) t;
  PERFORM pg_temp.check(NOT has_table_privilege(r, t, p), format('%s has no %s on %s', r, p, t))
     FROM unnest(ARRAY['ops_planner', 'ops_executor']) r, unnest(all_new) t,
          unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p;
  PERFORM pg_temp.check(NOT has_table_privilege('public', t, 'SELECT'), 'PUBLIC cannot SELECT ' || t) FROM unnest(all_new) t;
  PERFORM pg_temp.check(NOT has_function_privilege(r, f, 'EXECUTE'), format('%s cannot execute %s', r, f))
     FROM unnest(ARRAY['public', 'ops_planner', 'ops_executor']) r,
          unnest(ARRAY['ops._nodes_before_insert()', 'ops._nodes_before_update()', 'ops._findings_before_update()']) f;
  RAISE NOTICE 'ok   8 grants';
END $$;

-- 9. no existing table changed. The counts are the pre-0008 shape; M2 adds columns, so the check
-- applies only while 0008 is the newest applied migration.
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest <> '0008_spine_m1_tables' THEN
    RAISE NOTICE 'skip 9 column counts (newest migration is %)', newest;
    RETURN;
  END IF;
  PERFORM pg_temp.check(
    (SELECT jsonb_object_agg(table_name, n) FROM (
       SELECT table_name, count(*) AS n FROM information_schema.columns
        WHERE table_schema = 'ops'
          AND table_name IN ('sessions', 'decisions', 'backlog_items', 'context_documents', 'dispatch_types')
        GROUP BY table_name) s)
    = '{"sessions": 12, "decisions": 13, "backlog_items": 9, "context_documents": 10, "dispatch_types": 6}'::jsonb,
    'existing tables keep their column counts');
  RAISE NOTICE 'ok   9 existing tables unchanged';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.nodes) <> current_setting('ops_test.nodes_before')::bigint
     OR (SELECT count(*) FROM ops.findings) <> current_setting('ops_test.findings_before')::bigint
     OR (SELECT count(*) FROM ops.sessions) <> current_setting('ops_test.sessions_before')::bigint
     OR (SELECT count(*) FROM ops.dispatches) <> current_setting('ops_test.dispatches_before')::bigint
     OR (SELECT count(*) FROM ops.decisions) <> current_setting('ops_test.decisions_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok  10 no leftover rows; 0008 tests passed';
END $$;
