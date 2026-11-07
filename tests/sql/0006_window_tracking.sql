-- tests/sql/0006_window_tracking.sql
-- Tests for migrations/0006_window_tracking.sql. Run as the schema owner against a non-production
-- database where 0006 is applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0006_window_tracking.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- now() is fixed for the whole transaction; scenarios backdate rows relative to it by direct insert.
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
--
-- Advisory lock (read from the code, not tested for concurrency): tick() starts with
-- pg_advisory_xact_lock(hashtext('ops.tick')), so concurrent ticks serialise on one fixed key until
-- the calling transaction ends. The last block below only checks that the lock is taken.

\encoding UTF8
\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in session settings so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.windows_before', (SELECT count(*) FROM ops.windows)::text, false),
          set_config('ops_test.ticks_before', (SELECT count(*) FROM ops.ticks)::text, false);
END $$;

BEGIN;

CREATE FUNCTION pg_temp.reset() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF to_regclass('ops.usage_snapshots') IS NOT NULL THEN EXECUTE 'DELETE FROM ops.usage_snapshots'; END IF;  -- 0038 snapshots reference windows
  UPDATE ops.sessions SET window_id = NULL WHERE window_id IS NOT NULL;  -- 0010 links sessions to windows
  DELETE FROM ops.ticks; DELETE FROM ops.windows; DELETE FROM ops.tick_daily;
END $$;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

CREATE FUNCTION pg_temp.win(p_start interval, p_end interval, p_source ops.window_start_source DEFAULT 'inferred',
                            p_event text DEFAULT NULL) RETURNS ops.windows LANGUAGE sql AS $$
  INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser, calendar_event_id)
  VALUES (now() + p_start, now() + p_end, p_source, now() + p_start, 'code', p_event)
  RETURNING *;
$$;

-- 1. ok vs resume around the 30-minute boundary
DO $$
DECLARE w ops.windows; r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours');
  INSERT INTO ops.ticks (at, window_id, source, state) VALUES (now() - interval '29 min 59 sec', w.id, 'code', 'ok');
  r := ops.tick('code', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok', '29m59s gap is ok: ' || r::text);
  PERFORM pg_temp.check(r->>'directive' IS NULL, 'code tick has no directive: ' || r::text);
  PERFORM pg_temp.check(r->>'line' = format('ok %s · 4h00 left', ops._wlabel(w.number)), 'ok line: ' || r::text);

  DELETE FROM ops.ticks;
  INSERT INTO ops.ticks (at, window_id, source, state) VALUES (now() - interval '30 min', w.id, 'code', 'ok');
  r := ops.tick('code', 'test');
  PERFORM pg_temp.check(r->>'state' = 'resume' AND (r->>'gap')::int = 30, '30m gap resumes: ' || r::text);
  PERFORM pg_temp.check(r->>'line' = format('resume %s · idle 30m · 4h00 left', ops._wlabel(w.number)),
                        'resume line: ' || r::text);
  RAISE NOTICE 'ok   1 ok vs resume at 30 minutes';
END $$;

-- 2. lazy expiry: a window started 5h01m ago is not live
DO $$
DECLARE w ops.windows; r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-5 hours -1 minute', interval '-1 minute');
  PERFORM pg_temp.check(NOT (SELECT live FROM ops.window_state WHERE id = w.id), 'window_state.live is false');
  r := ops.tick('code', 'test');
  PERFORM pg_temp.check(r->>'state' = 'new' AND (r->'window'->>'number')::int <> w.number,
                        'expired window replaced by a new one: ' || r::text);
  PERFORM pg_temp.check(r->>'line' LIKE '% · prev ' || ops._wlabel(w.number) || ' last active %', 'new line names prev: ' || r::text);
  RAISE NOTICE 'ok   2 lazy expiry';
END $$;

-- 3. need_cal, then a call with no events opens an inferred window with CAL_CREATE
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'need_cal' AND r->'window' = 'null'::jsonb, 'need_cal without a window: ' || r::text);
  PERFORM pg_temp.check(r->>'directive' = 'LIST_CAL', 'LIST_CAL directive: ' || r::text);
  PERFORM pg_temp.check(r->>'line' = 'need_cal · no activity recorded', 'need_cal line: ' || r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.windows) = 0, 'need_cal opens no window');
  PERFORM pg_temp.check((SELECT count(*) FROM ops.ticks WHERE window_id IS NULL AND state = 'need_cal') = 1,
                        'need_cal tick logged with null window_id');

  r := ops.tick('chat', 'test', p_calendar => '[]');
  PERFORM pg_temp.check(r->>'state' = 'new' AND r->'window'->>'start_source' = 'inferred', 'inferred window: ' || r::text);
  PERFORM pg_temp.check((r->'window'->>'started_at')::timestamptz = now(), 'inferred window starts now');
  PERFORM pg_temp.check(r->>'directive' = 'CAL_CREATE', 'CAL_CREATE directive: ' || r::text);
  PERFORM pg_temp.check((SELECT initialiser FROM ops.windows) = 'chat', 'initialiser chat');

  RAISE NOTICE 'ok   3 need_cal then inferred + CAL_CREATE';
END $$;

DO $$
DECLARE w ops.windows; r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-11 hours', interval '-6 hours');
  INSERT INTO ops.ticks (at, window_id, source, state) VALUES (now() - interval '6 hours 12 minutes', w.id, 'chat', 'ok');
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'line' = 'need_cal · last activity 6h12 ago', 'need_cal last activity line: ' || r::text);
  PERFORM pg_temp.check((r->'detail'->>'last_activity')::timestamptz = now() - interval '6 hours 12 minutes',
                        'LIST_CAL detail carries last activity: ' || r::text);
  RAISE NOTICE 'ok   3b need_cal reports last activity';
END $$;

-- 4. a second call adopts an in-progress event
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'need_cal', 'first call needs the calendar');
  r := ops.tick('chat', 'test', p_calendar => jsonb_build_array(
         jsonb_build_object('id', 'ev-live', 'start', now() - interval '2 hours', 'end', now() + interval '3 hours',
                            'title', 'Claude window', 'description', '')));
  PERFORM pg_temp.check(r->>'state' = 'new' AND r->'window'->>'calendar_event_id' = 'ev-live', 'event adopted: ' || r::text);
  PERFORM pg_temp.check(r->'window'->>'start_source' = 'stated', 'untagged event adopted as stated: ' || r::text);
  PERFORM pg_temp.check((r->'window'->>'started_at')::timestamptz = now() - interval '2 hours', 'adopted start');
  PERFORM pg_temp.check(r->>'directive' IS NULL, 'linked window needs no CAL_CREATE: ' || r::text);
  PERFORM pg_temp.check((SELECT initialiser FROM ops.windows) = 'calendar', 'adopted initialiser calendar');

  PERFORM pg_temp.reset();
  r := ops.tick('chat', 'test', p_calendar => jsonb_build_array(
         jsonb_build_object('id', 'ev-live-d', 'start', now() - interval '1 hour', 'end', now() + interval '4 hours',
                            'title', '[degraded] window')));
  PERFORM pg_temp.check(r->'window'->>'start_source' = 'degraded', 'tagged event adopted as degraded: ' || r::text);
  RAISE NOTICE 'ok   4 adopt in-progress event';
END $$;

-- 5. degraded import: imported, re-import skipped, overlap is a conflict that does not abort the call
DO $$
DECLARE r jsonb; cal jsonb;
BEGIN
  PERFORM pg_temp.reset();
  cal := jsonb_build_array(
    jsonb_build_object('id', 'ev-d1', 'start', now() - interval '12 hours', 'end', now() - interval '7 hours',
                       'title', 'Claude [degraded]'),
    jsonb_build_object('id', 'ev-d2', 'start', now() - interval '10 hours', 'end', now() - interval '6 hours',
                       'title', '[Degraded] overlap'),
    jsonb_build_object('id', 'ev-plain', 'start', now() - interval '20 hours', 'end', now() - interval '15 hours',
                       'title', 'Claude'),
    jsonb_build_object('id', 'ev-bad', 'start', 'not a time', 'end', now(), 'title', '[degraded]'));
  r := ops.tick('chat', 'test', p_calendar => cal);
  PERFORM pg_temp.check(jsonb_array_length(r->'imported') = 1 AND r->'imported'->0->>'event_id' = 'ev-d1', 'ev-d1 imported: ' || r::text);
  PERFORM pg_temp.check(r->'conflicts' @> '[{"event_id": "ev-d2"}]' AND r->'conflicts' @> '[{"event_id": "ev-bad"}]',
                        'ev-d2 and ev-bad are conflicts: ' || r::text);
  PERFORM pg_temp.check((SELECT start_source = 'degraded' AND initialiser = 'calendar'
                                AND first_contact_at = started_at
                           FROM ops.windows WHERE calendar_event_id = 'ev-d1'), 'imported window shape');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.windows WHERE calendar_event_id IN ('ev-plain', 'ev-d2')),
                        'untagged and conflicting events not imported');
  PERFORM pg_temp.check(r->>'state' = 'new' AND r->'window'->>'start_source' = 'inferred'
                        AND r->>'directive' = 'CAL_CREATE', 'call continued to an inferred window: ' || r::text);

  -- re-import with no live window: drop the inferred window from the first call
  DELETE FROM ops.ticks;
  DELETE FROM ops.windows WHERE calendar_event_id IS NULL;
  r := ops.tick('chat', 'test', p_calendar => cal);
  PERFORM pg_temp.check(r->'imported' = '[]'::jsonb AND r->'skipped' @> '["ev-d1"]', 'ev-d1 skipped on re-import: ' || r::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.windows WHERE calendar_event_id = 'ev-d1') = 1, 'no duplicate import');
  RAISE NOTICE 'ok   5 degraded import';
END $$;

-- 6. code source with no live window opens a window immediately
DO $$
DECLARE r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  r := ops.tick('code', 'claude-code', 'sess-1');
  PERFORM pg_temp.check(r->>'state' = 'new' AND r->>'directive' IS NULL, 'code opens without directive: ' || r::text);
  PERFORM pg_temp.check((SELECT initialiser = 'code' AND start_source = 'inferred' AND started_at = now()
                                AND resets_at = now() + interval '5 hours' FROM ops.windows), 'code window shape');
  PERFORM pg_temp.check((SELECT client = 'claude-code' AND chat_ref = 'sess-1' FROM ops.ticks), 'tick row fields');
  RAISE NOTICE 'ok   6 code source opens inferred window';
END $$;

-- 7. CAL_CREATE until window_link_event, then none; refusal on a different id
DO $$
DECLARE r jsonb; n int; w ops.windows; refused boolean := false;
BEGIN
  PERFORM pg_temp.reset();
  r := ops.tick('chat', 'test', p_calendar => '[]');
  n := (r->'window'->>'number')::int;
  PERFORM pg_temp.check(r->>'directive' = 'CAL_CREATE', 'CAL_CREATE on open');
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'state' = 'ok' AND r->>'directive' = 'CAL_CREATE', 'CAL_CREATE repeats: ' || r::text);
  w := ops.window_link_event(n, 'ev-1');
  PERFORM pg_temp.check(w.calendar_event_id = 'ev-1', 'link returns the updated row');
  r := ops.tick('chat', 'test');
  PERFORM pg_temp.check(r->>'directive' IS NULL, 'no directive once linked: ' || r::text);
  w := ops.window_link_event(n, 'ev-1');
  PERFORM pg_temp.check(w.calendar_event_id = 'ev-1', 'relinking the same id is a no-op');
  BEGIN
    PERFORM ops.window_link_event(n, 'ev-2');
  EXCEPTION WHEN raise_exception THEN refused := true;
  END;
  PERFORM pg_temp.check(refused, 'link to a different event id refused');
  PERFORM pg_temp.check((SELECT calendar_event_id FROM ops.windows WHERE number = n) = 'ev-1', 'link unchanged');
  RAISE NOTICE 'ok   7 CAL_CREATE until linked';
END $$;

-- 8. correction ranking
DO $$
DECLARE w ops.windows; r jsonb;
BEGIN
  PERFORM pg_temp.reset();
  w := pg_temp.win(interval '-1 hour', interval '4 hours');           -- inferred, first contact now-1h

  r := ops.tick('chat', 'test', p_reset_at => now() + interval '3 hours 30 minutes', p_reset_source => 'stated');
  SELECT * INTO w FROM ops.windows WHERE id = w.id;
  PERFORM pg_temp.check(w.start_source = 'stated' AND w.resets_at = now() + interval '3 hours 30 minutes'
                        AND w.started_at = now() - interval '1 hour 30 minutes', 'stated overrides inferred');
  PERFORM pg_temp.check(r->>'state' = 'ok' AND r->>'directive' = 'CAL_CREATE', 'unlinked correction is ok: ' || r::text);

  r := ops.tick('chat', 'test', p_reset_at => now() + interval '3 hours', p_reset_source => 'inferred');
  PERFORM pg_temp.check((SELECT resets_at FROM ops.windows WHERE id = w.id) = now() + interval '3 hours 30 minutes',
                        'inferred cannot override stated');
  PERFORM pg_temp.check(r->>'directive' = 'CONFLICT' AND r->'detail'->>'reason' = 'rank'
                        AND r->'detail'->'also' = '["CAL_CREATE"]', 'rank refusal is CONFLICT: ' || r::text);
  PERFORM pg_temp.check(r->>'line' LIKE 'ok % · CONFLICT', 'conflict marked in line: ' || r::text);

  PERFORM ops.window_link_event(w.number, 'ev-w');
  r := ops.tick('chat', 'test', p_reset_at => now() + interval '3 hours 45 minutes', p_reset_source => 'observed');
  PERFORM pg_temp.check((SELECT start_source = 'observed' AND resets_at = now() + interval '3 hours 45 minutes'
                           FROM ops.windows WHERE id = w.id), 'observed overrides stated');
  PERFORM pg_temp.check(r->>'state' = 'fix_cal' AND r->>'directive' IS NULL, 'linked correction is fix_cal: ' || r::text);

  -- start after first contact: refused
  r := ops.tick('chat', 'test', p_reset_at => now() + interval '4 hours 30 minutes', p_reset_source => 'observed');
  PERFORM pg_temp.check(r->>'directive' = 'CONFLICT' AND r->'detail'->>'reason' = 'first_contact', 'first contact refusal: ' || r::text);
  -- 0038 keeps fix_cal for chat while the linked event's reset differs (corrected two lines above, not relinked)
  IF (SELECT max(version) FROM ops.schema_migrations) < '0038' THEN
  PERFORM pg_temp.check(r->>'state' = 'ok', 'state stays as computed: ' || r::text);
  ELSE
    RAISE NOTICE 'skip 8 state ok after a refused correction (newest migration is %)', (SELECT max(version) FROM ops.schema_migrations);
    PERFORM pg_temp.check(r->>'state' = 'fix_cal', 'state stays fix_cal until relinked (0038): ' || r::text);
  END IF;
  PERFORM pg_temp.check((SELECT resets_at FROM ops.windows WHERE id = w.id) = now() + interval '3 hours 45 minutes',
                        'refused correction leaves the window');

  -- overlap with an earlier window: refused
  PERFORM pg_temp.win(interval '-7 hours', interval '-1 hour -20 minutes', 'degraded');
  r := ops.tick('chat', 'test', p_reset_at => now() + interval '3 hours 35 minutes', p_reset_source => 'observed');
  PERFORM pg_temp.check(r->>'directive' = 'CONFLICT' AND r->'detail'->>'reason' = 'overlap'
                        AND r->'detail'->>'overlaps' IS NOT NULL, 'overlap refusal: ' || r::text);

  -- no live window: a future reset creates the window; a past one is refused
  PERFORM pg_temp.reset();
  r := ops.tick('chat', 'test', p_reset_at => now() + interval '2 hours', p_reset_source => 'stated');
  PERFORM pg_temp.check(r->>'state' = 'new' AND r->'window'->>'start_source' = 'stated'
                        AND (r->'window'->>'started_at')::timestamptz = now() - interval '3 hours', 'correction creates window: ' || r::text);
  PERFORM pg_temp.reset();
  r := ops.tick('code', 'test', p_reset_at => now() - interval '1 minute', p_reset_source => 'stated');
  PERFORM pg_temp.check(r->>'directive' = 'CONFLICT' AND r->'detail'->>'reason' = 'reset_not_future'
                        AND r->>'state' = 'new' AND r->'window'->>'start_source' = 'inferred', 'past reset refused: ' || r::text);
  PERFORM pg_temp.reset();
  r := ops.tick('code', 'test', p_reset_at => now() + interval '6 hours', p_reset_source => 'stated');
  PERFORM pg_temp.check(r->'detail'->>'reason' = 'start_in_future' AND r->'window'->>'start_source' = 'inferred',
                        'reset more than a window away refused: ' || r::text);
  RAISE NOTICE 'ok   8 correction ranking';
END $$;

-- 9. the exclusion constraint rejects an overlapping direct insert
DO $$
DECLARE rejected boolean := false;
BEGIN
  PERFORM pg_temp.reset();
  PERFORM pg_temp.win(interval '-2 hours', interval '3 hours');
  BEGIN
    PERFORM pg_temp.win(interval '2 hours', interval '7 hours');
  EXCEPTION WHEN exclusion_violation THEN rejected := true;
  END;
  PERFORM pg_temp.check(rejected, 'overlapping insert rejected');
  PERFORM pg_temp.win(interval '3 hours', interval '8 hours');      -- touching end-to-start is allowed
  RAISE NOTICE 'ok   9 exclusion constraint';
END $$;

-- 10. rollup: ticks older than 30 days move to tick_daily and are deleted; counts add on a rerun
DO $$
DECLARE d date := ((now() - interval '31 days') AT TIME ZONE 'Africa/Nairobi')::date;
BEGIN
  PERFORM pg_temp.reset();
  INSERT INTO ops.ticks (at, source, state)
  SELECT now() - interval '31 days', s::ops.contact_source, 'need_cal'
    FROM unnest(ARRAY['code', 'code', 'code', 'chat', 'chat']) s;
  INSERT INTO ops.ticks (at, source, state) VALUES (now() - interval '29 days', 'code', 'need_cal');
  PERFORM ops.tick('code', 'test');
  PERFORM pg_temp.check((SELECT ticks FROM ops.tick_daily WHERE day = d AND source = 'code') = 3, 'code rolled up');
  PERFORM pg_temp.check((SELECT ticks FROM ops.tick_daily WHERE day = d AND source = 'chat') = 2, 'chat rolled up');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.ticks WHERE at < now() - interval '30 days'), 'old ticks deleted');
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM ops.ticks WHERE at = now() - interval '29 days'), 'recent ticks kept');

  INSERT INTO ops.ticks (at, source, state)
  SELECT now() - interval '31 days', 'code', 'need_cal' FROM generate_series(1, 2);
  PERFORM ops.tick('code', 'test');
  PERFORM pg_temp.check((SELECT ticks FROM ops.tick_daily WHERE day = d AND source = 'code') = 5, 'counts add on rerun');
  PERFORM pg_temp.check((SELECT sum(ticks) FROM ops.tick_daily) = 7, 'no other days touched');
  RAISE NOTICE 'ok  10 rollup';
END $$;

-- 11. grants. Planner SELECT on the tables arrives with 0007, so that check follows the ledger and the
-- file passes before and after 0007 is applied.
DO $$
DECLARE f_tick text := 'ops.tick(ops.contact_source, text, text, timestamptz, ops.window_start_source, jsonb)';
        f_link text := 'ops.window_link_event(integer, text)';
        has_0007 boolean := EXISTS (SELECT 1 FROM ops.schema_migrations WHERE version = '0007_window_grants_changelog');
BEGIN
  PERFORM pg_temp.check(has_function_privilege('ops_planner', f_tick, 'EXECUTE'), 'planner executes tick');
  PERFORM pg_temp.check(has_function_privilege('ops_executor', f_tick, 'EXECUTE'), 'executor executes tick');
  PERFORM pg_temp.check(has_function_privilege('ops_planner', f_link, 'EXECUTE'), 'planner executes window_link_event');
  PERFORM pg_temp.check(NOT has_function_privilege('ops_executor', f_link, 'EXECUTE'), 'executor cannot link');
  PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.window_state', 'SELECT')
                        AND has_table_privilege('ops_executor', 'ops.window_state', 'SELECT'), 'both read window_state');
  PERFORM pg_temp.check(NOT has_table_privilege(r, t, p), format('%s has no %s on %s', r, p, t))
     FROM unnest(ARRAY['ops_planner', 'ops_executor']) r,
          unnest(ARRAY['ops.windows', 'ops.ticks', 'ops.tick_daily']) t,
          unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) p;
  PERFORM pg_temp.check(has_table_privilege('ops_planner', t, 'SELECT') = has_0007,
                        format('planner SELECT on %s should be %s', t, has_0007))
     FROM unnest(ARRAY['ops.windows', 'ops.ticks', 'ops.tick_daily']) t;
  PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', t, 'SELECT'), format('executor cannot SELECT %s', t))
     FROM unnest(ARRAY['ops.windows', 'ops.ticks', 'ops.tick_daily']) t;
  PERFORM pg_temp.check(NOT has_function_privilege('public', f_tick, 'EXECUTE'), 'PUBLIC cannot execute tick');
  RAISE NOTICE 'ok  11 grants (0007 applied: %)', has_0007;
END $$;

-- 12. tick() holds the fixed advisory lock for the rest of the transaction
DO $$
BEGIN
  PERFORM pg_temp.check(EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()
                                   AND granted), 'advisory lock held');
  RAISE NOTICE 'ok  12 advisory lock taken';
END $$;

ROLLBACK;

-- no leftover rows
DO $$ BEGIN
  IF (SELECT count(*) FROM ops.windows) <> current_setting('ops_test.windows_before')::bigint
     OR (SELECT count(*) FROM ops.ticks) <> current_setting('ops_test.ticks_before')::bigint THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok  13 no leftover rows; 0006 tests passed';
END $$;
