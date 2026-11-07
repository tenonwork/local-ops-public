-- tests/sql/0012_session_task_status_on_close.sql
-- Tests for migrations/0012_session_task_status_on_close.sql. Run as the schema owner against a non-production
-- database where 0012 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0012_session_task_status_on_close.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent (e066c400): the file uses only rows it creates, counts relative to the starting state and
-- asserts only on its own session ids (open_session's auto-close also reaches other stale active sessions whose
-- derived node is the opened node, since 0018; the ROLLBACK undoes that).

\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in session settings so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.sessions_before', (SELECT count(*) FROM ops.sessions)::text, false),
          set_config('ops_test.decisions_before', (SELECT count(*) FROM ops.decisions)::text, false);
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

-- status/close_reason/task_status; 0022 drops sessions.task_status (M5b release 2), so the column is read through
-- to_jsonb and, when absent, the 2eecc405 mapping stands in (every row satisfied it since 0012)
CREATE FUNCTION pg_temp.state(p_id uuid) RETURNS text LANGUAGE sql AS $$
  SELECT s.status || '/' || coalesce(s.close_reason::text, '-') || '/'
         || coalesce(to_jsonb(s)->>'task_status',
                     CASE WHEN s.status = 'active' THEN 'open' WHEN s.close_reason = 'stale' THEN 'unfinished'
                          ELSE 'closed' END)
    FROM ops.sessions s WHERE s.id = p_id;
$$;

-- 1. close_session 'normal' and 'erosion' -> task_status closed
DO $$
DECLARE v_a uuid; v_b uuid;
BEGIN
  v_a := ops.open_session(p_node_path => 'global.local-ops.core'::public.ltree, p_kind => 'execution');
  PERFORM pg_temp.check(pg_temp.state(v_a) = 'active/-/open', 'new session active/open: ' || pg_temp.state(v_a));
  PERFORM ops.close_session(v_a, 't0012 normal', 'next', '[]', 'normal');
  PERFORM pg_temp.check(pg_temp.state(v_a) = 'closed/normal/closed', 'close normal: ' || pg_temp.state(v_a));

  v_b := ops.open_session(p_node_path => 'global.local-ops'::public.ltree, p_kind => 'planning');
  PERFORM ops.close_session(v_b, 't0012 erosion', 'next', '[]', 'erosion');
  PERFORM pg_temp.check(pg_temp.state(v_b) = 'closed/erosion/closed', 'close erosion: ' || pg_temp.state(v_b));

  -- the default reason is 'normal'
  v_b := ops.open_session(p_node_path => 'global.local-ops'::public.ltree, p_kind => 'planning');
  PERFORM ops.close_session(v_b, 't0012 default', 'next', '[]');
  PERFORM pg_temp.check(pg_temp.state(v_b) = 'closed/normal/closed', 'close default reason: ' || pg_temp.state(v_b));
  RAISE NOTICE 'ok   1 close_session normal / erosion / default -> closed';
END $$;

-- 2. close_session 'stale' still raises with the same message, and leaves the session active/open
DO $$
DECLARE v_s uuid := ops.open_session(p_node_path => 'global.local-ops.core'::public.ltree, p_kind => 'execution'); e text;
BEGIN
  e := pg_temp.err(format($q$SELECT ops.close_session(%L, 's', 'n', '[]', 'stale')$q$, v_s));
  PERFORM pg_temp.check(e = 'P0001 stale closure is automatic only', 'stale rejected: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'active/-/open', 'session untouched: ' || pg_temp.state(v_s));
  -- the other validations are unchanged
  e := pg_temp.err(format($q$SELECT ops.close_session(%L, 's', 'n', NULL)$q$, v_s));
  PERFORM pg_temp.check(e = 'P0001 decisions must be an explicit JSON array (use [] if none were made)',
                        'decisions NULL rejected: ' || coalesce(e, 'success'));
  PERFORM ops.close_session(v_s, 's', 'n', '[]');
  e := pg_temp.err(format($q$SELECT ops.close_session(%L, 's', 'n', '[]')$q$, v_s));
  PERFORM pg_temp.check(e = format('P0001 session %s is not active', v_s), 'second close rejected: ' || coalesce(e, 'success'));
  RAISE NOTICE 'ok   2 stale rejected; validations unchanged';
END $$;

-- 3. stale auto-close in open_session -> closed / stale / unfinished; the new session is active / open
DO $$
DECLARE v_hours integer := coalesce(
          (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
        v_old uuid; v_fresh uuid; v_new uuid;
        v_lo uuid := (SELECT id FROM ops.projects WHERE key = 'local-ops');
        newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (v_lo, 'execution', now() - make_interval(hours => v_hours + 1)) RETURNING id INTO v_old;
  INSERT INTO ops.sessions (project_id, kind, occurred_at)
  VALUES (v_lo, 'execution', now() - make_interval(hours => v_hours - 1)) RETURNING id INTO v_fresh;
  -- 0023 deletes the local-ops project row and adds sessions.node_id (M5b release 2): from 0023 on the fixtures carry
  -- the global.local-ops node as their session node, so their derived node is still the opened node
  IF newest >= '0023' THEN
    UPDATE ops.sessions SET node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.local-ops')
     WHERE id IN (v_old, v_fresh);
  END IF;
  -- node-keyed open_session (0018) closes stale sessions whose derived node is the opened node (9c94a9fd); the two
  -- fixture sessions have no component, so the open is on the project node global.local-ops
  v_new := ops.open_session(p_node_path => 'global.local-ops'::public.ltree, p_kind => 'execution');
  PERFORM pg_temp.check(pg_temp.state(v_old) = 'closed/stale/unfinished', 'stale session: ' || pg_temp.state(v_old));
  PERFORM pg_temp.check((SELECT summary = 'auto-closed: stale' AND closed_at = now() FROM ops.sessions WHERE id = v_old),
                        'stale summary and closed_at');
  PERFORM pg_temp.check(pg_temp.state(v_fresh) = 'active/-/open', 'session inside the threshold untouched: ' || pg_temp.state(v_fresh));
  PERFORM pg_temp.check(pg_temp.state(v_new) = 'active/-/open', 'new session: ' || pg_temp.state(v_new));
  RAISE NOTICE 'ok   3 stale auto-close -> unfinished (threshold % h)', v_hours;
END $$;

-- 4. decisions via close_session are still inserted with the session link
DO $$
DECLARE v_s uuid := ops.open_session(p_node_path => 'global.local-ops.core'::public.ltree, p_kind => 'execution'); v_n integer;
        v_before bigint := (SELECT count(*) FROM ops.decisions);
BEGIN
  v_n := ops.close_session(v_s, 's', 'n',
           '[{"decision": "t0012 a", "rationale": "r"}, {"decision": "t0012 b", "scope": "x"}]');
  PERFORM pg_temp.check(v_n = 2, 'close_session returns 2, got ' || v_n);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.decisions) = v_before + 2, 'decisions grew by 2');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.decisions d JOIN ops.sessions s ON s.id = d.session_id
                          WHERE d.session_id = v_s AND d.project_id IS NOT DISTINCT FROM s.project_id
                            AND d.component_id IS NOT DISTINCT FROM s.component_id) = 2,
                        'both decisions linked to the session, project and component');
  PERFORM pg_temp.check(pg_temp.state(v_s) = 'closed/normal/closed', 'closed with decisions: ' || pg_temp.state(v_s));
  RAISE NOTICE 'ok   4 decisions linked';
END $$;

-- 5. catalog: signatures, defaults, SECURITY DEFINER, search_path, owner and ACL of both functions
--    0014 re-creates both with defaulted trailing parameters (24c61089): from 0014 on, its signatures are asserted
--    0021 drops the project-keyed open_session (M5b release 2): from 0021 on, only close_session is asserted
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 5 ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance) catalog (newest migration is %)', newest;
  END IF;
  PERFORM set_config('search_path', 'pg_catalog', true);   -- type names print schema-qualified
  SELECT string_agg(e.sig || ' ' || coalesce(to_jsonb(p)::text, 'missing'), '; ') INTO v_bad
    FROM (VALUES
      (false, 'ops.open_session(text,text,text)', 'p_project_key text, p_component_key text, p_kind text', 'uuid'),
      (false, 'ops.close_session(uuid,text,text,jsonb,ops.close_reason)',
       'p_session uuid, p_summary text, p_next_step text, p_decisions jsonb, p_reason ops.close_reason DEFAULT ''normal''::ops.close_reason',
       'integer'),
      (true, 'ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
       'p_project_key text, p_component_key text, p_kind text, p_scope ops.segment_scope DEFAULT NULL::ops.segment_scope, '
       || 'p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, '
       || 'p_provenance ops.provenance DEFAULT ''recorded''::ops.provenance', 'uuid'),
      (true, 'ops.close_session(uuid,text,text,jsonb,ops.close_reason,timestamptz)',
       'p_session uuid, p_summary text, p_next_step text, p_decisions jsonb, p_reason ops.close_reason DEFAULT ''normal''::ops.close_reason, '
       || 'p_closed_at timestamp with time zone DEFAULT NULL::timestamp with time zone',
       'integer')) e(m0014, sig, args, res)
    LEFT JOIN LATERAL (
      SELECT pg_get_function_arguments(oid) args, pg_get_function_result(oid) res, prosecdef, proconfig,
             pg_get_userbyid(proowner) owner, proacl::text acl, prokind, (SELECT lanname::text FROM pg_language l WHERE l.oid = prolang) lang
        FROM pg_proc WHERE oid = to_regprocedure(e.sig)) p ON true
   WHERE e.m0014 = (newest >= '0014')
     AND NOT (newest >= '0021' AND e.sig LIKE 'ops.open_session(%')
     AND (p IS NULL OR p.args <> e.args OR p.res <> e.res OR NOT p.prosecdef
      OR p.proconfig IS DISTINCT FROM ARRAY['search_path=ops, pg_temp'] OR p.owner <> v_owner
      OR p.acl <> format('{%1$s=X/%1$s,ops_planner=X/%1$s}', v_owner) OR p.prokind <> 'f' OR p.lang <> 'plpgsql');
  PERFORM set_config('search_path', 'ops, pg_temp', true);
  PERFORM pg_temp.check(v_bad IS NULL, 'function catalog: ' || coalesce(v_bad, ''));
  RAISE NOTICE 'ok   5 signatures (%), security, search_path, owner % and ACL',
    CASE WHEN newest >= '0014' THEN '0014' ELSE '0012' END, v_owner;
END $$;

-- 6. EXECUTE: ops_planner yes; ops_executor and PUBLIC no (0014 signatures from 0014 on, as in block 5;
--    open_session(text, ...) skipped from 0021 on)
DO $$
DECLARE f text; newest text := (SELECT max(version) FROM ops.schema_migrations);
BEGIN
  IF newest >= '0021' THEN
    RAISE NOTICE 'skip 6 ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance) EXECUTE (newest migration is %)', newest;
  END IF;
  FOREACH f IN ARRAY CASE WHEN newest >= '0014'
      THEN ARRAY['ops.open_session(text,text,text,ops.segment_scope,timestamptz,ops.provenance)',
                 'ops.close_session(uuid,text,text,jsonb,ops.close_reason,timestamptz)']
      ELSE ARRAY['ops.open_session(text,text,text)', 'ops.close_session(uuid,text,text,jsonb,ops.close_reason)'] END LOOP
    CONTINUE WHEN newest >= '0021' AND f LIKE 'ops.open_session(%';
    PERFORM pg_temp.check(has_function_privilege('ops_planner', f, 'EXECUTE'), 'ops_planner executes ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f, 'EXECUTE'), 'ops_executor does not execute ' || f);
    PERFORM pg_temp.check(NOT has_function_privilege('public', f, 'EXECUTE'), 'PUBLIC does not execute ' || f);
  END LOOP;
  RAISE NOTICE 'ok   6 execute grants';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.sessions) <> current_setting('ops_test.sessions_before')::bigint
     OR (SELECT count(*) FROM ops.decisions) <> current_setting('ops_test.decisions_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   7 no leftover rows; 0012 tests passed';
END $$;
