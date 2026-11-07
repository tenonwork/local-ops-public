-- tests/sql/0014_writer_functions.sql
-- Tests for migrations/0014_writer_functions.sql. Run as the schema owner against a non-production database where
-- 0014 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0014_writer_functions.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so every call below also
-- proves the functions work under the pinned path (block 0 asserts it).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400 / 7eb6746f): the file creates its own projects t0014a / t0014b (and a node-less
-- t0014nonode), components, sessions, dispatches and decisions, asserts only on those, and counts relative to the
-- starting state. Calls on local-ops only open sessions (open_session's auto-close also reaches other stale
-- active sessions of that project; the ROLLBACK undoes that).
-- 0021 drops the project-keyed overloads (M5b release 2): from 0021 on, blocks 0-4 and 6 (whose subject is a
-- project-keyed function) skip, and blocks 0, 2, 3 and 4 build the fixtures later blocks need through the 0018
-- node-keyed functions; blocks 7 and 8 open their sessions through the node-keyed open_session.

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in a session setting so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.counts_before', (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'dispatch_types', (SELECT count(*) FROM ops.dispatch_types)))::text, false);
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

-- asserts p_sql raises check_violation with a message containing p_like
CREATE FUNCTION pg_temp.rejects(p_sql text, p_like text, p_what text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text := pg_temp.err(p_sql);
BEGIN
  PERFORM pg_temp.check(e LIKE '23514 %' || p_like || '%', p_what || ': ' || coalesce(e, 'success'));
END $$;

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- status/close_reason/task_status; 0022 drops sessions.task_status (M5b release 2), so the column is read through
-- to_jsonb and, when absent, the 2eecc405 mapping stands in (every row satisfied it since 0012)
CREATE FUNCTION pg_temp.state(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT s.status || '/' || coalesce(s.close_reason::text, '-') || '/'
         || coalesce(to_jsonb(s)->>'task_status',
                     CASE WHEN s.status = 'active' THEN 'open' WHEN s.close_reason = 'stale' THEN 'unfinished'
                          ELSE 'closed' END)
    FROM ops.sessions s WHERE s.id = p_id;
$$;

-- 0. create_project / create_component; fixtures for the rest of the file
DO $$
DECLARE p ops.projects; c ops.components; n ops.nodes; v_global ops.nodes;
        v_nodes bigint := (SELECT count(*) FROM ops.nodes); newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 0 create_project / create_component (text) assertions, fixtures through the node-keyed functions (newest migration is %)', newest;
    p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0014a', p_name => 'T0014 A', p_params => '{"x": 1}');
    PERFORM set_config('ops_test.pa', p.id::text, true), set_config('ops_test.pa_node', p.node_id::text, true);
    p := ops.create_project(p_parent_path => 'global'::public.ltree, p_key => 't0014b', p_name => 'T0014 B');
    PERFORM set_config('ops_test.pb', p.id::text, true), set_config('ops_test.pb_node', p.node_id::text, true);
    c := ops.create_component(p_parent_path => 'global.t0014a'::public.ltree, p_key => 'ca', p_kind => 'service',
                              p_repo_ref => 'repo-a', p_verify_cmd => 'npm test', p_params => '{"y": 2}');
    PERFORM set_config('ops_test.ca', c.id::text, true), set_config('ops_test.ca_node', c.node_id::text, true);
    c := ops.create_component(p_parent_path => 'global.t0014a'::public.ltree, p_key => 'cb', p_kind => 'service');
    PERFORM set_config('ops_test.cb_node', c.node_id::text, true);
    c := ops.create_component(p_parent_path => 'global.t0014a'::public.ltree, p_key => 'cz', p_kind => 'service',
                              p_verify_cmd => 'npm test');
    UPDATE ops.components SET active = false WHERE id = c.id;
    c := ops.create_component(p_parent_path => 'global.t0014b'::public.ltree, p_key => 'cx', p_kind => 'service',
                              p_verify_cmd => 'make');
    PERFORM set_config('ops_test.cx', c.id::text, true);
    RETURN;
  END IF;
  SELECT * INTO v_global FROM ops.nodes WHERE kind = 'global';

  p := ops.create_project(p_key => 't0014a', p_name => 'T0014 A', p_params => '{"x": 1}');
  SELECT * INTO n FROM ops.nodes WHERE id = p.node_id;
  PERFORM pg_temp.check(p.key = 't0014a' AND p.name = 'T0014 A' AND p.params = '{"x": 1}', 'project row');
  PERFORM pg_temp.check(n.kind = 'project' AND n.parent_id = v_global.id AND n.key = 't0014a'
                        AND n.title = 'T0014 A' AND n.path::text = 'global.t0014a' AND n.component_id IS NULL,
                        'project node under global: ' || coalesce(n.path::text, 'missing'));
  PERFORM pg_temp.check((SELECT node_id FROM ops.projects WHERE key = 't0014a') = n.id, 'projects.node_id stored');
  PERFORM set_config('ops_test.pa', p.id::text, true);
  PERFORM set_config('ops_test.pa_node', n.id::text, true);
  p := ops.create_project('t0014b', 'T0014 B');
  PERFORM pg_temp.check(p.params = '{}', 'params default {}');
  PERFORM set_config('ops_test.pb', p.id::text, true);
  PERFORM set_config('ops_test.pb_node', p.node_id::text, true);

  c := ops.create_component('t0014a', 'ca', 'service', 'repo-a', 'npm test', '{"y": 2}');
  SELECT * INTO n FROM ops.nodes WHERE id = c.node_id;
  PERFORM pg_temp.check(c.project_id = pg_temp.id('pa') AND c.kind = 'service' AND c.repo_ref = 'repo-a'
                        AND c.verify_cmd = 'npm test' AND c.params = '{"y": 2}' AND c.active, 'component row');
  PERFORM pg_temp.check(n.kind = 'node' AND n.parent_id = pg_temp.id('pa_node') AND n.key = 'ca'
                        AND n.component_id = c.id AND n.path::text = 'global.t0014a.ca',
                        'component node under the project node: ' || coalesce(n.path::text, 'missing'));
  PERFORM pg_temp.check((SELECT node_id FROM ops.components WHERE id = c.id) = n.id, 'components.node_id stored');
  PERFORM set_config('ops_test.ca', c.id::text, true);
  PERFORM set_config('ops_test.ca_node', n.id::text, true);
  c := ops.create_component('t0014a', 'cb', 'service');                      -- no verify_cmd
  PERFORM pg_temp.check(c.repo_ref IS NULL AND c.verify_cmd IS NULL AND c.params = '{}', 'component defaults');
  PERFORM set_config('ops_test.cb_node', c.node_id::text, true);
  c := ops.create_component('t0014a', 'cz', 'service', NULL, 'npm test');    -- deactivated below
  UPDATE ops.components SET active = false WHERE id = c.id;
  c := ops.create_component('t0014b', 'cx', 'service', NULL, 'make');
  PERFORM set_config('ops_test.cx', c.id::text, true);

  PERFORM pg_temp.check((SELECT count(*) FROM ops.nodes) = v_nodes + 6, 'six nodes created');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('t0014a', 'dup')$q$, 'already exists', 'duplicate project');
  PERFORM pg_temp.rejects($q$SELECT ops.create_project('Bad Key', 'x')$q$, 'invalid project key', 'bad project key');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('t0014a', 'ca', 'service')$q$, 'already exists',
                          'duplicate component');
  RAISE NOTICE 'ok   0 create_project / create_component nodes and node_id';
END $$;

-- 1. create_component on a project without a node raises
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 1 create_component(text, ...) on a node-less project (newest migration is %)', newest;
    RETURN;
  END IF;
  INSERT INTO ops.projects (key, name) VALUES ('t0014nonode', 'no node');
  PERFORM pg_temp.rejects($q$SELECT ops.create_component('t0014nonode', 'c', 'service')$q$,
                          'project "t0014nonode" has no node', 'node-less project');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.components c JOIN ops.projects p ON p.id = c.project_id
                                     WHERE p.key = 't0014nonode'), 'no component written');
  RAISE NOTICE 'ok   1 create_component refuses a project without a node';
END $$;

-- 2. create_dispatch
DO $$
DECLARE d ops.dispatches; v_s uuid; v_sb uuid; v_before bigint := (SELECT count(*) FROM ops.dispatches);
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 2 create_dispatch(text, ...), fixture through the node-keyed function (newest migration is %)', newest;
    -- the fixture carries a session of its own (required from 0022)
    d := ops.create_dispatch(p_node_path => 'global.t0014a.ca'::public.ltree, p_dispatch_type => 'addition',
                             p_title => 't0014 add', p_prompt => 'prompt',
                             p_session => ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning'));
    PERFORM set_config('ops_test.dispatch_a', d.id::text, true);
    RETURN;
  END IF;
  d := ops.create_dispatch('t0014a', 'cb', 'investigation', 't0014 inv', 'prompt');
  PERFORM pg_temp.check(d.status = 'pending' AND d.session_id IS NULL AND d.context_refs = '{}' AND d.priority = 100
                        AND d.project_id = pg_temp.id('pa'), 'dispatch pending with defaults');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.dispatch_nodes WHERE dispatch_id = d.id)
                        = ARRAY[pg_temp.id('cb_node')], 'dispatch_nodes = component node');

  v_s := ops.open_session('t0014a', 'ca', 'planning');
  INSERT INTO ops.context_documents (project_id, doc_key, title, content, node_id, doc_type)
  VALUES (pg_temp.id('pa'), 'T0014_DOC', 'doc', E'# Top\ntext\n## Part\nbody', pg_temp.id('pa_node'), 'manual');
  d := ops.create_dispatch('t0014a', 'ca', 'addition', 't0014 add', 'prompt', '{T0014_DOC,T0014_DOC#Part}', 7, v_s);
  PERFORM pg_temp.check(d.status = 'pending' AND d.session_id = v_s AND d.priority = 7
                        AND d.context_refs = '{T0014_DOC,T0014_DOC#Part}', 'session, refs and priority stored');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.dispatch_nodes WHERE dispatch_id = d.id)
                        = ARRAY[pg_temp.id('ca_node')], 'dispatch_nodes = ca node');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) = v_before + 2, 'two dispatches written');

  INSERT INTO ops.dispatch_types (type, description, commit_policy, active)
  VALUES ('t0014_inactive', 'inactive test type', 'none', false);
  v_sb := ops.open_session('t0014b', NULL, 'planning');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch('t0014a', 'cz', 'investigation', 't', 'p')$q$,
                          'component "t0014a/cz" is not active', 'inactive component');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch('t0014a', 'ca', 't0014_inactive', 't', 'p')$q$,
                          'dispatch type "t0014_inactive" is not active', 'inactive type');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch('t0014a', 'ca', 'no_such_type_t0014', 't', 'p')$q$,
                          'unknown dispatch type', 'unknown type');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch('t0014a', 'cb', 'addition', 't', 'p')$q$,
                          'has commit policy local but component "t0014a/cb" has no verify_cmd', 'policy without verify_cmd');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch(p_project_key => 't0014a', p_component_key => 'ca', p_dispatch_type => 'addition', p_title => 't', p_prompt => 'p', p_context_refs => '{NO_SUCH_DOC_T0014}')$q$,
                          'context ref "NO_SUCH_DOC_T0014" does not resolve', 'unknown ref');
  PERFORM pg_temp.rejects($q$SELECT ops.create_dispatch(p_project_key => 't0014a', p_component_key => 'ca', p_dispatch_type => 'addition', p_title => 't', p_prompt => 'p', p_context_refs => '{T0014_DOC#Nope}')$q$,
                          'context ref "T0014_DOC#Nope" does not resolve', 'heading miss');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('t0014a', 'ca', 'addition', 't', 'p', '{}', 100, %L)$q$, v_sb),
                          'belongs to another project', 'session of another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.create_dispatch('t0014a', 'ca', 'addition', 't', 'p', '{}', 100, %L)$q$,
                                 gen_random_uuid()), 'does not exist', 'unknown session');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatches) = v_before + 2, 'refusals wrote nothing');
  PERFORM set_config('ops_test.dispatch_a', d.id::text, true);
  RAISE NOTICE 'ok   2 create_dispatch pending, node, session; five refusals';
END $$;

-- 3. log_decision
DO $$
DECLARE d ops.decisions; d2 ops.decisions; v_sb uuid; v_db uuid; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 3 log_decision(text, ...), fixtures through the node-keyed function (newest migration is %)', newest;
    -- the fixtures carry sessions of their own (required from 0022)
    PERFORM set_config('ops_test.decision_a',
      (ops.log_decision(p_node_path => 'global.t0014a'::public.ltree, p_decision => 't0014 project-level',
                        p_session => ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning'))).id::text, true);
    PERFORM set_config('ops_test.decision_b',
      (ops.log_decision(p_node_path => 'global.t0014b'::public.ltree, p_decision => 't0014 b decision',
                        p_session => ops.open_session(p_node_path => 'global.t0014b'::public.ltree, p_kind => 'planning'))).id::text, true);
    RETURN;
  END IF;
  d := ops.log_decision('t0014a', 't0014 project-level');
  PERFORM pg_temp.check(d.component_id IS NULL AND d.project_id = pg_temp.id('pa') AND d.rejected_alternatives = '[]',
                        'decision row');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d.id)
                        = ARRAY[pg_temp.id('pa_node')], 'no component -> project node');
  d2 := ops.log_decision('t0014a', 't0014 component-level', 'ca', 'why', '["alt"]', 'when', 'scope-x', d.id,
                         ops.open_session('t0014a', 'ca', 'planning'));
  PERFORM pg_temp.check(d2.component_id = pg_temp.id('ca') AND d2.supersedes = d.id AND d2.session_id IS NOT NULL
                        AND d2.rationale = 'why' AND d2.rejected_alternatives = '["alt"]'
                        AND d2.revisit_condition = 'when' AND d2.scope = 'scope-x', 'all fields stored');
  PERFORM pg_temp.check((SELECT array_agg(node_id) FROM ops.decision_nodes WHERE decision_id = d2.id)
                        = ARRAY[pg_temp.id('ca_node')], 'component -> component node');

  v_db := (ops.log_decision('t0014b', 't0014 b decision')).id;
  v_sb := ops.open_session('t0014b', NULL, 'planning');
  PERFORM set_config('ops_test.decision_b', v_db::text, true);
  PERFORM set_config('ops_test.decision_a', d.id::text, true);
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision(p_project_key => 't0014a', p_decision => 'x', p_component_key => NULL, p_rationale => NULL, p_rejected_alternatives => '[]', p_revisit_condition => NULL, p_scope => NULL, p_supersedes => %L)$q$, v_db),
                          'does not exist in project "t0014a"', 'supersedes from another project');
  PERFORM pg_temp.rejects(format($q$SELECT ops.log_decision('t0014a', 'x', NULL, NULL, '[]', NULL, NULL, NULL, %L)$q$, v_sb),
                          'belongs to another project', 'session from another project');
  RAISE NOTICE 'ok   3 log_decision home rule both branches; cross-project refusals';
END $$;

-- 4. add_backlog_item
DO $$
DECLARE b ops.backlog_items; v_xd uuid; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 4 add_backlog_item(text, ...), fixture through the node-keyed function (newest migration is %)', newest;
    b := ops.add_backlog_item(p_node_path => 'global.t0014a.ca'::public.ltree, p_kind => 'task', p_title => 't0014 item 2',
                              p_detail => 'detail', p_source_dispatch => pg_temp.id('dispatch_a'), p_severity => 'high');
    PERFORM set_config('ops_test.backlog', b.id::text, true);
    RETURN;
  END IF;
  b := ops.add_backlog_item('t0014a', 'followup', 't0014 item');
  PERFORM pg_temp.check(b.kind = 'followup' AND b.severity = 'untriaged' AND b.home_node_id = pg_temp.id('pa_node')
                        AND b.component_id IS NULL AND b.status = 'open', 'project-level item');
  PERFORM pg_temp.check(b.source = 'kind:followup', 'source without dispatch: ' || coalesce(b.source, 'NULL'));
  b := ops.add_backlog_item('t0014a', 'task', 't0014 item 2', 'ca', 'detail', pg_temp.id('dispatch_a'), 'high');
  PERFORM pg_temp.check(b.kind = 'task' AND b.severity = 'high' AND b.home_node_id = pg_temp.id('ca_node')
                        AND b.component_id = pg_temp.id('ca') AND b.detail = 'detail', 'component-level item');
  PERFORM pg_temp.check(b.source = 'kind:task|dispatch:' || pg_temp.id('dispatch_a'),
                        'source with dispatch: ' || coalesce(b.source, 'NULL'));
  PERFORM set_config('ops_test.backlog', b.id::text, true);

  v_xd := (ops.create_dispatch('t0014b', 'cx', 'investigation', 't0014 b', 'p')).id;
  PERFORM pg_temp.rejects(format($q$SELECT ops.add_backlog_item(p_project_key => 't0014a', p_kind => 'task', p_title => 'x', p_component_key => NULL, p_detail => NULL, p_source_dispatch => %L)$q$, v_xd),
                          'does not exist in project "t0014a"', 'source dispatch from another project');
  RAISE NOTICE 'ok   4 add_backlog_item kind, severity, home node, source';
END $$;

-- 5. update_backlog_item
DO $$
DECLARE v_id uuid := pg_temp.id('backlog'); b ops.backlog_items;
BEGIN
  b := ops.update_backlog_item(v_id, 'done');
  PERFORM pg_temp.check(b.status = 'done' AND b.closed_at = now() AND b.detail = 'detail', 'done: closed_at, detail kept');
  b := ops.update_backlog_item(v_id, 'open', 'new detail');
  PERFORM pg_temp.check(b.status = 'open' AND b.closed_at IS NULL AND b.detail = 'new detail', 'reopen clears closed_at');
  b := ops.update_backlog_item(v_id, 'dropped');
  PERFORM pg_temp.check(b.status = 'dropped' AND b.closed_at = now() AND b.detail = 'new detail', 'dropped');
  PERFORM pg_temp.rejects(format($q$SELECT ops.update_backlog_item(%L, 'closed')$q$, v_id),
                          'invalid backlog status "closed"', 'bad status');
  PERFORM pg_temp.rejects(format($q$SELECT ops.update_backlog_item(%L, 'done')$q$, gen_random_uuid()),
                          'does not exist', 'unknown item');
  RAISE NOTICE 'ok   5 update_backlog_item';
END $$;

-- 6. open_session: scope, provenance, stale auto-close, old positional call
DO $$
DECLARE v_s uuid; s ops.sessions; v_hours integer := coalesce(
          (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
        v_old uuid; v_fresh uuid; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 6 open_session(text, ...) (newest migration is %)', newest;
    RETURN;
  END IF;
  v_s := ops.open_session('local-ops', 'core', 'execution');                 -- old 3-argument positional call
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.scope = 'global' AND s.provenance = 'recorded' AND s.occurred_at = now()
                        AND s.recorded_at = now(), 'local-ops (global.local-ops) -> global, recorded');
  v_s := ops.open_session('t0014a', NULL, 'planning');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'project', 'test project -> project');
  v_s := ops.open_session(p_project_key => 't0014a', p_component_key => NULL, p_kind => 'planning', p_scope => 'global');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'global', 'explicit global wins');
  v_s := ops.open_session(p_project_key => 'local-ops', p_component_key => NULL, p_kind => 'planning', p_scope => 'project');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'project', 'explicit project wins');
  v_s := ops.open_session('t0014nonode', NULL, 'planning');
  PERFORM pg_temp.check((SELECT scope FROM ops.sessions WHERE id = v_s) = 'project', 'node-less project -> project');

  v_s := ops.open_session('t0014b', NULL, 'execution', NULL, now() - interval '2 hours', 'reconstructed');
  SELECT * INTO s FROM ops.sessions WHERE id = v_s;
  PERFORM pg_temp.check(s.provenance = 'reconstructed' AND s.occurred_at = now() - interval '2 hours'
                        AND s.recorded_at = now() AND s.status = 'active', 'reconstructed occurred_at / recorded_at');

  PERFORM pg_temp.rejects($q$SELECT ops.open_session('t0014a', NULL, 'planning', NULL, now() - interval '1 hour')$q$,
                          'occurred_at must be given exactly when provenance is reconstructed', 'occurred_at without reconstructed');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('t0014a', NULL, 'planning', NULL, NULL, 'reconstructed')$q$,
                          'occurred_at must be given exactly when provenance is reconstructed', 'reconstructed without occurred_at');
  PERFORM pg_temp.rejects($q$SELECT ops.open_session('t0014a', NULL, 'planning', NULL, now() + interval '1 minute', 'reconstructed')$q$,
                          'is in the future', 'future occurred_at');

  -- stale auto-close unchanged (0012 block 3 on this file's project)
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), 'execution', now() - make_interval(hours => v_hours + 1)) RETURNING id INTO v_old;
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (pg_temp.id('pa'), 'execution', now() - make_interval(hours => v_hours - 1)) RETURNING id INTO v_fresh;
  v_s := ops.open_session('t0014a', 'ca', 'execution');
  PERFORM pg_temp.check(pg_temp.state(v_old) = 'closed/stale/unfinished', 'stale session: ' || pg_temp.state(v_old));
  PERFORM pg_temp.check((SELECT summary = 'auto-closed: stale' AND closed_at = now() FROM ops.sessions WHERE id = v_old),
                        'stale summary and closed_at');
  PERFORM pg_temp.check(pg_temp.state(v_fresh) = 'active/-/open', 'fresh session untouched');
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'active/-/open', 'new session active/open');
  RAISE NOTICE 'ok   6 open_session scope default and override, reconstructed, refusals, stale auto-close, 3-arg call';
END $$;

-- 7. close_session: p_closed_at, inline supersedes and decision_nodes, stale refusal, old positional call
DO $$
DECLARE v_s uuid; v_n integer; e text; d ops.decisions;
BEGIN
  -- reconstructed: p_closed_at accepted inside [occurred_at, now()]
  v_s := ops.open_session(p_node_path => 'global.t0014b'::public.ltree, p_kind => 'execution',
                          p_occurred_at => now() - interval '3 hours', p_provenance => 'reconstructed');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'normal', now() - interval '4 hours')$q$, v_s),
                          'is outside occurred_at', 'closed_at before occurred_at');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'normal', now() + interval '1 minute')$q$, v_s),
                          'is outside occurred_at', 'closed_at in the future');
  PERFORM ops.close_session(v_s, 's', 'n', '[]', 'normal', now() - interval '1 hour');
  PERFORM pg_temp.check((SELECT closed_at = now() - interval '1 hour' FROM ops.sessions WHERE id = v_s)
                        AND pg_temp.state(v_s) = 'closed/normal/closed', 'reconstructed closed_at stored');

  -- recorded: p_closed_at rejected, session stays active
  v_s := ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning');
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'normal', now())$q$, v_s),
                          'closed_at may only be given for a reconstructed session', 'closed_at on recorded');
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'active/-/open', 'recorded session untouched');

  -- stale still rejected with the same message
  e := pg_temp.err(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'stale')$q$, v_s));
  PERFORM pg_temp.check(e = 'P0001 stale closure is automatic only', 'stale rejected: ' || coalesce(e, 'success'));

  -- inline decisions: supersedes kept, decision_nodes by home rule (project node: session without component)
  v_n := ops.close_session(v_s, 's', 'n', format('[{"decision": "t0014 inline", "supersedes": "%s"}, {"decision": "t0014 plain"}]',
                                                 pg_temp.id('decision_a'))::jsonb);
  PERFORM pg_temp.check(v_n = 2, 'two inline decisions');
  SELECT * INTO d FROM ops.decisions WHERE session_id = v_s AND decision = 't0014 inline';
  PERFORM pg_temp.check(d.supersedes = pg_temp.id('decision_a'), 'inline supersedes kept');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.decision_nodes dn JOIN ops.decisions x ON x.id = dn.decision_id
                          WHERE x.session_id = v_s AND dn.node_id = pg_temp.id('pa_node')) = 2,
                        'both inline decisions on the project node');
  PERFORM pg_temp.check((SELECT supersedes IS NULL FROM ops.decisions WHERE session_id = v_s AND decision = 't0014 plain'),
                        'no supersedes when not given');

  -- session with a component -> component node; old 5-argument positional call
  v_s := ops.open_session(p_node_path => 'global.t0014a.ca'::public.ltree, p_kind => 'execution');
  v_n := ops.close_session(v_s, 's', 'n', '[{"decision": "t0014 comp"}]'::jsonb, 'normal'::ops.close_reason);
  PERFORM pg_temp.check(v_n = 1 AND (SELECT dn.node_id FROM ops.decision_nodes dn JOIN ops.decisions x ON x.id = dn.decision_id
                                      WHERE x.session_id = v_s) = pg_temp.id('ca_node'), 'component session -> ca node');

  -- supersedes from another project raises; nothing written, session stays active
  v_s := ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning');
  -- 0023 makes the supersedes check node-based with a new message (M5b release 2)
  IF (SELECT max(version) FROM ops.schema_migrations) >= '0023' THEN
    RAISE NOTICE 'skip 7 close_session message ''in the project of session'' (newest migration is %)',
      (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[{"decision": "x", "supersedes": "%s"}]')$q$,
                                   v_s, pg_temp.id('decision_b')),
                            format('does not exist in global.t0014a (the scope of session %s)', v_s),
                            'inline supersedes from another project (0023 message)');
  ELSE
  PERFORM pg_temp.rejects(format($q$SELECT ops.close_session(%L, 's', 'n', '[{"decision": "x", "supersedes": "%s"}]')$q$,
                                 v_s, pg_temp.id('decision_b')),
                          'does not exist in the project of session', 'inline supersedes from another project');
  END IF;
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'active/-/open'
                        AND NOT EXISTS (SELECT 1 FROM ops.decisions WHERE session_id = v_s), 'refusal wrote nothing');
  RAISE NOTICE 'ok   7 close_session closed_at, inline supersedes and nodes, stale refusal, 5-arg call';
END $$;

-- 8. adopt_orphans
DO $$
DECLARE v_s uuid; v_other uuid; r jsonb; v_typ text := 'investigation';
        v_ca uuid := pg_temp.id('ca'); v_pa uuid := pg_temp.id('pa'); v_pb uuid := pg_temp.id('pb');
        dec_in uuid; dec_out uuid; dec_owned uuid; dec_b uuid; dis_in uuid; dis_out uuid; dis_owned uuid; dis_b uuid;
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  v_s := ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning');
  -- 0022 makes decisions.session_id and dispatches.session_id NOT NULL (M5b release 2): no null-session row is left
  -- to adopt; the adoption is pinned to the state before 0022, the range and session refusals still run
  IF newest >= '0022' THEN
    RAISE NOTICE 'skip 8 adopt_orphans adopting null-session decisions and dispatches (newest migration is %)', newest;
  ELSE
  v_other := ops.open_session(p_node_path => 'global.t0014a'::public.ltree, p_kind => 'planning');
  -- decisions: in range / out of range / owned by another session / another project
  INSERT INTO ops.decisions (project_id, decision, recorded_at) VALUES (v_pa, 't0014 in', now() - interval '30 minutes')
    RETURNING id INTO dec_in;
  INSERT INTO ops.decisions (project_id, decision, recorded_at) VALUES (v_pa, 't0014 out', now() - interval '2 hours')
    RETURNING id INTO dec_out;
  INSERT INTO ops.decisions (project_id, decision, recorded_at, session_id)
  VALUES (v_pa, 't0014 owned', now() - interval '30 minutes', v_other) RETURNING id INTO dec_owned;
  INSERT INTO ops.decisions (project_id, decision, recorded_at) VALUES (v_pb, 't0014 b', now() - interval '30 minutes')
    RETURNING id INTO dec_b;
  -- dispatches: the same four cases
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, title, prompt, created_at)
  VALUES (v_pa, v_ca, v_typ, 't0014 in', 'p', now() - interval '30 minutes') RETURNING id INTO dis_in;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, title, prompt, created_at)
  VALUES (v_pa, v_ca, v_typ, 't0014 out', 'p', now() - interval '2 hours') RETURNING id INTO dis_out;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, title, prompt, created_at, session_id)
  VALUES (v_pa, v_ca, v_typ, 't0014 owned', 'p', now() - interval '30 minutes', v_other) RETURNING id INTO dis_owned;
  INSERT INTO ops.dispatches (project_id, component_id, dispatch_type, title, prompt, created_at)
  VALUES (v_pb, pg_temp.id('cx'), v_typ, 't0014 b', 'p', now() - interval '30 minutes') RETURNING id INTO dis_b;

  -- blocks 2-4 left earlier null-session rows of t0014a at now(); the range ends before now() to exclude them
  r := ops.adopt_orphans(v_s, now() - interval '1 hour', now() - interval '1 minute');
  PERFORM pg_temp.check(r = '{"decisions": 1, "dispatches": 1}', 'counts: ' || r::text);
  PERFORM pg_temp.check((SELECT session_id FROM ops.decisions WHERE id = dec_in) = v_s
                        AND (SELECT session_id FROM ops.dispatches WHERE id = dis_in) = v_s, 'in-range orphans adopted');
  PERFORM pg_temp.check((SELECT session_id IS NULL FROM ops.decisions WHERE id = dec_out)
                        AND (SELECT session_id IS NULL FROM ops.dispatches WHERE id = dis_out), 'out-of-range rows left');
  PERFORM pg_temp.check((SELECT session_id FROM ops.decisions WHERE id = dec_owned) = v_other
                        AND (SELECT session_id FROM ops.dispatches WHERE id = dis_owned) = v_other, 'owned rows left');
  PERFORM pg_temp.check((SELECT session_id IS NULL FROM ops.decisions WHERE id = dec_b)
                        AND (SELECT session_id IS NULL FROM ops.dispatches WHERE id = dis_b), 'other project rows left');
  -- upper bound is exclusive
  r := ops.adopt_orphans(v_s, now() - interval '3 hours', now() - interval '2 hours');
  PERFORM pg_temp.check(r = '{"decisions": 0, "dispatches": 0}', 'exclusive upper bound: ' || r::text);
  r := ops.adopt_orphans(v_s, now() - interval '2 hours', now() - interval '119 minutes');
  PERFORM pg_temp.check(r = '{"decisions": 1, "dispatches": 1}', 'inclusive lower bound: ' || r::text);
  END IF;

  -- 0023 drops adopt_orphans (M5b release 2): from 0023 on the function is absent (tests/sql/0023)
  IF newest >= '0023' THEN
    RAISE NOTICE 'skip 8 adopt_orphans range and session refusals (newest migration is %)', newest;
    PERFORM pg_temp.check(to_regprocedure('ops.adopt_orphans(uuid,timestamptz,timestamptz)') IS NULL, 'adopt_orphans absent');
  ELSE
  PERFORM pg_temp.rejects(format($q$SELECT ops.adopt_orphans(%L, now(), now())$q$, v_s), 'from < to', 'from = to');
  PERFORM pg_temp.rejects(format($q$SELECT ops.adopt_orphans(%L, now(), now() - interval '1 hour')$q$, v_s),
                          'from < to', 'from > to');
  PERFORM pg_temp.rejects(format($q$SELECT ops.adopt_orphans(%L, now() - interval '1 hour', now())$q$, gen_random_uuid()),
                          'does not exist', 'unknown session');
  END IF;
  RAISE NOTICE 'ok   8 adopt_orphans';
END $$;

-- 9. catalog: SECURITY DEFINER, pinned search_path; EXECUTE for ops_planner only (new and re-created functions)
DO $$
DECLARE f text; newest text := (SELECT max(version) FROM ops.schema_migrations);
        -- 0016 re-creates update_backlog_item with a trailing p_severity; check whichever signature is current
        v_update text := CASE WHEN newest <= '0015_spine_m4b_enforcement' THEN 'ops.update_backlog_item(uuid,text,text)'
                              ELSE 'ops.update_backlog_item(uuid,text,text,ops.backlog_severity)' END;
BEGIN
  IF newest > '0015_spine_m4b_enforcement' THEN
    RAISE NOTICE 'skip 9 update_backlog_item(uuid,text,text), check % instead (newest migration is %)', v_update, newest;
  END IF;
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 9 the six project-keyed signatures (newest migration is %)', newest;
  END IF;
  FOREACH f IN ARRAY ARRAY[
      'ops.create_project(text,text,jsonb)',
      'ops.create_component(text,text,text,text,text,jsonb)',
      'ops.create_dispatch(text,text,text,text,text,text[],integer,uuid)',
      'ops.log_decision(text,text,text,text,jsonb,text,text,uuid,uuid)',
      'ops.add_backlog_item(text,ops.backlog_kind,text,text,text,uuid,ops.backlog_severity)',
      v_update,
      'ops.adopt_orphans(uuid,timestamptz,timestamptz)',
      'ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
      'ops.close_session(uuid,text,text,jsonb,ops.close_reason,timestamptz)'] LOOP
    CONTINUE WHEN newest >= '0021' AND f ~ '^ops\.(create_project|create_component|create_dispatch|log_decision|add_backlog_item|open_session)\(text';
    -- 0023 drops adopt_orphans (M5b release 2)
    IF newest >= '0023' AND f = 'ops.adopt_orphans(uuid,timestamptz,timestamptz)' THEN
      RAISE NOTICE 'skip 9 % (newest migration is %)', f, newest;
      PERFORM pg_temp.check(to_regprocedure(f) IS NULL, 'absent ' || f);
      CONTINUE;
    END IF;
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp']
                             FROM pg_proc WHERE oid = to_regprocedure(f)), 'secdef and search_path ' || f);
    PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'ops_planner executes ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f, 'EXECUTE'), 'ops_executor does not execute ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'PUBLIC does not execute ' || f);
  END LOOP;
  IF newest <= '0017_promote_dispatch_type' THEN
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname IN ('open_session', 'close_session')) = 2, 'one overload each');
  ELSIF newest >= '0021' THEN
    -- 0021 drops the project-keyed open_session; the node-keyed one remains
    RAISE NOTICE 'skip 9 open_session = 2, check open_session = 1 and close_session = 1 instead (newest migration is %)', newest;
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname = 'open_session') = 1, 'open_session: node-keyed overload only');
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname = 'close_session') = 1, 'close_session: one overload');
  ELSE
    -- 0018 adds the node-keyed open_session(public.ltree, ...); close_session keeps one overload
    RAISE NOTICE 'skip 9 one overload each, check open_session = 2 and close_session = 1 instead (newest migration is %)', newest;
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname = 'open_session') = 2, 'open_session: text and node-keyed overloads');
    PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname = 'close_session') = 1, 'close_session: one overload');
  END IF;
  RAISE NOTICE 'ok   9 security, search_path and EXECUTE grants';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches), 'dispatch_nodes', (SELECT count(*) FROM ops.dispatch_nodes),
    'decisions', (SELECT count(*) FROM ops.decisions), 'decision_nodes', (SELECT count(*) FROM ops.decision_nodes),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items),
    'context_documents', (SELECT count(*) FROM ops.context_documents),
    'dispatch_types', (SELECT count(*) FROM ops.dispatch_types)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok  10 no leftover rows; 0014 tests passed';
END $$;
