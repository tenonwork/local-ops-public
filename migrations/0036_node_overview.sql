-- 0036_node_overview
-- Dispatch 9079b41d. Node overview release (c4db6ad1); promoted by a separate promote dispatch after planner review.
-- No protocol_rules change; no table change.
--   * ops.node_overview(ltree, integer): the overview a planner sees when it opens a session at a node, one bounded
--     block of plain text rendered here. Sections NODE, CONTEXT (ancestors, then the documents resolve_context would
--     resolve at the node: index lines only, never content), CHILDREN, NEXT STEP (latest closed session on exactly this
--     node with a next_step), BACKLOG (open items in the subtree, minus those under a strict-descendant project).
--   * Budget: while the text is longer than p_max_chars, trim in order, re-measuring after each change: (1) medium and
--     low lines -> one count line; (2) child lines from the end -> '+n more children'; (3) ancestor summaries;
--     (4) listed backlog lines from the end -> one count line; (5) document lines -> key list, then a count. The NODE
--     line and the NEXT STEP section are never trimmed; the most trimmed form is returned when nothing more can go.
--   * open_session is unchanged (its result stays uuid); the MCP change is a later dispatch.
-- The executor gets nothing new: its SELECT and EXECUTE sets are checked against the step-1 snapshot.

BEGIN;

-- ── 1. guard; snapshots for step 3
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0035_node_summaries' THEN
    RAISE EXCEPTION '0036: expected newest ledger version 0035_node_summaries, found %', v_newest;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'node_overview') THEN
    RAISE EXCEPTION '0036: a function ops.node_overview already exists';
  END IF;

  PERFORM set_config('ops_m0036.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0036.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0036.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  IF EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
              WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                AND has_table_privilege('ops_planner', c.oid, p)) THEN
    RAISE EXCEPTION '0036: ops_planner holds a table write privilege in ops';
  END IF;
  PERFORM set_config('ops_m0036.counts', (SELECT jsonb_build_object(
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents)))::text, true);
END $$;

-- ── 2. reader
CREATE FUNCTION ops.node_overview(p_node_path public.ltree, p_max_chars integer DEFAULT 4000)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  n ops.nodes;
  v_node_line text;
  v_anc_full text[]; v_anc_path text[];
  v_doc_full text[]; v_doc_keys text[]; v_doc_n integer;
  v_child text[]; v_child_n integer; v_child_keep integer;
  v_next text[];
  v_list text[]; v_list_sev text[]; v_list_n integer; v_list_keep integer;
  v_ml text[]; v_medium integer; v_low integer;
  v_trim1 boolean := false; v_trim3 boolean := false; v_doc_mode integer := 0;
  v_lines text[]; v_text text; v_s ops.sessions;
BEGIN
  n := ops._node(p_node_path);
  IF p_max_chars IS NULL OR p_max_chars < 500 THEN
    RAISE EXCEPTION 'p_max_chars must be at least 500' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- 1 NODE
  v_node_line := 'NODE ' || n.path::text || ' (' || n.kind::text || ') — ' || coalesce(n.summary, '(no summary)');

  -- 2 CONTEXT: ancestors root first, then the documents resolve_context would resolve here
  SELECT coalesce(array_agg('  ' || a.path::text || ' — ' || coalesce(a.summary, '(no summary)') ORDER BY public.nlevel(a.path)), '{}'),
         coalesce(array_agg('  ' || a.path::text ORDER BY public.nlevel(a.path)), '{}')
    INTO v_anc_full, v_anc_path
    FROM ops.nodes a
   WHERE a.path OPERATOR(public.@>) n.path AND a.id <> n.id;

  SELECT coalesce(array_agg(x.line ORDER BY x.doc_key), '{}'), coalesce(array_agg(x.doc_key ORDER BY x.doc_key), '{}')
    INTO v_doc_full, v_doc_keys
    FROM (SELECT DISTINCT ON (d.doc_key) d.doc_key,
                 '  doc ' || d.doc_key || ' (' || d.home || ', v' || d.version || ') — ' || d.title
                 || coalesce(': ' || left(d.summary, 160), '')
                 || CASE WHEN d.trust_status <> 'approved'
                          AND NOT EXISTS (SELECT 1 FROM ops.document_versions dv
                                           WHERE dv.document_id = d.id AND dv.trust_status = 'approved')
                         THEN ' [no approved version]' ELSE '' END
                 || CASE WHEN d.at_level > 1 THEN ' [ambiguous]' ELSE '' END AS line
            FROM (SELECT cd.id, cd.doc_key, cd.title, cd.summary, cd.version, cd.trust_status, dn.path::text AS home,
                         public.nlevel(dn.path) AS lvl,
                         max(public.nlevel(dn.path)) OVER (PARTITION BY cd.doc_key) AS deepest,
                         count(*) OVER (PARTITION BY cd.doc_key, public.nlevel(dn.path)) AS at_level
                    FROM ops.context_documents cd JOIN ops.nodes dn ON dn.id = cd.node_id
                   WHERE dn.path OPERATOR(public.@>) n.path AND cd.retired_at IS NULL) d
           WHERE d.lvl = d.deepest
           ORDER BY d.doc_key, d.home, d.id) x;
  v_doc_n := cardinality(v_doc_keys);

  -- 3 CHILDREN: active direct children by key, with the active nodes strictly below each
  SELECT coalesce(array_agg('  ' || c.key || ' — ' || coalesce(c.summary, '(no summary)') || ' (+'
                            || (SELECT count(*) FROM ops.nodes b
                                 WHERE b.status = 'active' AND b.path OPERATOR(public.<@) c.path AND b.id <> c.id)
                            || ' below)' ORDER BY c.key), '{}')
    INTO v_child
    FROM ops.nodes c
   WHERE c.parent_id = n.id AND c.status = 'active';
  v_child_n := cardinality(v_child);
  v_child_keep := v_child_n;

  -- 4 NEXT STEP: latest closed session on exactly this node with a next_step
  SELECT * INTO v_s FROM ops.sessions s
   WHERE s.node_id = n.id AND s.status = 'closed' AND s.next_step IS NOT NULL
   ORDER BY s.closed_at DESC, s.id DESC LIMIT 1;
  IF v_s.id IS NOT NULL THEN
    v_next := ARRAY['NEXT STEP (' || left(v_s.id::text, 8) || ', closed '
                    || to_char(v_s.closed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC)', v_s.next_step];
  ELSE
    v_next := ARRAY['NEXT STEP', '  none at this node'];
  END IF;

  -- 5 BACKLOG: open items in the subtree, minus those under a project strictly below this node
  SELECT coalesce(array_agg(x.line ORDER BY x.ord, x.created_at, x.id) FILTER (WHERE x.ord <= 3), '{}'),
         coalesce(array_agg(x.sev ORDER BY x.ord, x.created_at, x.id) FILTER (WHERE x.ord <= 3), '{}'),
         coalesce(array_agg(x.line ORDER BY x.ord, x.created_at, x.id) FILTER (WHERE x.ord > 3), '{}'),
         count(*) FILTER (WHERE x.sev = 'medium'), count(*) FILTER (WHERE x.sev = 'low')
    INTO v_list, v_list_sev, v_ml, v_medium, v_low
    FROM (SELECT b.id, b.created_at, b.severity::text AS sev,
                 array_position(ARRAY['critical', 'high', 'untriaged', 'medium', 'low'], b.severity::text) AS ord,
                 '  ' || left(b.id::text, 8) || ' [' || b.severity::text || '/' || b.kind::text || '] ' || left(b.title, 100)
                 || CASE WHEN h.id <> n.id THEN ' (@' || h.path::text || ')' ELSE '' END AS line
            FROM ops.backlog_items b JOIN ops.nodes h ON h.id = b.home_node_id
           WHERE b.status = 'open' AND h.path OPERATOR(public.<@) n.path
             AND NOT EXISTS (SELECT 1 FROM ops.nodes p
                              WHERE p.kind = 'project' AND p.id <> n.id AND p.path OPERATOR(public.<@) n.path
                                AND h.path OPERATOR(public.<@) p.path)) x;
  v_list_n := cardinality(v_list);
  v_list_keep := v_list_n;

  -- render; while too long, apply the next trim step and re-measure
  LOOP
    v_lines := ARRAY[v_node_line, 'CONTEXT'];
    v_lines := array_cat(v_lines, CASE WHEN v_trim3 THEN v_anc_path ELSE v_anc_full END);
    IF v_doc_n > 0 THEN
      v_lines := array_cat(v_lines, CASE v_doc_mode
                                      WHEN 0 THEN v_doc_full
                                      WHEN 1 THEN ARRAY['  docs: ' || array_to_string(v_doc_keys, ', ')]
                                      ELSE ARRAY['  docs: ' || v_doc_n || ' (resolve_context)'] END);
    END IF;

    v_lines := array_append(v_lines, 'CHILDREN');
    IF v_child_n = 0 THEN
      v_lines := array_append(v_lines, '  none');
    ELSE
      v_lines := array_cat(v_lines, v_child[1:v_child_keep]);
      IF v_child_keep < v_child_n THEN
        v_lines := array_append(v_lines, '  +' || (v_child_n - v_child_keep) || ' more children');
      END IF;
    END IF;

    v_lines := array_cat(v_lines, v_next);

    v_lines := array_append(v_lines, 'BACKLOG (open, subtree)');
    IF v_list_n = 0 AND v_medium + v_low = 0 THEN
      v_lines := array_append(v_lines, '  none');
    ELSE
      v_lines := array_cat(v_lines, v_list[1:v_list_keep]);
      IF v_list_keep < v_list_n THEN
        v_lines := array_append(v_lines,
          '  ' || (SELECT string_agg('+' || t.cnt || ' ' || t.sev, ', ' ORDER BY t.ord)
                     FROM (SELECT u.sev, count(*) AS cnt,
                                  array_position(ARRAY['critical', 'high', 'untriaged'], u.sev) AS ord
                             FROM unnest(v_list_sev[v_list_keep + 1:v_list_n]) u(sev) GROUP BY u.sev) t)
          || ' not listed — list_backlog');
      END IF;
      IF NOT v_trim1 THEN
        v_lines := array_cat(v_lines, v_ml);
      ELSIF v_medium + v_low > 0 THEN
        v_lines := array_append(v_lines, '  ' || concat_ws(' · ', CASE WHEN v_medium > 0 THEN 'medium ' || v_medium END,
                                                                   CASE WHEN v_low > 0 THEN 'low ' || v_low END));
      END IF;
    END IF;

    v_text := array_to_string(v_lines, E'\n');
    EXIT WHEN length(v_text) <= p_max_chars;

    IF NOT v_trim1 AND v_medium + v_low > 0 THEN
      v_trim1 := true;                                   -- (1)
    ELSIF v_child_keep > 0 THEN
      v_child_keep := v_child_keep - 1;                  -- (2)
    ELSIF NOT v_trim3 AND cardinality(v_anc_full) > 0 THEN
      v_trim3 := true;                                   -- (3)
    ELSIF v_list_keep > 0 THEN
      v_list_keep := v_list_keep - 1;                    -- (4)
    ELSIF v_doc_n > 0 AND v_doc_mode < 2 THEN
      v_doc_mode := v_doc_mode + 1;                      -- (5)
    ELSE
      EXIT;                                              -- most trimmed form
    END IF;
  END LOOP;
  RETURN v_text;
END $$;
REVOKE ALL ON FUNCTION ops.node_overview(public.ltree, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.node_overview(public.ltree, integer) TO ops_planner;
COMMENT ON FUNCTION ops.node_overview(public.ltree, integer) IS
  'Node overview release (c4db6ad1): bounded plain-text overview of a node for session opening; planner only.';

-- ── 3. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text; v_a uuid; v_s uuid; v_out text; v_pos integer[]; v_next text;
        v_path text := current_setting('search_path');
BEGIN
  -- catalog of step 2; catalog text is rendered with schema-qualified names: no public on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'node_overview') <> 1
     OR NOT (SELECT prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=ops, pg_temp']
                    AND pg_get_userbyid(proowner) = v_owner AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
                    AND pg_get_function_arguments(oid) = 'p_node_path public.ltree, p_max_chars integer DEFAULT 4000'
                    AND pg_get_function_result(oid) = 'text'
                    AND obj_description(oid, 'pg_proc') = 'Node overview release (c4db6ad1): bounded plain-text overview of a node for session opening; planner only.'
                    AND prosrc NOT LIKE '%wait for release 2%' AND prosrc NOT LIKE '%in the project of session%'
               FROM pg_proc WHERE oid = 'ops.node_overview(public.ltree, integer)'::regprocedure)
     OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
           FROM pg_proc p, aclexplode(p.proacl) a
          WHERE p.oid = 'ops.node_overview(public.ltree, integer)'::regprocedure AND a.grantee <> p.proowner)
        <> ARRAY['ops_planner'] THEN
    RAISE EXCEPTION '0036: ops.node_overview signature, volatility, SECURITY DEFINER, search_path, owner, comment, body or ACL wrong';
  END IF;
  PERFORM set_config('search_path', v_path, true);

  -- nothing else changed
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0036.executor_reads')
     OR (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
          WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text
        <> current_setting('ops_m0036.executor_fns') THEN
    RAISE EXCEPTION '0036: ops_executor SELECT or EXECUTE set changed';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0036: ops_planner holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules)
     IS DISTINCT FROM current_setting('ops_m0036.rules_md5') THEN
    RAISE EXCEPTION '0036: protocol_rules changed';
  END IF;

  -- behaviour on probe nodes under global with their own session and backlog, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title, summary)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0036a', 'node', '0036 probe', '0036 probe node.')
    RETURNING id INTO v_a;
    INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_a, 'child', 'node', '0036 probe child');
    PERFORM ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0036p', p_name => '0036 probe project');
    v_s := ops.open_session(p_node_path => 'global.t0036a'::public.ltree, p_kind => 'planning');
    v_next := '0036 probe next step: ' || repeat('n', 200);
    UPDATE ops.sessions SET status = 'closed', close_reason = 'normal', closed_at = '2026-01-02 03:04:00+00', next_step = v_next
     WHERE id = v_s;
    INSERT INTO ops.backlog_items (home_node_id, severity, kind, title, status)
    SELECT h.id, s.sev::ops.backlog_severity, 'task', '0036 probe ' || h.key || ' ' || s.sev || ' ' || repeat('t', 60), 'open'
      FROM ops.nodes h, unnest(ARRAY['critical', 'high', 'untriaged', 'medium', 'low']) s(sev)
     WHERE h.path::text IN ('global.t0036a', 'global.t0036p');

    v_out := ops.node_overview('global.t0036a', 100000);
    v_pos := ARRAY[strpos(v_out, 'NODE global.t0036a (node) — 0036 probe node.'), strpos(v_out, E'\nCONTEXT\n'),
                   strpos(v_out, E'\nCHILDREN\n'), strpos(v_out, E'\nNEXT STEP ('), strpos(v_out, E'\nBACKLOG (open, subtree)\n')];
    IF v_pos[1] <> 1 OR NOT (0 < v_pos[2] AND v_pos[2] < v_pos[3] AND v_pos[3] < v_pos[4] AND v_pos[4] < v_pos[5])
       OR strpos(v_out, E'closed 2026-01-02 03:04 UTC)\n' || v_next || E'\nBACKLOG') = 0
       OR strpos(v_out, E'\n  child — (no summary) (+0 below)\n') = 0
       OR (SELECT count(*) FROM regexp_matches(v_out, '0036 probe t0036a ', 'g')) <> 5
       OR strpos(v_out, 't0036p') > 0 OR right(v_out, 1) = E'\n' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0936', MESSAGE = 'sections at global.t0036a: ' || v_out;
    END IF;
    -- the project boundary: global omits the project's items, the project shows them
    v_out := ops.node_overview('global', 1000000);
    IF (SELECT count(*) FROM regexp_matches(v_out, '0036 probe t0036a ', 'g')) <> 5 OR strpos(v_out, '0036 probe t0036p') > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0936', MESSAGE = 'project boundary at global';
    END IF;
    v_out := ops.node_overview('global.t0036p', 1000000);
    IF (SELECT count(*) FROM regexp_matches(v_out, '0036 probe t0036p ', 'g')) <> 5 OR strpos(v_out, '0036 probe t0036a') > 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0936', MESSAGE = 'project boundary at global.t0036p';
    END IF;
    v_out := ops.node_overview('global.t0036a', 500);
    IF length(v_out) > 500 OR strpos(v_out, E'\n' || v_next || E'\n') = 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0936', MESSAGE = 'budget 500 (' || length(v_out) || '): ' || v_out;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0936', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0936' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0036: node overview probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text LIKE 'global.t0036%')
     OR EXISTS (SELECT 1 FROM ops.projects WHERE key = 't0036p')
     OR (SELECT jsonb_build_object(
           'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
           'backlog_items', (SELECT count(*) FROM ops.backlog_items),
           'context_documents', (SELECT count(*) FROM ops.context_documents)))
        <> current_setting('ops_m0036.counts')::jsonb THEN
    RAISE EXCEPTION '0036: probe rows were not rolled back, or row counts changed';
  END IF;
  RAISE NOTICE '0036 checks passed';
END $$;

-- ── 4. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0036_node_overview');

COMMIT;
