-- 0015_spine_m4b_enforcement
-- Dispatch d98f6b4a. Spine M4b: enforcement after M4a (0014 writer functions, MCP routed through them since f043e2d).
-- No function signature changes and no new tool.
-- Decisions:
--   275da438 backlog_items.home_node_id and kind become NOT NULL here, after one last run of ops._spine_backfill(),
--            which is then dropped (0010 / 0011 kept it for this catch-up).
--   011b32a8 / 4596a343 the component-belongs-to-project rule, lost for rows with project_id NULL since 0009 made
--            project_id nullable (the composite FKs (component_id, project_id) are MATCH SIMPLE), is restored as one
--            shared trigger function on sessions, decisions, context_documents and backlog_items. It also requires
--            the node of a backlog item (home_node_id) or a document (node_id) to sit in its component's subtree.
--            Writer functions are not changed; the trigger covers them, backfills and manual SQL alike.
--   ec1a8782 / b28e2660 every planner write tool calls an ops.* SECURITY DEFINER function, so the direct table write
--            grants of ops_planner are revoked on every ops table. SELECT grants and ops_executor are unchanged.
--   147e71ce investigation dispatches get an additive "queries" execution rule; "writes" and "phases" unchanged.
--   8faeee76 ltree lives in public; ltree comparisons use OPERATOR(public.<@).
-- Writes: the helper's fill (NULL backlog kind / home_node_id, missing nodes and links), one dispatch_types row.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── 0. ACL snapshot (relations and functions) and row counts, before any change
DO $$ BEGIN
  PERFORM set_config('ops_m0015.acl_before', (
    SELECT jsonb_agg(x ORDER BY x) FROM (
      SELECT 'rel ' || c.relname || ' ' || pg_get_userbyid(a.grantee) || ' ' || a.privilege_type AS x
        FROM pg_class c, aclexplode(c.relacl) a
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'S', 'p', 'm', 'f')
      UNION ALL
      SELECT 'fn ' || p.oid::regprocedure::text || ' ' || pg_get_userbyid(a.grantee) || ' ' || a.privilege_type
        FROM pg_proc p, aclexplode(p.proacl) a
       WHERE p.pronamespace = 'ops'::regnamespace AND p.proname <> '_spine_backfill') s)::text, true);
  PERFORM set_config('ops_m0015.counts_before', (
    SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'dispatches', (SELECT count(*) FROM ops.dispatches), 'decisions', (SELECT count(*) FROM ops.decisions),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items), 'sessions', (SELECT count(*) FROM ops.sessions),
             'context_documents', (SELECT count(*) FROM ops.context_documents),
             'dispatch_types', (SELECT count(*) FROM ops.dispatch_types)))::text, true);
  PERFORM set_config('ops_m0015.investigation_before',
    (SELECT execution_rules::text FROM ops.dispatch_types WHERE type = 'investigation'), true);
  RAISE NOTICE 'row counts before: %', current_setting('ops_m0015.counts_before');
END $$;

-- ── 1. catch-up backfill
DO $$ BEGIN
  RAISE NOTICE 'spine backfill: %', ops._spine_backfill();
END $$;

-- ── 2. guard: no NULL left in backlog kind / home_node_id (no guessing)
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(id::text || ' (kind ' || coalesce(kind::text, 'NULL') || ', home_node_id '
                    || coalesce(home_node_id::text, 'NULL') || ')', ', ' ORDER BY id)
    INTO v_bad FROM ops.backlog_items WHERE kind IS NULL OR home_node_id IS NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'backlog_items with kind or home_node_id NULL after the backfill: %', v_bad
      USING ERRCODE = 'check_violation';
  END IF;
END $$;

-- ── 3. NOT NULL
ALTER TABLE ops.backlog_items
  ALTER COLUMN home_node_id SET NOT NULL,
  ALTER COLUMN kind         SET NOT NULL;

-- ── 4. the helper has done its last run
DROP FUNCTION ops._spine_backfill();

-- ── 5. component-scope trigger
CREATE FUNCTION ops._component_scope()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components; v_node uuid; v_cpath text; v_npath text;
BEGIN
  IF NEW.component_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO c FROM ops.components WHERE id = NEW.component_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'component % does not exist (%)', NEW.component_id, TG_TABLE_NAME
      USING ERRCODE = 'check_violation';
  END IF;
  IF c.project_id IS DISTINCT FROM NEW.project_id THEN
    RAISE EXCEPTION 'component % does not belong to project % (%)', NEW.component_id,
      coalesce(NEW.project_id::text, 'null'), TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  IF c.node_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_TABLE_NAME = 'backlog_items' THEN
    v_node := NEW.home_node_id;
  ELSIF TG_TABLE_NAME = 'context_documents' THEN
    v_node := NEW.node_id;
  ELSE
    RETURN NEW;
  END IF;
  IF v_node IS NULL THEN
    RETURN NEW;                              -- NOT NULL refuses it
  END IF;
  SELECT path::text INTO v_cpath FROM ops.nodes WHERE id = c.node_id;
  SELECT path::text INTO v_npath FROM ops.nodes WHERE id = v_node;
  IF v_npath IS NULL OR NOT (v_npath::public.ltree OPERATOR(public.<@) v_cpath::public.ltree) THEN
    RAISE EXCEPTION 'node % of % is outside the subtree of component % (node %)', coalesce(v_npath, v_node::text || ' (missing)'),
      TG_TABLE_NAME, NEW.component_id, v_cpath USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION ops._component_scope() FROM PUBLIC;
COMMENT ON FUNCTION ops._component_scope() IS
  'Component scope (backlog 011b32a8, migration 0015): a row with component_id must carry its component''s project_id; '
  'a backlog item''s home_node_id or a document''s node_id must be in the component''s node subtree.';

-- existing rows must already satisfy the rule
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(r.t || ':' || r.id::text, ', ' ORDER BY r.t, r.id) INTO v_bad
    FROM (SELECT 'sessions' AS t, id, project_id, component_id, NULL::uuid AS node_id FROM ops.sessions
          UNION ALL SELECT 'decisions', id, project_id, component_id, NULL FROM ops.decisions
          UNION ALL SELECT 'context_documents', id, project_id, component_id, node_id FROM ops.context_documents
          UNION ALL SELECT 'backlog_items', id, project_id, component_id, home_node_id FROM ops.backlog_items) r
    LEFT JOIN ops.components c ON c.id = r.component_id
    LEFT JOIN ops.nodes cn ON cn.id = c.node_id
    LEFT JOIN ops.nodes rn ON rn.id = r.node_id
   WHERE r.component_id IS NOT NULL
     AND (c.id IS NULL
          OR c.project_id IS DISTINCT FROM r.project_id
          OR (r.t IN ('context_documents', 'backlog_items') AND cn.id IS NOT NULL
              AND (rn.id IS NULL OR NOT (rn.path OPERATOR(public.<@) cn.path))));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'existing rows violate the component-scope rule: %', v_bad USING ERRCODE = 'check_violation';
  END IF;
  RAISE NOTICE 'component scope: no existing violations';
END $$;

CREATE TRIGGER sessions_component_scope
  BEFORE INSERT OR UPDATE OF component_id, project_id ON ops.sessions
  FOR EACH ROW EXECUTE FUNCTION ops._component_scope();
CREATE TRIGGER decisions_component_scope
  BEFORE INSERT OR UPDATE OF component_id, project_id ON ops.decisions
  FOR EACH ROW EXECUTE FUNCTION ops._component_scope();
CREATE TRIGGER context_documents_component_scope
  BEFORE INSERT OR UPDATE OF component_id, project_id, node_id ON ops.context_documents
  FOR EACH ROW EXECUTE FUNCTION ops._component_scope();
CREATE TRIGGER backlog_items_component_scope
  BEFORE INSERT OR UPDATE OF component_id, project_id, home_node_id ON ops.backlog_items
  FOR EACH ROW EXECUTE FUNCTION ops._component_scope();

-- ── 6. planner loses every direct table write; no default privilege may hand it back on new tables
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(pg_get_userbyid(d.defaclrole) || ' ' || coalesce(d.defaclnamespace::regnamespace::text, '(all)')
                    || ' ' || d.defaclobjtype::text || ' ' || d.defaclacl::text, '; ') INTO v_bad
    FROM pg_default_acl d, aclexplode(d.defaclacl) a
   WHERE a.grantee = 'ops_planner'::regrole
     AND a.privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
     AND (d.defaclnamespace = 0 OR d.defaclnamespace = 'ops'::regnamespace);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'default privileges grant ops_planner writes on future ops tables: %', v_bad;
  END IF;
END $$;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA ops FROM ops_planner;

-- ── 7. investigation dispatches: queue tools only (147e71ce)
UPDATE ops.dispatch_types
   SET execution_rules = execution_rules || '{"queries": "executor queue tools only (get_pending, claim_dispatch, complete_dispatch, fail_dispatch, get_dispatch_type); no other database queries"}'::jsonb
 WHERE type = 'investigation';

-- ── 8. checks: any failure aborts the migration
DO $$
DECLARE v_bad text; v_after jsonb; v_before jsonb := current_setting('ops_m0015.acl_before')::jsonb;
        v_rules jsonb; v_rules_before jsonb := current_setting('ops_m0015.investigation_before')::jsonb;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'backlog_items'
              AND column_name IN ('home_node_id', 'kind') AND is_nullable <> 'NO') THEN
    RAISE EXCEPTION 'backlog_items home_node_id / kind are not NOT NULL';
  END IF;
  IF to_regprocedure('ops._spine_backfill()') IS NOT NULL THEN
    RAISE EXCEPTION 'ops._spine_backfill() still exists';
  END IF;

  -- trigger function: invoker, pinned search_path, owner-only EXECUTE; four triggers on it
  IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'ops._component_scope()'::regprocedure AND NOT p.prosecdef
                  AND p.proconfig = ARRAY['search_path=ops, pg_temp']
                  AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
                  AND NOT has_function_privilege('ops_planner', p.oid, 'EXECUTE')
                  AND NOT has_function_privilege('ops_executor', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'ops._component_scope() is not SECURITY INVOKER with pinned search_path and owner-only EXECUTE';
  END IF;
  IF (SELECT array_agg(tgrelid::regclass::text || '.' || tgname ORDER BY tgname) FROM pg_trigger
       WHERE tgfoid = 'ops._component_scope()'::regprocedure AND NOT tgisinternal)
     IS DISTINCT FROM ARRAY['ops.backlog_items.backlog_items_component_scope',
                            'ops.context_documents.context_documents_component_scope',
                            'ops.decisions.decisions_component_scope', 'ops.sessions.sessions_component_scope'] THEN
    RAISE EXCEPTION 'component-scope triggers missing';
  END IF;

  -- grants: the only ACL change is ops_planner losing INSERT / UPDATE / DELETE / TRUNCATE on relations
  SELECT jsonb_agg(x ORDER BY x) INTO v_after FROM (
    SELECT 'rel ' || c.relname || ' ' || pg_get_userbyid(a.grantee) || ' ' || a.privilege_type AS x
      FROM pg_class c, aclexplode(c.relacl) a
     WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'S', 'p', 'm', 'f')
    UNION ALL
    SELECT 'fn ' || p.oid::regprocedure::text || ' ' || pg_get_userbyid(a.grantee) || ' ' || a.privilege_type
      FROM pg_proc p, aclexplode(p.proacl) a
     WHERE p.pronamespace = 'ops'::regnamespace AND p.proname <> '_component_scope') s;
  SELECT jsonb_agg(x ORDER BY x) INTO v_before FROM jsonb_array_elements_text(v_before) x
   WHERE x !~ '^rel \S+ ops_planner (INSERT|UPDATE|DELETE|TRUNCATE)$';
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'ACLs changed beyond the planner write revoke: before %, after %', v_before, v_after;
  END IF;
  SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'ops_planner still writes: %', v_bad;
  END IF;
  RAISE NOTICE 'grants: % ACL entries kept, planner writes revoked', jsonb_array_length(v_after);

  SELECT execution_rules INTO v_rules FROM ops.dispatch_types WHERE type = 'investigation';
  IF v_rules - 'queries' IS DISTINCT FROM v_rules_before - 'queries' OR NOT v_rules ? 'queries' THEN
    RAISE EXCEPTION 'investigation execution_rules: % (before %)', v_rules, v_rules_before;
  END IF;

  IF (SELECT jsonb_build_object(
             'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
             'dispatches', (SELECT count(*) FROM ops.dispatches), 'decisions', (SELECT count(*) FROM ops.decisions),
             'backlog_items', (SELECT count(*) FROM ops.backlog_items), 'sessions', (SELECT count(*) FROM ops.sessions),
             'context_documents', (SELECT count(*) FROM ops.context_documents),
             'dispatch_types', (SELECT count(*) FROM ops.dispatch_types)))
     <> current_setting('ops_m0015.counts_before')::jsonb THEN
    RAISE EXCEPTION '0015 changed row counts (before %)', current_setting('ops_m0015.counts_before');
  END IF;
  RAISE NOTICE '0015 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0015_spine_m4b_enforcement');

COMMIT;
