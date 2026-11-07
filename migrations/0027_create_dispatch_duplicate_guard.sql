-- 0027_create_dispatch_duplicate_guard
-- Dispatch cceaf074. Release 3, migration 4 of 4 (0024-0027 are promoted together as one set by a separate promote
-- dispatch after planner review). On 2026-10-13 two planner turns 14 minutes apart created identical promote
-- dispatches (81c6897b and 7873a124: same component, title and prompt) and nothing refused the second; 0024 hides an
-- unapproved duplicate promote, but a duplicate of any other type would run twice.
--   * ops.create_dispatch(ltree, ...) refuses a new dispatch when a pending or claimed dispatch on the same component
--     has the same title and the same prompt: 23514 (check_violation), message
--     'duplicate of <status> dispatch <id8> on <path>: same title and prompt'. done, failed, refused_premise and
--     cancelled dispatches do not block. The key is title AND prompt (test fixtures reuse prompt 'p' with distinct
--     titles).
--   * The check runs after every existing validation, immediately before the INSERT, so earlier refusals still win.
--   * The body is the 0023 body with only the guard added (step 5 checks that); signature, result, owner,
--     SECURITY DEFINER, search_path, ACL and comment are unchanged (tests/sql/0022 block 5 and 0023 block 1 pin the
--     comment verbatim).

BEGIN;

-- ── 1. guard; catalog state of create_dispatch
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0026_context_document_versions' THEN
    RAISE EXCEPTION '0027: expected newest ledger version 0026_context_document_versions, found %', v_newest;
  END IF;
  IF to_regprocedure('ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)') IS NULL THEN
    RAISE EXCEPTION '0027: ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid) does not exist';
  END IF;

  PERFORM set_config('ops_m0027.fn_before', (
    SELECT jsonb_build_object(
             'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
             'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
             'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc)
      FROM pg_proc p
     WHERE p.oid = 'ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)'::regprocedure)::text,
    true);
END $$;

-- ── 2. create_dispatch (0023 5d): the duplicate guard immediately before the INSERT; the body is otherwise unchanged
CREATE OR REPLACE FUNCTION ops.create_dispatch(p_node_path public.ltree, p_dispatch_type text, p_title text, p_prompt text,
                                    p_context_refs text[] DEFAULT '{}', p_priority integer DEFAULT 100,
                                    p_session uuid DEFAULT NULL)
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
                              priority, status)
  VALUES (v_project, c.id, p_dispatch_type, p_session, p_title, p_prompt, p_context_refs, p_priority, 'pending')
  RETURNING * INTO r;
  INSERT INTO ops.dispatch_nodes (dispatch_id, node_id) VALUES (r.id, c.node_id);
  RETURN r;
END $$;

-- ── 3. checks: any failure aborts the migration
DO $$
DECLARE v_before jsonb := current_setting('ops_m0027.fn_before')::jsonb; v_after jsonb; v_bad text;
        v_anchor text := E'\n\n  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt, context_refs,';
        v_guard text := E'\n  -- release 3 (cceaf074): an open dispatch with the same title and prompt on this component is a duplicate'
          || E'\n  SELECT * INTO r FROM ops.dispatches'
          || E'\n   WHERE component_id = c.id AND status IN (''pending'', ''claimed'') AND title = p_title AND prompt = p_prompt'
          || E'\n   ORDER BY created_at, id LIMIT 1;'
          || E'\n  IF FOUND THEN'
          || E'\n    RAISE EXCEPTION USING ERRCODE = ''check_violation'','
          || E'\n      MESSAGE = format(''duplicate of %s dispatch %s on %s: same title and prompt'', r.status, left(r.id::text, 8), p_node_path);'
          || E'\n  END IF;';
        v_n uuid; v_c ops.components; v_s uuid; v_d ops.dispatches; v_e text;
BEGIN
  SELECT jsonb_build_object(
           'args', pg_get_function_arguments(p.oid), 'argtypes', p.proargtypes::text, 'result', pg_get_function_result(p.oid),
           'secdef', p.prosecdef, 'config', p.proconfig, 'owner', pg_get_userbyid(p.proowner),
           'acl', p.proacl::text, 'comment', obj_description(p.oid, 'pg_proc'), 'src', p.prosrc)
    INTO v_after
    FROM pg_proc p WHERE p.oid = 'ops.create_dispatch(public.ltree, text, text, text, text[], integer, uuid)'::regprocedure;
  SELECT string_agg(k, ', ') INTO v_bad
    FROM unnest(ARRAY['args', 'argtypes', 'result', 'secdef', 'config', 'owner', 'acl', 'comment']) k
   WHERE v_after->k IS DISTINCT FROM v_before->k;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0027: create_dispatch catalog changed: %', v_bad;
  END IF;
  IF v_before->>'comment' IS DISTINCT FROM
     'M5b release 1 (cd187cd6): node-keyed create_dispatch; component at the path, node-based session check.' THEN
    RAISE EXCEPTION '0027: create_dispatch comment is %', v_before->>'comment';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_dispatch') <> 1 THEN
    RAISE EXCEPTION '0027: create_dispatch has more than one overload';
  END IF;
  -- the old body with only the guard added before the INSERT
  IF (length(v_before->>'src') - length(replace(v_before->>'src', v_anchor, ''))) / length(v_anchor) <> 1
     OR v_after->>'src' IS DISTINCT FROM replace(v_before->>'src', v_anchor, v_guard || v_anchor) THEN
    RAISE EXCEPTION '0027: body differs from the old body with the guard added';
  END IF;

  -- behaviour on a loose node/component under global with its own session, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0027probe', 'node', '0027 probe') RETURNING id INTO v_n;
    v_c := ops.create_component('global.t0027probe'::public.ltree, 'pc', 'service', NULL, 'npm test');
    v_s := ops.open_session(p_node_path => 'global.t0027probe.pc'::public.ltree, p_kind => 'planning');
    v_d := ops.create_dispatch(p_node_path => 'global.t0027probe.pc'::public.ltree, p_dispatch_type => 'modification',
                               p_title => '0027 probe', p_prompt => 'p', p_session => v_s);
    BEGIN
      PERFORM ops.create_dispatch(p_node_path => 'global.t0027probe.pc'::public.ltree, p_dispatch_type => 'modification',
                                  p_title => '0027 probe', p_prompt => 'p', p_session => v_s);
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM '23514 duplicate of pending dispatch ' || left(v_d.id::text, 8)
                            || ' on global.t0027probe.pc: same title and prompt' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0927', MESSAGE = 'identical second create: ' || coalesce(v_e, 'null');
    END IF;
    PERFORM ops.create_dispatch(p_node_path => 'global.t0027probe.pc'::public.ltree, p_dispatch_type => 'modification',
                                p_title => '0027 probe 2', p_prompt => 'p', p_session => v_s);
    IF (SELECT count(*) FROM ops.dispatches WHERE component_id = v_c.id) <> 2 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0927', MESSAGE = 'expected 2 probe dispatches';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0927', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0927' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0027: duplicate guard probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = 'global.t0027probe') THEN
    RAISE EXCEPTION '0027: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0027 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0027_create_dispatch_duplicate_guard');

COMMIT;
