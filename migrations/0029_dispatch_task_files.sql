-- 0029_dispatch_task_files
-- Dispatch f66fda07. Work-log release, migration 2 of 4 (0028-0031 are promoted together as one set by a separate
-- promote dispatch after planner review). Design 93b049b0: task_files are the repo-relative files a dispatch will
-- touch; claim-time work_log delivery (a later MCP dispatch) ranks rows whose files_changed overlap them first. The
-- database stores them; it does not interpret them.
--   * ops.dispatches.task_files text[] NOT NULL DEFAULT '{}', CHECK dispatches_task_files_clean: no NULL and no blank
--     (btrim = '') element. Existing rows get '{}'.
--   * ops.create_dispatch(ltree, ...) gains a trailing p_task_files text[] DEFAULT '{}'. The 7-argument function is
--     dropped and recreated, not overloaded (0021 pins one overload per name), so 7-positional and named calls keep
--     resolving through the default. A NULL array or a NULL / blank element is refused with 23514
--     'task_files must be an array of non-blank paths (use {} for none)'.
--   * The body is the 0027 body with only that check (after the context_refs null check) and the INSERT column added
--     (step 4 checks that); result, owner, SECURITY DEFINER, search_path, ACL and comment are as before (tests/sql/0022
--     block 5 and 0023 block 1 pin the comment verbatim).
-- ops.claim_dispatch (void) and ops.get_pending (SETOF ops.dispatches, so it returns the new column) are untouched.

BEGIN;

-- ── 1. guard; catalog state of create_dispatch and the dispatches table ACL
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0028_work_log_functions' THEN
    RAISE EXCEPTION '0029: expected newest ledger version 0028_work_log_functions, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION '0029: expected protocol version 9, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.dispatches'::regclass AND attname = 'task_files'
                AND NOT attisdropped) THEN
    RAISE EXCEPTION '0029: ops.dispatches.task_files already exists';
  END IF;
  IF to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)') IS NULL THEN
    RAISE EXCEPTION '0029: ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid) does not exist';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_dispatch') <> 1 THEN
    RAISE EXCEPTION '0029: create_dispatch has more than one overload';
  END IF;

  PERFORM set_config('ops_m0029.fn_before', (
    SELECT jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc)
      FROM pg_proc p
     WHERE p.oid = 'ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)'::regprocedure)::text,
    true);
  PERFORM set_config('ops_m0029.table_acl', (SELECT relacl::text FROM pg_class WHERE oid = 'ops.dispatches'::regclass), true);
END $$;

-- ── 2. the column; a blank element is a run of delimiter, spaces, delimiter in the \x01-joined array
ALTER TABLE ops.dispatches ADD COLUMN task_files text[] NOT NULL DEFAULT '{}';
ALTER TABLE ops.dispatches ADD CONSTRAINT dispatches_task_files_clean CHECK (
  array_position(task_files, NULL) IS NULL
  AND (cardinality(task_files) = 0
       OR (E'\x01' || array_to_string(task_files, E'\x01') || E'\x01') !~ E'\x01 *\x01'));

-- ── 3. create_dispatch: the 0027 body with the task_files check and the INSERT column
DROP FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid);
CREATE FUNCTION ops.create_dispatch(p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text,
                                    p_context_refs text[] DEFAULT '{}', p_priority integer DEFAULT 100,
                                    p_session uuid DEFAULT NULL, p_task_files text[] DEFAULT '{}')
RETURNS ops.dispatches LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components; t ops.dispatch_types; v_ref text; s ops.sessions; v_root ops.nodes; v_project uuid;
        r ops.dispatches;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  c := ops._component(p_node_path);
  IF NOT c.active THEN
    RAISE EXCEPTION 'component % is not active', p_node_path USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO t FROM ops.dispatch_types WHERE type = p_dispatch_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown dispatch type "%"', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF NOT t.active THEN
    RAISE EXCEPTION 'dispatch type "%" is not active', p_dispatch_type USING ERRCODE = 'check_violation';
  END IF;
  IF t.commit_policy <> 'none' AND length(btrim(coalesce(c.verify_cmd, ''))) = 0 THEN
    RAISE EXCEPTION 'dispatch type "%" has commit policy % but component % has no verify_cmd',
      p_dispatch_type, t.commit_policy, p_node_path USING ERRCODE = 'check_violation';
  END IF;
  IF p_context_refs IS NULL THEN
    RAISE EXCEPTION 'context_refs must be an array (use {} for none)' USING ERRCODE = 'check_violation';
  END IF;
  -- work-log release (f66fda07): task_files are repo-relative paths, stored as given
  IF p_task_files IS NULL OR array_position(p_task_files, NULL) IS NOT NULL
     OR EXISTS (SELECT 1 FROM unnest(p_task_files) f WHERE btrim(f) = '') THEN
    RAISE EXCEPTION 'task_files must be an array of non-blank paths (use {} for none)' USING ERRCODE = 'check_violation';
  END IF;
  -- a miss is the node ops.resolve_context raising P0001 ('unknown context ref' / 'heading ... not found' / 'ambiguous')
  FOREACH v_ref IN ARRAY p_context_refs LOOP
    BEGIN
      PERFORM ops.resolve_context(p_node_path, v_ref);
    EXCEPTION WHEN raise_exception THEN
      RAISE EXCEPTION 'context ref "%" does not resolve: %', v_ref, SQLERRM USING ERRCODE = 'check_violation';
    END;
  END LOOP;
  v_root := ops._node(public.subpath(p_node_path, 0, least(2, public.nlevel(p_node_path))));
  SELECT id INTO v_project FROM ops.projects WHERE node_id = v_root.id;
  IF p_session IS NOT NULL THEN
    SELECT * INTO s FROM ops.sessions WHERE id = p_session;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (SELECT path FROM ops.nodes WHERE id = coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id)))
           OPERATOR(public.<@) v_root.path THEN
      RAISE EXCEPTION 'session % is outside % (the scope of %)', p_session, v_root.path, p_node_path
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF c.node_id IS NULL THEN
    RAISE EXCEPTION 'component % has no node', p_node_path USING ERRCODE = 'check_violation';
  END IF;
  -- release 3 (cceaf074): an open dispatch with the same title and prompt on this component is a duplicate
  SELECT * INTO r FROM ops.dispatches
   WHERE component_id = c.id AND status IN ('pending', 'claimed') AND title = p_title AND prompt = p_prompt
   ORDER BY created_at, id LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'check_violation',
      MESSAGE = format('duplicate of %s dispatch %s on %s: same title and prompt', r.status, left(r.id::text, 8), p_node_path);
  END IF;

  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt, context_refs,
                              priority, status, task_files)
  VALUES (v_project, c.id, p_dispatch_type, p_session, p_title, p_prompt, p_context_refs, p_priority, 'pending', p_task_files)
  RETURNING * INTO r;
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id) VALUES (r.id, c.node_id);
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[]) TO ops_planner;
DO $$
DECLARE v_before jsonb := current_setting('ops_m0029.fn_before')::jsonb;
BEGIN
  EXECUTE format('ALTER FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[]) OWNER TO %I',
                 v_before->>'owner');
  EXECUTE format('COMMENT ON FUNCTION ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[]) IS %L',
                 v_before->>'comment');
END $$;

-- ── 4. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0029.fn_before')::jsonb; v_after jsonb; v_bad text;
        v_proc regprocedure := to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid, text[])');
        v_check_anchor text := E'\n    RAISE EXCEPTION ''context_refs must be an array (use {} for none)'' USING ERRCODE = ''check_violation'';\n  END IF;';
        v_check text := E'\n  -- work-log release (f66fda07): task_files are repo-relative paths, stored as given'
          || E'\n  IF p_task_files IS NULL OR array_position(p_task_files, NULL) IS NOT NULL'
          || E'\n     OR EXISTS (SELECT 1 FROM unnest(p_task_files) f WHERE btrim(f) = '''') THEN'
          || E'\n    RAISE EXCEPTION ''task_files must be an array of non-blank paths (use {} for none)'' USING ERRCODE = ''check_violation'';'
          || E'\n  END IF;';
        v_cols_old text := E'context_refs,\n                              priority, status)';
        v_cols_new text := E'context_refs,\n                              priority, status, task_files)';
        v_vals_old text := 'p_context_refs, p_priority, ''pending'')';
        v_vals_new text := 'p_context_refs, p_priority, ''pending'', p_task_files)';
        v_src text; v_anchor text;
        v_msg text := '23514 task_files must be an array of non-blank paths (use {} for none)';
        v_n uuid; v_c ops.components; v_s uuid; v_d ops.dispatches; v_e text; v_k bigint;
BEGIN
  IF v_proc IS NULL THEN
    RAISE EXCEPTION '0029: the 8-argument create_dispatch does not exist';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_dispatch') <> 1 THEN
    RAISE EXCEPTION '0029: create_dispatch does not have exactly one overload';
  END IF;
  SELECT jsonb_build_object(
           'args', pg_get_function_arguments(p.oid), 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc)
    INTO v_after
    FROM pg_proc p WHERE p.oid = v_proc;
  IF v_after->>'args' IS DISTINCT FROM (v_before->>'args') || ', p_task_files text[] DEFAULT ''{}''::text[]' THEN
    RAISE EXCEPTION '0029: create_dispatch arguments are %', v_after->>'args';
  END IF;
  SELECT string_agg(k, ', ') INTO v_bad
    FROM unnest(ARRAY['result', 'secdef', 'config', 'owner', 'acl', 'comment']) k
   WHERE v_after->k IS DISTINCT FROM v_before->k;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0029: create_dispatch catalog changed: %', v_bad;
  END IF;
  IF v_before->>'comment' IS DISTINCT FROM
     'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.' THEN
    RAISE EXCEPTION '0029: create_dispatch comment is %', v_before->>'comment';
  END IF;
  -- the old body with only the check and the INSERT column added; each anchor matches exactly once
  v_src := v_before->>'src';
  FOREACH v_anchor IN ARRAY ARRAY[v_check_anchor, v_cols_old, v_vals_old] LOOP
    IF (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor) <> 1 THEN
      RAISE EXCEPTION '0029: body anchor does not match exactly once: %', v_anchor;
    END IF;
  END LOOP;
  IF v_after->>'src' IS DISTINCT FROM
     replace(replace(replace(v_src, v_check_anchor, v_check_anchor || v_check), v_cols_old, v_cols_new), v_vals_old, v_vals_new) THEN
    RAISE EXCEPTION '0029: body differs from the old body with the task_files check and INSERT column added';
  END IF;
  IF NOT has_function_privilege('ops_planner', v_proc, 'EXECUTE')
     OR has_function_privilege('ops_executor', v_proc, 'EXECUTE')
     OR has_function_privilege('public', v_proc, 'EXECUTE') THEN
    RAISE EXCEPTION '0029: create_dispatch EXECUTE is not ops_planner only';
  END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'ops.dispatches'::regclass) IS DISTINCT FROM current_setting('ops_m0029.table_acl')
     OR has_table_privilege('ops_executor', 'ops.dispatches', 'SELECT, INSERT, UPDATE, DELETE')
     OR NOT has_table_privilege('ops_planner', 'ops.dispatches', 'SELECT') THEN
    RAISE EXCEPTION '0029: table privileges on ops.dispatches changed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                  WHERE a.attrelid = 'ops.dispatches'::regclass AND a.attname = 'task_files'
                    AND a.atttypid = 'text[]'::regtype AND a.attnotnull
                    AND pg_get_expr(d.adbin, d.adrelid) = '''{}''::text[]')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.dispatches'::regclass
                       AND conname = 'dispatches_task_files_clean' AND contype = 'c' AND convalidated)
     OR EXISTS (SELECT 1 FROM ops.dispatches WHERE task_files <> '{}') THEN
    RAISE EXCEPTION '0029: task_files column, default, check or backfill wrong';
  END IF;

  -- behaviour on a loose node/component under global with its own session, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0029probe', 'node', '0029 probe') RETURNING id INTO v_n;
    v_c := ops.create_component('global.t0029probe'::public.ltree, 'pc', 'service', NULL, 'npm test');
    v_s := ops.open_session(p_node_path => 'global.t0029probe.pc'::public.ltree, p_kind => 'planning');
    v_d := ops.create_dispatch(p_node_path => 'global.t0029probe.pc'::public.ltree, p_dispatch_type => 'modification',
                               p_title => '0029 probe default', p_prompt => 'p', p_session => v_s);
    IF v_d.task_files IS DISTINCT FROM '{}'::text[] THEN
      RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'default task_files ' || coalesce(v_d.task_files::text, 'null');
    END IF;
    v_d := ops.create_dispatch(p_node_path => 'global.t0029probe.pc'::public.ltree, p_dispatch_type => 'modification',
                               p_title => '0029 probe files', p_prompt => 'p', p_session => v_s,
                               p_task_files => ARRAY['a/b.ts', 'c.sql']);
    IF (SELECT task_files FROM ops.dispatches WHERE id = v_d.id) IS DISTINCT FROM ARRAY['a/b.ts', 'c.sql'] THEN
      RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'stored task_files';
    END IF;
    SELECT count(*) INTO v_k FROM ops.dispatches WHERE component_id = v_c.id;
    FOREACH v_anchor IN ARRAY ARRAY['NULL', 'ARRAY[''a.ts'', NULL]', 'ARRAY[''a.ts'', ''  '']'] LOOP
      BEGIN
        EXECUTE format('SELECT ops.create_dispatch(p_node_path => %L::public.ltree, p_dispatch_type => %L, p_title => %L, '
                       'p_prompt => %L, p_session => %L::uuid, p_task_files => %s::text[])',
                       'global.t0029probe.pc', 'modification', '0029 probe refused', 'p', v_s, v_anchor);
        v_e := 'success';
      EXCEPTION WHEN OTHERS THEN
        v_e := SQLSTATE || ' ' || SQLERRM;
      END;
      IF v_e IS DISTINCT FROM v_msg THEN
        RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'task_files ' || v_anchor || ': ' || coalesce(v_e, 'null');
      END IF;
    END LOOP;
    IF (SELECT count(*) FROM ops.dispatches WHERE component_id = v_c.id) <> v_k THEN
      RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'a refused create wrote a row';
    END IF;
    v_d := ops.create_dispatch('global.t0029probe.pc'::public.ltree, 'modification', '0029 probe positional', 'p',
                               '{}'::text[], 100, v_s);
    IF v_d.task_files IS DISTINCT FROM '{}'::text[] THEN
      RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = '7-positional call';
    END IF;
    IF (SELECT array_agg(g.task_files::text ORDER BY g.title) FROM ops.get_pending('global.t0029probe.pc'::public.ltree) g)
       IS DISTINCT FROM ARRAY['{}', '{a/b.ts,c.sql}', '{}'] THEN
      RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'get_pending task_files';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0929', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0929' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0029: task_files probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = 'global.t0029probe') THEN
    RAISE EXCEPTION '0029: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0029 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0029_dispatch_task_files');

COMMIT;
