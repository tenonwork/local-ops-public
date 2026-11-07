-- 0026_context_document_versions
-- Dispatch cd611cfb. Release 3, migration 3 of 4 (0024-0027 are promoted together as one set by a separate promote
-- dispatch after planner review). Backlog 0609bdb8.
-- Decisions:
--   68b68b89 (2026-10-08) the trigger that fills ops.document_versions on context_documents changes was deferred from
--            M1 and never landed; no context-document writer may ship without it.
--   760461c5 (2026-10-13)
--     (1) the trigger owns context_documents.version: an INSERT always stores version 1; an UPDATE bumps it by
--         exactly 1 when content, summary or trust_status changes (IS DISTINCT FROM), otherwise keeps OLD.version;
--         any direct write to version is overwritten.
--     (2) each version gets one document_versions row (document_id, version, content, summary, trust_status from the
--         new row; change_kind 'addition' on insert, 'update' on a bump). Changes to title, doc_key, node_id,
--         doc_type, project_id, component_id or the usage columns create no version.
--     (3) changed_by_session / changed_by_dispatch stay NULL and source_decision_ids stays '{}' here; a later writer
--         migration replaces ops._doc_version_record() to fill them.
-- Two owner-only SECURITY INVOKER trigger functions (the 0015 _component_scope pattern), two triggers. No table,
-- grant or row change. No owner role is named: objects belong to the applying role.

BEGIN;

-- ── 1. guard; snapshots of what must not change
DO $$
DECLARE v_newest text; v_trg text[];
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0025_read_first_order_rule' THEN
    RAISE EXCEPTION '0026: expected newest ledger version 0025_read_first_order_rule, found %', v_newest;
  END IF;
  SELECT array_agg(tgname::text ORDER BY tgname) INTO v_trg FROM pg_trigger
   WHERE tgrelid = 'ops.context_documents'::regclass AND NOT tgisinternal;
  IF v_trg IS DISTINCT FROM ARRAY['context_documents_component_scope'] THEN
    RAISE EXCEPTION '0026: expected context_documents_component_scope as the only trigger on ops.context_documents, found %', v_trg;
  END IF;
  IF to_regprocedure('ops._doc_version_set()') IS NOT NULL OR to_regprocedure('ops._doc_version_record()') IS NOT NULL THEN
    RAISE EXCEPTION '0026: ops._doc_version_set() or ops._doc_version_record() already exists';
  END IF;

  PERFORM set_config('ops_m0026.executor_fns', (
    SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
     WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))::text, true);
  PERFORM set_config('ops_m0026.scope_trigger', (
    SELECT pg_get_triggerdef(oid) FROM pg_trigger
     WHERE tgrelid = 'ops.context_documents'::regclass AND tgname = 'context_documents_component_scope'), true);
END $$;

-- ── 2. BEFORE: the trigger owns version (760461c5 rule 1)
CREATE FUNCTION ops._doc_version_set()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ops, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.version := 1;
  ELSIF (NEW.content, NEW.summary, NEW.trust_status) IS DISTINCT FROM (OLD.content, OLD.summary, OLD.trust_status) THEN
    NEW.version := OLD.version + 1;
  ELSE
    NEW.version := OLD.version;
  END IF;
  RETURN NEW;
END $$;

-- ── 3. AFTER: one document_versions row per version (760461c5 rules 2-3)
CREATE FUNCTION ops._doc_version_record()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ops, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.version <> OLD.version THEN
    INSERT INTO ops.document_versions (document_id, version, content, summary, trust_status, change_kind)
    VALUES (NEW.id, NEW.version, NEW.content, NEW.summary, NEW.trust_status,
            CASE TG_OP WHEN 'INSERT' THEN 'addition' ELSE 'update' END::ops.change_kind);
  END IF;
  RETURN NULL;
END $$;

-- ── 4. triggers
CREATE TRIGGER context_documents_version_set
  BEFORE INSERT OR UPDATE ON ops.context_documents
  FOR EACH ROW EXECUTE FUNCTION ops._doc_version_set();
CREATE TRIGGER context_documents_version_record
  AFTER INSERT OR UPDATE ON ops.context_documents
  FOR EACH ROW EXECUTE FUNCTION ops._doc_version_record();

-- ── 5. owner-only; comments
REVOKE ALL ON FUNCTION ops._doc_version_set(), ops._doc_version_record() FROM PUBLIC;
COMMENT ON FUNCTION ops._doc_version_set() IS
  'Release 3 (0609bdb8): owns context_documents.version: 1 on insert; +1 on an update that changes content, summary or trust_status; otherwise unchanged (decision 760461c5).';
COMMENT ON FUNCTION ops._doc_version_record() IS
  'Release 3 (0609bdb8): writes one document_versions row per context_documents version (addition on insert, update on a bump); session, dispatch and source decisions not yet filled (decision 760461c5).';
COMMENT ON TRIGGER context_documents_version_set ON ops.context_documents IS
  'Release 3 (0609bdb8): BEFORE INSERT OR UPDATE; sets version through ops._doc_version_set().';
COMMENT ON TRIGGER context_documents_version_record ON ops.context_documents IS
  'Release 3 (0609bdb8): AFTER INSERT OR UPDATE; records each new version through ops._doc_version_record().';

-- ── 6. checks: any failure aborts the migration
DO $$
DECLARE v_fn text; v_bad text; v_n integer; v_node uuid; v_doc uuid;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['ops._doc_version_set()', 'ops._doc_version_record()'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = v_fn::regprocedure AND NOT p.prosecdef
                    AND p.proconfig = ARRAY['search_path=ops, pg_temp'] AND p.prorettype = 'trigger'::regtype
                    AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
                    AND NOT has_function_privilege('ops_planner', p.oid, 'EXECUTE')
                    AND NOT has_function_privilege('ops_executor', p.oid, 'EXECUTE')) THEN
      RAISE EXCEPTION '0026: % is not a SECURITY INVOKER trigger function with search_path ops, pg_temp and owner-only EXECUTE', v_fn;
    END IF;
    IF obj_description(v_fn::regprocedure, 'pg_proc') NOT LIKE 'Release 3 (0609bdb8): %' THEN
      RAISE EXCEPTION '0026: % comment does not start ''Release 3 (0609bdb8): ''', v_fn;
    END IF;
  END LOOP;
  SELECT string_agg(tgname::text, ', ') INTO v_bad FROM pg_trigger
   WHERE tgrelid = 'ops.context_documents'::regclass
     AND tgname IN ('context_documents_version_set', 'context_documents_version_record')
     AND obj_description(oid, 'pg_trigger') NOT LIKE 'Release 3 (0609bdb8): %';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0026: trigger comment does not start ''Release 3 (0609bdb8): '': %', v_bad;
  END IF;
  IF (SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
       WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))::text
     IS DISTINCT FROM current_setting('ops_m0026.executor_fns') THEN
    RAISE EXCEPTION '0026: ops_executor EXECUTE set changed (before %)', current_setting('ops_m0026.executor_fns');
  END IF;
  IF (SELECT pg_get_triggerdef(oid) FROM pg_trigger
       WHERE tgrelid = 'ops.context_documents'::regclass AND tgname = 'context_documents_component_scope')
     IS DISTINCT FROM current_setting('ops_m0026.scope_trigger') THEN
    RAISE EXCEPTION '0026: context_documents_component_scope changed';
  END IF;
  -- compared structurally (tgtype: ROW 1, BEFORE 2, INSERT 4, UPDATE 16), not as text: pg_get_triggerdef depends on search_path
  IF (SELECT array_agg(t.tgname::text ORDER BY t.tgname) FROM pg_trigger t
       WHERE t.tgrelid = 'ops.context_documents'::regclass AND NOT t.tgisinternal)
     IS DISTINCT FROM ARRAY['context_documents_component_scope', 'context_documents_version_record', 'context_documents_version_set']
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'ops.context_documents'::regclass
                     AND tgname = 'context_documents_version_set' AND tgfoid = 'ops._doc_version_set()'::regprocedure
                     AND tgtype = 23 AND tgattr = ''::int2vector AND tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'ops.context_documents'::regclass
                     AND tgname = 'context_documents_version_record' AND tgfoid = 'ops._doc_version_record()'::regprocedure
                     AND tgtype = 21 AND tgattr = ''::int2vector AND tgenabled = 'O') THEN
    RAISE EXCEPTION '0026: expected exactly three triggers on ops.context_documents (component scope, version set, version record)';
  END IF;

  -- behaviour, in a subtransaction that is always rolled back
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 'm0026-check', 'node', 'm0026-check') RETURNING id INTO v_node;
    INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, version)
    VALUES ('M0026_CHECK', 'check', 'one', v_node, 'manual', 7) RETURNING id INTO v_doc;
    IF (SELECT version FROM ops.context_documents WHERE id = v_doc) <> 1
       OR (SELECT count(*) FROM ops.document_versions WHERE document_id = v_doc) <> 1
       OR NOT EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 1
                         AND change_kind = 'addition' AND content = 'one') THEN
      RAISE EXCEPTION '0026: insert did not store version 1 with one addition row';
    END IF;
    UPDATE ops.context_documents SET content = 'two' WHERE id = v_doc;
    IF (SELECT version FROM ops.context_documents WHERE id = v_doc) <> 2
       OR (SELECT count(*) FROM ops.document_versions WHERE document_id = v_doc) <> 2
       OR NOT EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = 2
                         AND change_kind = 'update' AND content = 'two') THEN
      RAISE EXCEPTION '0026: content update did not store version 2 with one update row';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'OP026', MESSAGE = 'm0026 rollback sentinel';
  EXCEPTION WHEN SQLSTATE 'OP026' THEN
    NULL;
  END;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE key = 'm0026-check') THEN
    RAISE EXCEPTION '0026: behaviour check left rows behind';
  END IF;
  RAISE NOTICE '0026 checks passed';
END $$;

-- ── 7. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0026_context_document_versions');

COMMIT;
