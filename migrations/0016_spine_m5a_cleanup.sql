-- 0016_spine_m5a_cleanup
-- Dispatch 23279ed8. Spine M5a: the part of spine M5 that does not depend on the local-ops project row (deleting
-- that row and nulling project_id is M5b, a later migration).
-- Decisions (inlined in the dispatch):
--   011b32a8 the component-scope trigger ops._component_scope() (0015) is attached to ops.dispatches too, so the
--            composite FKs (component_id, project_id) -> components(id, project_id), MATCH SIMPLE since 0009 made
--            project_id nullable, are no longer the only check on any table. All five are dropped, then the unique
--            key components_id_project_id_key that backs them. The function itself is not changed.
--   component_id FKs added before composite drop; found in 23279ed8 review (dispatch 6eb684b9): each of the five
--            tables gets <table>_component_id_fkey (component_id) -> components(id), NO ACTION, validated.
--   context_documents_node_idx (0009) is redundant with context_documents_node_id_doc_type_key UNIQUE (node_id, doc_type).
--   ops.update_backlog_item gains a trailing p_severity ops.backlog_severity DEFAULT NULL (NULL = unchanged).
--            The MCP tool is changed by a separate dispatch after promote.
-- Writes: none to rows; step 7 checks the row counts.
-- No CASCADE anywhere: a drop blocked by a dependency aborts the migration.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).
-- DROP + CREATE gives update_backlog_item the applying role as owner and the default PUBLIC EXECUTE, so the
-- re-grant revokes PUBLIC and grants ops_planner, which reproduces the captured ACL (step 7 compares).

BEGIN;

-- ── 0. update_backlog_item catalog state and row counts, before any change
DO $$ BEGIN
  PERFORM set_config('ops_m0016.fn_before', (
    SELECT jsonb_build_object('secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
                              'acl', p.proacl::text, 'result', pg_get_function_result(p.oid))
      FROM pg_proc p WHERE p.oid = 'ops.update_backlog_item(uuid, text, text)'::regprocedure)::text, true);
  PERFORM set_config('ops_m0016.counts_before', (
    SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
             'dispatches', (SELECT count(*) FROM ops.dispatches),
             'context_documents', (SELECT count(*) FROM ops.context_documents),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items)))::text, true);
  RAISE NOTICE 'update_backlog_item before: %', current_setting('ops_m0016.fn_before');
  RAISE NOTICE 'row counts before: %', current_setting('ops_m0016.counts_before');
END $$;

-- ── 1. guard: every dispatch with a component carries that component's project
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(d.id::text, ', ' ORDER BY d.id) INTO v_bad
    FROM ops.dispatches d LEFT JOIN ops.components c ON c.id = d.component_id
   WHERE d.component_id IS NOT NULL AND c.project_id IS DISTINCT FROM d.project_id;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'dispatches whose component belongs to another project: %', v_bad USING ERRCODE = 'check_violation';
  END IF;
  RAISE NOTICE 'dispatches component scope: no existing violations';
END $$;

-- ── 2. component-scope trigger on dispatches (project rule only; the function returns early for this table)
CREATE TRIGGER dispatches_component_scope
  BEFORE INSERT OR UPDATE OF component_id, project_id ON ops.dispatches
  FOR EACH ROW EXECUTE FUNCTION ops._component_scope();

-- ── 2a. single-column component FKs, added before the composite FKs go (same shape as nodes_component_id_fkey)
ALTER TABLE ops.sessions          ADD CONSTRAINT sessions_component_id_fkey
  FOREIGN KEY (component_id) REFERENCES ops.components(id);
ALTER TABLE ops.decisions         ADD CONSTRAINT decisions_component_id_fkey
  FOREIGN KEY (component_id) REFERENCES ops.components(id);
ALTER TABLE ops.dispatches        ADD CONSTRAINT dispatches_component_id_fkey
  FOREIGN KEY (component_id) REFERENCES ops.components(id);
ALTER TABLE ops.context_documents ADD CONSTRAINT context_documents_component_id_fkey
  FOREIGN KEY (component_id) REFERENCES ops.components(id);
ALTER TABLE ops.backlog_items     ADD CONSTRAINT backlog_items_component_id_fkey
  FOREIGN KEY (component_id) REFERENCES ops.components(id);

-- ── 3. composite FKs and their backing unique key
ALTER TABLE ops.sessions         DROP CONSTRAINT sessions_component_id_project_id_fkey;
ALTER TABLE ops.decisions         DROP CONSTRAINT decisions_component_id_project_id_fkey;
ALTER TABLE ops.dispatches        DROP CONSTRAINT dispatches_component_id_project_id_fkey;
ALTER TABLE ops.context_documents DROP CONSTRAINT context_documents_component_id_project_id_fkey;
ALTER TABLE ops.backlog_items     DROP CONSTRAINT backlog_items_component_id_project_id_fkey;
ALTER TABLE ops.components        DROP CONSTRAINT components_id_project_id_key;

-- ── 4. redundant index
DROP INDEX ops.context_documents_node_idx;

-- ── 5. update_backlog_item: optional severity
DROP FUNCTION ops.update_backlog_item(uuid, text, text);

CREATE FUNCTION ops.update_backlog_item(p_id uuid, p_status text, p_detail text DEFAULT NULL,
                                        p_severity ops.backlog_severity DEFAULT NULL)
RETURNS ops.backlog_items LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE b ops.backlog_items;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('open', 'done', 'dropped') THEN
    RAISE EXCEPTION 'invalid backlog status "%" (open, done or dropped)', p_status USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO b FROM ops.backlog_items WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'backlog item % does not exist', p_id USING ERRCODE = 'check_violation';
  END IF;
  -- open clears closed_at; a status change to done or dropped stamps now(); an unchanged status keeps it
  UPDATE ops.backlog_items
     SET status = p_status,
         closed_at = CASE WHEN p_status = 'open' THEN NULL
                          WHEN p_status <> b.status THEN now()
                          ELSE b.closed_at END,
         detail = coalesce(p_detail, detail),
         severity = coalesce(p_severity, severity)
   WHERE id = p_id
  RETURNING * INTO b;
  RETURN b;
END $$;

REVOKE ALL ON FUNCTION ops.update_backlog_item(uuid, text, text, ops.backlog_severity) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.update_backlog_item(uuid, text, text, ops.backlog_severity) TO ops_planner;
COMMENT ON FUNCTION ops.update_backlog_item(uuid, text, text, ops.backlog_severity) IS
  'Set a backlog item status (open / done / dropped; closed_at bookkeeping), optionally replace its detail and, since '
  'migration 0016, its severity (p_severity; NULL leaves it unchanged).';

-- ── 6. trigger comment
COMMENT ON TRIGGER dispatches_component_scope ON ops.dispatches IS
  'Component scope (backlog 011b32a8, migration 0016): a dispatch''s component must belong to its project. '
  'Replaces dispatches_component_id_project_id_fkey.';

-- ── 7. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0016.fn_before')::jsonb; v_after jsonb; v_bad text;
        f regprocedure := to_regprocedure('ops.update_backlog_item(uuid, text, text, ops.backlog_severity)');
BEGIN
  -- five component-scope triggers on the one function
  IF (SELECT array_agg(tgrelid::regclass::text || '.' || tgname ORDER BY tgname) FROM pg_trigger
       WHERE tgfoid = 'ops._component_scope()'::regprocedure AND NOT tgisinternal)
     IS DISTINCT FROM ARRAY['ops.backlog_items.backlog_items_component_scope',
                            'ops.context_documents.context_documents_component_scope',
                            'ops.decisions.decisions_component_scope',
                            'ops.dispatches.dispatches_component_scope',
                            'ops.sessions.sessions_component_scope'] THEN
    RAISE EXCEPTION 'component-scope triggers: expected five';
  END IF;

  -- composite FKs and backing key gone; single-column project FKs and components (project_id, key) kept
  SELECT string_agg(conname, ', ') INTO v_bad FROM pg_constraint
   WHERE connamespace = 'ops'::regnamespace
     AND (conname LIKE '%component_id_project_id_fkey' OR conname = 'components_id_project_id_key');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'constraints still present: %', v_bad;
  END IF;
  SELECT string_agg(x, ', ') INTO v_bad
    FROM unnest(ARRAY['sessions_project_id_fkey', 'decisions_project_id_fkey', 'dispatches_project_id_fkey',
                      'context_documents_project_id_fkey', 'backlog_items_project_id_fkey',
                      'components_project_id_key_key']) x
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE connamespace = 'ops'::regnamespace AND conname = x);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'constraints lost: %', v_bad;
  END IF;
  SELECT string_agg(t, ', ') INTO v_bad
    FROM unnest(ARRAY['sessions', 'decisions', 'dispatches', 'context_documents', 'backlog_items']) t
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conname = t || '_component_id_fkey' AND conrelid = ('ops.' || t)::regclass
                        AND contype = 'f' AND confrelid = 'ops.components'::regclass AND convalidated
                        AND conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                             WHERE attrelid = ('ops.' || t)::regclass AND attname = 'component_id')]
                        AND confkey = ARRAY[(SELECT attnum FROM pg_attribute
                                              WHERE attrelid = 'ops.components'::regclass AND attname = 'id')]);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'single-column component_id FK missing on: %', v_bad;
  END IF;

  IF to_regclass('ops.context_documents_node_idx') IS NOT NULL
     OR to_regclass('ops.context_documents_node_id_doc_type_key') IS NULL THEN
    RAISE EXCEPTION 'context_documents indexes: node_idx must be gone, node_id_doc_type_key kept';
  END IF;

  -- update_backlog_item: one overload; security, config, owner, ACL and result as before
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'update_backlog_item') <> 1
     OR f IS NULL THEN
    RAISE EXCEPTION 'expected exactly one overload ops.update_backlog_item(uuid, text, text, ops.backlog_severity)';
  END IF;
  SELECT jsonb_build_object('secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
                            'acl', p.proacl::text, 'result', pg_get_function_result(p.oid))
    INTO v_after FROM pg_proc p WHERE p.oid = f;
  RAISE NOTICE 'update_backlog_item after: %', v_after;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'update_backlog_item changed beyond its parameters: % -> %', v_before, v_after;
  END IF;
  IF NOT (v_after->>'secdef')::boolean OR v_after->'config' IS DISTINCT FROM '["search_path=ops, pg_temp"]'::jsonb
     OR NOT has_function_privilege('ops_planner', f, 'EXECUTE')
     OR has_function_privilege('ops_executor', f, 'EXECUTE')
     OR has_function_privilege('public', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'update_backlog_item must be SECURITY DEFINER, search_path = ops, pg_temp, EXECUTE for ops_planner only';
  END IF;

  -- no rows written
  IF (SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
             'dispatches', (SELECT count(*) FROM ops.dispatches),
             'context_documents', (SELECT count(*) FROM ops.context_documents),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items)))
     <> current_setting('ops_m0016.counts_before')::jsonb THEN
    RAISE EXCEPTION '0016 changed row counts (before %)', current_setting('ops_m0016.counts_before');
  END IF;
  RAISE NOTICE '0016 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0016_spine_m5a_cleanup');

COMMIT;
