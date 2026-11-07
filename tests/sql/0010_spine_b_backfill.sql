-- tests/sql/0010_spine_b_backfill.sql
-- Tests for migrations/0010_spine_b_backfill.sql. Run as the schema owner against a non-production
-- database where 0010 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0010_spine_b_backfill.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree operators are
-- reached schema-qualified and paths are compared as text.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): blocks 2-4 assert the helper's mapping only on rows they create, block 5 absorbs
-- rows written since 0010 before the idempotence check, and counts are relative to the state the file starts
-- from. Blocks 1 (pinned subtree size), 3 and 6 (the task_status values and counts that 0011 defaults change),
-- 5 (applied state needs no fill) and 8 (grant snapshot) pin the state right after 0010; they skip that part
-- once a newer migration is applied (7eb6746f). M4b (0015) drops the helper and makes backlog kind NOT NULL, so
-- blocks 2-8 skip with one NOTICE each once the helper no longer exists; block 1 still runs.

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in session settings so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.nodes_before', (SELECT count(*) FROM ops.nodes)::text, false),
          set_config('ops_test.sessions_before', (SELECT count(*) FROM ops.sessions)::text, false),
          set_config('ops_test.windows_before', (SELECT count(*) FROM ops.windows)::text, false),
          set_config('ops_test.components_before', (SELECT count(*) FROM ops.components)::text, false),
          set_config('ops_test.decisions_before', (SELECT count(*) FROM ops.decisions)::text, false),
          set_config('ops_test.decision_nodes_before', (SELECT count(*) FROM ops.decision_nodes)::text, false),
          set_config('ops_test.backlog_items_before', (SELECT count(*) FROM ops.backlog_items)::text, false),
          set_config('ops_test.dispatches_before', (SELECT count(*) FROM ops.dispatches)::text, false),
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

-- p_sql succeeds; it runs in a subtransaction that a sentinel error then rolls back, so it leaves no rows
CREATE FUNCTION pg_temp.passes(p_sql text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'probe passed' USING ERRCODE = 'T0010';
  EXCEPTION WHEN OTHERS THEN
    e := SQLSTATE || ' ' || SQLERRM;
  END;
  IF e NOT LIKE 'T0010 %' THEN RAISE EXCEPTION 'FAIL: % (got %)', p_what, e; END IF;
END $$;

-- md5 per table of the pre-M2 columns (to_jsonb minus the M2 columns, ordered by id)
CREATE FUNCTION pg_temp.fp() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'sessions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['window_id', 'scope', 'task_status', 'usage_open',
                   'usage_close', 'resumed_from', 'path_id'])::text, E'\n' ORDER BY t.id), '')) FROM ops.sessions t),
    'decisions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'trust_status')::text, E'\n' ORDER BY t.id), ''))
                    FROM ops.decisions t),
    'backlog_items', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['home_node_id', 'severity', 'kind',
                        'resolved_by'])::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
    'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
    'projects', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                   FROM ops.projects t),
    'components', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.components t));
$$;

-- md5 per table of whole rows, M2 columns and links included
CREATE FUNCTION pg_temp.full_fp() RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'sessions', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.sessions t),
    'decisions', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.decisions t),
    'backlog_items', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
    'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
    'projects', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.projects t),
    'components', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.components t),
    'nodes', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.nodes t),
    'decision_nodes', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.decision_id, t.node_id), ''))
                         FROM ops.decision_nodes t),
    'dispatch_nodes', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.dispatch_id, t.node_id), ''))
                         FROM ops.dispatch_nodes t));
$$;

CREATE FUNCTION pg_temp.node_id(p_path text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM ops.nodes WHERE path::text = p_path;
$$;

-- true (with one NOTICE) once M4b (0015) has dropped the helper: blocks that call it, check it or insert backlog
-- items without kind then skip
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

-- fixture sessions for the decisions and dispatches created below (session_id NOT NULL from 0022): one without a
-- project, one in local-ops. Created before block 2, whose helper call fills them, so the exact counts of blocks 5
-- and 6 are unchanged; occurred_at 1980 lies outside every window, so no window_id is ever filled for them.
DO $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO ops.sessions (kind, occurred_at) VALUES ('planning', '1980-01-01 00:00+00') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.s_none', v_id::text, true);
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES ((SELECT id FROM ops.projects WHERE key = 'local-ops'), 'planning', '1980-01-01 00:00+00') RETURNING id INTO v_id;
  PERFORM set_config('ops_test.s_lo', v_id::text, true);
END $$;

-- the fixture session for a row of project p_project (NULL: the project-less one)
CREATE FUNCTION pg_temp.session(p_project uuid) RETURNS uuid LANGUAGE sql AS $$
  SELECT CASE WHEN p_project IS NULL THEN current_setting('ops_test.s_none') ELSE current_setting('ops_test.s_lo') END::uuid;
$$;

-- 1. tree: the three framework nodes
DO $$
DECLARE g ops.nodes; lo ops.nodes; co ops.nodes; v_core uuid; v_sub bigint;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  SELECT * INTO g FROM ops.nodes WHERE path::text = 'global';
  SELECT * INTO lo FROM ops.nodes WHERE path::text = 'global.local-ops';
  SELECT * INTO co FROM ops.nodes WHERE path::text = 'global.local-ops.core';
  -- the core component through its node, not the local-ops project row (0023 deletes that row)
  v_core := (SELECT c.id FROM ops.components c JOIN ops.nodes n ON n.id = c.node_id
              WHERE n.path::text = 'global.local-ops.core');
  PERFORM pg_temp.check(g.kind = 'global' AND g.parent_id IS NULL AND g.key = 'global', 'global node');
  PERFORM pg_temp.check(lo.kind = 'node' AND lo.parent_id = g.id AND lo.key = 'local-ops'
                        AND lo.title = 'local-ops framework' AND lo.component_id IS NULL, 'local-ops node');
  PERFORM pg_temp.check(co.kind = 'node' AND co.parent_id = lo.id AND co.key = 'core', 'core node');
  PERFORM pg_temp.check(co.component_id = v_core, 'core node carries the core component');
  PERFORM pg_temp.check((g.status, lo.status, co.status) = ('active', 'active', 'active'), 'framework nodes active');

  SELECT count(*) INTO v_sub FROM ops.nodes WHERE path OPERATOR(public.<@) 'global.local-ops'::public.ltree;
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 1 pinned subtree size (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check(v_sub = 2, 'subtree of global.local-ops has 2 nodes, got ' || v_sub);
    PERFORM pg_temp.check((SELECT count(*) FROM ops.nodes) = 3, 'exactly 3 nodes right after 0010');
  END IF;
  -- relative: one child under core grows the subtree by one
  INSERT INTO ops.nodes (parent_id, key, kind, title) VALUES (co.id, 't0010', 'node', 't0010');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.nodes WHERE path OPERATOR(public.<@) 'global.local-ops'::public.ltree)
                        = v_sub + 1, 'subtree grows by one');
  PERFORM pg_temp.check((SELECT path::text FROM ops.nodes WHERE parent_id = co.id AND key = 't0010')
                        = 'global.local-ops.core.t0010', 'child path under core');
  RAISE NOTICE 'ok   1 tree (local-ops subtree % nodes before the test child)', v_sub;
END $$;

-- 2. mapping: home rule on registry, decisions, backlog and dispatches. The decisions, backlog items and dispatches
--    are created here with no links and no home node; the helper's mapping is asserted on those rows only.
DO $$
DECLARE v_lo uuid := pg_temp.node_id('global.local-ops'); v_co uuid := pg_temp.node_id('global.local-ops.core');
        c ops.components := (SELECT c FROM ops.components c WHERE c.id =
                               (SELECT component_id FROM ops.nodes WHERE path::text = 'global.local-ops.core'));
        v_d uuid[]; v_b uuid[]; v_x uuid[]; v_bad bigint;
BEGIN
  IF pg_temp.helper_gone('2 mapping') THEN RETURN; END IF;
  PERFORM pg_temp.check((SELECT node_id FROM ops.projects WHERE key = 'local-ops') = v_lo, 'projects.node_id local-ops');
  PERFORM pg_temp.check((SELECT node_id FROM ops.components WHERE id = c.id) = v_co, 'components.node_id core');

  WITH i AS (INSERT INTO ops.decisions (project_id, component_id, session_id, decision)
             VALUES (NULL, NULL, pg_temp.session(NULL), 't0010 b2 no component'),
                    (c.project_id, NULL, pg_temp.session(c.project_id), 't0010 b2 project only'),
                    (c.project_id, c.id, pg_temp.session(c.project_id), 't0010 b2 core')
             RETURNING id)
  SELECT array_agg(id) INTO v_d FROM i;
  WITH i AS (INSERT INTO ops.backlog_items (project_id, component_id, title, source)
             VALUES (NULL, NULL, 't0010 b2 no component', 'kind:task'),
                    (c.project_id, NULL, 't0010 b2 project only', 'kind:followup'),
                    (c.project_id, c.id, 't0010 b2 core', 'kind:proposal')
             RETURNING id)
  SELECT array_agg(id) INTO v_b FROM i;
  WITH i AS (INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
             SELECT c.project_id, c.id, 'addition',
                    pg_temp.session(c.project_id), 't0010 b2 ' || n, 'p'
               FROM generate_series(1, 2) n
             RETURNING id)
  SELECT array_agg(id) INTO v_x FROM i;
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.decision_nodes WHERE decision_id = ANY (v_d))
                        AND NOT EXISTS (SELECT 1 FROM ops.dispatch_nodes WHERE dispatch_id = ANY (v_x))
                        AND NOT EXISTS (SELECT 1 FROM ops.backlog_items WHERE id = ANY (v_b) AND home_node_id IS NOT NULL),
                        'test rows start unlinked and unhomed');
  PERFORM ops._spine_backfill();

  SELECT count(*) INTO v_bad FROM ops.decisions d
   WHERE d.id = ANY (v_d)
     AND NOT EXISTS (SELECT 1 FROM ops.decision_nodes dn WHERE dn.decision_id = d.id
                        AND dn.node_id = CASE WHEN d.component_id IS NULL THEN v_lo ELSE v_co END);
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' decisions not linked to their home node');
  SELECT count(*) INTO v_bad FROM ops.decision_nodes dn JOIN ops.decisions d ON d.id = dn.decision_id
   WHERE d.id = ANY (v_d) AND dn.node_id <> CASE WHEN d.component_id IS NULL THEN v_lo ELSE v_co END;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' decision links off the home node');

  SELECT count(*) INTO v_bad FROM ops.backlog_items b
   WHERE b.id = ANY (v_b) AND b.home_node_id IS DISTINCT FROM CASE WHEN b.component_id IS NULL THEN v_lo ELSE v_co END;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' backlog items homed off the rule');

  SELECT count(*) INTO v_bad FROM ops.dispatches x
   WHERE x.id = ANY (v_x)
     AND NOT EXISTS (SELECT 1 FROM ops.dispatch_nodes xn WHERE xn.dispatch_id = x.id AND xn.node_id = v_co);
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' dispatches not linked to core');
  SELECT count(*) INTO v_bad FROM ops.dispatch_nodes WHERE dispatch_id = ANY (v_x) AND node_id <> v_co;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' dispatch links off core');
  RAISE NOTICE 'ok   2 mapping (test rows: % decisions, % on core; % backlog items, % on core; % dispatches on core)',
    cardinality(v_d), (SELECT count(component_id) FROM ops.decisions WHERE id = ANY (v_d)),
    cardinality(v_b), (SELECT count(component_id) FROM ops.backlog_items WHERE id = ANY (v_b)), cardinality(v_x);
END $$;

-- 3. sessions: scope, task_status and window_id row by row, on sessions created here around a window of their own
DO $$
DECLARE v_win uuid; v_s uuid[]; v_bad bigint; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF pg_temp.helper_gone('3 sessions') THEN RETURN; END IF;
  INSERT INTO ops.windows (started_at, resets_at, start_source, initialiser)
  VALUES ('1990-01-01 00:00+00', '1990-01-01 05:00+00', 'inferred', 'code') RETURNING id INTO v_win;
  WITH i AS (INSERT INTO ops.sessions (kind, status, close_reason, closed_at, occurred_at)
             VALUES ('planning', 'active', NULL, NULL, '1990-01-01 01:00+00'),
                    ('planning', 'closed', 'normal', now(), '1990-01-01 02:00+00'),
                    ('execution', 'closed', 'stale', now(), '1989-12-31 12:00+00'),
                    ('execution', 'closed', 'erosion', now(), '1990-01-01 05:00+00')
             RETURNING id)
  SELECT array_agg(id) INTO v_s FROM i;
  PERFORM ops._spine_backfill();

  SELECT count(*) INTO v_bad FROM ops.sessions WHERE id = ANY (v_s) AND scope IS DISTINCT FROM 'global';
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' sessions not scope global');
  -- closed sessions get task_status 'open' by default from 0011 on, so the helper's closed/stale mapping is
  -- unreachable for them; that part is pinned to the state right after 0010
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 3 task_status mapping of closed sessions (newest migration is %)', newest;
  END IF;
  SELECT count(*) INTO v_bad FROM ops.sessions
   WHERE id = ANY (v_s) AND (status = 'active' OR newest = '0010_spine_b_backfill')
     AND task_status IS DISTINCT FROM CASE WHEN status = 'active' THEN 'open'
                                           WHEN close_reason = 'stale' THEN 'unfinished'
                                           ELSE 'closed' END::ops.task_status;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' sessions with the wrong task_status');
  SELECT count(*) INTO v_bad FROM ops.sessions s
   WHERE s.id = ANY (v_s)
     AND s.window_id IS DISTINCT FROM (SELECT w.id FROM ops.windows w
                                        WHERE s.occurred_at >= w.started_at AND s.occurred_at < w.resets_at);
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' sessions with the wrong window_id');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.sessions WHERE id = ANY (v_s) AND window_id = v_win) = 2,
                        'two test sessions in the test window (the one at resets_at and the stale one are outside)');
  SELECT count(*) INTO v_bad FROM ops.sessions
   WHERE id = ANY (v_s)
     AND (resumed_from IS NOT NULL OR usage_open IS NOT NULL OR usage_close IS NOT NULL OR path_id IS NOT NULL);
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' sessions with resumed_from/usage/path_id set');
  RAISE NOTICE 'ok   3 sessions (% test rows, % in a window)',
    cardinality(v_s), (SELECT count(window_id) FROM ops.sessions WHERE id = ANY (v_s));
END $$;

-- 4. values: trust, severity, kind from the source prefix, on rows created here; the helper leaves dispatch_types
--    (and the project_id of a type created here) untouched
DO $$
DECLARE v_d uuid; v_b uuid[]; v_bad bigint; v_types text;
BEGIN
  IF pg_temp.helper_gone('4 values') THEN RETURN; END IF;
  INSERT INTO ops.decisions (session_id, decision) VALUES (pg_temp.session(NULL), 't0010 b4') RETURNING id INTO v_d;
  WITH i AS (INSERT INTO ops.backlog_items (title, source)
             SELECT 't0010 b4 ' || s, s
               FROM unnest(ARRAY['kind:task', 'kind:followup', 'kind:proposal', 'kind:discussion', 'kind:allowed_bug',
                                 'kind:task|dispatch:x']) s
             RETURNING id)
  SELECT array_agg(id) INTO v_b FROM i;
  INSERT INTO ops.dispatch_types (type, description, commit_policy) VALUES ('t0010', 't', 'none');
  SELECT md5(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.type)) INTO v_types FROM ops.dispatch_types t;
  PERFORM ops._spine_backfill();

  SELECT count(*) INTO v_bad FROM ops.decisions WHERE id = v_d AND trust_status IS DISTINCT FROM 'approved';
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' decisions not approved');
  SELECT count(*) INTO v_bad FROM ops.backlog_items WHERE id = ANY (v_b) AND severity IS DISTINCT FROM 'untriaged';
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' backlog items not untriaged');
  SELECT count(*) INTO v_bad FROM ops.backlog_items
   WHERE id = ANY (v_b) AND kind::text IS DISTINCT FROM substring(source FROM '^kind:([a-z_]+)(?:\||$)');
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' backlog items whose kind differs from the source prefix');
  SELECT count(*) INTO v_bad FROM ops.backlog_items WHERE id = ANY (v_b) AND resolved_by IS NOT NULL;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' backlog items with resolved_by set');
  SELECT count(*) INTO v_bad FROM ops.dispatch_types WHERE type = 't0010' AND project_id IS NOT NULL;
  PERFORM pg_temp.check(v_bad = 0, v_bad || ' dispatch_types with project_id set');
  PERFORM pg_temp.check((SELECT md5(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.type)) FROM ops.dispatch_types t)
                        = v_types, 'the helper leaves dispatch_types unchanged');
  RAISE NOTICE 'ok   4 values (kinds: %)',
    (SELECT string_agg(k || '=' || n, ', ' ORDER BY k) FROM (SELECT kind::text AS k, count(*) AS n
                                                              FROM ops.backlog_items WHERE id = ANY (v_b) GROUP BY 1) s);
END $$;

-- 5. idempotence: once rows written since 0010 are absorbed, the helper fills nothing and changes nothing.
--    That the applied state needs no fill at all is pinned to the state right after 0010.
DO $$
DECLARE v_before jsonb; v_res jsonb; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF pg_temp.helper_gone('5 idempotence') THEN RETURN; END IF;
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 5 applied state needs no fill (newest migration is %)', newest;
    PERFORM ops._spine_backfill();         -- absorb rows written since 0010
  ELSE
    v_before := pg_temp.full_fp();
    v_res := ops._spine_backfill();
    PERFORM pg_temp.check(v_res = pg_temp.zero(), 'call on the applied state returns all-zero counts: ' || v_res::text);
    PERFORM pg_temp.check(pg_temp.full_fp() = v_before, 'call on the applied state changes nothing');
  END IF;
  v_before := pg_temp.full_fp();
  v_res := ops._spine_backfill();
  PERFORM pg_temp.check(v_res = pg_temp.zero(), 'second call returns all-zero counts: ' || v_res::text);
  PERFORM pg_temp.check(pg_temp.full_fp() = v_before, 'second call changes nothing');
  RAISE NOTICE 'ok   5 idempotent';
END $$;

-- 6. catch-up rows: filled per the rules, pre-M2 columns untouched
DO $$
DECLARE v_lo uuid := pg_temp.node_id('global.local-ops'); v_co uuid := pg_temp.node_id('global.local-ops.core');
        c ops.components := (SELECT c FROM ops.components c WHERE c.key = 'core');
        v_win uuid; v_s_start uuid; v_s_end uuid; v_s_stale uuid; v_s_erosion uuid;
        v_d_none uuid; v_d_core uuid; v_b uuid; v_x uuid; v_fp jsonb; v_full jsonb; v_res jsonb;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
        -- M3 (0011) defaults fill these on insert, so the helper no longer sees them NULL
        v_defaulted text[] := ARRAY['sessions_scope', 'sessions_task_status', 'decisions_trust_status', 'backlog_severity'];
        v_expect jsonb := pg_temp.zero() || '{"sessions_scope": 4, "sessions_task_status": 4, "sessions_window_id": 2,
                                              "decisions_trust_status": 2, "decision_nodes_inserted": 2,
                                              "backlog_severity": 1, "backlog_kind": 1, "backlog_home_node_id": 1,
                                              "dispatch_nodes_inserted": 1}'::jsonb;
BEGIN
  IF pg_temp.helper_gone('6 catch-up rows') THEN RETURN; END IF;
  INSERT INTO ops.windows (started_at, resets_at, start_source, initialiser)
  VALUES ('2000-01-01 00:00+00', '2000-01-01 05:00+00', 'inferred', 'code') RETURNING id INTO v_win;
  INSERT INTO ops.sessions (kind, occurred_at) VALUES ('planning', '2000-01-01 00:00+00') RETURNING id INTO v_s_start;
  INSERT INTO ops.sessions (kind, status, close_reason, closed_at, occurred_at)
  VALUES ('planning', 'closed', 'normal', now(), '2000-01-01 05:00+00') RETURNING id INTO v_s_end;
  INSERT INTO ops.sessions (kind, status, close_reason, closed_at, occurred_at)
  VALUES ('execution', 'closed', 'stale', now(), '1999-12-31 12:00+00') RETURNING id INTO v_s_stale;
  INSERT INTO ops.sessions (kind, status, close_reason, closed_at, occurred_at)
  VALUES ('execution', 'closed', 'erosion', now(), '2000-01-01 02:00+00') RETURNING id INTO v_s_erosion;
  INSERT INTO ops.decisions (session_id, decision) VALUES (pg_temp.session(NULL), 't0010 no component')
  RETURNING id INTO v_d_none;
  INSERT INTO ops.decisions (project_id, component_id, session_id, decision)
  VALUES (c.project_id, c.id, pg_temp.session(c.project_id), 't0010 core')
  RETURNING id INTO v_d_core;
  INSERT INTO ops.backlog_items (project_id, component_id, title, source)
  VALUES (c.project_id, c.id, 't0010', 'kind:proposal') RETURNING id INTO v_b;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, session_id, title, prompt)
  VALUES (c.project_id, c.id, 'addition', pg_temp.session(c.project_id),
          't0010', 'p')
  RETURNING id INTO v_x;

  v_fp := pg_temp.fp();
  v_res := ops._spine_backfill();
  PERFORM pg_temp.check(pg_temp.fp() = v_fp, 'pre-M2 columns unchanged by the helper');
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 6 counts % (newest migration is %)', v_defaulted, newest;
    PERFORM pg_temp.check(v_res - v_defaulted = v_expect - v_defaulted, 'catch-up counts: ' || v_res::text);
  ELSE
    PERFORM pg_temp.check(v_res = v_expect, 'catch-up counts: ' || v_res::text);
  END IF;

  -- 0022 drops sessions.task_status (M5b release 2); from then on scope and window only
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 6 task_status of the active session (newest migration is %)', newest;
    PERFORM pg_temp.check((SELECT (scope, window_id) = ('global', v_win)
                             FROM ops.sessions WHERE id = v_s_start), 'active session at window start: in window');
  ELSE
  PERFORM pg_temp.check((SELECT (scope, task_status, window_id) = ('global', 'open', v_win)
                           FROM ops.sessions WHERE id = v_s_start), 'active session at window start: open, in window');
  END IF;
  PERFORM pg_temp.check((SELECT scope = 'global' AND window_id IS NULL
                           FROM ops.sessions WHERE id = v_s_end), 'session at resets_at: outside the window');
  PERFORM pg_temp.check((SELECT scope = 'global' AND window_id IS NULL
                           FROM ops.sessions WHERE id = v_s_stale), 'stale session: no window');
  PERFORM pg_temp.check((SELECT (scope, window_id) = ('global', v_win)
                           FROM ops.sessions WHERE id = v_s_erosion), 'erosion session: in window');
  -- closed sessions now get task_status 'open' by default (0011), so the helper's closed/stale mapping is
  -- unreachable; it is pinned to the state right after 0010
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 6 task_status mapping of closed sessions (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check((SELECT task_status = 'closed' FROM ops.sessions WHERE id = v_s_end), 'session at resets_at: closed');
    PERFORM pg_temp.check((SELECT task_status = 'unfinished' FROM ops.sessions WHERE id = v_s_stale), 'stale session: unfinished');
    PERFORM pg_temp.check((SELECT task_status = 'closed' FROM ops.sessions WHERE id = v_s_erosion), 'erosion session: closed');
  END IF;
  PERFORM pg_temp.check((SELECT trust_status = 'approved' FROM ops.decisions WHERE id = v_d_none)
                        AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = v_d_none) = ARRAY[v_lo],
                        'decision without component: approved, linked to local-ops');
  PERFORM pg_temp.check((SELECT trust_status = 'approved' FROM ops.decisions WHERE id = v_d_core)
                        AND (SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = v_d_core) = ARRAY[v_co],
                        'decision on core: approved, linked to core');
  PERFORM pg_temp.check((SELECT (severity, kind, home_node_id) = ('untriaged', 'proposal', v_co)
                           FROM ops.backlog_items WHERE id = v_b), 'backlog kind:proposal filled, homed on core');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.dispatch_nodes WHERE dispatch_id = v_x) = ARRAY[v_co],
                        'dispatch linked to core');

  v_full := pg_temp.full_fp();
  PERFORM pg_temp.check(ops._spine_backfill() = pg_temp.zero() AND pg_temp.full_fp() = v_full,
                        'call after catch-up is a no-op');
  RAISE NOTICE 'ok   6 catch-up rows filled; pre-M2 fingerprint unchanged';
END $$;

-- 7. guards: unparseable kind, unmapped component, context_documents rows
CREATE FUNCTION pg_temp.with_backlog(p_source text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ops.backlog_items (title, source) VALUES ('t0010 guard', p_source);
  RETURN ops._spine_backfill();
END $$;

CREATE FUNCTION pg_temp.with_component_decision() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_p uuid := (SELECT id FROM ops.projects WHERE key = 'local-ops'); v_c uuid;
BEGIN
  INSERT INTO ops.components (project_id, key, kind) VALUES (v_p, 't0010', 'test') RETURNING id INTO v_c;
  INSERT INTO ops.decisions (project_id, component_id, session_id, decision)
  VALUES (v_p, v_c, pg_temp.session(v_p), 't0010 other component');
  RETURN ops._spine_backfill();
END $$;

-- the document sits on a node of its own under local-ops, never on a real document's (node_id, doc_type)
CREATE FUNCTION pg_temp.with_document(p_node boolean, p_type boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_node uuid;
BEGIN
  IF p_node THEN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES (pg_temp.node_id('global.local-ops'), 't0010-doc', 'node', 't0010-doc') RETURNING id INTO v_node;
  END IF;
  INSERT INTO ops.context_documents (doc_key, title, content, node_id, doc_type)
  VALUES ('T0010', 't', 'c', v_node, CASE WHEN p_type THEN 'manual' END);
  RETURN ops._spine_backfill();
END $$;

DO $$
DECLARE v_full jsonb := pg_temp.full_fp(); newest text := (SELECT max(version) FROM ops.schema_migrations);
        -- the helper's 23514 guard on documents is pinned to the state right after 0010; from 0011 on, NOT NULL
        -- on node_id and doc_type refuses the insert first (23502)
        v_doc_state text := CASE WHEN newest <> '0010_spine_b_backfill' THEN '23502' ELSE '23514' END;
BEGIN
  IF pg_temp.helper_gone('7 guards') THEN RETURN; END IF;
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 7 helper guard on documents, expect NOT NULL refusal instead (newest migration is %)', newest;
  END IF;
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_backlog(NULL)$q$, '23514', 'backlog source NULL');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_backlog('proposal')$q$, '23514', 'backlog source without kind: prefix');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_backlog('dispatch:x|kind:proposal')$q$, '23514', 'kind: not a prefix');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_backlog('kind:bug')$q$, '23514', 'unknown kind value');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_backlog('kind:proposalx')$q$, '23514', 'kind value with trailing text');
  PERFORM pg_temp.passes($q$SELECT pg_temp.with_backlog('kind:allowed_bug|dispatch:x')$q$,
                         'kind:allowed_bug with a suffix parses');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_component_decision()$q$, '23514', 'decision on an unmapped component');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_document(false, false)$q$, v_doc_state, 'context_documents row, node and type NULL');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_document(true, false)$q$, v_doc_state, 'context_documents row, doc_type NULL');
  PERFORM pg_temp.rejects($q$SELECT pg_temp.with_document(false, true)$q$, v_doc_state, 'context_documents row, node_id NULL');
  PERFORM pg_temp.passes($q$SELECT pg_temp.with_document(true, true)$q$,
                         'context_documents row with node_id and doc_type passes');
  PERFORM pg_temp.check(pg_temp.full_fp() = v_full, 'refused and probing calls left nothing behind');
  RAISE NOTICE 'ok   7 guards';
END $$;

-- 8. grants: the helper is owner-only; existing grants unchanged
DO $$
DECLARE p pg_proc := (SELECT p FROM pg_proc p WHERE p.oid = to_regprocedure('ops._spine_backfill()'));
        v_acl text; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF pg_temp.helper_gone('8 grants') THEN RETURN; END IF;
  PERFORM pg_temp.check(NOT has_function_privilege(r, 'ops._spine_backfill()', 'EXECUTE'), r || ' cannot execute the helper')
     FROM unnest(ARRAY['public', 'ops_planner', 'ops_executor']) r;
  PERFORM pg_temp.check(p.proacl IS NOT NULL AND array_length(p.proacl, 1) = 1, 'helper ACL holds the owner only: ' || p.proacl::text);
  PERFORM pg_temp.check(NOT p.prosecdef, 'helper is not security definer');
  PERFORM pg_temp.check(p.proconfig = ARRAY['search_path=ops, pg_temp'], 'helper search_path pinned');
  PERFORM pg_temp.check(p.prorettype = 'jsonb'::regtype, 'helper returns jsonb');

  -- every ACL in ops except the helper, against the snapshot taken on rehearsal before 0010 under
  -- search_path = ops, pg_temp (regprocedure text depends on it)
  SELECT md5(string_agg(x, E'\n' ORDER BY x COLLATE "C")) INTO v_acl FROM (
    SELECT 'rel ' || relname || ' ' || coalesce(relacl::text, '-') AS x FROM pg_class
     WHERE relnamespace = 'ops'::regnamespace AND relkind IN ('r', 'v', 'S')
    UNION ALL
    SELECT 'fn ' || oid::regprocedure::text || ' ' || coalesce(proacl::text, '-') FROM pg_proc
     WHERE pronamespace = 'ops'::regnamespace AND proname <> '_spine_backfill') s;
  IF newest <> '0010_spine_b_backfill' THEN
    RAISE NOTICE 'skip 8 grant snapshot (newest migration is %)', newest;
  ELSE
    PERFORM pg_temp.check(v_acl = '6bbefc12c0d8cfdf4de001af63d77fc0', 'ops grants unchanged by 0010 (60 ACLs): ' || v_acl);
  END IF;
  RAISE NOTICE 'ok   8 grants';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.nodes) <> current_setting('ops_test.nodes_before')::bigint
     OR (SELECT count(*) FROM ops.sessions) <> current_setting('ops_test.sessions_before')::bigint
     OR (SELECT count(*) FROM ops.windows) <> current_setting('ops_test.windows_before')::bigint
     OR (SELECT count(*) FROM ops.components) <> current_setting('ops_test.components_before')::bigint
     OR (SELECT count(*) FROM ops.decisions) <> current_setting('ops_test.decisions_before')::bigint
     OR (SELECT count(*) FROM ops.decision_nodes) <> current_setting('ops_test.decision_nodes_before')::bigint
     OR (SELECT count(*) FROM ops.backlog_items) <> current_setting('ops_test.backlog_items_before')::bigint
     OR (SELECT count(*) FROM ops.dispatches) <> current_setting('ops_test.dispatches_before')::bigint
     OR (SELECT count(*) FROM ops.dispatch_nodes) <> current_setting('ops_test.dispatch_nodes_before')::bigint
     OR (SELECT count(*) FROM ops.context_documents) <> current_setting('ops_test.context_documents_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   9 no leftover rows; 0010 tests passed';
END $$;
