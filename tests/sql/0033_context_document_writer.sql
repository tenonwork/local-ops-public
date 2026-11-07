-- tests/sql/0033_context_document_writer.sql
-- Tests for migrations/0033_context_document_writer.sql. Run as the schema owner against a non-production database
-- where 0033 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0033_context_document_writer.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own nodes global.t0033a (with component ca, child sub and grandchild
-- sub.leaf) and global.t0033b, a session on each, its own doc types, decisions (one superseded by another) and
-- dispatches (reviewed and unreviewed); it asserts only on documents it creates, never on global counts. Grants are
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
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules), 'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog),
    'doc_types', (SELECT count(*) FROM ops.doc_types),
    'nodes', (SELECT count(*) FROM ops.nodes), 'components', (SELECT count(*) FROM ops.components),
    'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
    'dispatches', (SELECT count(*) FROM ops.dispatches)))::text, false);
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

CREATE FUNCTION pg_temp.w(p_path text, p_key text, p_type text, p_content text, p_basis text,
                          p_decs uuid[] DEFAULT NULL, p_disps uuid[] DEFAULT NULL, p_summary text DEFAULT NULL,
                          p_session uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT ops.write_doc(p_path::public.ltree, p_key, p_type, 'T ' || p_key, p_content, p_summary, p_basis, p_decs, p_disps,
                       coalesce(p_session, pg_temp.id('s')));
$$;

CREATE FUNCTION pg_temp.w_err(p_path text, p_key text, p_type text, p_title text, p_content text, p_basis text,
                              p_decs uuid[], p_disps uuid[], p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.write_doc(%L::public.ltree, %L, %L, %L, %L, NULL, %L, %L::uuid[], %L::uuid[], %L::uuid)',
                            p_path, p_key, p_type, p_title, p_content, p_basis, p_decs, p_disps, p_session));
$$;

CREATE FUNCTION pg_temp.a_err(p_path text, p_key text, p_sha text, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.approve_doc(%L::public.ltree, %L, %L, %L::uuid)', p_path, p_key, p_sha, p_session));
$$;

CREATE FUNCTION pg_temp.r_err(p_path text, p_key text, p_reason text, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.retire_doc(%L::public.ltree, %L, %L, %L::uuid)', p_path, p_key, p_reason, p_session));
$$;

CREATE FUNCTION pg_temp.res_err(p_path text, p_ref text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.resolve_context(%L::public.ltree, %L)', p_path, p_ref));
$$;

CREATE FUNCTION pg_temp.doc(p_path text, p_key text) RETURNS ops.context_documents LANGUAGE sql AS $$
  SELECT cd.* FROM ops.context_documents cd JOIN ops.nodes n ON n.id = cd.node_id
   WHERE n.path::text = p_path AND cd.doc_key = p_key;
$$;

CREATE FUNCTION pg_temp.nver(p_doc uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.document_versions WHERE document_id = p_doc;
$$;

CREATE FUNCTION pg_temp.ver(p_doc uuid, p_version integer) RETURNS ops.document_versions LANGUAGE sql AS $$
  SELECT * FROM ops.document_versions WHERE document_id = p_doc AND version = p_version;
$$;

CREATE FUNCTION pg_temp.sha(p_text text) RETURNS text LANGUAGE sql AS $$
  SELECT encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;

CREATE FUNCTION pg_temp.ndocs() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.context_documents cd JOIN ops.nodes n ON n.id = cd.node_id
   WHERE n.path OPERATOR(public.<@) 'global.t0033a'::public.ltree OR n.path OPERATOR(public.<@) 'global.t0033b'::public.ltree;
$$;

-- 0. fixtures
DO $$
DECLARE c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0033a', 'node', 'T0033 A'),
         ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0033b', 'node', 'T0033 B');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0033a'), 'sub', 'node', 'T0033 sub');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global.t0033a.sub'), 'leaf', 'node', 'T0033 leaf');
  c := ops.create_component('global.t0033a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  INSERT INTO ops.doc_types (key, label, description) VALUES
    ('t0033_b', 't0033 b', 't0033 test doc type b'), ('t0033_c', 't0033 c', 't0033 test doc type c');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0033a'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.sb', ops.open_session(p_node_path => 'global.t0033b'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.dec', (ops.log_decision(p_node_path => 'global.t0033a'::public.ltree,
    p_decision => 't0033 decision', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.dec_old', (ops.log_decision(p_node_path => 'global.t0033a'::public.ltree,
    p_decision => 't0033 old decision', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.dec_new', (ops.log_decision(p_node_path => 'global.t0033a'::public.ltree,
    p_decision => 't0033 new decision', p_supersedes => pg_temp.id('dec_old'), p_session => pg_temp.id('s'))).id::text, true);
  -- dispatches: reviewed done / failed / refused_premise; unreviewed done; pending with reviewed_at set
  PERFORM set_config('ops_test.d_done', (ops.create_dispatch(p_node_path => 'global.t0033a.ca'::public.ltree,
    p_dispatch_type => 'modification', p_title => 't0033 done', p_prompt => 'p', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.d_failed', (ops.create_dispatch(p_node_path => 'global.t0033a.ca'::public.ltree,
    p_dispatch_type => 'modification', p_title => 't0033 failed', p_prompt => 'p', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.d_refused', (ops.create_dispatch(p_node_path => 'global.t0033a.ca'::public.ltree,
    p_dispatch_type => 'modification', p_title => 't0033 refused', p_prompt => 'p', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.d_unrev', (ops.create_dispatch(p_node_path => 'global.t0033a.ca'::public.ltree,
    p_dispatch_type => 'modification', p_title => 't0033 unreviewed', p_prompt => 'p', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.d_pend', (ops.create_dispatch(p_node_path => 'global.t0033a.ca'::public.ltree,
    p_dispatch_type => 'modification', p_title => 't0033 pending', p_prompt => 'p', p_session => pg_temp.id('s'))).id::text, true);
  UPDATE ops.dispatches SET status = 'done', claimed_at = now(), completed_at = now(), reviewed_at = now()
   WHERE id = pg_temp.id('d_done');
  UPDATE ops.dispatches SET status = 'failed', claimed_at = now(), completed_at = now(), reviewed_at = now()
   WHERE id = pg_temp.id('d_failed');
  UPDATE ops.dispatches SET status = 'refused_premise', claimed_at = now(), completed_at = now(), reviewed_at = now()
   WHERE id = pg_temp.id('d_refused');
  UPDATE ops.dispatches SET status = 'done', claimed_at = now(), completed_at = now() WHERE id = pg_temp.id('d_unrev');
  UPDATE ops.dispatches SET reviewed_at = now() WHERE id = pg_temp.id('d_pend');
  RAISE NOTICE 'ok   0 fixtures (global.t0033a/ca/sub/leaf, global.t0033b, sessions, doc types, decisions, dispatches)';
END $$;

-- a. catalog 0033 establishes (bounded: asserted while 0033 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text; v_fn regprocedure;
BEGIN
  IF NOT (newest >= '0033' AND newest < '0034') THEN
    RAISE NOTICE 'skip a catalog of 0033 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  -- catalog text is rendered with schema-qualified names: no ops on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);

  PERFORM pg_temp.check((SELECT array_agg(c.relname || ': ' || x.cols ORDER BY c.relname) FROM pg_class c
                           CROSS JOIN LATERAL (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
                                                                 || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END, ', ' ORDER BY a.attnum) AS cols
                                                 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) x
                          WHERE c.oid IN ('ops.context_documents'::regclass, 'ops.document_versions'::regclass))
                        = ARRAY[
    'context_documents: id uuid not null, project_id uuid, component_id uuid, doc_key text not null, title text not null, content text not null, summary text, version integer not null, provenance ops.provenance not null, updated_at timestamp with time zone not null, node_id uuid not null, doc_type text not null, trust_status ops.trust_status not null, reviewed_at timestamp with time zone, stale_since timestamp with time zone, use_count integer, last_used_at timestamp with time zone, retired_at timestamp with time zone, retired_reason text, retired_by_session uuid',
    'document_versions: id bigint not null, document_id uuid not null, version integer not null, content text not null, summary text, trust_status ops.trust_status not null, change_kind ops.change_kind not null, source_decision_ids uuid[] not null, changed_at timestamp with time zone not null, changed_by_session uuid, changed_by_dispatch uuid, basis text, source_dispatch_ids uuid[] not null'],
                        'a columns of context_documents and document_versions');
  PERFORM pg_temp.check((SELECT pg_get_expr(adbin, adrelid) FROM pg_attrdef WHERE adrelid = 'ops.document_versions'::regclass
                           AND adnum = (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.document_versions'::regclass
                                          AND attname = 'source_dispatch_ids')) = '''{}''::uuid[]',
                        'a source_dispatch_ids defaults to {}');
  PERFORM pg_temp.check((SELECT array_agg(conrelid::regclass::text || ' ' || conname || ' ' || pg_get_constraintdef(oid)
                                          ORDER BY conrelid::regclass::text, conname)
                           FROM pg_constraint WHERE conrelid IN ('ops.context_documents'::regclass, 'ops.document_versions'::regclass)
                            AND contype IN ('c', 'f', 'p', 'u'))
                        = ARRAY[
    'ops.context_documents context_documents_component_id_fkey FOREIGN KEY (component_id) REFERENCES ops.components(id)',
    'ops.context_documents context_documents_doc_key_check CHECK ((doc_key ~ ''^[A-Z0-9_]+$''::text))',
    'ops.context_documents context_documents_doc_type_fkey FOREIGN KEY (doc_type) REFERENCES ops.doc_types(key)',
    'ops.context_documents context_documents_node_id_doc_key_key UNIQUE (node_id, doc_key)',
    'ops.context_documents context_documents_node_id_doc_type_key UNIQUE (node_id, doc_type)',
    'ops.context_documents context_documents_node_id_fkey FOREIGN KEY (node_id) REFERENCES ops.nodes(id)',
    'ops.context_documents context_documents_pkey PRIMARY KEY (id)',
    'ops.context_documents context_documents_project_id_fkey FOREIGN KEY (project_id) REFERENCES ops.projects(id)',
    'ops.context_documents context_documents_retired CHECK ((((retired_at IS NULL) AND (retired_reason IS NULL) AND (retired_by_session IS NULL)) OR ((retired_at IS NOT NULL) AND (retired_reason IS NOT NULL) AND (retired_by_session IS NOT NULL) AND (length(btrim(retired_reason)) > 0))))',
    'ops.context_documents context_documents_retired_by_session_fkey FOREIGN KEY (retired_by_session) REFERENCES ops.sessions(id)',
    'ops.context_documents context_documents_use_count_check CHECK ((use_count >= 0))',
    'ops.document_versions document_versions_basis_check CHECK ((basis = ANY (ARRAY[''derived''::text, ''review''::text])))',
    'ops.document_versions document_versions_changed_by_dispatch_fkey FOREIGN KEY (changed_by_dispatch) REFERENCES ops.dispatches(id)',
    'ops.document_versions document_versions_changed_by_session_fkey FOREIGN KEY (changed_by_session) REFERENCES ops.sessions(id)',
    'ops.document_versions document_versions_document_id_fkey FOREIGN KEY (document_id) REFERENCES ops.context_documents(id)',
    'ops.document_versions document_versions_document_id_version_key UNIQUE (document_id, version)',
    'ops.document_versions document_versions_pkey PRIMARY KEY (id)',
    'ops.document_versions document_versions_source_dispatch_ids_check CHECK ((array_position(source_dispatch_ids, NULL::uuid) IS NULL))'],
                        'a constraints of context_documents and document_versions');
  PERFORM pg_temp.check((SELECT bool_and(col_description('ops.context_documents'::regclass, attnum) LIKE 'Writer release (f80bbc60): %')
                           FROM pg_attribute WHERE attrelid = 'ops.context_documents'::regclass
                            AND attname IN ('retired_at', 'retired_reason', 'retired_by_session')),
                        'a comments of the retired_* columns');

  -- functions
  PERFORM pg_temp.check((SELECT array_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') '
                                          || pg_get_function_result(p.oid) || ' ' || p.provolatile::text ORDER BY p.proname)
                           FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace
                            AND p.proname IN ('write_doc', 'approve_doc', 'retire_doc', '_doc_session', '_doc_attribution',
                                              'resolve_context', '_doc_version_record', '_doc_version_set'))
                        = ARRAY[
    '_doc_attribution(p_session uuid, p_basis text, p_decision_ids uuid[], p_dispatch_ids uuid[]) void v',
    '_doc_session(p_session uuid, p_node_path public.ltree) ops.nodes s',
    '_doc_version_record() trigger v',
    '_doc_version_set() trigger v',
    'approve_doc(p_node_path public.ltree, p_doc_key text, p_content_sha256 text, p_session uuid) jsonb v',
    'resolve_context(p_node_path public.ltree, p_ref text) text s',
    'retire_doc(p_node_path public.ltree, p_doc_key text, p_reason text, p_session uuid) jsonb v',
    'write_doc(p_node_path public.ltree, p_doc_key text, p_doc_type text, p_title text, p_content text, p_summary text, p_basis text, p_decision_ids uuid[], p_dispatch_ids uuid[], p_session uuid) jsonb v'],
                        'a function signatures, results and volatility');
  FOREACH v_fn IN ARRAY ARRAY['ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid)'::regprocedure,
                              'ops.approve_doc(public.ltree, text, text, uuid)', 'ops.retire_doc(public.ltree, text, text, uuid)'] LOOP
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                  AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
                                  AND obj_description(oid, 'pg_proc') LIKE 'Writer release (f80bbc60, 9f324853, da0592ad): %'
                             FROM pg_proc WHERE oid = v_fn), 'a secdef, search_path, owner, language, comment of ' || v_fn::text);
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                             FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner)
                          = ARRAY['ops_planner'], 'a ACL owner plus ops_planner on ' || v_fn::text);
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['ops._doc_session(uuid, public.ltree)'::regprocedure, 'ops._doc_attribution(uuid, text, uuid[], uuid[])'] LOOP
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                  AND proacl IS NOT NULL FROM pg_proc WHERE oid = v_fn)
                          AND NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner),
                          'a helper owner-only: ' || v_fn::text);
  END LOOP;
  PERFORM pg_temp.check(obj_description('ops.approve_doc(public.ltree, text, text, uuid)'::regprocedure, 'pg_proc')
                        LIKE '%only after the operator''s explicit yes naming the doc_key and content sha256 (rule doc_approval)%',
                        'a approve_doc comment names the operator''s yes and the sha256');
  PERFORM pg_temp.check((SELECT NOT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') LIKE 'Writer release (f80bbc60): %'
                                AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee <> proowner)
                           FROM pg_proc WHERE oid = 'ops._doc_version_record()'::regprocedure),
                        'a _doc_version_record: owner-only SECURITY INVOKER, Writer release comment');
  PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                AND obj_description(oid, 'pg_proc') = 'Writer release (f80bbc60): node-keyed resolve_context; nearest ancestor-or-self unretired document wins; serves the newest approved version.'
                           FROM pg_proc WHERE oid = 'ops.resolve_context(public.ltree, text)'::regprocedure)
                        AND (SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                               FROM pg_proc p, aclexplode(p.proacl) a
                              WHERE p.oid = 'ops.resolve_context(public.ltree, text)'::regprocedure AND a.grantee <> p.proowner)
                            = ARRAY['ops_executor', 'ops_planner'],
                        'a resolve_context: secdef, search_path, owner, comment, ACL executor and planner');

  -- rules, changelog 12, investigation execution rules
  PERFORM pg_temp.check((SELECT version = 1 AND value = jsonb_build_object('rule',
    'Context documents change only through write_doc, approve_doc and retire_doc. write_doc with basis derived lands a document approved without an operator gate, and is used only when every claim in the change traces to a logged, non-superseded decision or to concrete evidence (a reviewed dispatch report, later an evidence-backed mechanical finding), named as source ids. Basis review lands a draft and is required for a change that alters how something works rather than adding to it, an interpretive claim no source states, or content with no traceable source; the planner calls approve_doc only after the operator''s explicit yes naming the doc_key and content sha256 (one yes may name several). retire_doc needs the operator''s explicit yes unless a logged decision names the retirement. resolve_context serves the newest approved version of the nearest unretired document.')
                           FROM ops.protocol_rules WHERE key = 'doc_approval'), 'a rule doc_approval v1 text');
  PERFORM pg_temp.check((SELECT version = 2 AND value = '{"rule": "Active sessions older than this are auto-closed as stale when a new session opens on the same node.", "hours": 12}'::jsonb
                           FROM ops.protocol_rules WHERE key = 'session_stale_after'), 'a rule session_stale_after v2');
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) = 12
                        AND (SELECT count(*) FROM ops.protocol_changelog WHERE version = 12) = 1
                        AND EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 12
                                       AND rule_keys = ARRAY['doc_approval', 'session_stale_after']
                                       AND changes = 'doc_approval v1: derived writes land approved with source ids, review writes need the operator''s yes through approve_doc (sha256-bound), retire_doc gated unless a decision names it; session_stale_after v2: stale sessions close per node. Investigation queries allow resolve_context (decisions f80bbc60, 9f324853, da0592ad, e1b36a09).'),
                        'a protocol_changelog version 12');
  PERFORM pg_temp.check((SELECT execution_rules FROM ops.dispatch_types WHERE type = 'investigation')
                        = '{"phases": ["read", "analyse", "report"], "writes": "none (report only)", "queries": "executor queue tools (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type) plus resolve_context for read-first context; no other database queries"}'::jsonb,
                        'a investigation execution_rules');
  PERFORM set_config('search_path', 'ops, pg_temp', true);
  RAISE NOTICE 'ok   a catalog: columns, constraints, writers, helpers, trigger function, resolve_context, rules, changelog 12, investigation rules';
END $$;

-- b. grants (always asserted): planner executes the writers, writes no table; executor and PUBLIC get nothing
DO $$
DECLARE v_fn text; v_bad text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid)',
                              'ops.approve_doc(public.ltree, text, text, uuid)', 'ops.retire_doc(public.ltree, text, text, uuid)'] LOOP
    PERFORM pg_temp.check(has_function_privilege('ops_planner', v_fn, 'EXECUTE'), 'b planner EXECUTE on ' || v_fn);
    PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', v_fn, 'EXECUTE'), 'b executor no EXECUTE on ' || v_fn);
    PERFORM pg_temp.check(NOT has_function_privilege('public', v_fn, 'EXECUTE'), 'b PUBLIC no EXECUTE on ' || v_fn);
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['ops._doc_session(uuid, public.ltree)', 'ops._doc_attribution(uuid, text, uuid[], uuid[])',
                              'ops._doc_version_record()'] LOOP
    PERFORM pg_temp.check(NOT has_function_privilege('ops_planner', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('ops_executor', v_fn, 'EXECUTE')
                          AND NOT has_function_privilege('public', v_fn, 'EXECUTE'), 'b owner-only ' || v_fn);
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
     AND (has_table_privilege('ops_planner', c.oid, p) OR has_table_privilege('ops_executor', c.oid, p));
  PERFORM pg_temp.check(v_bad IS NULL, 'b no table writes for ops_planner or ops_executor: ' || coalesce(v_bad, ''));
  RAISE NOTICE 'ok   b grants: planner EXECUTE on three writers; executor and PUBLIC none; executor sets unchanged; no table writes';
END $$;

-- c. write_doc
DO $$
DECLARE s uuid := pg_temp.id('s'); sb uuid := pg_temp.id('sb'); dec uuid := pg_temp.id('dec'); j jsonb; d ops.context_documents;
        v ops.document_versions; v_n bigint; v_x uuid := gen_random_uuid(); e text;
BEGIN
  -- create derived (decision source)
  j := pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', 'one', 'derived', ARRAY[dec]);
  d := pg_temp.doc('global.t0033a', 'T0033_ONE');
  PERFORM pg_temp.check(j = jsonb_build_object('id', d.id, 'version', 1, 'trust_status', 'approved', 'created', true,
                                               'reactivated', false, 'content_sha256', pg_temp.sha('one')),
                        'c derived create result: ' || j::text);
  PERFORM pg_temp.check(d.trust_status = 'approved' AND d.title = 'T T0033_ONE' AND d.project_id IS NULL AND d.component_id IS NULL
                        AND d.doc_type = 'manual' AND d.retired_at IS NULL, 'c derived create row');
  v := pg_temp.ver(d.id, 1);
  PERFORM pg_temp.check(v.change_kind = 'addition' AND v.basis = 'derived' AND v.changed_by_session = s
                        AND v.source_decision_ids = ARRAY[dec] AND v.source_dispatch_ids = '{}' AND v.changed_by_dispatch IS NULL
                        AND v.trust_status = 'approved' AND v.content = 'one', 'c derived version row attribution');
  PERFORM pg_temp.check(current_setting('ops_doc.session') = '' AND current_setting('ops_doc.basis') = ''
                        AND current_setting('ops_doc.decisions') = '' AND current_setting('ops_doc.dispatches') = '',
                        'c ops_doc.* settings reset after the write');

  -- create derived (dispatch sources: reviewed done, failed, refused_premise)
  j := pg_temp.w('global.t0033a.sub', 'T0033_SUB', 'manual', 'sub', 'derived', NULL,
                 ARRAY[pg_temp.id('d_done'), pg_temp.id('d_failed'), pg_temp.id('d_refused')]);
  v := pg_temp.ver((j->>'id')::uuid, 1);
  PERFORM pg_temp.check(j->>'trust_status' = 'approved' AND v.basis = 'derived' AND v.source_decision_ids = '{}'
                        AND v.source_dispatch_ids = ARRAY[pg_temp.id('d_done'), pg_temp.id('d_failed'), pg_temp.id('d_refused')],
                        'c derived create with dispatch sources');

  -- create review (no sources) -> draft
  j := pg_temp.w('global.t0033a', 'T0033_REV', 't0033_b', 'rev', 'review');
  d := pg_temp.doc('global.t0033a', 'T0033_REV');
  v := pg_temp.ver(d.id, 1);
  PERFORM pg_temp.check(j->>'trust_status' = 'draft' AND (j->>'created')::boolean AND d.trust_status = 'draft'
                        AND v.basis = 'review' AND v.changed_by_session = s AND v.source_decision_ids = '{}'
                        AND v.source_dispatch_ids = '{}' AND v.trust_status = 'draft', 'c review create: draft, attributed');

  -- update: content and summary replaced, version 2, not created
  d := pg_temp.doc('global.t0033a', 'T0033_ONE');
  j := pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', 'one v2', 'derived', ARRAY[dec], NULL, 'summary 2');
  PERFORM pg_temp.check(j = jsonb_build_object('id', d.id, 'version', 2, 'trust_status', 'approved', 'created', false,
                                               'reactivated', false, 'content_sha256', pg_temp.sha('one v2')),
                        'c update result: ' || j::text);
  d := pg_temp.doc('global.t0033a', 'T0033_ONE');
  PERFORM pg_temp.check(d.content = 'one v2' AND d.summary = 'summary 2' AND d.version = 2 AND pg_temp.nver(d.id) = 2
                        AND (pg_temp.ver(d.id, 2)).change_kind = 'update' AND (pg_temp.ver(d.id, 2)).basis = 'derived',
                        'c update row and version 2');
  -- a no-op write adds no version
  j := pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', 'one v2', 'derived', ARRAY[dec], NULL, 'summary 2');
  PERFORM pg_temp.check((j->>'version')::int = 2 AND pg_temp.nver(d.id) = 2, 'c no-op write adds no version');
  -- summary NULL = none
  j := pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', 'one v2', 'derived', ARRAY[dec]);
  PERFORM pg_temp.check((j->>'version')::int = 3 AND (pg_temp.doc('global.t0033a', 'T0033_ONE')).summary IS NULL,
                        'c summary NULL clears the summary');
  -- review over approved: draft, version bump
  j := pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', 'one v2', 'review');
  PERFORM pg_temp.check(j->>'trust_status' = 'draft' AND (j->>'version')::int = 4
                        AND (pg_temp.ver(d.id, 4)).basis = 'review', 'c review over approved: draft, version 4');

  -- refusals (each leaves no document behind)
  v_n := pg_temp.ndocs();
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[dec], NULL, NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'c null session: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[dec], NULL, v_x);
  PERFORM pg_temp.check(e = '23514 session ' || v_x || ' does not exist', 'c unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[dec], NULL, sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0033a (the scope of global.t0033a)',
                        'c session outside: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a.sub', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[dec], NULL, sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0033a (the scope of global.t0033a.sub)',
                        'c session outside (deeper node): ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033nosuch', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[dec], NULL, s);
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0033nosuch', 'c unknown node: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'other', ARRAY[dec], NULL, s);
  PERFORM pg_temp.check(e = '23514 basis must be derived or review', 'c bad basis: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', NULL, ARRAY[dec], NULL, s);
  PERFORM pg_temp.check(e = '23514 basis must be derived or review', 'c null basis: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 basis derived needs at least one source (decision_ids or dispatch_ids)',
                        'c derived without sources: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', '{}', '{}', s);
  PERFORM pg_temp.check(e = '23514 basis derived needs at least one source (decision_ids or dispatch_ids)',
                        'c derived with empty sources: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[v_x], NULL, s);
  PERFORM pg_temp.check(e = '23514 decision ' || v_x || ' does not exist', 'c unknown decision: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', ARRAY[pg_temp.id('dec_old')], NULL, s);
  PERFORM pg_temp.check(e = '23514 decision ' || pg_temp.id('dec_old') || ' is superseded by ' || pg_temp.id('dec_new'),
                        'c superseded decision: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', NULL, ARRAY[v_x], s);
  PERFORM pg_temp.check(e = '23514 dispatch ' || v_x || ' does not exist', 'c unknown dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', NULL, ARRAY[pg_temp.id('d_unrev')], s);
  PERFORM pg_temp.check(e = '23514 dispatch ' || pg_temp.id('d_unrev') || ' has no reviewed report',
                        'c unreviewed dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'derived', NULL, ARRAY[pg_temp.id('d_pend')], s);
  PERFORM pg_temp.check(e = '23514 dispatch ' || pg_temp.id('d_pend') || ' has no reviewed report',
                        'c pending dispatch with reviewed_at: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'review', ARRAY[pg_temp.id('dec_old')], NULL, s);
  PERFORM pg_temp.check(e = '23514 decision ' || pg_temp.id('dec_old') || ' is superseded by ' || pg_temp.id('dec_new'),
                        'c review sources are checked too: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'bad-key', 'manual', 't', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 doc_key must match ^[A-Z0-9_]+$', 'c bad doc_key: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', NULL, 'manual', 't', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 doc_key must match ^[A-Z0-9_]+$', 'c null doc_key: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 't0033_nosuch', 't', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 doc_type t0033_nosuch is not registered', 'c unregistered doc_type: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', '  ', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 title is empty', 'c blank title: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', NULL, 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 title is empty', 'c null title: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', '', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 content is empty', 'c empty content: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', NULL, 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 content is empty', 'c null content: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_X', 'manual', 't', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 node global.t0033a already holds a manual document (T0033_ONE)',
                        'c second document of a type on a node: ' || coalesce(e, 'success'));
  e := pg_temp.w_err('global.t0033a', 'T0033_ONE', 't0033_c', 't', 'c', 'review', NULL, NULL, s);
  PERFORM pg_temp.check(e = '23514 doc_type of T0033_ONE at global.t0033a is manual, not t0033_c',
                        'c update with another doc_type: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.ndocs() = v_n AND (pg_temp.doc('global.t0033a', 'T0033_ONE')).version = 4,
                        'c refusals leave no row and no version');

  -- direct INSERT / UPDATE (owner) after writer calls: no attribution
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
  VALUES ('T0033_DIRECT', 'direct', 'direct one', (SELECT id FROM ops.nodes WHERE path::text = 'global.t0033b'), 'manual');
  d := pg_temp.doc('global.t0033b', 'T0033_DIRECT');
  UPDATE ops.context_documents SET content = 'direct two' WHERE id = d.id;
  PERFORM pg_temp.check((SELECT bool_and(changed_by_session IS NULL AND basis IS NULL AND source_decision_ids = '{}'
                                         AND source_dispatch_ids = '{}' AND changed_by_dispatch IS NULL) AND count(*) = 2
                           FROM ops.document_versions WHERE document_id = d.id), 'c direct insert and update: NULL / {} attribution');
  RAISE NOTICE 'ok   c write_doc: derived and review creates, update, no-op, summary, refusals, session refusals, attribution, direct writes';
END $$;

-- d. approve_doc and retire_doc
DO $$
DECLARE s uuid := pg_temp.id('s'); sb uuid := pg_temp.id('sb'); j jsonb; d ops.context_documents; v ops.document_versions;
        v_x uuid := gen_random_uuid(); e text; v_n bigint;
BEGIN
  d := pg_temp.doc('global.t0033a', 'T0033_REV');
  -- approve refusals
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', pg_temp.sha('rev'), NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'd approve null session: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', pg_temp.sha('rev'), v_x);
  PERFORM pg_temp.check(e = '23514 session ' || v_x || ' does not exist', 'd approve unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', pg_temp.sha('rev'), sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0033a (the scope of global.t0033a)',
                        'd approve session outside: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', 'abc', s);
  PERFORM pg_temp.check(e = '23514 content_sha256 must be 64 lowercase hex characters', 'd short sha: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', upper(pg_temp.sha('rev')), s);
  PERFORM pg_temp.check(e = '23514 content_sha256 must be 64 lowercase hex characters', 'd upper-case sha: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', NULL, s);
  PERFORM pg_temp.check(e = '23514 content_sha256 must be 64 lowercase hex characters', 'd null sha: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_NONE', pg_temp.sha('rev'), s);
  PERFORM pg_temp.check(e = '23514 no document T0033_NONE at global.t0033a', 'd unknown document: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a.sub', 'T0033_REV', pg_temp.sha('rev'), s);
  PERFORM pg_temp.check(e = '23514 no document T0033_REV at global.t0033a.sub', 'd document must be at exactly the node: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a.sub', 'T0033_SUB', pg_temp.sha('sub'), s);
  PERFORM pg_temp.check(e = '23514 document T0033_SUB at global.t0033a.sub is already approved', 'd already approved: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a', 'T0033_REV', pg_temp.sha('other'), s);
  PERFORM pg_temp.check(e = '23514 content sha256 mismatch for T0033_REV at global.t0033a: stored ' || pg_temp.sha('rev'),
                        'd sha mismatch: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check((pg_temp.doc('global.t0033a', 'T0033_REV')).trust_status = 'draft' AND pg_temp.nver(d.id) = 1,
                        'd refusals leave the draft unchanged');
  -- approve: version bump with basis review
  j := ops.approve_doc('global.t0033a', 'T0033_REV', pg_temp.sha('rev'), s);
  v := pg_temp.ver(d.id, 2);
  PERFORM pg_temp.check(j = jsonb_build_object('id', d.id, 'version', 2)
                        AND (pg_temp.doc('global.t0033a', 'T0033_REV')).trust_status = 'approved'
                        AND v.trust_status = 'approved' AND v.basis = 'review' AND v.changed_by_session = s
                        AND v.source_decision_ids = '{}' AND v.source_dispatch_ids = '{}' AND v.change_kind = 'update'
                        AND v.content = 'rev', 'd approve: version 2, basis review: ' || j::text);
  -- an imported document can be approved
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, trust_status)
  VALUES ('T0033_IMP', 'imp', 'imported', (SELECT id FROM ops.nodes WHERE path::text = 'global.t0033b'), 't0033_b', 'imported');
  j := ops.approve_doc('global.t0033b', 'T0033_IMP', pg_temp.sha('imported'), sb);
  PERFORM pg_temp.check((j->>'version')::int = 2 AND (pg_temp.doc('global.t0033b', 'T0033_IMP')).trust_status = 'approved',
                        'd imported -> approved');

  -- retire refusals
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', 'r', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'd retire null session: ' || coalesce(e, 'success'));
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', 'r', v_x);
  PERFORM pg_temp.check(e = '23514 session ' || v_x || ' does not exist', 'd retire unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', 'r', sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0033a (the scope of global.t0033a.sub.leaf)',
                        'd retire session outside: ' || coalesce(e, 'success'));
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', ' ', s);
  PERFORM pg_temp.check(e = '23514 retire reason is empty', 'd blank reason: ' || coalesce(e, 'success'));
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', NULL, s);
  PERFORM pg_temp.check(e = '23514 retire reason is empty', 'd null reason: ' || coalesce(e, 'success'));
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', 'r', s);
  PERFORM pg_temp.check(e = '23514 no document T0033_RET at global.t0033a.sub.leaf', 'd retire unknown document: ' || coalesce(e, 'success'));
  -- retire: retired_* set, no version
  j := pg_temp.w('global.t0033a.sub.leaf', 'T0033_RET', 't0033_c', 'ret', 'review');
  d := pg_temp.doc('global.t0033a.sub.leaf', 'T0033_RET');
  j := ops.retire_doc('global.t0033a.sub.leaf', 'T0033_RET', 'no longer needed', s);
  d := pg_temp.doc('global.t0033a.sub.leaf', 'T0033_RET');
  PERFORM pg_temp.check(j = jsonb_build_object('id', d.id, 'retired_at', d.retired_at) AND d.retired_at IS NOT NULL
                        AND d.retired_reason = 'no longer needed' AND d.retired_by_session = s AND d.version = 1
                        AND pg_temp.nver(d.id) = 1, 'd retire: retired_* set, no version: ' || j::text);
  e := pg_temp.r_err('global.t0033a.sub.leaf', 'T0033_RET', 'again', s);
  PERFORM pg_temp.check(e = '23514 document T0033_RET at global.t0033a.sub.leaf is already retired', 'd already retired: ' || coalesce(e, 'success'));
  e := pg_temp.a_err('global.t0033a.sub.leaf', 'T0033_RET', pg_temp.sha('ret'), s);
  PERFORM pg_temp.check(e = '23514 document T0033_RET at global.t0033a.sub.leaf is retired', 'd approve a retired document: ' || coalesce(e, 'success'));
  -- retired_* direct: the check refuses a partial set
  e := pg_temp.err(format('UPDATE ops.context_documents SET retired_at = NULL WHERE id = %L', d.id));
  PERFORM pg_temp.check(e LIKE '23514 %context_documents_retired%', 'd partial retired_* refused: ' || coalesce(e, 'success'));
  -- reactivation through write_doc
  j := pg_temp.w('global.t0033a.sub.leaf', 'T0033_RET', 't0033_c', 'ret', 'review');
  d := pg_temp.doc('global.t0033a.sub.leaf', 'T0033_RET');
  PERFORM pg_temp.check((j->>'reactivated')::boolean AND NOT (j->>'created')::boolean AND d.retired_at IS NULL
                        AND d.retired_reason IS NULL AND d.retired_by_session IS NULL AND d.version = 1,
                        'd write_doc reactivates a retired document (same content: no version): ' || j::text);
  j := pg_temp.w('global.t0033a.sub.leaf', 'T0033_RET', 't0033_c', 'ret', 'review');
  PERFORM pg_temp.check(NOT (j->>'reactivated')::boolean, 'd a second write is not a reactivation');
  RAISE NOTICE 'ok   d approve_doc and retire_doc: refusals, approval version with basis review, imported, retire, reactivation';
END $$;

-- e. resolve_context
DO $$
DECLARE s uuid := pg_temp.id('s'); dec uuid := pg_temp.id('dec'); e text; v_sub uuid;
BEGIN
  -- approved row served
  PERFORM pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', E'# Top\nold\n## Part\nold part', 'derived', ARRAY[dec]);
  PERFORM pg_temp.check(ops.resolve_context('global.t0033a', 'T0033_ONE') = E'# Top\nold\n## Part\nold part', 'e approved row served');
  PERFORM pg_temp.check(ops.resolve_context('global.t0033a.sub.leaf', 'T0033_REV') = 'rev', 'e approved ancestor served');
  -- a draft over an approved version serves the older approved text, sections included
  PERFORM pg_temp.w('global.t0033a', 'T0033_ONE', 'manual', E'# Top\nnew\n## Part\nnew part', 'review');
  PERFORM pg_temp.check((pg_temp.doc('global.t0033a', 'T0033_ONE')).trust_status = 'draft', 'e the row is a draft');
  PERFORM pg_temp.check(ops.resolve_context('global.t0033a', 'T0033_ONE') = E'# Top\nold\n## Part\nold part',
                        'e draft over approved: newest approved version served');
  PERFORM pg_temp.check(ops.resolve_context('global.t0033a.sub', 'T0033_ONE#Part') = E'## Part\nold part',
                        'e draft over approved: section of the approved version');
  e := pg_temp.res_err('global.t0033a', 'T0033_ONE#Nope');
  PERFORM pg_temp.check(e = 'P0001 heading "Nope" not found in T0033_ONE', 'e heading miss message unchanged: ' || coalesce(e, 'success'));
  -- never approved raises; no ancestor fallback for an unapproved document
  PERFORM pg_temp.w('global.t0033a.sub.leaf', 'T0033_NEW', 'manual', 'never', 'review');
  e := pg_temp.res_err('global.t0033a.sub.leaf', 'T0033_NEW');
  PERFORM pg_temp.check(e = 'P0001 context ref T0033_NEW has no approved version at global.t0033a.sub.leaf',
                        'e never approved: ' || coalesce(e, 'success'));
  e := pg_temp.res_err('global.t0033a.sub.leaf', 'T0033_NEW#Top');
  PERFORM pg_temp.check(e = 'P0001 context ref T0033_NEW#Top has no approved version at global.t0033a.sub.leaf',
                        'e never approved, with heading: ' || coalesce(e, 'success'));
  PERFORM pg_temp.w('global.t0033a', 'T0033_FB', 't0033_c', 'parent fb', 'derived', ARRAY[dec]);
  PERFORM pg_temp.w('global.t0033a.sub', 'T0033_FB', 't0033_b', 'child fb', 'review');
  e := pg_temp.res_err('global.t0033a.sub.leaf', 'T0033_FB');
  PERFORM pg_temp.check(e = 'P0001 context ref T0033_FB has no approved version at global.t0033a.sub.leaf',
                        'e no ancestor fallback for an unapproved document: ' || coalesce(e, 'success'));
  -- a retired document is skipped in favour of an ancestor's, or unknown
  PERFORM ops.retire_doc('global.t0033a.sub', 'T0033_FB', 'child retired', s);
  PERFORM pg_temp.check(ops.resolve_context('global.t0033a.sub.leaf', 'T0033_FB') = 'parent fb', 'e retired child: ancestor served');
  PERFORM ops.retire_doc('global.t0033a', 'T0033_FB', 'parent retired', s);
  e := pg_temp.res_err('global.t0033a.sub.leaf', 'T0033_FB');
  PERFORM pg_temp.check(e = 'P0001 unknown context ref T0033_FB', 'e all retired: unknown: ' || coalesce(e, 'success'));
  e := pg_temp.res_err('global.t0033a', 'T0033_NOSUCH');
  PERFORM pg_temp.check(e = 'P0001 unknown context ref T0033_NOSUCH', 'e unknown ref message unchanged: ' || coalesce(e, 'success'));
  -- UNIQUE (node_id, doc_key) refuses a same-node pair
  v_sub := (SELECT id FROM ops.nodes WHERE path::text = 'global.t0033a.sub');
  e := pg_temp.err(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
                             VALUES ('T0033_SUB', 'pair', 'pair', %L, 't0033_c')$q$, v_sub));
  PERFORM pg_temp.check(e LIKE '23505 %context_documents_node_id_doc_key_key%', 'e same-node pair refused 23505: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   e resolve_context: approved row, newest approved version under a draft, never approved, no fallback, retired skipped, UNIQUE';
END $$;

ROLLBACK;

-- f. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'document_versions', (SELECT count(*) FROM ops.document_versions),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules), 'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog),
    'doc_types', (SELECT count(*) FROM ops.doc_types),
    'nodes', (SELECT count(*) FROM ops.nodes), 'components', (SELECT count(*) FROM ops.components),
    'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
    'dispatches', (SELECT count(*) FROM ops.dispatches)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   f no leftover rows; 0033 tests passed';
END $$;
