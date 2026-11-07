-- 0035_node_summaries
-- Dispatch 9903da02. Node summaries (release dd73af1f); promoted by a separate promote dispatch after planner review.
-- No protocol_rules change.
--   * ops.nodes.summary stays nullable; when present it is one line (no \r or \n), non-blank after trimming, at most
--     200 characters (CHECK nodes_summary_shape). Each write stamps summary_updated_at and, through the writer,
--     summary_session_id (CHECK nodes_summary_stamp: a session stamp needs a time stamp). No history table; summaries
--     are never derived from documents. Completeness is the MCP tool layer's and a health check's job, not the table's.
--   * The three existing nodes are backfilled (session NULL, time = this migration's now()).
--   * create_project / create_component gain a trailing p_summary text DEFAULT NULL (replaced, not overloaded); a
--     non-null summary is stored and stamps summary_updated_at (no session: these functions take none).
--   * ops.set_node_summary(ltree, text, uuid): planner-only writer; node and session through ops._doc_session.
-- The executor gets nothing new: its SELECT and EXECUTE sets are checked against the step-1 snapshot.

BEGIN;

-- ── 1. guard; snapshots for step 5
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0034_decision_read_path' THEN
    RAISE EXCEPTION '0035: expected newest ledger version 0034_decision_read_path, found %', v_newest;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.nodes'::regclass AND NOT attisdropped
                AND attname IN ('summary_updated_at', 'summary_session_id')) THEN
    RAISE EXCEPTION '0035: ops.nodes already has summary_updated_at or summary_session_id';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'set_node_summary') THEN
    RAISE EXCEPTION '0035: a function ops.set_node_summary already exists';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_project') <> 1
     OR to_regprocedure('ops.create_project(public.ltree,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION '0035: expected exactly one ops.create_project(ltree, text, text, jsonb)';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'create_component') <> 1
     OR to_regprocedure('ops.create_component(public.ltree,text,text,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION '0035: expected exactly one ops.create_component(ltree, text, text, text, text, jsonb)';
  END IF;

  PERFORM set_config('ops_m0035.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0035.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0035.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  IF EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
              WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                AND has_table_privilege('ops_planner', c.oid, p)) THEN
    RAISE EXCEPTION '0035: ops_planner holds a table write privilege in ops';
  END IF;
  PERFORM set_config('ops_m0035.nodes', (SELECT count(*) FROM ops.nodes)::text, true);
END $$;

-- ── 2. stamp columns, backfill, shape and stamp checks
ALTER TABLE ops.nodes
  ADD COLUMN summary_updated_at timestamptz,
  ADD COLUMN summary_session_id uuid REFERENCES ops.sessions(id);

DO $$
DECLARE r record; v_n integer;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('global', 'Root of the local-ops tree: framework-wide decisions, the MANUAL, and the rules every project inherits.'),
      ('global.local-ops', 'The local-ops framework itself: planning, decisions, backlog and vision for building and running it.'),
      ('global.local-ops.core', 'Core repo: Postgres ops schema, numbered migrations, the local_ops MCP server and their tests.')
    ) AS t(path, summary) LOOP
    UPDATE ops.nodes SET summary = r.summary, summary_updated_at = now()
     WHERE path::text = r.path AND summary IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN
      RAISE EXCEPTION '0035: backfill of % hit % rows with summary NULL, expected 1', r.path, v_n;
    END IF;
  END LOOP;
END $$;

ALTER TABLE ops.nodes
  ADD CONSTRAINT nodes_summary_shape
    CHECK (summary IS NULL OR (btrim(summary) <> '' AND summary !~ '[\r\n]' AND char_length(summary) <= 200)),
  ADD CONSTRAINT nodes_summary_stamp CHECK (summary_session_id IS NULL OR summary_updated_at IS NOT NULL);

-- ── 3. create_project / create_component with a trailing p_summary (bodies otherwise unchanged)
DROP FUNCTION ops.create_project(public.ltree, text, text, jsonb);
CREATE FUNCTION ops.create_project(p_parent_path public.ltree, p_key text, p_name text, p_params jsonb DEFAULT '{}',
                                   p_summary text DEFAULT NULL)
RETURNS ops.projects LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_parent ops.nodes; v_node uuid; r ops.projects;
BEGIN
  v_parent := ops._node(p_parent_path);
  IF v_parent.kind <> 'global' THEN
    RAISE EXCEPTION 'parent of project "%" must be the global node, not % (deeper parents wait for release 2)',
      p_key, v_parent.path;
  END IF;
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid project key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_name, ''))) = 0 THEN
    RAISE EXCEPTION 'project "%" needs a name', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of project "%" must be a JSON object', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.projects WHERE key = p_key) THEN
    RAISE EXCEPTION 'project "%" already exists', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under the global node', p_key USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO ops.projects (key, name, params) VALUES (p_key, p_name, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title, summary, summary_updated_at)
  VALUES (v_parent.id, p_key, 'project', p_name, p_summary, CASE WHEN p_summary IS NOT NULL THEN now() END)
  RETURNING id INTO v_node;
  UPDATE ops.projects SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

DROP FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb);
CREATE FUNCTION ops.create_component(p_parent_path public.ltree, p_key text, p_kind text, p_repo_ref text DEFAULT NULL,
                                     p_verify_cmd text DEFAULT NULL, p_params jsonb DEFAULT '{}',
                                     p_summary text DEFAULT NULL)
RETURNS ops.components LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE v_parent ops.nodes; v_project uuid; v_node uuid; r ops.components;
BEGIN
  v_parent := ops._node(p_parent_path);
  IF v_parent.kind = 'global'
     OR EXISTS (SELECT 1 FROM ops.nodes a
                 WHERE a.component_id IS NOT NULL AND v_parent.path OPERATOR(public.<@) a.path) THEN
    RAISE EXCEPTION 'parent % of component "%" must be a project or plain node outside any component',
      v_parent.path, p_key;
  END IF;
  IF p_key IS NULL OR p_key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid component key "%"', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF length(btrim(coalesce(p_kind, ''))) = 0 THEN
    RAISE EXCEPTION 'component "%/%" needs a kind', v_parent.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_params IS NULL OR jsonb_typeof(p_params) <> 'object' THEN
    RAISE EXCEPTION 'params of component "%/%" must be a JSON object', v_parent.key, p_key
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key AND component_id IS NOT NULL) THEN
    RAISE EXCEPTION 'component "%/%" already exists', v_parent.key, p_key USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE parent_id = v_parent.id AND key = p_key) THEN
    RAISE EXCEPTION 'a node "%" already exists under %', p_key, v_parent.path USING ERRCODE = 'check_violation';
  END IF;
  -- the depth-2 ancestor's projects row, if any
  SELECT id INTO v_project FROM ops.projects
   WHERE node_id = (SELECT id FROM ops.nodes
                     WHERE path OPERATOR(public.=) public.subpath(v_parent.path, 0, least(2, public.nlevel(v_parent.path))));

  INSERT INTO ops.components (project_id, key, kind, repo_ref, verify_cmd, params)
  VALUES (v_project, p_key, p_kind, p_repo_ref, p_verify_cmd, p_params) RETURNING * INTO r;
  INSERT INTO ops.nodes (parent_id, key, kind, title, component_id, summary, summary_updated_at)
  VALUES (v_parent.id, p_key, 'node', p_key, r.id, p_summary, CASE WHEN p_summary IS NOT NULL THEN now() END)
  RETURNING id INTO v_node;
  UPDATE ops.components SET node_id = v_node WHERE id = r.id RETURNING * INTO r;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION ops.create_project(public.ltree, text, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_project(public.ltree, text, text, jsonb, text) TO ops_planner;
REVOKE ALL ON FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb, text) TO ops_planner;
COMMENT ON FUNCTION ops.create_project(public.ltree, text, text, jsonb, text) IS
  'Node summary release (dd73af1f): node-keyed create_project; the parent must be the global node.';
COMMENT ON FUNCTION ops.create_component(public.ltree, text, text, text, text, jsonb, text) IS
  'Node summary release (dd73af1f): node-keyed create_component; the parent is a project node or a plain node outside any component (not the global node); project_id from the depth-2 ancestor, else NULL; duplicate = a node with that key under the parent.';

-- ── 4. planner writer
CREATE FUNCTION ops.set_node_summary(p_node_path public.ltree, p_summary text, p_session uuid)
RETURNS TABLE(node_path public.ltree, summary text, summary_updated_at timestamptz, summary_session_id uuid)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes;
BEGIN
  n := ops._doc_session(p_session, p_node_path);
  IF p_summary IS NULL THEN
    RAISE EXCEPTION 'summary is required' USING ERRCODE = 'check_violation';
  END IF;
  -- shape violations surface as nodes_summary_shape (23514)
  RETURN QUERY
    UPDATE ops.nodes x SET summary = p_summary, summary_updated_at = now(), summary_session_id = p_session
     WHERE x.id = n.id
    RETURNING x.path, x.summary, x.summary_updated_at, x.summary_session_id;
END $$;
REVOKE ALL ON FUNCTION ops.set_node_summary(public.ltree, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.set_node_summary(public.ltree, text, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.set_node_summary(public.ltree, text, uuid) IS
  'Node summary release (dd73af1f): planner writer for nodes.summary; stamps time and session.';

-- ── 5. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text; v_s uuid; v_p ops.projects; v_c ops.components; v_row record; v_bad_summary text;
        v_path text := current_setting('search_path');
BEGIN
  -- catalog of steps 2-4; catalog text is rendered with schema-qualified names: no public on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
  IF (SELECT array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) || CASE WHEN attnotnull THEN ' not null' ELSE '' END
                       ORDER BY attname)
        FROM pg_attribute WHERE attrelid = 'ops.nodes'::regclass AND NOT attisdropped
         AND attname IN ('summary', 'summary_updated_at', 'summary_session_id'))
     <> ARRAY['summary text', 'summary_session_id uuid', 'summary_updated_at timestamp with time zone']
     OR (SELECT array_agg(conname::text || ': ' || pg_get_constraintdef(oid) ORDER BY conname) FROM pg_constraint
          WHERE conrelid = 'ops.nodes'::regclass AND conname IN ('nodes_summary_shape', 'nodes_summary_stamp'))
        <> ARRAY['nodes_summary_shape: CHECK (((summary IS NULL) OR ((btrim(summary) <> ''''::text) AND (summary !~ ''[\r\n]''::text) AND (char_length(summary) <= 200))))',
                 'nodes_summary_stamp: CHECK (((summary_session_id IS NULL) OR (summary_updated_at IS NOT NULL)))']
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'ops.nodes'::regclass AND contype = 'f'
                       AND confrelid = 'ops.sessions'::regclass
                       AND pg_get_constraintdef(oid) = 'FOREIGN KEY (summary_session_id) REFERENCES ops.sessions(id)') THEN
    RAISE EXCEPTION '0035: ops.nodes summary columns or constraints wrong';
  END IF;
  SELECT string_agg(e.sig, ', ') INTO v_bad
    FROM (VALUES
      ('ops.create_project(public.ltree,text,text,jsonb,text)', 'create_project',
       'p_parent_path public.ltree, p_key text, p_name text, p_params jsonb DEFAULT ''{}''::jsonb, p_summary text DEFAULT NULL::text',
       'ops.projects',
       'Node summary release (dd73af1f): node-keyed create_project; the parent must be the global node.'),
      ('ops.create_component(public.ltree,text,text,text,text,jsonb,text)', 'create_component',
       'p_parent_path public.ltree, p_key text, p_kind text, p_repo_ref text DEFAULT NULL::text, p_verify_cmd text DEFAULT NULL::text, p_params jsonb DEFAULT ''{}''::jsonb, p_summary text DEFAULT NULL::text',
       'ops.components',
       'Node summary release (dd73af1f): node-keyed create_component; the parent is a project node or a plain node outside any component (not the global node); project_id from the depth-2 ancestor, else NULL; duplicate = a node with that key under the parent.'),
      ('ops.set_node_summary(public.ltree,text,uuid)', 'set_node_summary',
       'p_node_path public.ltree, p_summary text, p_session uuid',
       'TABLE(node_path public.ltree, summary text, summary_updated_at timestamp with time zone, summary_session_id uuid)',
       'Node summary release (dd73af1f): planner writer for nodes.summary; stamps time and session.')
    ) e(sig, name, args, result, cmt)
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.sig)
   WHERE p.oid IS NULL OR NOT p.prosecdef OR p.provolatile <> 'v' OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp']
      OR pg_get_userbyid(p.proowner) <> v_owner OR pg_get_function_arguments(p.oid) <> e.args
      OR pg_get_function_result(p.oid) <> e.result OR obj_description(p.oid, 'pg_proc') IS DISTINCT FROM e.cmt
      OR (SELECT count(*) FROM pg_proc q WHERE q.pronamespace = 'ops'::regnamespace AND q.proname = e.name) <> 1
      OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
            FROM aclexplode(p.proacl) a WHERE a.grantee <> p.proowner) <> ARRAY['ops_planner'];
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0035: signature, volatility, SECURITY DEFINER, search_path, owner, comment, overloads or ACL wrong: %', v_bad;
  END IF;
  PERFORM set_config('search_path', v_path, true);

  -- nothing else changed
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0035.executor_reads')
     OR (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
          WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text
        <> current_setting('ops_m0035.executor_fns') THEN
    RAISE EXCEPTION '0035: ops_executor SELECT or EXECUTE set changed';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0035: ops_planner holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules)
     IS DISTINCT FROM current_setting('ops_m0035.rules_md5') THEN
    RAISE EXCEPTION '0035: protocol_rules changed';
  END IF;
  IF (SELECT count(*) FROM ops.nodes)::text <> current_setting('ops_m0035.nodes') THEN
    RAISE EXCEPTION '0035: ops.nodes row count changed';
  END IF;
  IF (SELECT string_agg(path::text || '=' || summary || '/' || (summary_updated_at = now())::text || '/'
                        || coalesce(summary_session_id::text, 'null'), '|' ORDER BY path::text)
        FROM ops.nodes WHERE path::text IN ('global', 'global.local-ops', 'global.local-ops.core'))
     IS DISTINCT FROM
     'global=Root of the local-ops tree: framework-wide decisions, the MANUAL, and the rules every project inherits./true/null'
     || '|global.local-ops=The local-ops framework itself: planning, decisions, backlog and vision for building and running it./true/null'
     || '|global.local-ops.core=Core repo: Postgres ops schema, numbered migrations, the local_ops MCP server and their tests./true/null' THEN
    RAISE EXCEPTION '0035: backfilled summaries wrong';
  END IF;

  -- behaviour on a probe project and component under global with their own session, rolled back by a sentinel
  BEGIN
    v_p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0035probe', p_name => '0035 probe',
                              p_summary => '0035 probe project.');
    v_c := ops.create_component(p_parent_path => 'global.t0035probe'::public.ltree, p_key => 'comp', p_kind => 'service',
                                p_summary => '0035 probe component.');
    IF NOT (SELECT summary = '0035 probe project.' AND summary_updated_at = now() AND summary_session_id IS NULL
              FROM ops.nodes WHERE id = v_p.node_id)
       OR NOT (SELECT summary = '0035 probe component.' AND summary_updated_at = now() AND summary_session_id IS NULL
                 FROM ops.nodes WHERE id = v_c.node_id) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0935', MESSAGE = 'create_project / create_component summary and stamps';
    END IF;
    v_s := ops.open_session(p_node_path => 'global.t0035probe'::public.ltree, p_kind => 'planning');
    SELECT * INTO v_row FROM ops.set_node_summary('global.t0035probe.comp', '0035 probe component, updated.', v_s);
    IF v_row.node_path::text IS DISTINCT FROM 'global.t0035probe.comp'
       OR v_row.summary IS DISTINCT FROM '0035 probe component, updated.'
       OR v_row.summary_updated_at IS DISTINCT FROM now() OR v_row.summary_session_id IS DISTINCT FROM v_s
       OR NOT (SELECT summary = '0035 probe component, updated.' AND summary_updated_at = now() AND summary_session_id = v_s
                 FROM ops.nodes WHERE id = v_c.node_id) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0935', MESSAGE = 'set_node_summary result or stored stamps';
    END IF;
    FOREACH v_bad_summary IN ARRAY ARRAY[repeat('x', 201), '', '   ', 'a' || chr(10) || 'b'] LOOP
      BEGIN
        PERFORM ops.set_node_summary('global.t0035probe.comp', v_bad_summary, v_s);
        RAISE EXCEPTION USING ERRCODE = 'P0935', MESSAGE = 'accepted summary ' || quote_literal(v_bad_summary);
      EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_bad = CONSTRAINT_NAME;
        IF v_bad IS DISTINCT FROM 'nodes_summary_shape' THEN
          RAISE EXCEPTION USING ERRCODE = 'P0935', MESSAGE = 'summary ' || quote_literal(v_bad_summary)
            || ' refused by ' || coalesce(v_bad, 'no constraint');
        END IF;
      END;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'P0935', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0935' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0035: node summary probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text LIKE 'global.t0035probe%')
     OR EXISTS (SELECT 1 FROM ops.projects WHERE key = 't0035probe')
     OR (SELECT count(*) FROM ops.nodes)::text <> current_setting('ops_m0035.nodes') THEN
    RAISE EXCEPTION '0035: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0035 checks passed';
END $$;

-- ── 6. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0035_node_summaries');

COMMIT;
