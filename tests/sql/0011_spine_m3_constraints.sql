-- tests/sql/0011_spine_m3_constraints.sql
-- Tests for migrations/0011_spine_m3_constraints.sql. Run as the schema owner against a non-production
-- database where 0011 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0011_spine_m3_constraints.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file uses only rows it creates, counts relative to the starting state and
-- never assumes a table is empty or holds a fixed count. Block 7 (grant snapshot) pins the state right after
-- 0011 and skips once a newer migration is applied. M4b (0015) makes backlog home_node_id / kind NOT NULL (block 1
-- expects that, block 2 supplies both) and drops the helper (blocks 3 and 6 skip once it no longer exists).

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in session settings so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.sessions_before', (SELECT count(*) FROM ops.sessions)::text, false),
          set_config('ops_test.projects_before', (SELECT count(*) FROM ops.projects)::text, false),
          set_config('ops_test.nodes_before', (SELECT count(*) FROM ops.nodes)::text, false),
          set_config('ops_test.decisions_before', (SELECT count(*) FROM ops.decisions)::text, false),
          set_config('ops_test.decision_nodes_before', (SELECT count(*) FROM ops.decision_nodes)::text, false),
          set_config('ops_test.backlog_items_before', (SELECT count(*) FROM ops.backlog_items)::text, false),
          set_config('ops_test.dispatch_nodes_before', (SELECT count(*) FROM ops.dispatch_nodes)::text, false),
          set_config('ops_test.context_documents_before', (SELECT count(*) FROM ops.context_documents)::text, false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- runs p_sql in a subtransaction; returns 'SQLSTATE message' on error, NULL on success
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;

CREATE FUNCTION pg_temp.rejects(p_sql text, p_state text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  IF e IS NULL OR e NOT LIKE p_state || ' %' THEN
    RAISE EXCEPTION 'FAIL: % (expected %, got %)', p_what, p_state, coalesce(e, 'success');
  END IF;
END $$;

CREATE FUNCTION pg_temp.node_id(p_path text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ops.nodes WHERE path::text = p_path;
$$;

-- true (with one NOTICE) once M4b (0015) has dropped the helper: blocks that call it then skip
CREATE FUNCTION pg_temp.helper_gone(p_block text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  IF to_regprocedure('ops._spine_backfill()') IS NULL THEN
    RAISE NOTICE 'skip %: ops._spine_backfill() no longer exists (newest migration is %)', p_block,
      (SELECT max(version) FROM ops.schema_migrations);
    RETURN true;
  END IF;
  RETURN false;
END $$;

-- the helper's result with every count zero
CREATE FUNCTION pg_temp.zero() RETURNS jsonb LANGUAGE sql AS $$
  SELECT '{"nodes_inserted": 0, "projects_node_id": 0, "components_node_id": 0, "sessions_scope": 0,
           "sessions_task_status": 0, "sessions_window_id": 0, "decisions_trust_status": 0,
           "decision_nodes_inserted": 0, "backlog_severity": 0, "backlog_kind": 0, "backlog_home_node_id": 0,
           "dispatch_nodes_inserted": 0}'::jsonb;
$$;

-- 1. catalog: NOT NULL with the expected default; still-nullable columns have no default
DO $$
DECLARE v_bad text; newest text := (SELECT max(version) FROM ops.schema_migrations);
        -- M4b (0015) sets NOT NULL (no default) on backlog_items home_node_id and kind
        v_m4b boolean := newest > '0014_writer_functions';
BEGIN
  IF v_m4b THEN
    RAISE NOTICE 'skip 1 backlog_items home_node_id / kind still nullable, expect NOT NULL (newest migration is %)', newest;
  END IF;
  -- 0022 drops sessions.task_status (M5b release 2); its NOT NULL / default is pinned to the state before 0022
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 1 sessions.task_status NOT NULL default open (newest migration is %)', newest;
  END IF;
  SELECT string_agg(e.t || '.' || e.c || ' (' || coalesce(k.is_nullable, '?') || ', ' || coalesce(k.column_default, '-') || ')', ', ')
    INTO v_bad
    FROM (SELECT * FROM (VALUES ('sessions', 'scope', 'global'), ('sessions', 'task_status', 'open'),
                 ('backlog_items', 'severity', 'untriaged'), ('decisions', 'trust_status', 'approved'),
                 ('context_documents', 'trust_status', 'approved'),
                 ('context_documents', 'node_id', NULL), ('context_documents', 'doc_type', NULL)) v(t, c, d)
           WHERE NOT (newest >= '0022' AND (v.t, v.c) = ('sessions', 'task_status'))
          UNION ALL
          SELECT * FROM (VALUES ('backlog_items', 'home_node_id', NULL::text), ('backlog_items', 'kind', NULL)) v(t, c, d)
           WHERE v_m4b) e(t, c, d)
    LEFT JOIN information_schema.columns k
      ON k.table_schema = 'ops' AND k.table_name = e.t AND k.column_name = e.c
   WHERE k.is_nullable IS DISTINCT FROM 'NO'
      OR split_part(k.column_default, '::', 1) IS DISTINCT FROM quote_literal(e.d);
  PERFORM pg_temp.check(v_bad IS NULL, 'NOT NULL with expected default: ' || coalesce(v_bad, ''));

  SELECT string_agg(e.t || '.' || e.c || ' (' || coalesce(k.is_nullable, '?') || ', ' || coalesce(k.column_default, '-') || ')', ', ')
    INTO v_bad
    FROM (VALUES ('backlog_items', 'home_node_id'), ('backlog_items', 'kind'), ('projects', 'node_id'),
                 ('components', 'node_id'), ('dispatch_types', 'project_id'), ('sessions', 'window_id'),
                 ('sessions', 'resumed_from'), ('sessions', 'usage_open'), ('sessions', 'usage_close'),
                 ('sessions', 'path_id')) e(t, c)
    LEFT JOIN information_schema.columns k
      ON k.table_schema = 'ops' AND k.table_name = e.t AND k.column_name = e.c
   WHERE (k.is_nullable IS DISTINCT FROM 'YES' OR k.column_default IS NOT NULL)
     AND NOT (v_m4b AND e.t = 'backlog_items' AND e.c IN ('home_node_id', 'kind'));
  PERFORM pg_temp.check(v_bad IS NULL, 'still nullable, no default: ' || coalesce(v_bad, ''));

  PERFORM pg_temp.check((SELECT array_agg(pg_get_constraintdef(oid) ORDER BY conname) FROM pg_constraint
                          WHERE connamespace = 'ops'::regnamespace AND contype = 'u'
                            AND conname IN ('projects_node_id_key', 'context_documents_node_id_doc_type_key'))
                        = ARRAY['UNIQUE (node_id, doc_type)', 'UNIQUE (node_id)'], 'both unique constraints exist');
  RAISE NOTICE 'ok   1 catalog';
END $$;

-- 2. defaults apply when the M2 columns are omitted; explicit NULL is refused (the test documents sit on a node
--    the block creates, so they never meet UNIQUE (node_id, doc_type) against a real document)
DO $$
DECLARE v_s ops.sessions; v_b ops.backlog_items; v_d ops.decisions; v_c ops.context_documents;
        v_lo uuid := pg_temp.node_id('global.local-ops'); v_dn uuid; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0011-doc', 'node', 't0011-doc') RETURNING id INTO v_dn;
  INSERT INTO ops.sessions (kind) VALUES ('planning') RETURNING * INTO v_s;
  -- 0022 drops sessions.task_status (M5b release 2): from then on the scope default only
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 2 session task_status default, its NULL refusals (newest migration is %)', newest;
    PERFORM pg_temp.check(v_s.scope = 'global', 'session defaults: ' || to_jsonb(v_s)::text);
  ELSE
  PERFORM pg_temp.check((v_s.scope, v_s.task_status) = ('global', 'open'), 'session defaults: ' || to_jsonb(v_s)::text);
  END IF;
  IF to_regprocedure('ops._spine_backfill()') IS NULL THEN
    RAISE NOTICE 'skip 2 backlog insert without kind / home_node_id, supply both (0015 NOT NULL)';
    INSERT INTO ops.backlog_items (title, source, kind, home_node_id) VALUES ('t0011 defaults', 'kind:task', 'task', v_lo)
    RETURNING * INTO v_b;
  ELSE
    INSERT INTO ops.backlog_items (title, source) VALUES ('t0011 defaults', 'kind:task') RETURNING * INTO v_b;
  END IF;
  PERFORM pg_temp.check(v_b.severity = 'untriaged', 'backlog severity default: ' || to_jsonb(v_b)::text);
  -- the project-less decision carries the project-less session v_s (session_id NOT NULL from 0022)
  INSERT INTO ops.decisions (session_id, decision) VALUES (v_s.id, 't0011 defaults') RETURNING * INTO v_d;
  PERFORM pg_temp.check(v_d.trust_status = 'approved', 'decision trust default: ' || to_jsonb(v_d)::text);
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
  VALUES ('T0011A', 't', 'c', v_dn, 'manual') RETURNING * INTO v_c;
  PERFORM pg_temp.check(v_c.trust_status = 'approved', 'document trust default: ' || to_jsonb(v_c)::text);

  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, scope) VALUES ('planning', NULL)$q$, '23502', 'sessions.scope NULL');
  IF newest < '0022' THEN
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, task_status) VALUES ('planning', NULL)$q$, '23502', 'sessions.task_status NULL');
  END IF;
  PERFORM pg_temp.rejects($q$INSERT INTO ops.backlog_items (title, source, severity) VALUES ('t', 'kind:task', NULL)$q$,
                          '23502', 'backlog_items.severity NULL');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.decisions (decision, trust_status) VALUES ('t', NULL)$q$, '23502', 'decisions.trust_status NULL');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, trust_status)
                                    VALUES ('T0011B', 't', 'c', %L, 'manual', NULL)$q$, v_dn), '23502', 'context_documents.trust_status NULL');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.context_documents (doc_key, title, content, doc_type)
                             VALUES ('T0011B', 't', 'c', 'manual')$q$, '23502', 'context_documents.node_id omitted');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id)
                                    VALUES ('T0011B', 't', 'c', %L)$q$, v_dn), '23502', 'context_documents.doc_type omitted');
  IF newest < '0022' THEN
  PERFORM pg_temp.rejects(format($q$UPDATE ops.sessions SET task_status = NULL WHERE id = %L$q$, v_s.id), '23502',
                          'UPDATE sessions.task_status to NULL');
  END IF;
  RAISE NOTICE 'ok   2 defaults apply; NULL refused';
END $$;

-- 3. still nullable: backlog without home_node_id and kind is accepted, the helper fills it
DO $$
DECLARE v_b ops.backlog_items; v_res jsonb; v_co uuid := pg_temp.node_id('global.local-ops.core');
        c ops.components := (SELECT c FROM ops.components c WHERE c.key = 'core');
BEGIN
  IF pg_temp.helper_gone('3 still nullable') THEN RETURN; END IF;
  PERFORM ops._spine_backfill();           -- absorb rows created by block 2 and anything written before the file
  INSERT INTO ops.backlog_items (project_id, component_id, title, source)
  VALUES (c.project_id, c.id, 't0011 nullable', 'kind:followup|dispatch:x') RETURNING * INTO v_b;
  PERFORM pg_temp.check(v_b.home_node_id IS NULL AND v_b.kind IS NULL, 'home_node_id and kind stay NULL on insert');
  INSERT INTO ops.projects (key, name) VALUES ('t0011-nonode', 't');
  PERFORM pg_temp.check((SELECT node_id IS NULL FROM ops.projects WHERE key = 't0011-nonode'), 'projects.node_id may be NULL');
  v_res := ops._spine_backfill();
  PERFORM pg_temp.check(v_res = pg_temp.zero() || '{"backlog_kind": 1, "backlog_home_node_id": 1}'::jsonb,
                        'helper fills the one backlog row: ' || v_res::text);
  PERFORM pg_temp.check((SELECT (kind, home_node_id) = ('followup', v_co) FROM ops.backlog_items WHERE id = v_b.id),
                        'kind followup, homed on core');
  RAISE NOTICE 'ok   3 still nullable; helper fills';
END $$;

-- 4. unique node keys
DO $$
DECLARE v_lo uuid := pg_temp.node_id('global.local-ops'); v_n uuid; v_pn uuid;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0023 deletes the local-ops project row (M5b release 2): from 0023 on the unique is exercised on a project row
  -- and node this block creates
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 4 a project holds the local-ops node (newest migration is %)', newest;
    INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.node_id('global'), 't0011-p4', 'project', 't0011-p4')
    RETURNING id INTO v_pn;
    INSERT INTO ops.projects (key, name, node_id) VALUES ('t0011-p4', 't', v_pn);
    PERFORM pg_temp.check(EXISTS (SELECT 1 FROM ops.projects WHERE node_id = v_pn), 'a project holds the t0011-p4 node');
    PERFORM pg_temp.rejects(format($q$INSERT INTO ops.projects (key, name, node_id) VALUES ('t0011-dup', 't', %L)$q$, v_pn),
                            '23505', 'second project on the same node');
  ELSE
  PERFORM pg_temp.check(v_lo IS NOT NULL AND EXISTS (SELECT 1 FROM ops.projects WHERE node_id = v_lo),
                        'a project holds the local-ops node');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.projects (key, name, node_id) VALUES ('t0011-dup', 't', %L)$q$, v_lo),
                          '23505', 'second project on the same node');
  END IF;
  PERFORM pg_temp.check(pg_temp.err($q$INSERT INTO ops.projects (key, name) VALUES ('t0011-n1', 't'), ('t0011-n2', 't')$q$)
                        IS NULL, 'two projects with node_id NULL do not collide');
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (pg_temp.node_id('global.local-ops.core'), 't0011', 'node', 't0011')
  RETURNING id INTO v_n;
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type) VALUES ('T0011U1', 't', 'c', v_n, 'manual');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
                                    VALUES ('T0011U2', 't', 'c', %L, 'manual')$q$, v_n),
                          '23505', 'second document with the same (node_id, doc_type)');
  RAISE NOTICE 'ok   4 unique';
END $$;

-- 5. task_status: the 2eecc405 mapping on the historical rows 0011 step 3 governed, i.e. sessions closed at or
--    before the 0011 ledger row (filled by the helper in 0010 or corrected by 0011 step 3). Sessions closed
--    later are written by close_session / open_session and covered by tests/sql/0012.
DO $$
DECLARE v_bad bigint; v_n bigint;
        v_at timestamptz := (SELECT applied_at FROM ops.schema_migrations WHERE version = '0011_spine_m3_constraints');
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  PERFORM pg_temp.check(v_at IS NOT NULL, '0011 ledger row exists');
  -- 0022 drops sessions.task_status (M5b release 2)
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 5 task_status mapping of sessions closed by 0011 (newest migration is %)', newest;
    RETURN;
  END IF;
  SELECT count(*), count(*) FILTER (WHERE task_status IS DISTINCT FROM
           CASE WHEN close_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status)
    INTO v_n, v_bad
    FROM ops.sessions WHERE status = 'closed' AND closed_at <= v_at;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' sessions closed by 0011 off the closed/stale mapping');
  RAISE NOTICE 'ok   5 task_status (% sessions closed by 0011 on the mapping)', v_n;
END $$;

-- 6. helper: kept, owner-only, idempotent apart from rows this block creates
DO $$
DECLARE v_res jsonb; c ops.components := (SELECT c FROM ops.components c WHERE c.key = 'core'); v_s0 uuid; v_sc uuid;
BEGIN
  IF pg_temp.helper_gone('6 helper') THEN RETURN; END IF;
  PERFORM pg_temp.check(to_regprocedure('ops._spine_backfill()') IS NOT NULL, 'helper exists');
  PERFORM pg_temp.check(NOT has_function_privilege(r, 'ops._spine_backfill()', 'EXECUTE'), r || ' cannot execute the helper')
     FROM unnest(ARRAY['public', 'ops_planner', 'ops_executor']) r;

  -- sessions for the decision and dispatch below (session_id NOT NULL from 0022), created before the absorbing
  -- call so the counts below stay those of the rows created here
  INSERT INTO ops.sessions (kind) VALUES ('planning') RETURNING id INTO v_s0;
  INSERT INTO ops.sessions (project_id, kind) VALUES (c.project_id, 'planning') RETURNING id INTO v_sc;
  PERFORM ops._spine_backfill();           -- absorb earlier blocks
  PERFORM pg_temp.check(ops._spine_backfill() = pg_temp.zero(), 'call on a filled state returns zeros');

  INSERT INTO ops.decisions (session_id, decision) VALUES (v_s0, 't0011 helper');
  INSERT INTO ops.backlog_items (title, source) VALUES ('t0011 helper', 'kind:discussion');
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
  VALUES (c.project_id, c.id, 'addition', v_sc, 't0011', 'p');
  v_res := ops._spine_backfill();
  PERFORM pg_temp.check(v_res = pg_temp.zero() || '{"decision_nodes_inserted": 1, "backlog_kind": 1, "backlog_home_node_id": 1,
                                                   "dispatch_nodes_inserted": 1}'::jsonb,
                        'counts only for the rows created here: ' || v_res::text);
  PERFORM pg_temp.check(ops._spine_backfill() = pg_temp.zero(), 'next call returns zeros');
  RAISE NOTICE 'ok   6 helper';
END $$;

-- 7. grants: unchanged by 0011 (snapshot of every ops ACL, helper included, taken on rehearsal before 0011
--    under search_path = ops, pg_temp)
DO $$
DECLARE v_acl text; v_n bigint; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  SELECT count(*), md5(string_agg(x, E'\n' ORDER BY x COLLATE "C")) INTO v_n, v_acl FROM (
    SELECT 'rel ' || relname || ' ' || coalesce(relacl::text, '-') AS x FROM pg_class
     WHERE relnamespace = 'ops'::regnamespace AND relkind IN ('r', 'v', 'S')
    UNION ALL
    SELECT 'fn ' || oid::regprocedure::text || ' ' || coalesce(proacl::text, '-') FROM pg_proc
     WHERE pronamespace = 'ops'::regnamespace) s;
  IF newest <> '0011_spine_m3_constraints' THEN
    RAISE NOTICE 'skip 7 grant snapshot (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check(v_n = 61 AND v_acl = '328b7d27fe7d5a7215c34b93714126fa',
                          'ops grants unchanged by 0011 (61 ACLs): ' || v_n || ' ' || v_acl);
    RAISE NOTICE 'ok   7 grants';
  END IF;
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.sessions) <> current_setting('ops_test.sessions_before')::bigint
     OR (SELECT count(*) FROM ops.projects) <> current_setting('ops_test.projects_before')::bigint
     OR (SELECT count(*) FROM ops.nodes) <> current_setting('ops_test.nodes_before')::bigint
     OR (SELECT count(*) FROM ops.decisions) <> current_setting('ops_test.decisions_before')::bigint
     OR (SELECT count(*) FROM ops.decision_nodes) <> current_setting('ops_test.decision_nodes_before')::bigint
     OR (SELECT count(*) FROM ops.backlog_items) <> current_setting('ops_test.backlog_items_before')::bigint
     OR (SELECT count(*) FROM ops.dispatch_nodes) <> current_setting('ops_test.dispatch_nodes_before')::bigint
     OR (SELECT count(*) FROM ops.context_documents) <> current_setting('ops_test.context_documents_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   8 no leftover rows; 0011 tests passed';
END $$;
