-- 0021_drop_project_keyed_functions
-- Dispatch 2f5152e2. Spine M5b release 2, migration 1 of 3 (0021-0023 are promoted together as one set by a separate
-- promote dispatch after planner review).
-- Drops the ten project-keyed (text) overloads superseded by the 0018 node-keyed (public.ltree) versions:
-- open_session, get_pending, get_unreviewed_reports, resolve_context, create_project, create_component,
-- create_dispatch, log_decision, add_backlog_item, and the owner-only helper ops._component(text, text).
-- Only the text overloads call text versions (_component(text,text) from get_pending 0001 and create_dispatch,
-- log_decision, add_backlog_item, open_session 0014; resolve_context(text,text) from create_dispatch 0014), so the
-- nine public functions are dropped first and ops._component(text, text) last; no CASCADE, no IF EXISTS.
-- Per function name the ops_planner / ops_executor EXECUTE grants of the surviving ltree overload equal those of the
-- dropped text overload, so no grant changes. The MCP layer has called only the ltree versions since cf9e8d92.
-- Changes nothing else: no table, no other function, no grant, no row.

BEGIN;

-- ── 1. guard: newest ledger version is 0020 and all ten text signatures exist; records the ops function count
DO $$
DECLARE v_newest text; v_missing text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0020_planner_supersedes_rule' THEN
    RAISE EXCEPTION '0021: expected newest ledger version 0020_planner_supersedes_rule, found %', v_newest;
  END IF;
  SELECT string_agg(s, ', ') INTO v_missing FROM unnest(ARRAY[
      'ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
      'ops.get_pending(text,text)',
      'ops.get_unreviewed_reports(text)',
      'ops.resolve_context(text,text)',
      'ops.create_project(text,text,jsonb)',
      'ops.create_component(text,text,text,text,text,jsonb)',
      'ops.create_dispatch(text,text,text,text,text,text[],integer,uuid)',
      'ops.log_decision(text,text,text,text,jsonb,text,text,uuid,uuid)',
      'ops.add_backlog_item(text,ops.backlog_kind,text,text,text,uuid,ops.backlog_severity)',
      'ops._component(text,text)']) s
   WHERE to_regprocedure(s) IS NULL;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '0021: project-keyed signatures missing: %', v_missing;
  END IF;
  PERFORM set_config('ops_m0021.fn_count_before',
    (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)::text, true);
  RAISE NOTICE 'ops functions before: %', current_setting('ops_m0021.fn_count_before');
END $$;

-- ── 2. drop the nine public text overloads, then the owner-only helper they call
DROP FUNCTION ops.open_session(text, text, text, ops.segment_scope, timestamptz, ops.provenance);
DROP FUNCTION ops.get_pending(text, text);
DROP FUNCTION ops.get_unreviewed_reports(text);
DROP FUNCTION ops.resolve_context(text, text);
DROP FUNCTION ops.create_project(text, text, jsonb);
DROP FUNCTION ops.create_component(text, text, text, text, text, jsonb);
DROP FUNCTION ops.create_dispatch(text, text, text, text, text, text[], integer, uuid);
DROP FUNCTION ops.log_decision(text, text, text, text, jsonb, text, text, uuid, uuid);
DROP FUNCTION ops.add_backlog_item(text, ops.backlog_kind, text, text, text, uuid, ops.backlog_severity);
DROP FUNCTION ops._component(text, text);

-- ── 3. checks: any failure aborts the migration
DO $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[
      'ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
      'ops.get_pending(text,text)',
      'ops.get_unreviewed_reports(text)',
      'ops.resolve_context(text,text)',
      'ops.create_project(text,text,jsonb)',
      'ops.create_component(text,text,text,text,text,jsonb)',
      'ops.create_dispatch(text,text,text,text,text,text[],integer,uuid)',
      'ops.log_decision(text,text,text,text,jsonb,text,text,uuid,uuid)',
      'ops.add_backlog_item(text,ops.backlog_kind,text,text,text,uuid,ops.backlog_severity)',
      'ops._component(text,text)']) s
   WHERE to_regprocedure(s) IS NOT NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0021: project-keyed signatures still present: %', v_bad;
  END IF;

  -- each name keeps exactly one overload, the 0018 one (first parameter public.ltree)
  SELECT string_agg(n || ' (' || coalesce(x.overloads, 0) || ' overloads, ltree first: ' || coalesce(x.ltree_first, false) || ')', ', ')
    INTO v_bad
    FROM unnest(ARRAY['open_session', 'get_pending', 'get_unreviewed_reports', 'resolve_context', 'create_project',
                      'create_component', 'create_dispatch', 'log_decision', 'add_backlog_item', '_component']) n
    LEFT JOIN LATERAL (
      SELECT count(*) AS overloads, bool_and(p.proargtypes[0] = 'public.ltree'::regtype) AS ltree_first
        FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = n) x ON true
   WHERE coalesce(x.overloads, 0) <> 1 OR NOT coalesce(x.ltree_first, false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0021: expected exactly one node-keyed overload per name: %', v_bad;
  END IF;

  -- no other ops function dropped or added
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace)
     <> current_setting('ops_m0021.fn_count_before')::bigint - 10 THEN
    RAISE EXCEPTION '0021: expected exactly 10 fewer ops functions (before %, now %)',
      current_setting('ops_m0021.fn_count_before'), (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace);
  END IF;
  RAISE NOTICE '0021 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0021_drop_project_keyed_functions');

COMMIT;
