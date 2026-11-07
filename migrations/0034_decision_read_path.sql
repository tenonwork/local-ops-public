-- 0034_decision_read_path
-- Dispatch a20baceb. Decision read path (decisions 3dae01c4, c4840eb8, 8e4d46a9); promoted by a separate promote
-- dispatch after planner review. No protocol_rules change.
--   * ops.current_decisions: the decisions no other decision supersedes, with their node and a derived gist (never
--     stored; no column is added to ops.decisions). gist = the first sentence (up to and including the first . ! or ?
--     followed by whitespace or the end), whitespace runs collapsed to one space, trimmed; no terminator -> the whole
--     text; longer than 200 characters -> the first 199 plus '…'. Accepted limitation: "e.g. " ends a sentence.
--   * ops.get_decisions(ltree, integer): current decisions homed at a node and its ancestors, nearest first, as gists
--     with ids. Planner-only in this release; claim-time delivery to the executor is a later release.
-- The executor gets nothing new: its SELECT and EXECUTE sets are checked against the step-1 snapshot.

BEGIN;

-- ── 1. guard; snapshots for step 4
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0033_context_document_writer' THEN
    RAISE EXCEPTION '0034: expected newest ledger version 0033_context_document_writer, found %', v_newest;
  END IF;
  IF to_regclass('ops.current_decisions') IS NOT NULL THEN
    RAISE EXCEPTION '0034: relation ops.current_decisions already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'get_decisions') THEN
    RAISE EXCEPTION '0034: a function ops.get_decisions already exists';
  END IF;

  PERFORM set_config('ops_m0034.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0034.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0034.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  IF EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
              WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                AND has_table_privilege('ops_planner', c.oid, p)) THEN
    RAISE EXCEPTION '0034: ops_planner holds a table write privilege in ops';
  END IF;
END $$;

-- ── 2. current decisions with derived gists
CREATE VIEW ops.current_decisions AS
SELECT d.id,
       left(d.id::text, 8) AS id8,
       CASE WHEN length(s.sentence) > 200 THEN left(s.sentence, 199) || '…' ELSE s.sentence END AS gist,
       d.decision, d.rationale, d.revisit_condition, d.supersedes,
       dn.node_id, n.path AS node_path, d.session_id, d.occurred_at
  FROM ops.decisions d
  JOIN ops.decision_nodes dn ON dn.decision_id = d.id
  JOIN ops.nodes n ON n.id = dn.node_id
 CROSS JOIN LATERAL (SELECT btrim(regexp_replace(d.decision, '\s+', ' ', 'g')) AS text) w
 CROSS JOIN LATERAL (SELECT coalesce(substring(w.text FROM '^.*?[.!?](?=\s|$)'), w.text) AS sentence) s
 WHERE NOT EXISTS (SELECT 1 FROM ops.decisions x WHERE x.supersedes = d.id);
REVOKE ALL ON ops.current_decisions FROM PUBLIC;
GRANT SELECT ON ops.current_decisions TO ops_planner;
COMMENT ON VIEW ops.current_decisions IS 'Decision read path (3dae01c4): current decisions with derived gists.';

-- ── 3. reader: a node and its ancestors, nearest first
CREATE FUNCTION ops.get_decisions(p_node_path public.ltree, p_limit integer DEFAULT 50)
RETURNS TABLE(id uuid, id8 text, gist text, node_path public.ltree, distance integer, occurred_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes;
BEGIN
  n := ops._node(p_node_path);
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'limit must be between 1 and 200' USING ERRCODE = 'check_violation';
  END IF;
  RETURN QUERY
    SELECT cd.id, cd.id8, cd.gist, cd.node_path, public.nlevel(n.path) - public.nlevel(cd.node_path), cd.occurred_at
      FROM ops.current_decisions cd
     WHERE cd.node_path OPERATOR(public.@>) n.path
     ORDER BY public.nlevel(n.path) - public.nlevel(cd.node_path), cd.occurred_at DESC, cd.id
     LIMIT p_limit;
END $$;
REVOKE ALL ON FUNCTION ops.get_decisions(public.ltree, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.get_decisions(public.ltree, integer) TO ops_planner;
COMMENT ON FUNCTION ops.get_decisions(public.ltree, integer) IS
  'Decision read path (c4840eb8, 8e4d46a9): current decisions at a node and its ancestors, nearest first, as gists. Planner-only until claim-time delivery.';

-- ── 4. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text; v_n uuid; v_c uuid; v_s uuid; v_old uuid; v_new uuid; v_c1 uuid; v_c2 uuid; v_g uuid;
        v_ids uuid[]; v_dist integer[]; v_global bigint; v_path text := current_setting('search_path');
BEGIN
  -- catalog of steps 2-3; catalog text is rendered with schema-qualified names: no public on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);
  IF NOT (SELECT relkind = 'v' AND pg_get_userbyid(relowner) = v_owner
                 AND obj_description(oid, 'pg_class') = 'Decision read path (3dae01c4): current decisions with derived gists.'
            FROM pg_class WHERE oid = 'ops.current_decisions'::regclass)
     OR (SELECT array_agg(attname::text || ' ' || format_type(atttypid, atttypmod) ORDER BY attnum)
           FROM pg_attribute WHERE attrelid = 'ops.current_decisions'::regclass AND attnum > 0 AND NOT attisdropped)
        <> ARRAY['id uuid', 'id8 text', 'gist text', 'decision text', 'rationale text', 'revisit_condition text',
                 'supersedes uuid', 'node_id uuid', 'node_path public.ltree', 'session_id uuid',
                 'occurred_at timestamp with time zone']
     OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                   || ' ' || a.privilege_type), '{}')
           FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = 'ops.current_decisions'::regclass AND a.grantee <> c.relowner)
        <> ARRAY['ops_planner SELECT'] THEN
    RAISE EXCEPTION '0034: ops.current_decisions kind, owner, comment, columns or ACL wrong';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname = 'get_decisions') <> 1
     OR NOT (SELECT prosecdef AND provolatile = 's' AND proconfig = ARRAY['search_path=ops, pg_temp']
                    AND pg_get_userbyid(proowner) = v_owner
                    AND pg_get_function_identity_arguments(oid) = 'p_node_path public.ltree, p_limit integer'
                    AND pg_get_function_arguments(oid) = 'p_node_path public.ltree, p_limit integer DEFAULT 50'
                    AND pg_get_function_result(oid) = 'TABLE(id uuid, id8 text, gist text, node_path public.ltree, distance integer, occurred_at timestamp with time zone)'
                    AND obj_description(oid, 'pg_proc') = 'Decision read path (c4840eb8, 8e4d46a9): current decisions at a node and its ancestors, nearest first, as gists. Planner-only until claim-time delivery.'
               FROM pg_proc WHERE oid = 'ops.get_decisions(public.ltree, integer)'::regprocedure)
     OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
           FROM pg_proc p, aclexplode(p.proacl) a
          WHERE p.oid = 'ops.get_decisions(public.ltree, integer)'::regprocedure AND a.grantee <> p.proowner)
        <> ARRAY['ops_planner'] THEN
    RAISE EXCEPTION '0034: ops.get_decisions signature, volatility, SECURITY DEFINER, search_path, owner, comment or ACL wrong';
  END IF;
  PERFORM set_config('search_path', v_path, true);

  -- nothing else changed
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0034.executor_reads')
     OR (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
          WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text
        <> current_setting('ops_m0034.executor_fns') THEN
    RAISE EXCEPTION '0034: ops_executor SELECT or EXECUTE set changed';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0034: ops_planner holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules)
     IS DISTINCT FROM current_setting('ops_m0034.rules_md5') THEN
    RAISE EXCEPTION '0034: protocol_rules changed';
  END IF;

  -- behaviour on probe nodes under global with their own session and decisions, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0034probe', 'node', '0034 probe') RETURNING id INTO v_n;
    INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_n, 'child', 'node', '0034 probe child') RETURNING id INTO v_c;
    v_s := ops.open_session(p_node_path => 'global.t0034probe'::public.ltree, p_kind => 'planning');
    v_old := (ops.log_decision(p_node_path => 'global.t0034probe'::public.ltree, p_decision => '0034 probe old. More.',
                               p_session => v_s)).id;
    v_new := (ops.log_decision(p_node_path => 'global.t0034probe'::public.ltree, p_decision => '0034 probe new. More.',
                               p_supersedes => v_old, p_session => v_s)).id;
    v_c1 := (ops.log_decision(p_node_path => 'global.t0034probe.child'::public.ltree, p_decision => '0034 probe child one',
                              p_session => v_s)).id;
    v_c2 := (ops.log_decision(p_node_path => 'global.t0034probe.child'::public.ltree, p_decision => '0034 probe child two',
                              p_session => v_s)).id;
    v_g := (ops.log_decision(p_node_path => 'global'::public.ltree, p_decision => '0034 probe global', p_session => v_s)).id;

    SELECT array_agg(g.id ORDER BY ord), array_agg(g.distance ORDER BY ord) INTO v_ids, v_dist
      FROM ops.get_decisions('global.t0034probe.child', 200) WITH ORDINALITY g(id, id8, gist, node_path, distance, occurred_at, ord);
    v_global := (SELECT count(*) FROM ops.current_decisions WHERE node_path::text = 'global');
    IF v_ids[1:2] @> ARRAY[v_c1, v_c2] IS NOT TRUE OR v_dist[1:2] <> ARRAY[0, 0] OR v_ids[3] IS DISTINCT FROM v_new
       OR v_dist[3] <> 1 OR v_old = ANY (v_ids) OR NOT v_g = ANY (v_ids)
       OR cardinality(v_ids) <> least(200, 3 + v_global)
       OR EXISTS (SELECT 1 FROM unnest(v_dist[4:]) x WHERE x <> 2) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0934', MESSAGE = 'get_decisions at the child: ' || coalesce(v_ids::text, 'null')
        || ' distances ' || coalesce(v_dist::text, 'null');
    END IF;
    IF (SELECT gist FROM ops.current_decisions WHERE id = v_new) <> '0034 probe new.' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0934', MESSAGE = 'gist of the probe decision';
    END IF;
    IF (SELECT count(*) FROM ops.get_decisions('global.t0034probe.child', 1)) <> 1
       OR (SELECT count(*) FROM ops.get_decisions('global.t0034probe.child', 2) g WHERE g.distance = 0) <> 2 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0934', MESSAGE = 'get_decisions limit';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0934', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0934' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0034: decision read path probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text IN ('global.t0034probe', 'global.t0034probe.child'))
     OR EXISTS (SELECT 1 FROM ops.decisions WHERE decision LIKE '0034 probe %') THEN
    RAISE EXCEPTION '0034: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0034 checks passed';
END $$;

-- ── 5. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0034_decision_read_path');

COMMIT;
