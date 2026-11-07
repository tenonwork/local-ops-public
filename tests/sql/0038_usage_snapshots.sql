-- tests/sql/0038_usage_snapshots.sql
-- Tests for migrations/0038_usage_snapshots.sql. Run as the schema owner against a non-production database where
-- 0038 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0038_usage_snapshots.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- now() is fixed for the whole transaction; scenarios backdate rows relative to it by direct insert.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: windows, ticks and snapshots are isolated as tests/sql/0006 does (deleted inside the rolled-back
-- transaction before each scenario); dispatch_usage is checked on the file's own project t0038a, component ca, session
-- and dispatches. Grants are checked at catalog level (b28e2660): ops_dev is not a member of ops_planner.

\encoding UTF8
\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in a session setting so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.counts_before', (SELECT jsonb_build_object(
    'windows', (SELECT count(*) FROM ops.windows), 'ticks', (SELECT count(*) FROM ops.ticks),
    'tick_daily', (SELECT count(*) FROM ops.tick_daily), 'usage_snapshots', (SELECT count(*) FROM ops.usage_snapshots),
    'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
    'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
    'dispatches', (SELECT count(*) FROM ops.dispatches)))::text, false);
END $$;

BEGIN;

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

CREATE FUNCTION pg_temp.reset() RETURNS void LANGUAGE sql AS $$
  UPDATE ops.sessions SET window_id = NULL WHERE window_id IS NOT NULL;  -- 0010 links sessions to windows
  DELETE FROM ops.usage_snapshots; DELETE FROM ops.ticks; DELETE FROM ops.windows; DELETE FROM ops.tick_daily;
$$;

CREATE FUNCTION pg_temp.win(p_start interval, p_end interval, p_source ops.window_start_source DEFAULT 'inferred',
                            p_event text DEFAULT NULL) RETURNS ops.windows LANGUAGE sql AS $$
  INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser, calendar_event_id)
  VALUES (now() + p_start, now() + p_end, p_source, now() + p_start, 'code', p_event)
  RETURNING *;
$$;

-- a status-line reading from client 't0038'
CREATE FUNCTION pg_temp.rec(p_5h numeric, p_5h_reset timestamptz, p_7d numeric DEFAULT 20,
                            p_7d_reset timestamptz DEFAULT now() + interval '5 days') RETURNS jsonb LANGUAGE sql AS $$
  SELECT ops.record_usage('t0038', 'sess-0038', p_5h, p_5h_reset, p_7d, p_7d_reset);
$$;

CREATE FUNCTION pg_temp.snap(p_id bigint) RETURNS ops.usage_snapshots LANGUAGE sql AS $$
  SELECT * FROM ops.usage_snapshots WHERE id = p_id;
$$;

-- a snapshot written as the owner, captured at now() + p_at
CREATE FUNCTION pg_temp.snap_at(p_at interval, p_5h numeric, p_5h_reset timestamptz, p_7d numeric DEFAULT NULL,
                                p_7d_reset timestamptz DEFAULT NULL, p_window uuid DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO ops.usage_snapshots (captured_at, client, five_hour_pct, five_hour_resets_at, seven_day_pct,
                                   seven_day_resets_at, window_id)
  VALUES (now() + p_at, 't0038', p_5h, p_5h_reset, p_7d, p_7d_reset, p_window)
  RETURNING id;
$$;

-- a. catalog 0038 establishes (bounded: asserted while 0038 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text;
        v_rec regprocedure := 'ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz)'::regprocedure;
        v_now regprocedure := 'ops.usage_now()'::regprocedure;
BEGIN
  IF NOT (newest >= '0038' AND newest < '0039') THEN
    RAISE NOTICE 'skip a catalog of 0038 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);

  PERFORM pg_temp.check((SELECT format_type(atttypid, atttypmod) = 'timestamp with time zone' AND NOT attnotnull
                           FROM pg_attribute WHERE attrelid = 'ops.windows'::regclass AND attname = 'calendar_resets_at'
                            AND NOT attisdropped), 'a windows.calendar_resets_at nullable timestamptz');
  PERFORM pg_temp.check(col_description('ops.windows'::regclass,
                          (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.windows'::regclass AND attname = 'calendar_resets_at'))
                        LIKE 'Usage reader (b9cbaad8): %', 'a calendar_resets_at comment');

  PERFORM pg_temp.check((SELECT string_agg(attname || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
                           FROM pg_attribute WHERE attrelid = 'ops.usage_snapshots'::regclass AND attnum > 0 AND NOT attisdropped)
                        = 'id bigint, captured_at timestamp with time zone, client text, session_ref text, five_hour_pct numeric(5,2), five_hour_resets_at timestamp with time zone, seven_day_pct numeric(5,2), seven_day_resets_at timestamp with time zone, window_id uuid, tick_state text, tick_detail jsonb',
                        'a usage_snapshots columns');
  PERFORM pg_temp.check((SELECT array_agg(conname::text ORDER BY conname) FROM pg_constraint
                          WHERE conrelid = 'ops.usage_snapshots'::regclass AND contype <> 'n')
                        = ARRAY['usage_snapshots_five_hour_pair_check', 'usage_snapshots_five_hour_pct_check', 'usage_snapshots_pkey',
                                'usage_snapshots_present_check', 'usage_snapshots_seven_day_pair_check',
                                'usage_snapshots_seven_day_pct_check', 'usage_snapshots_window_id_fkey'],
                        'a usage_snapshots constraints');
  PERFORM pg_temp.check(to_regclass('ops.usage_snapshots_captured_at_idx') IS NOT NULL, 'a captured_at index');

  PERFORM pg_temp.check((SELECT string_agg(attname || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
                           FROM pg_attribute WHERE attrelid = 'ops.dispatch_usage'::regclass AND attnum > 0 AND NOT attisdropped)
                        = 'id uuid, dispatch_type text, claimed_at timestamp with time zone, completed_at timestamp with time zone, start_snapshot_id bigint, start_captured_at timestamp with time zone, start_five_hour_pct numeric(5,2), end_snapshot_id bigint, end_captured_at timestamp with time zone, end_five_hour_pct numeric(5,2), five_hour_delta numeric, delta_note text',
                        'a dispatch_usage columns');

  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = 'p_client text, p_session_ref text, p_five_hour_pct numeric, p_five_hour_resets_at timestamp with time zone, p_seven_day_pct numeric, p_seven_day_resets_at timestamp with time zone'
                                AND pg_get_function_result(oid) = 'jsonb' AND provolatile = 'v'
                           FROM pg_proc WHERE oid = v_rec), 'a record_usage signature');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) = ''
                                AND pg_get_function_result(oid) = 'TABLE(captured_at timestamp with time zone, age_s integer, client text, five_hour_pct numeric, five_hour_resets_at timestamp with time zone, seven_day_pct numeric, seven_day_resets_at timestamp with time zone, window_number integer)'
                                AND provolatile = 's'
                           FROM pg_proc WHERE oid = v_now), 'a usage_now signature');
  PERFORM pg_temp.check((SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname IN ('record_usage', 'usage_now', 'tick', 'window_link_event')) = 4, 'a one overload each');
  PERFORM pg_temp.check((SELECT bool_and(prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner)
                           FROM pg_proc WHERE pronamespace = 'ops'::regnamespace
                            AND proname IN ('record_usage', 'usage_now', 'tick', 'window_link_event')),
                        'a SECURITY DEFINER, search_path, owner');
  PERFORM pg_temp.check((SELECT bool_and(obj_description(oid, 'pg_proc') LIKE 'Usage reader (b9cbaad8): %') FROM pg_proc
                          WHERE oid IN (v_rec, v_now)), 'a function comments');
  PERFORM pg_temp.check((SELECT bool_and(pg_get_userbyid(relowner) = v_owner AND obj_description(oid, 'pg_class') LIKE 'Usage reader (b9cbaad8): %')
                           FROM pg_class WHERE oid IN ('ops.usage_snapshots'::regclass, 'ops.dispatch_usage'::regclass)),
                        'a table and view owner and comments');
  PERFORM pg_temp.check(obj_description('ops.dispatch_usage'::regclass, 'pg_class') LIKE '%all account activity in the interval (chat and other sessions)%',
                        'a dispatch_usage comment names the account-wide delta');
  RAISE NOTICE 'ok   a catalog: column, table, view, signatures, definer, owner, comments';
END $$;

-- b. grants (always asserted)
DO $$
DECLARE f_rec text := 'ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz)';
        f_now text := 'ops.usage_now()';
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_executor', f_rec, 'EXECUTE'), 'b executor EXECUTE on record_usage');
  PERFORM pg_temp.check(NOT has_function_privilege('ops_planner', f_rec, 'EXECUTE'), 'b planner no EXECUTE on record_usage');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f_rec, 'EXECUTE'), 'b PUBLIC no EXECUTE on record_usage');
  PERFORM pg_temp.check(has_function_privilege('ops_executor', f_now, 'EXECUTE')
                        AND has_function_privilege('ops_planner', f_now, 'EXECUTE'), 'b planner and executor EXECUTE on usage_now');
  PERFORM pg_temp.check(NOT has_function_privilege('public', f_now, 'EXECUTE'), 'b PUBLIC no EXECUTE on usage_now');
  PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.dispatch_usage', 'SELECT'), 'b planner SELECT on dispatch_usage');
  PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', 'ops.dispatch_usage', 'SELECT'), 'b executor no SELECT on dispatch_usage');
  PERFORM pg_temp.check(NOT has_table_privilege('public', 'ops.dispatch_usage', 'SELECT'), 'b PUBLIC no SELECT on dispatch_usage');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_class c, aclexplode(c.relacl) a
                                     WHERE c.oid = 'ops.usage_snapshots'::regclass AND a.grantee <> c.relowner),
                        'b usage_snapshots has no grants');
  PERFORM pg_temp.check(NOT has_table_privilege(r, 'ops.usage_snapshots', p), format('b %s has no %s on usage_snapshots', r, p))
     FROM unnest(ARRAY['ops_planner', 'ops_executor', 'public']) r, unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) p;
  PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', 'ops.window_link_event(integer, text)', 'EXECUTE'),
                        'b executor still cannot link');
  PERFORM pg_temp.check((SELECT array_agg(c.relname::text ORDER BY c.relname) FROM pg_class c
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                            AND has_table_privilege('ops_executor', c.oid, 'SELECT'))
                        = ARRAY['components', 'context_documents', 'dispatch_types', 'doc_types', 'entry_types', 'node_paths',
                                'nodes', 'projects', 'protocol_rules', 'window_state'], 'b ops_executor SELECT set unchanged');
  -- 0039 grants ops_executor EXECUTE on autorun_state (autorun gate): from 0039 on it joins the set
  IF (SELECT max(version) FROM ops.schema_migrations) < '0039' THEN
  PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                          WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                        = ARRAY['claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending', 'get_work_log', 'log_work',
                                'record_gate', 'record_usage', 'resolve_context', 'tick', 'usage_now'],
                        'b ops_executor EXECUTE set gains record_usage and usage_now');
  ELSE
    RAISE NOTICE 'skip b executor EXECUTE set pre-0039 (newest migration is %)', (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT proname::text ORDER BY proname::text) FROM pg_proc
                            WHERE pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', oid, 'EXECUTE'))
                          = ARRAY['autorun_state', 'claim_dispatch', 'complete_dispatch', 'fail_dispatch', 'get_pending',
                                  'get_work_log', 'log_work', 'record_gate', 'record_usage', 'resolve_context', 'tick',
                                  'usage_now'],
                          'b ops_executor EXECUTE set (0039)');
  END IF;
  RAISE NOTICE 'ok   b grants: record_usage executor only; usage_now planner and executor; dispatch_usage planner; usage_snapshots none';
END $$;

-- c. record_usage
DO $$
DECLARE r jsonb; w ops.windows; s ops.usage_snapshots; v_ticks bigint; v_snaps bigint; v_reset timestamptz := now() + interval '3 hours';
BEGIN
  PERFORM pg_temp.reset();
  -- refusals: 23514, nothing written
  PERFORM pg_temp.check(pg_temp.err(format('SELECT ops.record_usage(%s, NULL, 10, now() + interval ''1 hour'', NULL, NULL)', q))
                        = '23514 p_client is required', 'c client required: ' || q)
     FROM unnest(ARRAY['NULL', '''''', '''  ''']) q;
  PERFORM pg_temp.check(pg_temp.err(format('SELECT ops.record_usage(''t'', NULL, %s, %s, %s, %s)', a, b, c, d)) = m,
                        format('c refusal (%s, %s, %s, %s)', a, b, c, d))
     FROM (VALUES ('101', 'now() + interval ''1 hour''', 'NULL', 'NULL', '23514 used percentages must be between 0 and 100'),
                  ('-0.01', 'now() + interval ''1 hour''', 'NULL', 'NULL', '23514 used percentages must be between 0 and 100'),
                  ('10', 'now() + interval ''1 hour''', '100.5', 'now() + interval ''1 day''', '23514 used percentages must be between 0 and 100'),
                  ('10', 'NULL', 'NULL', 'NULL', '23514 each used percentage needs its resets_at, and each resets_at its used percentage'),
                  ('NULL', 'now() + interval ''1 hour''', 'NULL', 'NULL', '23514 each used percentage needs its resets_at, and each resets_at its used percentage'),
                  ('NULL', 'NULL', '10', 'NULL', '23514 each used percentage needs its resets_at, and each resets_at its used percentage'),
                  ('NULL', 'NULL', 'NULL', 'now() + interval ''1 day''', '23514 each used percentage needs its resets_at, and each resets_at its used percentage'),
                  ('NULL', 'NULL', 'NULL', 'NULL', '23514 a reading needs the five-hour or the seven-day window')) t(a, b, c, d, m);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_snapshots) = 0 AND (SELECT count(*) FROM ops.ticks) = 0
                        AND (SELECT count(*) FROM ops.windows) = 0, 'c refusals write nothing');

  -- first reading: recorded, opens an observed window (no window live)
  r := pg_temp.rec(10, v_reset);
  s := pg_temp.snap((r->>'id')::bigint);
  SELECT * INTO w FROM ops.windows;
  PERFORM pg_temp.check((r->>'recorded')::boolean AND r->'tick'->>'state' = 'new' AND r->'tick'->>'directive' IS NULL
                        AND r->'tick'->>'line' LIKE 'new W% · from % (observed)%', 'c first reading: ' || r::text);
  PERFORM pg_temp.check(w.start_source = 'observed' AND w.resets_at = v_reset AND w.started_at = v_reset - interval '5 hours'
                        AND w.initialiser = 'code' AND w.first_contact_at = now(), 'c observed window opened');
  PERFORM pg_temp.check(s.client = 't0038' AND s.session_ref = 'sess-0038' AND s.five_hour_pct = 10
                        AND s.five_hour_resets_at = v_reset AND s.seven_day_pct = 20 AND s.captured_at = now()
                        AND s.window_id = w.id AND s.tick_state = 'new' AND s.tick_detail IS NULL, 'c row fields: ' || to_jsonb(s)::text);
  PERFORM pg_temp.check((SELECT source = 'code' AND client = 't0038' AND window_id = w.id FROM ops.ticks), 'c tick logged as code');

  -- identical reading: not recorded, no tick
  v_ticks := (SELECT count(*) FROM ops.ticks);
  r := pg_temp.rec(10.00, v_reset);
  PERFORM pg_temp.check(r = '{"recorded": false}'::jsonb, 'c identical not recorded: ' || r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_snapshots) = 1 AND (SELECT count(*) FROM ops.ticks) = v_ticks,
                        'c identical adds no snapshot and no tick');

  -- changed percentage: recorded, ticks the live window
  r := pg_temp.rec(11.5, v_reset);
  PERFORM pg_temp.check((r->>'recorded')::boolean AND r->'tick'->>'state' = 'ok', 'c changed pct: ' || r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_snapshots) = 2 AND (SELECT count(*) FROM ops.ticks) = v_ticks + 1,
                        'c changed pct adds a snapshot and a tick');
  PERFORM pg_temp.check((pg_temp.snap((r->>'id')::bigint)).window_id = w.id, 'c changed pct row names the window');

  -- reset in the past: recorded, no tick
  v_ticks := (SELECT count(*) FROM ops.ticks);
  r := pg_temp.rec(12, now() - interval '1 minute');
  s := pg_temp.snap((r->>'id')::bigint);
  PERFORM pg_temp.check((r->>'recorded')::boolean AND r->'tick' = 'null'::jsonb, 'c past reset recorded without tick: ' || r::text);
  PERFORM pg_temp.check(s.window_id IS NULL AND s.tick_state IS NULL AND s.tick_detail IS NULL, 'c past reset row has no tick fields');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.ticks) = v_ticks, 'c past reset adds no tick');

  -- seven-day reading only: recorded, no tick
  r := ops.record_usage('t0038', NULL, NULL, NULL, 30, now() + interval '4 days');
  PERFORM pg_temp.check((r->>'recorded')::boolean AND r->'tick' = 'null'::jsonb
                        AND (SELECT count(*) FROM ops.ticks) = v_ticks, 'c seven-day only, no tick: ' || r::text);

  -- a correction refused by tick keeps its CONFLICT on the row
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours');             -- first contact now - 1h
  r := pg_temp.rec(40, now() + interval '4 hours 30 minutes');          -- would start after first contact
  s := pg_temp.snap((r->>'id')::bigint);
  PERFORM pg_temp.check((r->>'recorded')::boolean AND r->'tick'->>'directive' = 'CONFLICT'
                        AND r->'tick'->>'line' LIKE '% · CONFLICT', 'c refused correction: ' || r::text);
  -- no tick yet: the gap runs from first contact (1 hour), so the state is resume
  PERFORM pg_temp.check(s.window_id = w.id AND s.tick_state = 'resume' AND s.tick_detail->>'reason' = 'first_contact'
                        AND s.tick_detail->>'source' = 'observed', 'c row keeps the CONFLICT detail: ' || to_jsonb(s)::text);
  PERFORM pg_temp.check((SELECT resets_at FROM ops.windows WHERE id = w.id) = now() + interval '4 hours',
                        'c refused correction leaves the window');
  RAISE NOTICE 'ok   c record_usage: refusals, first reading, identical, changed, past reset, seven-day only, CONFLICT kept';
END $$;

-- d. persistent fix_cal
DO $$
DECLARE w ops.windows; r jsonb; l ops.windows;
BEGIN
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours');
  l := ops.window_link_event(w.number, 'ev-0038');
  PERFORM pg_temp.check(l.calendar_resets_at = now() + interval '4 hours', 'd link records the event reset');

  r := pg_temp.rec(30, now() + interval '3 hours 45 minutes');
  PERFORM pg_temp.check(r->'tick'->>'state' = 'fix_cal', 'd correcting code tick is fix_cal: ' || r::text);
  PERFORM pg_temp.check((SELECT calendar_resets_at = now() + interval '4 hours' AND resets_at = now() + interval '3 hours 45 minutes'
                           FROM ops.windows WHERE id = w.id), 'd event reset kept after the correction');

  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'fix_cal' AND r->>'directive' IS NULL
                        AND r->>'line' = format('fix_cal %s · resets %s (observed) · 3h45 left', ops._wlabel(w.number),
                                                ops._fmt_time(now() + interval '3 hours 45 minutes')), 'd chat tick fix_cal: ' || r::text);
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'fix_cal', 'd chat tick fix_cal again: ' || r::text);
  r := ops.tick('code', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok', 'd code tick not fix_cal: ' || r::text);

  l := ops.window_link_event(w.number, 'ev-0038');
  PERFORM pg_temp.check(l.calendar_resets_at = l.resets_at, 'd relink acknowledges the moved event');
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok', 'd chat tick ok after relink: ' || r::text);

  -- resume is not overridden
  PERFORM pg_temp.rec(31, now() + interval '3 hours 40 minutes');
  DELETE FROM ops.ticks WHERE window_id = w.id;                          -- gap from first contact: 1 hour
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'resume', 'd resume not overridden: ' || r::text);
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'fix_cal', 'd fix_cal again after the resume: ' || r::text);

  -- an unlinked window is never fix_cal
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours');
  r := pg_temp.rec(30, now() + interval '3 hours 45 minutes');
  PERFORM pg_temp.check(r->'tick'->>'state' = 'ok', 'd unlinked correction ok: ' || r::text);
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok' AND r->>'directive' = 'CAL_CREATE', 'd unlinked chat ok: ' || r::text);
  PERFORM pg_temp.check((SELECT calendar_resets_at IS NULL FROM ops.windows WHERE id = w.id), 'd unlinked has no event reset');

  -- a linked window with no recorded event reset (direct insert) is not fix_cal ...
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours', 'inferred', 'ev-direct');
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(w.calendar_resets_at IS NULL AND r->>'state' = 'resume', 'd linked, NULL event reset, resume: ' || r::text);
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok', 'd linked, NULL event reset, ok again: ' || r::text);
  -- ... until a correction records the old reset as the event's
  r := pg_temp.rec(30, now() + interval '3 hours 45 minutes');
  PERFORM pg_temp.check(r->'tick'->>'state' = 'fix_cal'
                        AND (SELECT calendar_resets_at FROM ops.windows WHERE id = w.id) = now() + interval '4 hours',
                        'd correction records the old reset: ' || r::text);
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'fix_cal', 'd then chat fix_cal: ' || r::text);
  RAISE NOTICE 'ok   d persistent fix_cal: chat until relink, code never, resume kept, unlinked and unset never';
END $$;

-- e. readers: usage_now and dispatch_usage
DO $$
DECLARE w ops.windows; u record; v_s2 bigint; v_r1 timestamptz := now() - interval '1 hour';
        v_r2 timestamptz := now() + interval '4 hours'; v_d1 uuid; v_d2 uuid; v_d3 uuid; v_d4 uuid; x record;
BEGIN
  PERFORM pg_temp.reset();
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_now()) = 0, 'e usage_now with no snapshot: zero rows');
  w := pg_temp.win(interval '-1 hour', interval '4 hours');
  PERFORM pg_temp.snap_at(interval '-3 hours', 50, now() - interval '1 minute');                     -- expired
  PERFORM pg_temp.snap_at(interval '-1 hour', 20, now() + interval '2 hours');
  v_s2 := pg_temp.snap_at(interval '-10 minutes', 40, now() + interval '2 hours', 25, now() + interval '3 days', w.id);
  PERFORM pg_temp.snap_at(interval '-5 minutes', NULL, NULL, 26, now() + interval '3 days');           -- seven-day only
  SELECT * INTO u FROM ops.usage_now();
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_now()) = 1, 'e usage_now one row');
  PERFORM pg_temp.check(u.captured_at = now() - interval '10 minutes' AND u.age_s = 600 AND u.client = 't0038'
                        AND u.five_hour_pct = 40 AND u.five_hour_resets_at = now() + interval '2 hours' AND u.seven_day_pct = 25
                        AND u.seven_day_resets_at = now() + interval '3 days' AND u.window_number = w.number,
                        'e usage_now newest unexpired: ' || row_to_json(u)::text);
  DELETE FROM ops.usage_snapshots WHERE five_hour_resets_at > now();
  PERFORM pg_temp.check((SELECT count(*) FROM ops.usage_now()) = 0, 'e usage_now with only expired or seven-day rows: zero rows');

  -- dispatch_usage on the file's own dispatches
  PERFORM ops.create_project('global'::public.ltree, 't0038a', 'T0038 A');
  PERFORM ops.create_component('global.t0038a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0038a'::public.ltree, p_kind => 'planning')::text, true);
  SELECT (ops.create_dispatch(p_node_path => 'global.t0038a.ca'::public.ltree, p_dispatch_type => 'investigation',
                              p_title => 't0038 ' || n, p_prompt => 'p', p_session => current_setting('ops_test.s')::uuid)).id
    INTO v_d1 FROM (VALUES ('d1')) t(n);
  SELECT (ops.create_dispatch(p_node_path => 'global.t0038a.ca'::public.ltree, p_dispatch_type => 'investigation',
                              p_title => 't0038 d2', p_prompt => 'p', p_session => current_setting('ops_test.s')::uuid)).id INTO v_d2;
  SELECT (ops.create_dispatch(p_node_path => 'global.t0038a.ca'::public.ltree, p_dispatch_type => 'investigation',
                              p_title => 't0038 d3', p_prompt => 'p', p_session => current_setting('ops_test.s')::uuid)).id INTO v_d3;
  SELECT (ops.create_dispatch(p_node_path => 'global.t0038a.ca'::public.ltree, p_dispatch_type => 'investigation',
                              p_title => 't0038 d4', p_prompt => 'p', p_session => current_setting('ops_test.s')::uuid)).id INTO v_d4;
  UPDATE ops.dispatches SET claimed_at = now() - interval '3 hours', completed_at = now() - interval '2 hours' WHERE id = v_d1;
  UPDATE ops.dispatches SET claimed_at = now() - interval '90 minutes', completed_at = now() - interval '30 minutes' WHERE id = v_d2;
  UPDATE ops.dispatches SET claimed_at = now() - interval '10 hours', completed_at = now() - interval '9 hours' WHERE id = v_d3;
  UPDATE ops.dispatches SET claimed_at = now() - interval '20 minutes' WHERE id = v_d4;              -- not finished

  DELETE FROM ops.usage_snapshots;
  PERFORM pg_temp.snap_at(interval '-3 hours -10 minutes', 10, v_r1);                                  -- d1 start
  PERFORM pg_temp.snap_at(interval '-2 hours -5 minutes', 18, v_r1);
  PERFORM pg_temp.snap_at(interval '-1 hour -57 minutes', 25, v_r1);                                    -- d1 end (+3m), d2 start
  PERFORM pg_temp.snap_at(interval '-1 hour -35 minutes', NULL, NULL, 26, now() + interval '3 days');   -- seven-day only, ignored
  PERFORM pg_temp.snap_at(interval '-40 minutes', 5, v_r2);                                             -- d2 end, new window

  SELECT * INTO x FROM ops.dispatch_usage WHERE id = v_d1;
  PERFORM pg_temp.check(x.dispatch_type = 'investigation' AND x.start_five_hour_pct = 10 AND x.end_five_hour_pct = 25
                        AND x.start_captured_at = now() - interval '3 hours 10 minutes'
                        AND x.end_captured_at = now() - interval '1 hour 57 minutes'
                        AND x.five_hour_delta = 15 AND x.delta_note IS NULL, 'e same-window delta: ' || row_to_json(x)::text);
  SELECT * INTO x FROM ops.dispatch_usage WHERE id = v_d2;
  PERFORM pg_temp.check(x.start_five_hour_pct = 25 AND x.end_five_hour_pct = 5 AND x.five_hour_delta IS NULL
                        AND x.delta_note = 'window_crossed', 'e crossed window: ' || row_to_json(x)::text);
  SELECT * INTO x FROM ops.dispatch_usage WHERE id = v_d3;
  PERFORM pg_temp.check(x.start_snapshot_id IS NULL AND x.end_snapshot_id IS NULL AND x.five_hour_delta IS NULL
                        AND x.delta_note = 'no_snapshot', 'e no snapshot: ' || row_to_json(x)::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.dispatch_usage WHERE id = v_d4), 'e unfinished dispatch not listed');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.dispatch_usage)
                        = (SELECT count(*) FROM ops.dispatches WHERE claimed_at IS NOT NULL AND completed_at IS NOT NULL),
                        'e one row per finished dispatch');
  RAISE NOTICE 'ok   e usage_now newest unexpired / none; dispatch_usage same window, crossed, no snapshot';
END $$;

ROLLBACK;

-- f. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
        'windows', (SELECT count(*) FROM ops.windows), 'ticks', (SELECT count(*) FROM ops.ticks),
        'tick_daily', (SELECT count(*) FROM ops.tick_daily), 'usage_snapshots', (SELECT count(*) FROM ops.usage_snapshots),
        'projects', (SELECT count(*) FROM ops.projects), 'components', (SELECT count(*) FROM ops.components),
        'nodes', (SELECT count(*) FROM ops.nodes), 'sessions', (SELECT count(*) FROM ops.sessions),
        'dispatches', (SELECT count(*) FROM ops.dispatches)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   f no leftover rows; 0038 tests passed';
END $$;
