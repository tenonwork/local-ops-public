-- 0028_work_log_functions
-- Dispatch e0636813. Work-log release, migration 1 of 4 (0028-0031 are promoted together as one set by a separate
-- promote dispatch after planner review). Protocol version 8 -> 9.
-- ops.work_log replaces CLAUDE_LOG.md as the change log (later migrations of this release drop CLAUDE_LOG.md from
-- read_first_order and backfill its entries). The executor reaches work_log only through definer functions, never
-- table grants (tests/sql/0008 block 8 pins: executor has no SELECT and no role writes work_log / work_log_nodes).
--   * ops.log_work(dispatch, entry_type, title, ...) (SECURITY DEFINER, EXECUTE ops_executor only): one work_log row
--     (origin 'code', provenance 'recorded', session_id NULL) and one work_log_nodes row on the dispatch's component
--     node, for a claimed dispatch only. Refusals (23514): 'dispatch <uuid> does not exist',
--     'dispatch <id8> is <status>, not claimed'. Commit sha and backfill source key live in external_refs:
--     {"kind":"commit","sha":"..."}, {"kind":"claude_log","line":N}. Promote rows use entry_type 'migration'.
--   * ops.get_work_log(path, files, limit) (SECURITY DEFINER, STABLE, EXECUTE ops_executor only): distinct rows
--     tagged to a node whose path @> path, rows whose files_changed overlap files first, then newest, then id;
--     at most coalesce(limit, protocol rule work_log_delivery cap) rows. An unknown path raises P0001 (ops._node).
--   * ops.complete_dispatch: a claimed dispatch whose type has commit_policy local or push and no work_log row with
--     its dispatch_id is refused with 23514 'dispatch <id8> (commit_policy <policy>) has no work_log entry; call
--     ops.log_work first'. commit_policy none (investigation, promote) and fail_dispatch need no log. Signature,
--     result, owner, SECURITY DEFINER, search_path, ACL and comment are unchanged (step 7 checks that).
--   * Unique partial index work_log_claude_log_line_uq on the first claude_log line in external_refs.
--   * Protocol rule work_log_delivery (cap 10); protocol_changelog version 9.
-- The MCP layer (a later dispatch) calls ops.log_work then ops.complete_dispatch in one transaction.

BEGIN;

-- ── 1. guard; catalog state of complete_dispatch
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0027_create_dispatch_duplicate_guard' THEN
    RAISE EXCEPTION '0028: expected newest ledger version 0027_create_dispatch_duplicate_guard, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 8 THEN
    RAISE EXCEPTION '0028: expected protocol version 8, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname IN ('log_work', 'get_work_log')) THEN
    RAISE EXCEPTION '0028: ops.log_work or ops.get_work_log already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'work_log_delivery') THEN
    RAISE EXCEPTION '0028: protocol rule work_log_delivery already exists';
  END IF;
  IF to_regprocedure('ops.complete_dispatch(uuid, text, text)') IS NULL THEN
    RAISE EXCEPTION '0028: ops.complete_dispatch(uuid, text, text) does not exist';
  END IF;

  PERFORM set_config('ops_m0028.fn_before', (
    SELECT jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'))
      FROM pg_proc p
     WHERE p.oid = 'ops.complete_dispatch(uuid, text, text)'::regprocedure)::text,
    true);
  PERFORM set_config('ops_m0028.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
END $$;

-- ── 2. log_work: one work_log row and one work_log_nodes row for a claimed dispatch
CREATE FUNCTION ops.log_work(p_dispatch_id uuid, p_entry_type text, p_title text, p_description text DEFAULT NULL,
                             p_files_changed text[] DEFAULT '{}', p_follow_ups jsonb DEFAULT '[]',
                             p_test_summary text DEFAULT NULL, p_external_refs jsonb DEFAULT '[]')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE d ops.dispatches; v_node uuid; v_id uuid;
BEGIN
  SELECT * INTO d FROM ops.dispatches WHERE id = p_dispatch_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = format('dispatch %s does not exist', p_dispatch_id);
  END IF;
  IF d.status <> 'claimed' THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = format('dispatch %s is %s, not claimed', left(d.id::text, 8), d.status);
  END IF;
  SELECT node_id INTO v_node FROM ops.components WHERE id = d.component_id;
  IF v_node IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = format('dispatch %s has no component node', left(d.id::text, 8));
  END IF;
  INSERT INTO ops.work_log (origin, entry_type, title, description, follow_ups, files_changed, external_refs,
                            test_summary, dispatch_id, session_id, provenance)
  VALUES ('code', p_entry_type, p_title, p_description, coalesce(p_follow_ups, '[]'), coalesce(p_files_changed, '{}'),
          coalesce(p_external_refs, '[]'), p_test_summary, d.id, NULL, 'recorded')
  RETURNING id INTO v_id;
  INSERT INTO ops.work_log_nodes (work_log_id, node_id) VALUES (v_id, v_node);
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb) TO ops_executor;
COMMENT ON FUNCTION ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb) IS
  'Work-log release (e0636813): one work_log row (origin code) and one work_log_nodes row on the component node for a claimed dispatch; else 23514.';

-- ── 3. get_work_log: rows tagged to the path or an ancestor, file overlap first, then newest, capped
CREATE FUNCTION ops.get_work_log(p_node_path public.ltree, p_files text[] DEFAULT '{}', p_limit integer DEFAULT NULL)
RETURNS TABLE (id uuid, occurred_at timestamptz, entry_type text, title text, description text, files_changed text[],
               follow_ups jsonb, test_summary text, external_refs jsonb, dispatch_id uuid, file_overlap boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  PERFORM ops._node(p_node_path);
  RETURN QUERY
  SELECT w.id, w.occurred_at, w.entry_type, w.title, w.description, w.files_changed, w.follow_ups, w.test_summary,
         w.external_refs, w.dispatch_id, w.files_changed && coalesce(p_files, '{}')
    FROM ops.work_log w
   WHERE EXISTS (SELECT 1 FROM ops.work_log_nodes wn JOIN ops.nodes n ON n.id = wn.node_id
                  WHERE wn.work_log_id = w.id AND n.path OPERATOR(public.@>) p_node_path)
   ORDER BY w.files_changed && coalesce(p_files, '{}') DESC, w.occurred_at DESC, w.id
   LIMIT coalesce(p_limit, (SELECT (r.value->>'cap')::int FROM ops.protocol_rules r WHERE r.key = 'work_log_delivery'));
END $$;
REVOKE ALL ON FUNCTION ops.get_work_log(public.ltree, text[], integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.get_work_log(public.ltree, text[], integer) TO ops_executor;
COMMENT ON FUNCTION ops.get_work_log(public.ltree, text[], integer) IS
  'Work-log release (e0636813): work_log rows tagged to the path or an ancestor; file overlap first, then newest; at most p_limit or the work_log_delivery cap.';

-- ── 4. complete_dispatch (0001): a local/push dispatch needs a work_log row first; otherwise unchanged
CREATE OR REPLACE FUNCTION ops.complete_dispatch(p_id uuid, p_result text, p_report text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_policy text;
BEGIN
  SELECT t.commit_policy INTO v_policy
    FROM ops.dispatches d JOIN ops.dispatch_types t ON t.type = d.dispatch_type
   WHERE d.id = p_id AND d.status = 'claimed';
  IF v_policy IN ('local', 'push') AND NOT EXISTS (SELECT 1 FROM ops.work_log WHERE dispatch_id = p_id) THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = format('dispatch %s (commit_policy %s) has no work_log entry; call ops.log_work first',
                       left(p_id::text, 8), v_policy);
  END IF;
  UPDATE ops.dispatches SET status = 'done', result = p_result, report = p_report, completed_at = now()
   WHERE id = p_id AND status = 'claimed';
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % is not claimed', p_id; END IF;
END $$;

-- ── 5. backfill source key: one work_log row per CLAUDE_LOG.md line
CREATE UNIQUE INDEX work_log_claude_log_line_uq ON ops.work_log
  ((jsonb_path_query_first(external_refs, '$[*] ? (@.kind == "claude_log").line')))
  WHERE jsonb_path_query_first(external_refs, '$[*] ? (@.kind == "claude_log").line') IS NOT NULL;

-- ── 6. protocol rule work_log_delivery (version left at its default of 1) and changelog
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'work_log_delivery',
  jsonb_build_object(
    'cap', 10,
    'rule', 'claim_dispatch delivers work_log rows tagged to the dispatch''s node or an ancestor: rows whose files_changed overlap the dispatch''s task files first, then newest; at most cap rows.')
);
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  9,
  ARRAY['work_log_delivery'],
  'New rule work_log_delivery: work_log rows tagged to the dispatch''s node or an ancestor, file overlap first, then newest, at most cap (10) rows (work-log release, dispatch e0636813).'
);

-- ── 7. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0028.fn_before')::jsonb; v_after jsonb; v_bad text; v_fn regprocedure;
        v_n uuid; v_c ops.components; v_s uuid; v_dm uuid; v_di uuid; v_dp uuid; v_w uuid; v_e text; v_r record;
BEGIN
  SELECT jsonb_build_object(
           'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'))
    INTO v_after
    FROM pg_proc p WHERE p.oid = 'ops.complete_dispatch(uuid, text, text)'::regprocedure;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION '0028: complete_dispatch catalog changed: before %, after %', v_before, v_after;
  END IF;

  FOREACH v_fn IN ARRAY ARRAY['ops.log_work(uuid, text, text, text, text[], jsonb, text, jsonb)'::regprocedure,
                              'ops.get_work_log(public.ltree, text[], integer)'::regprocedure] LOOP
    IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                   AND pg_get_userbyid(proowner) = v_before->>'owner'
              FROM pg_proc WHERE oid = v_fn) THEN
      RAISE EXCEPTION '0028: % is not SECURITY DEFINER with search_path ops, pg_temp owned by %', v_fn, v_before->>'owner';
    END IF;
    IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
          FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner) <> ARRAY['ops_executor']
       OR NOT has_function_privilege('ops_executor', v_fn, 'EXECUTE')
       OR has_function_privilege('ops_planner', v_fn, 'EXECUTE')
       OR has_function_privilege('public', v_fn, 'EXECUTE') THEN
      RAISE EXCEPTION '0028: % ACL is not owner plus ops_executor only', v_fn;
    END IF;
  END LOOP;
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'ops.get_work_log(public.ltree, text[], integer)'::regprocedure) <> 's' THEN
    RAISE EXCEPTION '0028: get_work_log is not STABLE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'work_log_delivery' AND version = 1
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['cap', 'rule']
                    AND value->'cap' = '10'::jsonb)
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 9 AND rule_keys = ARRAY['work_log_delivery'])
     OR (SELECT max(version) FROM ops.protocol_changelog) <> 9 THEN
    RAISE EXCEPTION '0028: work_log_delivery rule or protocol_changelog version 9 missing or wrong';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'work_log_delivery')
     IS DISTINCT FROM current_setting('ops_m0028.rules_md5') THEN
    RAISE EXCEPTION '0028: other protocol_rules rows changed';
  END IF;
  IF NOT (SELECT indisunique FROM pg_index WHERE indexrelid = to_regclass('ops.work_log_claude_log_line_uq')) THEN
    RAISE EXCEPTION '0028: work_log_claude_log_line_uq missing or not unique';
  END IF;

  -- behaviour on a loose node/component under global with its own session, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0028probe', 'node', '0028 probe') RETURNING id INTO v_n;
    v_c := ops.create_component('global.t0028probe'::public.ltree, 'pc', 'service', NULL, 'npm test');
    v_s := ops.open_session(p_node_path => 'global.t0028probe.pc'::public.ltree, p_kind => 'planning');
    v_dm := (ops.create_dispatch(p_node_path => 'global.t0028probe.pc'::public.ltree, p_dispatch_type => 'modification',
                                 p_title => '0028 probe m', p_prompt => 'p', p_session => v_s)).id;
    v_di := (ops.create_dispatch(p_node_path => 'global.t0028probe.pc'::public.ltree, p_dispatch_type => 'investigation',
                                 p_title => '0028 probe i', p_prompt => 'p', p_session => v_s)).id;
    v_dp := (ops.create_dispatch(p_node_path => 'global.t0028probe.pc'::public.ltree, p_dispatch_type => 'modification',
                                 p_title => '0028 probe p', p_prompt => 'p', p_session => v_s)).id;
    PERFORM ops.claim_dispatch(v_dm, '0028 probe');
    PERFORM ops.claim_dispatch(v_di, '0028 probe');
    BEGIN
      PERFORM ops.complete_dispatch(v_dm, 'r', 'report');
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM '23514 dispatch ' || left(v_dm::text, 8)
                            || ' (commit_policy local) has no work_log entry; call ops.log_work first'
       OR (SELECT status FROM ops.dispatches WHERE id = v_dm) <> 'claimed' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0928', MESSAGE = 'complete without log: ' || coalesce(v_e, 'null');
    END IF;
    v_w := ops.log_work(v_dm, 'chore', '0028 probe log', p_files_changed => ARRAY['a.sql', 'b.sql']);
    PERFORM ops.complete_dispatch(v_dm, 'r', 'report');
    PERFORM ops.complete_dispatch(v_di, 'r', 'report');
    IF (SELECT array_agg(status::text ORDER BY title) FROM ops.dispatches WHERE id IN (v_dm, v_di)) <> ARRAY['done', 'done'] THEN
      RAISE EXCEPTION USING ERRCODE = 'P0928', MESSAGE = 'logged modification or investigation not done';
    END IF;
    BEGIN
      PERFORM ops.log_work(v_dp, 'chore', '0028 probe pending');
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM '23514 dispatch ' || left(v_dp::text, 8) || ' is pending, not claimed' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0928', MESSAGE = 'log_work on pending: ' || coalesce(v_e, 'null');
    END IF;
    SELECT * INTO v_r FROM ops.get_work_log('global.t0028probe.pc'::public.ltree, ARRAY['b.sql']);
    IF v_r.id IS DISTINCT FROM v_w OR v_r.file_overlap IS NOT TRUE OR v_r.dispatch_id IS DISTINCT FROM v_dm
       OR (SELECT count(*) FROM ops.get_work_log('global.t0028probe.pc'::public.ltree)) <> 1 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0928', MESSAGE = 'get_work_log did not return the logged row with file_overlap';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0928', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0928' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0028: work_log probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = 'global.t0028probe') OR EXISTS (SELECT 1 FROM ops.work_log
              WHERE title LIKE '0028 probe%') THEN
    RAISE EXCEPTION '0028: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0028 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0028_work_log_functions');

COMMIT;
