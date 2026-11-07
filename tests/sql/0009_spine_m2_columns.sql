-- tests/sql/0009_spine_m2_columns.sql
-- Tests for migrations/0009_spine_m2_columns.sql. Run as the schema owner against a non-production
-- database where 0009 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0009_spine_m2_columns.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- Blocks 1 (column counts; nullability of the columns 0011 constrains), 3, 8 (NULL in columns 0011
-- defaults) and 9 pin the state right after 0009 (before B backfills, M3 constrains and M4 replaces
-- functions); they skip once a newer migration is applied. From M4b (0015) on, block 1 asserts backlog_items
-- home_node_id / kind NOT NULL, block 5 expects the component-scope trigger's 23514 and block 10 expects no planner
-- table writes.

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
          set_config('ops_test.components_before', (SELECT count(*) FROM ops.components)::text, false),
          set_config('ops_test.context_documents_before', (SELECT count(*) FROM ops.context_documents)::text, false),
          set_config('ops_test.decisions_before', (SELECT count(*) FROM ops.decisions)::text, false),
          set_config('ops_test.backlog_items_before', (SELECT count(*) FROM ops.backlog_items)::text, false),
          set_config('ops_test.dispatch_types_before', (SELECT count(*) FROM ops.dispatch_types)::text, false),
          set_config('ops_test.gate_events_before', (SELECT count(*) FROM ops.gate_events)::text, false);
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

CREATE FUNCTION pg_temp.accepts(p_sql text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  IF e IS NOT NULL THEN RAISE EXCEPTION 'FAIL: % (got %)', p_what, e; END IF;
END $$;

-- every column 0009 adds: table, column, expected type
CREATE TEMP TABLE new_cols (tbl text, col text, typ text) ON COMMIT DROP;
INSERT INTO new_cols VALUES
  ('sessions', 'window_id', 'uuid'), ('sessions', 'scope', 'ops.segment_scope'),
  ('sessions', 'task_status', 'ops.task_status'), ('sessions', 'usage_open', 'numeric(5,2)'),
  ('sessions', 'usage_close', 'numeric(5,2)'), ('sessions', 'resumed_from', 'uuid'), ('sessions', 'path_id', 'uuid'),
  ('projects', 'node_id', 'uuid'),
  ('components', 'node_id', 'uuid'),
  ('context_documents', 'node_id', 'uuid'), ('context_documents', 'doc_type', 'text'),
  ('context_documents', 'trust_status', 'ops.trust_status'),
  ('context_documents', 'reviewed_at', 'timestamp with time zone'),
  ('context_documents', 'stale_since', 'timestamp with time zone'),
  ('context_documents', 'use_count', 'integer'), ('context_documents', 'last_used_at', 'timestamp with time zone'),
  ('decisions', 'trust_status', 'ops.trust_status'),
  ('backlog_items', 'home_node_id', 'uuid'), ('backlog_items', 'severity', 'ops.backlog_severity'),
  ('backlog_items', 'kind', 'ops.backlog_kind'), ('backlog_items', 'resolved_by', 'uuid'),
  ('dispatch_types', 'project_id', 'uuid');

-- 1. new columns: type, nullable, no default; nothing else added to these tables
DO $$
DECLARE r record; v_count int; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  FOR r IN
    SELECT n.tbl, n.col, n.typ, c.is_nullable, c.column_default,
           CASE c.data_type WHEN 'USER-DEFINED' THEN c.udt_schema || '.' || c.udt_name
                            WHEN 'numeric' THEN format('numeric(%s,%s)', c.numeric_precision, c.numeric_scale)
                            ELSE c.data_type END AS actual
      FROM new_cols n
      LEFT JOIN information_schema.columns c
        ON c.table_schema = 'ops' AND c.table_name = n.tbl AND c.column_name = n.col
  LOOP
    -- 0022 drops sessions.task_status (M5b release 2); the column is pinned to the state before 0022
    IF newest >= '0022' AND (r.tbl, r.col) = ('sessions', 'task_status') THEN
      RAISE NOTICE 'skip 1 %.% exists, type, nullable (newest migration is %)', r.tbl, r.col, newest;
      CONTINUE;
    END IF;
    PERFORM pg_temp.check(r.actual IS NOT NULL, format('%s.%s exists', r.tbl, r.col));
    PERFORM pg_temp.check(r.actual = r.typ, format('%s.%s type %s, expected %s', r.tbl, r.col, r.actual, r.typ));
    -- M3 (0011) sets NOT NULL and defaults on these; their nullability is pinned to the state right after 0009
    IF newest <> '0009_spine_m2_columns'
       AND (r.tbl, r.col) IN (('sessions', 'scope'), ('sessions', 'task_status'), ('backlog_items', 'severity'),
                              ('decisions', 'trust_status'), ('context_documents', 'trust_status'),
                              ('context_documents', 'node_id'), ('context_documents', 'doc_type')) THEN
      RAISE NOTICE 'skip 1 %.% nullable, no default (newest migration is %)', r.tbl, r.col, newest;
      CONTINUE;
    END IF;
    -- M4b (0015) sets NOT NULL on these two; from 0015 on the new state is asserted instead
    IF newest > '0014_writer_functions' AND (r.tbl, r.col) IN (('backlog_items', 'home_node_id'), ('backlog_items', 'kind')) THEN
      RAISE NOTICE 'skip 1 %.% nullable, assert NOT NULL instead (newest migration is %)', r.tbl, r.col, newest;
      PERFORM pg_temp.check(r.is_nullable = 'NO', format('%s.%s NOT NULL from 0015', r.tbl, r.col));
      PERFORM pg_temp.check(r.column_default IS NULL, format('%s.%s has no default (%s)', r.tbl, r.col, r.column_default));
      CONTINUE;
    END IF;
    PERFORM pg_temp.check(r.is_nullable = 'YES', format('%s.%s nullable', r.tbl, r.col));
    PERFORM pg_temp.check(r.column_default IS NULL, format('%s.%s has no default (%s)', r.tbl, r.col, r.column_default));
  END LOOP;
  -- pre-0009 column counts plus the new ones
  IF (SELECT max(version) FROM ops.schema_migrations) <> '0009_spine_m2_columns' THEN
    RAISE NOTICE 'skip 1 column counts (newest migration is %)', (SELECT max(version) FROM ops.schema_migrations);
  ELSE
  PERFORM pg_temp.check(
    (SELECT jsonb_object_agg(table_name, n) FROM (
       SELECT table_name, count(*) AS n FROM information_schema.columns
        WHERE table_schema = 'ops'
          AND table_name IN ('sessions', 'projects', 'components', 'context_documents', 'decisions',
                             'backlog_items', 'dispatch_types')
        GROUP BY table_name) s)
    = '{"sessions": 19, "projects": 6, "components": 10, "context_documents": 17, "decisions": 14,
        "backlog_items": 13, "dispatch_types": 7}'::jsonb,
    'column counts are pre-0009 plus the new columns');
  END IF;
  SELECT count(*) INTO v_count FROM new_cols;
  PERFORM pg_temp.check(v_count = 22, '22 new columns listed');
  RAISE NOTICE 'ok   1 new columns: type, nullable, no default';
END $$;

-- 2. project_id nullability
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  -- 0023 drops NOT NULL on dispatches.project_id (M5b release 2): from 0023 on all six are nullable
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 2 dispatches.project_id NOT NULL (newest migration is %)', newest;
    PERFORM pg_temp.check(
      (SELECT array_agg(table_name || ':' || is_nullable ORDER BY table_name) FROM information_schema.columns
        WHERE table_schema = 'ops' AND column_name = 'project_id'
          AND table_name IN ('sessions', 'decisions', 'context_documents', 'backlog_items', 'components', 'dispatches'))
      = ARRAY['backlog_items:YES', 'components:YES', 'context_documents:YES', 'decisions:YES',
              'dispatches:YES', 'sessions:YES'],
      'project_id nullable on the five context tables and on dispatches (0023)');
  ELSE
  PERFORM pg_temp.check(
    (SELECT array_agg(table_name || ':' || is_nullable ORDER BY table_name) FROM information_schema.columns
      WHERE table_schema = 'ops' AND column_name = 'project_id'
        AND table_name IN ('sessions', 'decisions', 'context_documents', 'backlog_items', 'components', 'dispatches'))
    = ARRAY['backlog_items:YES', 'components:YES', 'context_documents:YES', 'decisions:YES',
            'dispatches:NO', 'sessions:YES'],
    'project_id nullable on the five context tables, NOT NULL on dispatches');
  END IF;
  RAISE NOTICE 'ok   2 project_id nullability';
END $$;

-- 3. no hidden backfill: every pre-existing row has NULL in every new column
DO $$
DECLARE r record; v_n bigint; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest <> '0009_spine_m2_columns' THEN
    RAISE NOTICE 'skip 3 no hidden backfill (newest migration is %)', newest;
    RETURN;
  END IF;
  FOR r IN SELECT tbl, col FROM new_cols LOOP
    EXECUTE format('SELECT count(*) FROM ops.%I WHERE %I IS NOT NULL', r.tbl, r.col) INTO v_n;
    PERFORM pg_temp.check(v_n = 0, format('%s.%s: %s pre-existing rows not NULL', r.tbl, r.col, v_n));
  END LOOP;
  RAISE NOTICE 'ok   3 no hidden backfill (all new columns NULL in % sessions, % backlog_items, % decisions)',
    (SELECT count(*) FROM ops.sessions), (SELECT count(*) FROM ops.backlog_items), (SELECT count(*) FROM ops.decisions);
END $$;

-- 4. foreign keys reject unknown ids (test documents sit on a node of their own, never on a real document's
--    (node_id, doc_type); the component probe carries no project, so only its unknown node_id can fail)
DO $$
DECLARE v_project uuid := NULL; v_node uuid;
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0009-fk', 'node', 't0009-fk') RETURNING id INTO v_node;
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, window_id) VALUES ('planning', gen_random_uuid())$q$,
                          '23503', 'sessions.window_id');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, resumed_from) VALUES ('planning', gen_random_uuid())$q$,
                          '23503', 'sessions.resumed_from');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, path_id) VALUES ('planning', gen_random_uuid())$q$,
                          '23503', 'sessions.path_id');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.projects (key, name, node_id) VALUES ('t0009', 't', gen_random_uuid())$q$,
                          '23503', 'projects.node_id');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.components (project_id, key, kind, node_id)
                                    VALUES (%L, 't0009', 'test', gen_random_uuid())$q$, v_project),
                          '23503', 'components.node_id');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
                             VALUES ('T0009', 't', 'c', gen_random_uuid(), 'manual')$q$, '23503', 'context_documents.node_id');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
                                    VALUES ('T0009', 't', 'c', %L, 'no-such-type')$q$, v_node),
                          '23503', 'context_documents.doc_type');
  -- kind (and a real home node for resolved_by) are supplied so the FK, not 0015's NOT NULL (23502), is what fails
  PERFORM pg_temp.rejects($q$INSERT INTO ops.backlog_items (title, kind, home_node_id) VALUES ('t', 'task', gen_random_uuid())$q$,
                          '23503', 'backlog_items.home_node_id');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.backlog_items (title, kind, home_node_id, resolved_by)
                                    VALUES ('t', 'task', %L, gen_random_uuid())$q$, v_node),
                          '23503', 'backlog_items.resolved_by');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.dispatch_types (type, description, commit_policy, project_id)
                             VALUES ('t0009', 't', 'none', gen_random_uuid())$q$, '23503', 'dispatch_types.project_id');
  RAISE NOTICE 'ok   4 foreign keys reject unknown ids';
END $$;

-- 5. foreign keys accept real targets; rows with no project are allowed (MATCH SIMPLE skips the component check;
--    from 0015 the component-scope trigger restores it). The test project and component sit on nodes of their own
--    (72af130d), never on the global node. The component c of the component-rule assertions is the block's own
--    (project t0009-own, on nodes the block creates), not the oldest component: from 0023 the local-ops core
--    component has no project (4b6c7575).
DO $$
DECLARE c ops.components;
        g ops.nodes; v_win uuid; v_s1 uuid; v_s2 uuid; v_path uuid; v_wl uuid; v_doc uuid; v_node uuid;
        v_pnode uuid; v_cnode uuid; v_opnode uuid; v_ocnode uuid;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  SELECT * INTO g FROM ops.nodes WHERE kind = 'global';
  IF NOT FOUND THEN
    INSERT INTO ops.nodes (key, kind, title) VALUES ('global', 'global', 'Global') RETURNING * INTO g;
  END IF;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (g.id, 't0009-own', 'node', 't0009-own') RETURNING id INTO v_opnode;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_opnode, 't0009-own-comp', 'node', 't0009-own-comp')
  RETURNING id INTO v_ocnode;
  INSERT INTO ops.projects (key, name, node_id) VALUES ('t0009-own', 't', v_opnode);
  INSERT INTO ops.components (project_id, key, kind, node_id)
  VALUES ((SELECT id FROM ops.projects WHERE key = 't0009-own'), 't0009-own', 'test', v_ocnode) RETURNING * INTO c;
  UPDATE ops.nodes SET component_id = c.id WHERE id = v_ocnode;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (g.id, 't0009-doc', 'node', 't0009-doc') RETURNING id INTO v_node;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (g.id, 't0009-proj', 'node', 't0009-proj') RETURNING id INTO v_pnode;
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (v_pnode, 't0009-comp', 'node', 't0009-comp')
  RETURNING id INTO v_cnode;
  INSERT INTO ops.windows (started_at, resets_at, start_source, initialiser)
  VALUES ('2000-01-01 00:00+00', '2000-01-01 05:00+00', 'inferred', 'code') RETURNING id INTO v_win;
  -- 0022 drops sessions.task_status (M5b release 2): from 0022 on the sessions are inserted without it
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 5 sessions.task_status in the session inserts (newest migration is %)', newest;
    INSERT INTO ops.sessions (kind, scope, window_id, usage_open)
    VALUES ('planning', 'global', v_win, 0) RETURNING id INTO v_s1;
    INSERT INTO ops.path_log (session_id, prompt_summary, proposed) VALUES (v_s1, 'p', '{}') RETURNING id INTO v_path;
    INSERT INTO ops.sessions (kind, scope, resumed_from, path_id, usage_open, usage_close)
    VALUES ('execution', 'global', v_s1, v_path, 12.5, 100) RETURNING id INTO v_s2;
  ELSE
  INSERT INTO ops.sessions (kind, scope, task_status, window_id, usage_open)
  VALUES ('planning', 'global', 'open', v_win, 0) RETURNING id INTO v_s1;
  INSERT INTO ops.path_log (session_id, prompt_summary, proposed) VALUES (v_s1, 'p', '{}') RETURNING id INTO v_path;
  INSERT INTO ops.sessions (kind, scope, task_status, resumed_from, path_id, usage_open, usage_close)
  VALUES ('execution', 'global', 'unfinished', v_s1, v_path, 12.5, 100) RETURNING id INTO v_s2;
  END IF;
  INSERT INTO ops.work_log (origin, entry_type, title) VALUES ('code', 'migration', 'wl') RETURNING id INTO v_wl;

  INSERT INTO ops.projects (key, name, node_id) VALUES ('t0009', 't', v_pnode);
  INSERT INTO ops.components (key, kind, node_id) VALUES ('t0009', 'test', v_cnode);
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, trust_status, use_count)
  VALUES ('T0009', 't', 'c', v_node, 'manual', 'draft', 0) RETURNING id INTO v_doc;
  -- the project-less decision carries the project-less session v_s1 (session_id NOT NULL from 0022)
  INSERT INTO ops.decisions (session_id, decision, trust_status) VALUES (v_s1, 't0009 decision', 'imported');
  INSERT INTO ops.backlog_items (title, home_node_id, severity, kind, resolved_by)
  VALUES ('t', g.id, 'untriaged', 'allowed_bug', v_wl);
  INSERT INTO ops.dispatch_types (type, description, commit_policy, project_id)
  VALUES ('t0009', 't', 'none', (SELECT id FROM ops.projects WHERE key = 't0009'));

  -- MATCH SIMPLE: component_id with a null project_id is not checked (M4b, 0015, restores the rule with a trigger:
  -- 23514, raised before the FK's 23503). kind and home_node_id (the component's node) are supplied so only the
  -- component rule decides.
  IF newest > '0014_writer_functions' THEN
    RAISE NOTICE 'skip 5 component_id with null project_id unchecked, expect 23514 instead (newest migration is %)', newest;
    PERFORM pg_temp.rejects(format($q$INSERT INTO ops.backlog_items (title, component_id, kind, home_node_id)
                                      VALUES ('t', %L, 'task', %L)$q$, c.id, c.node_id),
                            '23514', 'component_id with null project_id rejected by the component-scope trigger');
  ELSE
    PERFORM pg_temp.accepts(format($q$INSERT INTO ops.backlog_items (title, component_id, kind, home_node_id)
                                      VALUES ('t', %L, 'task', %L)$q$, c.id, c.node_id),
                            'component_id with null project_id is unchecked');
  END IF;
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.backlog_items (title, project_id, component_id, kind, home_node_id)
                                    VALUES ('t', (SELECT id FROM ops.projects WHERE key = 't0009'), %L, 'task', %L)$q$,
                                 c.id, c.node_id),
                          CASE WHEN newest > '0014_writer_functions' THEN '23514' ELSE '23503' END,
                          'component in another project still rejected when project_id is set');
  RAISE NOTICE 'ok   5 foreign keys accept real targets; project-less rows allowed';
END $$;

-- 6. checks: usage bounds and use_count (the test document sits on a node of its own)
DO $$
DECLARE v_node uuid;
BEGIN
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE kind = 'global'), 't0009-chk', 'node', 't0009-chk') RETURNING id INTO v_node;
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, usage_open) VALUES ('planning', -1)$q$, '23514', 'usage_open -1');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, usage_open) VALUES ('planning', 100.01)$q$, '23514', 'usage_open 100.01');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, usage_close) VALUES ('planning', -1)$q$, '23514', 'usage_close -1');
  PERFORM pg_temp.rejects($q$INSERT INTO ops.sessions (kind, usage_close) VALUES ('planning', 100.01)$q$, '23514', 'usage_close 100.01');
  PERFORM pg_temp.accepts($q$INSERT INTO ops.sessions (kind, usage_open, usage_close) VALUES ('planning', 0, 100)$q$, 'usage 0 and 100');
  PERFORM pg_temp.accepts($q$INSERT INTO ops.sessions (kind, usage_open, usage_close) VALUES ('planning', 100, 0)$q$, 'usage 100 and 0');
  PERFORM pg_temp.rejects(format($q$INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type, use_count)
                                    VALUES ('T0009B', 't', 'c', %L, 'manual', -1)$q$, v_node),
                          '23514', 'use_count -1');
  RAISE NOTICE 'ok   6 usage and use_count checks';
END $$;

-- 7. enum labels
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  PERFORM pg_temp.check(enum_range(NULL::ops.segment_scope)::text[] = ARRAY['global', 'project'], 'segment_scope');
  -- 0022 drops the enum ops.task_status (M5b release 2)
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 7 task_status enum labels (newest migration is %)', newest;
  ELSE
  PERFORM pg_temp.check(enum_range(NULL::ops.task_status)::text[] = ARRAY['open', 'unfinished', 'closed'], 'task_status');
  END IF;
  PERFORM pg_temp.check(enum_range(NULL::ops.backlog_severity)::text[]
                        = ARRAY['low', 'medium', 'high', 'critical', 'untriaged'], 'backlog_severity');
  PERFORM pg_temp.check(enum_range(NULL::ops.backlog_kind)::text[]
                        = ARRAY['task', 'followup', 'proposal', 'discussion', 'allowed_bug'], 'backlog_kind');
  PERFORM pg_temp.check(enum_range(NULL::ops.trust_status)::text[] = ARRAY['approved', 'imported', 'draft'],
                        'trust_status reused from 0008');
  RAISE NOTICE 'ok   7 enum labels';
END $$;

-- 8. existing functions still work
DO $$
DECLARE v_s uuid; v_n int; v_gate bigint; e text; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  v_s := ops.open_session(p_node_path => 'global.local-ops.core'::public.ltree, p_kind => 'execution');
  PERFORM pg_temp.check((SELECT status = 'active' FROM ops.sessions WHERE id = v_s), 'open_session row active');
  -- M3 (0011) gives scope and task_status defaults; NULL is pinned to the state right after 0009
  IF newest <> '0009_spine_m2_columns' THEN
    RAISE NOTICE 'skip 8 open_session scope/task_status NULL (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check((SELECT scope IS NULL AND task_status IS NULL FROM ops.sessions WHERE id = v_s),
                          'open_session row, new columns NULL');
  END IF;
  v_gate := ops.record_gate('t0009', 'pass', NULL, v_s);
  PERFORM pg_temp.check((SELECT session_id = v_s FROM ops.gate_events WHERE id = v_gate), 'record_gate');
  v_n := ops.close_session(v_s, 'sum', 'next', '[{"decision": "t0009 via close_session"}]');
  PERFORM pg_temp.check(v_n = 1, 'close_session recorded 1 decision');
  PERFORM pg_temp.check((SELECT status = 'closed' AND close_reason = 'normal' FROM ops.sessions WHERE id = v_s), 'session closed');
  -- 0023 deletes the local-ops project row (M5b release 2): from 0023 on the decision has no project and is homed
  -- on the core node through decision_nodes
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 8 close_session decision has project_id (newest migration is %)', newest;
    PERFORM pg_temp.check((SELECT d.project_id IS NULL
                                  AND (SELECT array_agg(n.path::text) FROM ops.decision_nodes dn JOIN ops.nodes n ON n.id = dn.node_id
                                        WHERE dn.decision_id = d.id) = ARRAY['global.local-ops.core']
                             FROM ops.decisions d WHERE d.session_id = v_s),
                          'close_session decision: project_id NULL, decision_nodes = the core node');
  ELSE
  PERFORM pg_temp.check((SELECT project_id IS NOT NULL FROM ops.decisions WHERE session_id = v_s),
                        'close_session decision has project_id');
  END IF;
  -- M3 (0011) gives trust_status a default; NULL is pinned to the state right after 0009
  IF newest <> '0009_spine_m2_columns' THEN
    RAISE NOTICE 'skip 8 close_session decision trust_status NULL (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check((SELECT trust_status IS NULL FROM ops.decisions WHERE session_id = v_s),
                          'close_session decision trust_status NULL');
  END IF;
  -- 0021 drops the project-keyed resolve_context(text, text) (M5b release 2)
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 8 resolve_context(text, text) error path (newest migration is %)', newest;
  ELSE
    e := pg_temp.err($q$SELECT ops.resolve_context('local-ops', 'NO_SUCH_DOC_0009')$q$);
    PERFORM pg_temp.check(e LIKE 'P0001 unknown context ref NO_SUCH_DOC_0009', 'resolve_context error path: ' || coalesce(e, 'success'));
  END IF;
  RAISE NOTICE 'ok   8 open_session, record_gate, close_session, resolve_context';
END $$;

-- 9. 0009 creates or replaces no function: names and prosrc md5 match the pre-0009 snapshot
DO $$
DECLARE v_now text[]; v_pre text[]; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest <> '0009_spine_m2_columns' THEN
    RAISE NOTICE 'skip 9 function snapshot (newest migration is %)', newest;
    RETURN;
  END IF;
  SELECT array_agg(proname || ':' || md5(prosrc) ORDER BY proname COLLATE "C") INTO v_now
    FROM pg_proc WHERE pronamespace = 'ops'::regnamespace;
  SELECT array_agg(x ORDER BY x COLLATE "C") INTO v_pre FROM unnest(ARRAY[
    '_component:27d40ea25522dafc52332ef4d5b96610',
    '_findings_before_update:527e438df392699f976e89e5fc5776ab',
    '_fmt_dur:029ba1cbdf5e04f4dbdb9d0ef3d8dacc',
    '_fmt_time:8ede5e7e7e78c1959c456510451a2027',
    '_nodes_before_insert:f0e1ac6a22acb33c859dba82e8282eff',
    '_nodes_before_update:9211d6e791fd76c162bf3a61d799f2ca',
    '_window_rank:35ddb572fd4869e4d7879885118d1f88',
    '_wlabel:b45726327514af78b23fa9a3c22e0394',
    'cancel_dispatch:910c6abe35e50fab9a2babd677d6e42a',
    'claim_dispatch:90b580496db11910eb15ceef43660c48',
    'close_session:35c0ad71f06b4bde46890fe3bd1bf320',
    'complete_dispatch:2e8e3d4655e1d46fe4b8fb202f0d9392',
    'fail_dispatch:671f06052467befb1bddee00e733bfb8',
    'get_pending:b4909433b5d5af4bc26708fd77d7c3a0',
    'get_unreviewed_reports:76ea37955b622780c51a49cbca7cef11',
    'mark_reviewed:7a181335776eb0c2f58ee5dd660c5b2e',
    'open_session:08715b22885ac0a9888a8d0841b25475',
    'record_gate:4aad5585c6893bfdfc0bd5da5272b815',
    'resolve_context:28f41f28333fdc691ac9c8bc1afe06ef',
    'tick:fbc3f53f1e07a15332cdea7fa0ea9f17',
    'window_link_event:ee7cfbe3adc04d7e5112e82da427eb86']) x;
  PERFORM pg_temp.check(v_now = v_pre, 'ops functions unchanged; now: ' || array_to_string(v_now, ' '));
  RAISE NOTICE 'ok   9 no function created or replaced (21 names, prosrc md5 unchanged)';
END $$;

-- 10. grants unchanged
DO $$
DECLARE r record; newest text := (SELECT max(version) FROM ops.schema_migrations);
        v_m4b boolean := newest > '0014_writer_functions';
BEGIN
  -- M4b (0015) revokes every planner table write; from 0015 on INSERT/UPDATE are expected false everywhere
  IF v_m4b THEN
    RAISE NOTICE 'skip 10 planner INSERT/UPDATE grants, expect none (newest migration is %)', newest;
  END IF;
  -- planner: SELECT on all seven; INSERT/UPDATE on the registry, context_documents, backlog_items; INSERT only on decisions
  FOR r IN SELECT t, ins AND NOT v_m4b AS ins, upd AND NOT v_m4b AS upd FROM (VALUES
      ('ops.sessions',          false, false), ('ops.projects',       true,  true),
      ('ops.components',        true,  true),  ('ops.dispatch_types', true,  true),
      ('ops.context_documents', true,  true),  ('ops.backlog_items',  true,  true),
      ('ops.decisions',         true,  false)) v(t, ins, upd)
  LOOP
    PERFORM pg_temp.check(has_table_privilege('ops_planner', r.t, 'SELECT'), 'planner SELECT ' || r.t);
    PERFORM pg_temp.check(has_table_privilege('ops_planner', r.t, 'INSERT') = r.ins, 'planner INSERT ' || r.t || ' = ' || r.ins);
    PERFORM pg_temp.check(has_table_privilege('ops_planner', r.t, 'UPDATE') = r.upd, 'planner UPDATE ' || r.t || ' = ' || r.upd);
    PERFORM pg_temp.check(NOT has_table_privilege('ops_planner', r.t, 'DELETE'), 'planner no DELETE ' || r.t);
  END LOOP;
  -- the table grants cover the new columns
  PERFORM pg_temp.check(CASE WHEN v_m4b
                          THEN NOT (has_column_privilege('ops_planner', 'ops.' || tbl, col, 'INSERT')
                                    OR has_column_privilege('ops_planner', 'ops.' || tbl, col, 'UPDATE'))
                          ELSE has_column_privilege('ops_planner', 'ops.' || tbl, col, 'INSERT')
                               AND has_column_privilege('ops_planner', 'ops.' || tbl, col, 'UPDATE') END,
                        format('planner INSERT/UPDATE on new column %s.%s = %s', tbl, col, NOT v_m4b))
     FROM new_cols WHERE tbl IN ('context_documents', 'backlog_items', 'projects', 'components', 'dispatch_types');
  -- executor: SELECT on projects, components, dispatch_types, context_documents only; never writes
  FOR r IN SELECT * FROM (VALUES
      ('ops.sessions', false), ('ops.projects', true), ('ops.components', true), ('ops.dispatch_types', true),
      ('ops.context_documents', true), ('ops.backlog_items', false), ('ops.decisions', false)) v(t, sel)
  LOOP
    PERFORM pg_temp.check(has_table_privilege('ops_executor', r.t, 'SELECT') = r.sel, 'executor SELECT ' || r.t || ' = ' || r.sel);
    PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', r.t, 'INSERT, UPDATE, DELETE'), 'executor no writes ' || r.t);
    PERFORM pg_temp.check(NOT has_table_privilege('public', r.t, 'SELECT'), 'PUBLIC no SELECT ' || r.t);
  END LOOP;
  RAISE NOTICE 'ok  10 grants unchanged';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.sessions) <> current_setting('ops_test.sessions_before')::bigint
     OR (SELECT count(*) FROM ops.projects) <> current_setting('ops_test.projects_before')::bigint
     OR (SELECT count(*) FROM ops.components) <> current_setting('ops_test.components_before')::bigint
     OR (SELECT count(*) FROM ops.context_documents) <> current_setting('ops_test.context_documents_before')::bigint
     OR (SELECT count(*) FROM ops.decisions) <> current_setting('ops_test.decisions_before')::bigint
     OR (SELECT count(*) FROM ops.backlog_items) <> current_setting('ops_test.backlog_items_before')::bigint
     OR (SELECT count(*) FROM ops.dispatch_types) <> current_setting('ops_test.dispatch_types_before')::bigint
     OR (SELECT count(*) FROM ops.gate_events) <> current_setting('ops_test.gate_events_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok  11 no leftover rows; 0009 tests passed';
END $$;
