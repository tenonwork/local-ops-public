-- 0033_context_document_writer
-- Dispatch 8e83c855. Writer release (decisions f80bbc60, 9f324853, da0592ad, e1b36a09); promoted by a separate promote
-- dispatch after planner review. Protocol version 11 -> 12.
--   * ops.context_documents: UNIQUE (node_id, doc_key); retired_at / retired_reason / retired_by_session (all three
--     or none). Documents are never deleted: a retired document is absent to resolve_context, and a later write_doc
--     on the same node and doc_key reactivates it.
--   * ops.document_versions: basis (derived | review) and source_dispatch_ids beside source_decision_ids;
--     ops._doc_version_record() fills changed_by_session, basis and both source arrays from the transaction-local
--     settings ops_doc.session / ops_doc.basis / ops_doc.decisions / ops_doc.dispatches the writers set around their
--     write. Unset or '' settings (direct writes) give the 0026 row: NULL / '{}'. changed_by_dispatch stays NULL.
--   * Writers, planner-only SECURITY DEFINER, each taking the session last, checked as ops.log_decision checks it
--     against the target node: write_doc (basis derived lands approved and needs a source; basis review lands
--     draft), approve_doc (sha256-bound), retire_doc.
--   * ops.resolve_context skips retired documents and serves the newest approved version.
--   * Protocol rule doc_approval v1, session_stale_after v2 (per node); investigation execution_rules.queries allows
--     resolve_context; protocol_changelog version 12.
-- The executor gets nothing new: its SELECT and EXECUTE sets are checked against the step-1 snapshot.

BEGIN;

-- ── 1. guard; snapshots for step 8
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0032_vision_items' THEN
    RAISE EXCEPTION '0033: expected newest ledger version 0032_vision_items, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 11 THEN
    RAISE EXCEPTION '0033: expected protocol version 11, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                AND proname IN ('write_doc', 'approve_doc', 'retire_doc', '_doc_session', '_doc_attribution')) THEN
    RAISE EXCEPTION '0033: a function write_doc, approve_doc, retire_doc, _doc_session or _doc_attribution already exists in ops';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'doc_approval') THEN
    RAISE EXCEPTION '0033: protocol rule doc_approval already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 12) THEN
    RAISE EXCEPTION '0033: protocol_changelog version 12 already exists';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'session_stale_after' AND version = 1) THEN
    RAISE EXCEPTION '0033: expected protocol rule session_stale_after at version 1';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.context_documents) OR EXISTS (SELECT 1 FROM ops.document_versions) THEN
    RAISE EXCEPTION '0033: expected ops.context_documents and ops.document_versions to be empty';
  END IF;

  PERFORM set_config('ops_m0033.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules
      WHERE key <> 'session_stale_after'), true);
  PERFORM set_config('ops_m0033.investigation_rest',
    (SELECT (execution_rules - 'queries')::text FROM ops.dispatch_types WHERE type = 'investigation'), true);
  PERFORM set_config('ops_m0033.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0033.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  IF EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
              WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                AND has_table_privilege('ops_planner', c.oid, p)) THEN
    RAISE EXCEPTION '0033: ops_planner holds a table write privilege in ops';
  END IF;
END $$;

-- ── 2. context_documents: one doc_key per node; retirement
ALTER TABLE ops.context_documents
  ADD CONSTRAINT context_documents_node_id_doc_key_key UNIQUE (node_id, doc_key),
  ADD COLUMN retired_at timestamptz,
  ADD COLUMN retired_reason text,
  ADD COLUMN retired_by_session uuid REFERENCES ops.sessions(id),
  ADD CONSTRAINT context_documents_retired CHECK (
    (retired_at IS NULL AND retired_reason IS NULL AND retired_by_session IS NULL)
    OR (retired_at IS NOT NULL AND retired_reason IS NOT NULL AND retired_by_session IS NOT NULL
        AND length(btrim(retired_reason)) > 0));
COMMENT ON COLUMN ops.context_documents.retired_at IS
  'Writer release (f80bbc60): set by retire_doc; a retired document is absent to resolve_context; write_doc on the same node and doc_key clears it.';
COMMENT ON COLUMN ops.context_documents.retired_reason IS
  'Writer release (f80bbc60): why retire_doc retired the document; set with retired_at and retired_by_session.';
COMMENT ON COLUMN ops.context_documents.retired_by_session IS
  'Writer release (f80bbc60): the session that called retire_doc; set with retired_at and retired_reason.';

-- ── 3. document_versions: basis and dispatch sources
ALTER TABLE ops.document_versions
  ADD COLUMN basis text CHECK (basis IN ('derived', 'review')),
  ADD COLUMN source_dispatch_ids uuid[] NOT NULL DEFAULT '{}'
    CONSTRAINT document_versions_source_dispatch_ids_check CHECK (array_position(source_dispatch_ids, NULL) IS NULL);

-- ── 4. version record with attribution from the writers' transaction-local settings
CREATE OR REPLACE FUNCTION ops._doc_version_record()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ops, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.version <> OLD.version THEN
    INSERT INTO ops.document_versions (document_id, version, content, summary, trust_status, change_kind,
                                       changed_by_session, basis, source_decision_ids, source_dispatch_ids)
    VALUES (NEW.id, NEW.version, NEW.content, NEW.summary, NEW.trust_status,
            CASE TG_OP WHEN 'INSERT' THEN 'addition' ELSE 'update' END::ops.change_kind,
            nullif(current_setting('ops_doc.session', true), '')::uuid,
            nullif(current_setting('ops_doc.basis', true), ''),
            string_to_array(coalesce(current_setting('ops_doc.decisions', true), ''), ',')::uuid[],
            string_to_array(coalesce(current_setting('ops_doc.dispatches', true), ''), ',')::uuid[]);
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ops._doc_version_record() FROM PUBLIC;
COMMENT ON FUNCTION ops._doc_version_record() IS
  'Writer release (f80bbc60): writes one document_versions row per context_documents version (addition on insert, update on a bump), with changed_by_session, basis and source decision / dispatch ids from the transaction-local settings ops_doc.* set by write_doc and approve_doc; unset or empty settings leave NULL / ''{}''.';

-- ── 5. writers
-- private helpers (owner only): the log_decision session check against the target node (returns the node), and the
-- ops_doc.* attribution settings (NULL arguments reset them to '')
CREATE FUNCTION ops._doc_session(p_session uuid, p_node_path public.ltree)
RETURNS ops.nodes LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; v_root ops.nodes; s ops.sessions;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  n := ops._node(p_node_path);
  v_root := ops._node(public.subpath(n.path, 0, least(2, public.nlevel(n.path))));
  SELECT * INTO s FROM ops.sessions WHERE id = p_session;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
  END IF;
  IF NOT coalesce((SELECT path FROM ops.nodes WHERE id = coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id)))
                  OPERATOR(public.<@) v_root.path, false) THEN
    RAISE EXCEPTION 'session % is outside % (the scope of %)', p_session, v_root.path, n.path
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION ops._doc_session(uuid, public.ltree) FROM PUBLIC;

CREATE FUNCTION ops._doc_attribution(p_session uuid, p_basis text, p_decision_ids uuid[], p_dispatch_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  PERFORM set_config('ops_doc.session', coalesce(p_session::text, ''), true);
  PERFORM set_config('ops_doc.basis', coalesce(p_basis, ''), true);
  PERFORM set_config('ops_doc.decisions', coalesce(array_to_string(p_decision_ids, ','), ''), true);
  PERFORM set_config('ops_doc.dispatches', coalesce(array_to_string(p_dispatch_ids, ','), ''), true);
END $$;
REVOKE ALL ON FUNCTION ops._doc_attribution(uuid, text, uuid[], uuid[]) FROM PUBLIC;

-- a. write_doc: create or update the document at (node, doc_key)
CREATE FUNCTION ops.write_doc(p_node_path public.ltree, p_doc_key text, p_doc_type text, p_title text, p_content text,
                              p_summary text, p_basis text, p_decision_ids uuid[], p_dispatch_ids uuid[], p_session uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; o ops.context_documents; r ops.context_documents; x ops.context_documents; v_id uuid;
        d ops.decisions; v_by uuid; p ops.dispatches; v_decs uuid[] := coalesce(p_decision_ids, '{}');
        v_disps uuid[] := coalesce(p_dispatch_ids, '{}'); v_trust ops.trust_status; v_found boolean;
BEGIN
  n := ops._doc_session(p_session, p_node_path);
  IF p_basis IS NULL OR p_basis NOT IN ('derived', 'review') THEN
    RAISE EXCEPTION 'basis must be derived or review' USING ERRCODE = 'check_violation';
  END IF;
  IF p_basis = 'derived' AND cardinality(v_decs) + cardinality(v_disps) = 0 THEN
    RAISE EXCEPTION 'basis derived needs at least one source (decision_ids or dispatch_ids)' USING ERRCODE = 'check_violation';
  END IF;
  FOREACH v_id IN ARRAY v_decs LOOP
    SELECT * INTO d FROM ops.decisions WHERE id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'decision % does not exist', v_id USING ERRCODE = 'check_violation';
    END IF;
    SELECT id INTO v_by FROM ops.decisions WHERE supersedes = v_id ORDER BY recorded_at, id LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'decision % is superseded by %', v_id, v_by USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  FOREACH v_id IN ARRAY v_disps LOOP
    SELECT * INTO p FROM ops.dispatches WHERE id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'dispatch % does not exist', v_id USING ERRCODE = 'check_violation';
    END IF;
    IF p.reviewed_at IS NULL OR p.status NOT IN ('done', 'failed', 'refused_premise') THEN
      RAISE EXCEPTION 'dispatch % has no reviewed report', v_id USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  IF p_doc_key IS NULL OR p_doc_key !~ '^[A-Z0-9_]+$' THEN
    RAISE EXCEPTION 'doc_key must match ^[A-Z0-9_]+$' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.doc_types WHERE key = p_doc_type) THEN
    RAISE EXCEPTION 'doc_type % is not registered', p_doc_type USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_title, ''))) = 0 THEN
    RAISE EXCEPTION 'title is empty' USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_content, ''))) = 0 THEN
    RAISE EXCEPTION 'content is empty' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o FROM ops.context_documents WHERE node_id = n.id AND doc_key = p_doc_key;
  v_found := FOUND;
  IF v_found AND o.doc_type <> p_doc_type THEN
    RAISE EXCEPTION 'doc_type of % at % is %, not %', p_doc_key, n.path, o.doc_type, p_doc_type
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT v_found THEN
    SELECT * INTO x FROM ops.context_documents WHERE node_id = n.id AND doc_type = p_doc_type;
    IF FOUND THEN
      RAISE EXCEPTION 'node % already holds a % document (%)', n.path, p_doc_type, x.doc_key
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  v_trust := CASE p_basis WHEN 'derived' THEN 'approved' ELSE 'draft' END::ops.trust_status;

  PERFORM ops._doc_attribution(p_session, p_basis, v_decs, v_disps);
  IF v_found THEN
    UPDATE ops.context_documents
       SET title = p_title, content = p_content, summary = p_summary, trust_status = v_trust, updated_at = now(),
           retired_at = NULL, retired_reason = NULL, retired_by_session = NULL
     WHERE id = o.id
    RETURNING * INTO r;
  ELSE
    INSERT INTO ops.context_documents (doc_key, title, content, summary, node_id, doc_type, trust_status)
    VALUES (p_doc_key, p_title, p_content, p_summary, n.id, p_doc_type, v_trust)
    RETURNING * INTO r;
  END IF;
  PERFORM ops._doc_attribution(NULL, NULL, NULL, NULL);

  RETURN jsonb_build_object('id', r.id, 'version', r.version, 'trust_status', r.trust_status, 'created', NOT v_found,
                            'reactivated', v_found AND o.retired_at IS NOT NULL,
                            'content_sha256', encode(sha256(convert_to(r.content, 'UTF8')), 'hex'));
END $$;
REVOKE ALL ON FUNCTION ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid) TO ops_planner;
COMMENT ON FUNCTION ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid) IS
  'Writer release (f80bbc60, 9f324853, da0592ad): creates or updates the context document at (node, doc_key); basis derived (at least one source: a non-superseded decision or a dispatch with a reviewed report) lands approved, basis review lands draft (rule doc_approval); node and doc_type are fixed once the document exists; reactivates a retired document.';

-- b. approve_doc: draft or imported -> approved, bound to the reviewed bytes
CREATE FUNCTION ops.approve_doc(p_node_path public.ltree, p_doc_key text, p_content_sha256 text, p_session uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; o ops.context_documents; r ops.context_documents; v_sha text;
BEGIN
  n := ops._doc_session(p_session, p_node_path);
  IF p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'content_sha256 must be 64 lowercase hex characters' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o FROM ops.context_documents WHERE node_id = n.id AND doc_key = p_doc_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no document % at %', p_doc_key, n.path USING ERRCODE = 'check_violation';
  END IF;
  IF o.retired_at IS NOT NULL THEN
    RAISE EXCEPTION 'document % at % is retired', p_doc_key, n.path USING ERRCODE = 'check_violation';
  END IF;
  IF o.trust_status = 'approved' THEN
    RAISE EXCEPTION 'document % at % is already approved', p_doc_key, n.path USING ERRCODE = 'check_violation';
  END IF;
  v_sha := encode(sha256(convert_to(o.content, 'UTF8')), 'hex');
  IF v_sha <> p_content_sha256 THEN
    RAISE EXCEPTION 'content sha256 mismatch for % at %: stored %', p_doc_key, n.path, v_sha
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM ops._doc_attribution(p_session, 'review', NULL, NULL);
  UPDATE ops.context_documents SET trust_status = 'approved', updated_at = now() WHERE id = o.id RETURNING * INTO r;
  PERFORM ops._doc_attribution(NULL, NULL, NULL, NULL);

  RETURN jsonb_build_object('id', r.id, 'version', r.version);
END $$;
REVOKE ALL ON FUNCTION ops.approve_doc(public.ltree, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.approve_doc(public.ltree, text, text, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.approve_doc(public.ltree, text, text, uuid) IS
  'Writer release (f80bbc60, 9f324853, da0592ad): sets a draft or imported document approved (version basis review) when the given sha256 equals the stored content''s; called only after the operator''s explicit yes naming the doc_key and content sha256 (rule doc_approval).';

-- c. retire_doc: the document stays; resolve_context treats it as absent
CREATE FUNCTION ops.retire_doc(p_node_path public.ltree, p_doc_key text, p_reason text, p_session uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; o ops.context_documents; r ops.context_documents;
BEGIN
  n := ops._doc_session(p_session, p_node_path);
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN
    RAISE EXCEPTION 'retire reason is empty' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o FROM ops.context_documents WHERE node_id = n.id AND doc_key = p_doc_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'no document % at %', p_doc_key, n.path USING ERRCODE = 'check_violation';
  END IF;
  IF o.retired_at IS NOT NULL THEN
    RAISE EXCEPTION 'document % at % is already retired', p_doc_key, n.path USING ERRCODE = 'check_violation';
  END IF;

  PERFORM ops._doc_attribution(p_session, NULL, NULL, NULL);
  UPDATE ops.context_documents SET retired_at = now(), retired_reason = p_reason, retired_by_session = p_session
   WHERE id = o.id RETURNING * INTO r;
  PERFORM ops._doc_attribution(NULL, NULL, NULL, NULL);

  RETURN jsonb_build_object('id', r.id, 'retired_at', r.retired_at);
END $$;
REVOKE ALL ON FUNCTION ops.retire_doc(public.ltree, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.retire_doc(public.ltree, text, text, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.retire_doc(public.ltree, text, text, uuid) IS
  'Writer release (f80bbc60, 9f324853, da0592ad): records retired_at, retired_reason and retired_by_session on the document (never deleted); needs the operator''s explicit yes unless a logged decision names the retirement (rule doc_approval).';

-- ── 6. resolve_context: unretired documents only; the newest approved version
CREATE OR REPLACE FUNCTION ops.resolve_context(p_node_path public.ltree, p_ref text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  n ops.nodes := ops._node(p_node_path);
  v_key text := split_part(p_ref, '#', 1);
  v_heading text := nullif(substr(p_ref, length(v_key) + 2), '');
  v_content text; v_line text; v_level int := 0; v_hlevel int; v_out text := ''; v_in boolean := false;
  v_depth int; v_matches int; v_at text; v_doc uuid;
  v_row ops.context_documents;
BEGIN
  SELECT public.nlevel(dn.path), count(*), min(dn.path::text), min(cd.id::text)::uuid
    INTO v_depth, v_matches, v_at, v_doc
    FROM ops.context_documents cd JOIN ops.nodes dn ON dn.id = cd.node_id
   WHERE dn.path OPERATOR(public.@>) n.path AND cd.doc_key = v_key AND cd.retired_at IS NULL
   GROUP BY public.nlevel(dn.path)
   ORDER BY public.nlevel(dn.path) DESC
   LIMIT 1;
  IF v_doc IS NULL THEN RAISE EXCEPTION 'unknown context ref %', p_ref; END IF;
  IF v_matches > 1 THEN RAISE EXCEPTION 'ambiguous context ref % at %', p_ref, v_at; END IF;
  SELECT * INTO v_row FROM ops.context_documents WHERE id = v_doc;
  IF v_row.trust_status = 'approved' THEN
    v_content := v_row.content;
  ELSE
    SELECT dv.content INTO v_content FROM ops.document_versions dv
     WHERE dv.document_id = v_doc AND dv.trust_status = 'approved' ORDER BY dv.version DESC LIMIT 1;
    IF v_content IS NULL THEN
      RAISE EXCEPTION 'context ref % has no approved version at %', p_ref, p_node_path;
    END IF;
  END IF;
  IF v_heading IS NULL THEN RETURN v_content; END IF;

  FOREACH v_line IN ARRAY string_to_array(v_content, E'\n') LOOP
    v_hlevel := length(substring(v_line from '^(#+)\s'));
    IF v_in AND v_hlevel IS NOT NULL AND v_hlevel <= v_level THEN EXIT; END IF;
    IF NOT v_in AND v_hlevel IS NOT NULL
       AND lower(btrim(regexp_replace(v_line, '^#+\s+', ''))) = lower(btrim(v_heading)) THEN
      v_in := true; v_level := v_hlevel;
    END IF;
    IF v_in THEN v_out := v_out || v_line || E'\n'; END IF;
  END LOOP;
  IF NOT v_in THEN RAISE EXCEPTION 'heading "%" not found in %', v_heading, v_key; END IF;
  RETURN rtrim(v_out, E'\n');
END $$;
COMMENT ON FUNCTION ops.resolve_context(public.ltree, text) IS
  'Writer release (f80bbc60): node-keyed resolve_context; nearest ancestor-or-self unretired document wins; serves the newest approved version.';

-- ── 7. rules: doc_approval v1, session_stale_after v2, investigation queries; changelog 12
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'doc_approval',
  jsonb_build_object(
    'rule', 'Context documents change only through write_doc, approve_doc and retire_doc. write_doc with basis derived lands a document approved without an operator gate, and is used only when every claim in the change traces to a logged, non-superseded decision or to concrete evidence (a reviewed dispatch report, later an evidence-backed mechanical finding), named as source ids. Basis review lands a draft and is required for a change that alters how something works rather than adding to it, an interpretive claim no source states, or content with no traceable source; the planner calls approve_doc only after the operator''s explicit yes naming the doc_key and content sha256 (one yes may name several). retire_doc needs the operator''s explicit yes unless a logged decision names the retirement. resolve_context serves the newest approved version of the nearest unretired document.')
);
UPDATE ops.protocol_rules
   SET version = 2, updated_at = now(),
       value = jsonb_build_object(
         'rule', 'Active sessions older than this are auto-closed as stale when a new session opens on the same node.',
         'hours', 12)
 WHERE key = 'session_stale_after';
UPDATE ops.dispatch_types
   SET execution_rules = jsonb_set(execution_rules, '{queries}', to_jsonb(
         'executor queue tools (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type) plus resolve_context for read-first context; no other database queries'::text))
 WHERE type = 'investigation';
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  12,
  ARRAY['doc_approval', 'session_stale_after'],
  'doc_approval v1: derived writes land approved with source ids, review writes need the operator''s yes through approve_doc (sha256-bound), retire_doc gated unless a decision names it; session_stale_after v2: stale sessions close per node. Investigation queries allow resolve_context (decisions f80bbc60, 9f324853, da0592ad, e1b36a09).'
);

-- ── 8. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_fns regprocedure[] := ARRAY['ops.write_doc(public.ltree, text, text, text, text, text, text, uuid[], uuid[], uuid)'::regprocedure,
                                      'ops.approve_doc(public.ltree, text, text, uuid)', 'ops.retire_doc(public.ltree, text, text, uuid)'];
        v_helpers regprocedure[] := ARRAY['ops._doc_session(uuid, public.ltree)'::regprocedure,
                                          'ops._doc_attribution(uuid, text, uuid[], uuid[])'];
        v_fn regprocedure; v_bad text; v_n uuid; v_s uuid; v_dec uuid; v_j jsonb; v_e text; v_sha text; v_doc uuid;
BEGIN
  -- catalog of steps 2-7
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.context_documents'::regclass
                    AND conname = 'context_documents_node_id_doc_key_key' AND contype = 'u'
                    AND pg_get_constraintdef(oid) = 'UNIQUE (node_id, doc_key)')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.context_documents'::regclass
                       AND conname = 'context_documents_retired' AND contype = 'c')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.context_documents'::regclass
                       AND contype = 'f' AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.context_documents'::regclass
                                                             AND attname = 'retired_by_session')]
                       AND confrelid = 'ops.sessions'::regclass)
     OR (SELECT array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) || CASE WHEN attnotnull THEN ' not null' ELSE '' END
                          ORDER BY attnum)
           FROM pg_attribute WHERE attrelid = 'ops.context_documents'::regclass
            AND attname IN ('retired_at', 'retired_reason', 'retired_by_session'))
        <> ARRAY['retired_at timestamp with time zone', 'retired_reason text', 'retired_by_session uuid']
     OR EXISTS (SELECT 1 FROM unnest(ARRAY['retired_at', 'retired_reason', 'retired_by_session']) c
                 WHERE col_description('ops.context_documents'::regclass,
                         (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.context_documents'::regclass AND attname = c))
                       NOT LIKE 'Writer release (f80bbc60): %') THEN
    RAISE EXCEPTION '0033: context_documents UNIQUE (node_id, doc_key), retired_* columns, check, FK or comments wrong';
  END IF;
  IF (SELECT array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) || CASE WHEN attnotnull THEN ' not null' ELSE '' END
                       ORDER BY attnum)
        FROM pg_attribute WHERE attrelid = 'ops.document_versions'::regclass AND attname IN ('basis', 'source_dispatch_ids'))
     <> ARRAY['basis text', 'source_dispatch_ids uuid[] not null']
     OR (SELECT count(*) FROM pg_constraint WHERE conrelid = 'ops.document_versions'::regclass AND contype = 'c') <> 2 THEN
    RAISE EXCEPTION '0033: document_versions basis / source_dispatch_ids wrong';
  END IF;
  IF NOT (SELECT NOT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                 AND obj_description(oid, 'pg_proc') LIKE 'Writer release (f80bbc60): %'
                 AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee <> proowner)
            FROM pg_proc WHERE oid = 'ops._doc_version_record()'::regprocedure) THEN
    RAISE EXCEPTION '0033: ops._doc_version_record() is not an owner-only SECURITY INVOKER function with its comment';
  END IF;
  FOREACH v_fn IN ARRAY v_fns LOOP
    IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                   AND prorettype = 'jsonb'::regtype AND provolatile = 'v'
                   AND obj_description(oid, 'pg_proc') LIKE 'Writer release (f80bbc60, 9f324853, da0592ad): %'
              FROM pg_proc WHERE oid = v_fn) THEN
      RAISE EXCEPTION '0033: % is not SECURITY DEFINER with search_path ops, pg_temp owned by % with its comment', v_fn, v_owner;
    END IF;
    IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
          FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner) <> ARRAY['ops_planner'] THEN
      RAISE EXCEPTION '0033: % ACL is not owner plus ops_planner', v_fn;
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY v_helpers LOOP
    IF NOT (SELECT prosecdef AND pg_get_userbyid(proowner) = v_owner AND proacl IS NOT NULL FROM pg_proc WHERE oid = v_fn)
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner) THEN
      RAISE EXCEPTION '0033: helper % is not owner-only', v_fn;
    END IF;
  END LOOP;
  IF NOT (SELECT prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=ops, pg_temp']
                 AND obj_description(oid, 'pg_proc') = 'Writer release (f80bbc60): node-keyed resolve_context; nearest ancestor-or-self unretired document wins; serves the newest approved version.'
            FROM pg_proc WHERE oid = 'ops.resolve_context(public.ltree, text)'::regprocedure)
     OR (SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
           FROM pg_proc p, aclexplode(p.proacl) a
          WHERE p.oid = 'ops.resolve_context(public.ltree, text)'::regprocedure AND a.grantee <> p.proowner)
        <> ARRAY['ops_executor', 'ops_planner']
     OR (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'resolve_context') <> 1 THEN
    RAISE EXCEPTION '0033: resolve_context catalog wrong';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'doc_approval' AND version = 1
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['rule'])
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'session_stale_after' AND version = 2
                       AND value = '{"rule": "Active sessions older than this are auto-closed as stale when a new session opens on the same node.", "hours": 12}'::jsonb)
     OR (SELECT count(*) FROM ops.protocol_changelog WHERE version = 12) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 12
                       AND rule_keys = ARRAY['doc_approval', 'session_stale_after'])
     OR (SELECT max(version) FROM ops.protocol_changelog) <> 12 THEN
    RAISE EXCEPTION '0033: doc_approval / session_stale_after rule or protocol_changelog version 12 missing or wrong';
  END IF;
  IF (SELECT execution_rules->>'queries' FROM ops.dispatch_types WHERE type = 'investigation')
       IS DISTINCT FROM 'executor queue tools (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type) plus resolve_context for read-first context; no other database queries'
     OR (SELECT (execution_rules - 'queries')::text FROM ops.dispatch_types WHERE type = 'investigation')
        IS DISTINCT FROM current_setting('ops_m0033.investigation_rest') THEN
    RAISE EXCEPTION '0033: investigation execution_rules wrong';
  END IF;

  -- nothing else changed
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0033.executor_reads')
     OR (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
          WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text
        <> current_setting('ops_m0033.executor_fns') THEN
    RAISE EXCEPTION '0033: ops_executor SELECT or EXECUTE set changed';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0033: ops_planner holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key NOT IN ('doc_approval', 'session_stale_after'))
     IS DISTINCT FROM current_setting('ops_m0033.rules_md5') THEN
    RAISE EXCEPTION '0033: other protocol_rules rows changed';
  END IF;

  -- behaviour on a probe node under global with its own session and decision, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0033probe', 'node', '0033 probe') RETURNING id INTO v_n;
    v_s := ops.open_session(p_node_path => 'global.t0033probe'::public.ltree, p_kind => 'planning');
    v_dec := (ops.log_decision(p_node_path => 'global.t0033probe'::public.ltree, p_decision => '0033 probe decision',
                               p_session => v_s)).id;

    -- review -> draft; never approved: resolve raises
    v_j := ops.write_doc('global.t0033probe', 'T0033_PROBE', 'manual', 'probe', 'one', NULL, 'review', NULL, NULL, v_s);
    v_doc := (v_j->>'id')::uuid;
    v_sha := v_j->>'content_sha256';
    IF v_j->>'trust_status' <> 'draft' OR (v_j->>'version')::int <> 1 OR NOT (v_j->>'created')::boolean
       OR (v_j->>'reactivated')::boolean OR v_sha <> encode(sha256(convert_to('one', 'UTF8')), 'hex') THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'review write result ' || v_j::text;
    END IF;
    BEGIN
      PERFORM ops.resolve_context('global.t0033probe', 'T0033_PROBE');
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM 'P0001 context ref T0033_PROBE has no approved version at global.t0033probe' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'resolve of a draft: ' || coalesce(v_e, 'null');
    END IF;

    -- approve: wrong sha refused, right sha approves
    BEGIN
      PERFORM ops.approve_doc('global.t0033probe', 'T0033_PROBE', repeat('0', 64), v_s);
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM '23514 content sha256 mismatch for T0033_PROBE at global.t0033probe: stored ' || v_sha THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'approve with a wrong sha: ' || coalesce(v_e, 'null');
    END IF;
    v_j := ops.approve_doc('global.t0033probe', 'T0033_PROBE', v_sha, v_s);
    IF (v_j->>'version')::int <> 2 OR (SELECT trust_status FROM ops.context_documents WHERE id = v_doc) <> 'approved'
       OR ops.resolve_context('global.t0033probe', 'T0033_PROBE') <> 'one' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'approve result ' || v_j::text;
    END IF;

    -- a review write over the approved version: resolve still serves the approved text
    PERFORM ops.write_doc('global.t0033probe', 'T0033_PROBE', 'manual', 'probe', 'two', NULL, 'review', NULL, NULL, v_s);
    IF ops.resolve_context('global.t0033probe', 'T0033_PROBE') <> 'one' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'draft over approved did not serve the approved text';
    END IF;

    -- derived with the fixture decision: approved, attributed
    v_j := ops.write_doc('global.t0033probe', 'T0033_PROBE', 'manual', 'probe', 'three', NULL, 'derived', ARRAY[v_dec], NULL, v_s);
    IF v_j->>'trust_status' <> 'approved' OR ops.resolve_context('global.t0033probe', 'T0033_PROBE') <> 'three'
       OR NOT EXISTS (SELECT 1 FROM ops.document_versions WHERE document_id = v_doc AND version = (v_j->>'version')::int
                         AND basis = 'derived' AND changed_by_session = v_s AND source_decision_ids = ARRAY[v_dec]
                         AND source_dispatch_ids = '{}' AND changed_by_dispatch IS NULL) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'derived write result ' || v_j::text;
    END IF;

    -- retire: resolve raises unknown; a write reactivates
    PERFORM ops.retire_doc('global.t0033probe', 'T0033_PROBE', 'probe retirement', v_s);
    BEGIN
      PERFORM ops.resolve_context('global.t0033probe', 'T0033_PROBE');
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM 'P0001 unknown context ref T0033_PROBE' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'resolve of a retired document: ' || coalesce(v_e, 'null');
    END IF;
    v_j := ops.write_doc('global.t0033probe', 'T0033_PROBE', 'manual', 'probe', 'three', NULL, 'derived', ARRAY[v_dec], NULL, v_s);
    IF NOT (v_j->>'reactivated')::boolean OR (v_j->>'created')::boolean
       OR ops.resolve_context('global.t0033probe', 'T0033_PROBE') <> 'three' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'reactivation result ' || v_j::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0933', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0933' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0033: writer probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = 'global.t0033probe')
     OR EXISTS (SELECT 1 FROM ops.context_documents) OR EXISTS (SELECT 1 FROM ops.document_versions)
     OR EXISTS (SELECT 1 FROM ops.decisions WHERE decision = '0033 probe decision') THEN
    RAISE EXCEPTION '0033: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0033 checks passed';
END $$;

-- ── 9. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0033_context_document_writer');

COMMIT;
