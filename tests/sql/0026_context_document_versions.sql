-- tests/sql/0026_context_document_versions.sql
-- Tests for migrations/0026_context_document_versions.sql. Run as the schema owner against a non-production
-- database where 0026 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0026_context_document_versions.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file creates its own node under the global node (as tests/sql/0008 block 5
-- does) and asserts only on the documents it creates on it (plus catalog state 0026 establishes).

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
    'nodes', (SELECT count(*) FROM ops.nodes), 'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions)))::text, false);
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

CREATE FUNCTION pg_temp.ver(p_doc uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT version FROM ops.context_documents WHERE id = p_doc;
$$;

CREATE FUNCTION pg_temp.nver(p_doc uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.document_versions WHERE document_id = p_doc;
$$;

-- 0. fixture: a node of its own under the global node
DO $$
DECLARE v_node uuid;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0026-doc', 'node', 't0026-doc') RETURNING id INTO v_node;
  PERFORM set_config('ops_test.node', v_node::text, true);
  RAISE NOTICE 'ok   0 fixture (node global.t0026-doc)';
END $$;

-- a. catalog 0026 establishes (bounded: asserted while 0026 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text; v_fn text; v_grantees text[];
BEGIN
  IF NOT (newest >= '0026' AND newest < '0027') THEN
    RAISE NOTICE 'skip a catalog of 0026 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  FOREACH v_fn IN ARRAY ARRAY['ops._doc_version_set()', 'ops._doc_version_record()'] LOOP
    PERFORM pg_temp.check((SELECT NOT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                                  AND prorettype = 'trigger'::regtype AND pg_get_userbyid(proowner) = v_owner
                             FROM pg_proc WHERE oid = to_regprocedure(v_fn)),
                          v_fn || ': SECURITY INVOKER trigger function, search_path ops, pg_temp, owner of ops');
    SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END), '{}')
      INTO v_grantees
      FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn::regprocedure AND a.grantee <> p.proowner;
    PERFORM pg_temp.check(v_grantees = '{}'::text[]
                          AND NOT has_function_privilege('ops_executor', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('ops_planner', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('public', v_fn, 'EXECUTE'),
                          v_fn || ' owner-only, grantees ' || v_grantees::text);
    PERFORM pg_temp.check(obj_description(v_fn::regprocedure, 'pg_proc') LIKE 'Release 3 (0609bdb8): %', v_fn || ' comment');
  END LOOP;

  -- structural, not pg_get_triggerdef text (search_path-dependent); tgtype: ROW 1, BEFORE 2, INSERT 4, UPDATE 16
  PERFORM pg_temp.check((SELECT array_agg(t.tgname || ' ' || t.tgfoid || ' ' || t.tgtype || ' ' || t.tgenabled::text || ' '
                                          || coalesce((SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                                                         FROM unnest(t.tgattr::int2[]) WITH ORDINALITY k(attnum, ord)
                                                         JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attnum = k.attnum), '')
                                          ORDER BY t.tgname)
                           FROM pg_trigger t WHERE t.tgrelid = 'ops.context_documents'::regclass AND NOT t.tgisinternal)
                        = ARRAY['context_documents_component_scope ' || 'ops._component_scope()'::regprocedure::oid || ' 23 O component_id,project_id,node_id',
                                'context_documents_version_record ' || 'ops._doc_version_record()'::regprocedure::oid || ' 21 O ',
                                'context_documents_version_set ' || 'ops._doc_version_set()'::regprocedure::oid || ' 23 O '],
                        'exactly three triggers on context_documents (component scope unchanged; version set BEFORE, version record AFTER, INSERT OR UPDATE, each row)');
  PERFORM pg_temp.check((SELECT bool_and(obj_description(oid, 'pg_trigger') LIKE 'Release 3 (0609bdb8): %') AND count(*) = 2
                           FROM pg_trigger WHERE tgrelid = 'ops.context_documents'::regclass
                            AND tgname IN ('context_documents_version_set', 'context_documents_version_record')),
                        'version trigger comments');

  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'record_gate',
                                'resolve_context', 'tick'],
                        'ops_executor EXECUTE set unchanged');
  RAISE NOTICE 'ok   a catalog: trigger functions invoker and owner-only; three triggers; comments; executor set';
END $$;

-- b. insert stores version 1 and exactly one addition row copied from the document
DO $$
DECLARE v_doc uuid; d ops.document_versions;
BEGIN
  INSERT INTO ops.context_documents (doc_key, title, content, summary, node_id, doc_type, trust_status)
  VALUES ('TEST_0026_B', 'b', 'body b', 'sum b', pg_temp.id('node'), 'manual', 'draft') RETURNING id INTO v_doc;
  PERFORM set_config('ops_test.b', v_doc::text, true);
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 1, 'b stored version 1');
  PERFORM pg_temp.check(pg_temp.nver(v_doc) = 1, 'b exactly one document_versions row');
  SELECT * INTO d FROM ops.document_versions WHERE document_id = v_doc;
  PERFORM pg_temp.check(d.version = 1 AND d.change_kind = 'addition' AND d.content = 'body b' AND d.summary = 'sum b'
                        AND d.trust_status = 'draft' AND d.changed_by_session IS NULL AND d.changed_by_dispatch IS NULL
                        AND d.source_decision_ids = '{}'::uuid[],
                        'b row: version 1, addition, content/summary/trust_status copied, session/dispatch NULL, sources {}');
  RAISE NOTICE 'ok   b insert: version 1, one addition row';
END $$;

-- c. an explicit version on insert is overwritten (a second node of its own: UNIQUE (node_id, doc_type))
DO $$
DECLARE v_node uuid; v_doc uuid;
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0026-doc-c', 'node', 't0026-doc-c') RETURNING id INTO v_node;
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, version)
  VALUES ('TEST_0026_C', 'c', 'body c', v_node, 'manual', 5) RETURNING id INTO v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 1, 'c explicit version 5 stored as 1, got ' || pg_temp.ver(v_doc));
  PERFORM pg_temp.check(pg_temp.nver(v_doc) = 1
                        AND EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 1),
                        'c one row at version 1');
  RAISE NOTICE 'ok   c explicit version on insert overwritten with 1';
END $$;

-- d. updates that change no versioned column keep the version and add no row
DO $$
DECLARE v_doc uuid := pg_temp.id('b');
BEGIN
  UPDATE ops.context_documents SET title = 'b renamed' WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 1 AND pg_temp.nver(v_doc) = 1, 'd title-only update: version 1, one row');
  UPDATE ops.context_documents SET content = content WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 1 AND pg_temp.nver(v_doc) = 1, 'd content set to itself: version 1, one row');
  UPDATE ops.context_documents SET use_count = 3, last_used_at = now(), doc_key = 'TEST_0026_B2' WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 1 AND pg_temp.nver(v_doc) = 1, 'd usage / doc_key update: version 1, one row');
  RAISE NOTICE 'ok   d non-versioned updates keep the version, no new row';
END $$;

-- e. content, trust_status and summary each bump the version by one with one update row
DO $$
DECLARE v_doc uuid := pg_temp.id('b'); d ops.document_versions;
BEGIN
  UPDATE ops.context_documents SET content = 'body b v2' WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 2 AND pg_temp.nver(v_doc) = 2, 'e content: version 2, two rows');
  SELECT * INTO d FROM ops.document_versions WHERE document_id = v_doc AND version = 2;
  PERFORM pg_temp.check(d.change_kind = 'update' AND d.content = 'body b v2' AND d.summary = 'sum b' AND d.trust_status = 'draft',
                        'e version 2 row: update with the new content');
  UPDATE ops.context_documents SET trust_status = 'approved' WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 3 AND pg_temp.nver(v_doc) = 3
                        AND EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 3
                                       AND change_kind = 'update' AND trust_status = 'approved'),
                        'e trust_status: version 3');
  UPDATE ops.context_documents SET summary = NULL WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 4 AND pg_temp.nver(v_doc) = 4
                        AND EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 4
                                       AND change_kind = 'update' AND summary IS NULL AND content = 'body b v2'),
                        'e summary (to NULL): version 4');
  RAISE NOTICE 'ok   e content / trust_status / summary each bump by one with an update row';
END $$;

-- f. a direct write to version alone is overwritten: no bump, no row
DO $$
DECLARE v_doc uuid := pg_temp.id('b');
BEGIN
  UPDATE ops.context_documents SET version = 99 WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 4 AND pg_temp.nver(v_doc) = 4, 'f version = 99 alone: stays 4, no new row');
  RAISE NOTICE 'ok   f direct version write overwritten';
END $$;

-- g. a direct version write together with a content change: current + 1
DO $$
DECLARE v_doc uuid := pg_temp.id('b');
BEGIN
  UPDATE ops.context_documents SET content = 'body b v5', version = 99 WHERE id = v_doc;
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 5 AND pg_temp.nver(v_doc) = 5
                        AND EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 5
                                       AND change_kind = 'update' AND content = 'body b v5')
                        AND NOT EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 99),
                        'g content + version 99: version 5');
  PERFORM pg_temp.check((SELECT array_agg(version ORDER BY version) FROM ops.document_versions WHERE document_id = v_doc)
                        = ARRAY[1, 2, 3, 4, 5], 'g history is 1..5 with no gap');
  RAISE NOTICE 'ok   g version write with a content change: current + 1';
END $$;

-- h. a document with history cannot be deleted (history kept)
DO $$
DECLARE v_doc uuid := pg_temp.id('b'); e text;
BEGIN
  e := pg_temp.err(format('DELETE FROM ops.context_documents WHERE id = %L', v_doc));
  PERFORM pg_temp.check(e LIKE '23503 %', 'h delete refused 23503, got ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.ver(v_doc) = 5 AND pg_temp.nver(v_doc) = 5, 'h document and history kept');
  RAISE NOTICE 'ok   h delete of a document with history refused 23503';
END $$;

ROLLBACK;

-- i. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'nodes', (SELECT count(*) FROM ops.nodes), 'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   i no leftover rows; 0026 tests passed';
END $$;
