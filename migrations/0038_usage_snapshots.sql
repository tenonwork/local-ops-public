-- 0038_usage_snapshots
-- Dispatch 45c1e2c8. Usage reader (b9cbaad8). Staged on 0037; promoted later with the set.
-- No protocol_rules change.
--   * ops.usage_snapshots: Claude plan-usage readings (five-hour and seven-day used percentage and reset) taken from the
--     Code status line's stdin rate_limits; owner only, written through ops.record_usage.
--   * ops.record_usage (executor only): validates and stores a reading unless it equals the newest one; a five-hour reset
--     in the future corrects the current window through ops.tick as an observed source (code contact), and the tick's
--     window, state and detail (CONFLICT included) are kept on the row.
--   * ops.windows.calendar_resets_at: the reset time the window's linked calendar event carries. window_link_event sets it
--     (relinking the same id acknowledges a moved event); an applied correction on a linked window keeps the old reset
--     there when it was unset. A chat tick on a live linked window whose reset differs from it reports fix_cal instead of
--     ok until the planner relinks; code ticks never get this pending fix_cal, and resume is not overridden.
--   * ops.usage_now (planner and executor): the newest snapshot whose five-hour window has not reset.
--   * ops.dispatch_usage (planner SELECT): per-dispatch five-hour usage derived when read, never stored on dispatches.
-- tick and window_link_event keep their signatures, grants and refusals; claim_dispatch and complete_dispatch are unchanged.
-- The executor's SELECT set is unchanged; its EXECUTE set gains record_usage and usage_now.

BEGIN;

-- ── 1. guard; snapshots for step 9
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0037_discovery_bar_rules' THEN
    RAISE EXCEPTION '0038: expected newest ledger version 0037_discovery_bar_rules, found %', v_newest;
  END IF;
  IF to_regclass('ops.usage_snapshots') IS NOT NULL THEN
    RAISE EXCEPTION '0038: ops.usage_snapshots already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.windows'::regclass AND attname = 'calendar_resets_at'
                AND NOT attisdropped) THEN
    RAISE EXCEPTION '0038: ops.windows already has calendar_resets_at';
  END IF;

  PERFORM set_config('ops_m0038.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0038.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0038.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  PERFORM set_config('ops_m0038.window_fns',
    (SELECT string_agg(pg_get_function_arguments(p.oid) || ' ' || pg_get_function_result(p.oid) || ' ' || p.prosecdef::text
                       || ' ' || coalesce(p.proconfig::text, '') || ' ' || pg_get_userbyid(p.proowner) || ' '
                       || coalesce(p.proacl::text, '') || ' ' || coalesce(obj_description(p.oid, 'pg_proc'), ''),
                       ' | ' ORDER BY p.proname)
       FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname IN ('tick', 'window_link_event')), true);
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname IN ('tick', 'window_link_event')) <> 2 THEN
    RAISE EXCEPTION '0038: expected one ops.tick and one ops.window_link_event';
  END IF;
END $$;

-- ── 2. the reset the linked calendar event carries; backfilled for linked windows
ALTER TABLE ops.windows ADD COLUMN calendar_resets_at timestamptz;
UPDATE ops.windows SET calendar_resets_at = resets_at WHERE calendar_event_id IS NOT NULL;
COMMENT ON COLUMN ops.windows.calendar_resets_at IS
  'Usage reader (b9cbaad8): the reset time the linked calendar event carries; set by window_link_event. A chat tick reports fix_cal while it differs from resets_at.';

-- ── 3. window_link_event: a link or a relink with the same id also records the reset the event now carries
CREATE OR REPLACE FUNCTION ops.window_link_event(p_number integer, p_event_id text)
RETURNS ops.windows LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE w ops.windows;
BEGIN
  IF length(btrim(coalesce(p_event_id, ''))) = 0 THEN RAISE EXCEPTION 'event id required'; END IF;
  SELECT * INTO w FROM ops.windows WHERE number = p_number FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown window %', ops._wlabel(p_number); END IF;
  IF w.calendar_event_id IS NOT NULL AND w.calendar_event_id <> p_event_id THEN
    RAISE EXCEPTION 'window % is already linked to event %', ops._wlabel(w.number), w.calendar_event_id;
  END IF;
  UPDATE ops.windows SET calendar_event_id = p_event_id, calendar_resets_at = resets_at WHERE id = w.id RETURNING * INTO w;
  RETURN w;
END $$;

-- ── 4. tick: as 0006, except (c) an applied correction on a linked window keeps the event's reset when it was unset,
--       and (d) a chat tick on a live linked window whose reset differs from the event's is fix_cal instead of ok
CREATE OR REPLACE FUNCTION ops.tick(p_source ops.contact_source, p_client text, p_chat_ref text DEFAULT NULL,
                                    p_reset_at timestamptz DEFAULT NULL,
                                    p_reset_source ops.window_start_source DEFAULT NULL,
                                    p_calendar jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_cfg        jsonb;
  v_len        interval;
  v_resume     interval;
  v_retention  interval;
  w            ops.windows;
  v_was_live   boolean;
  v_old_reset  timestamptz;
  v_state      text;
  v_conflict   jsonb;
  v_codes      text[] := '{}';
  v_directive  text;
  v_detail     jsonb;
  v_last       timestamptz;
  v_gap        interval;
  v_prev       ops.windows;
  v_prev_last  timestamptz;
  v_events     jsonb := '[]';
  v_imported   jsonb := '[]';
  v_skipped    jsonb := '[]';
  v_conflicts  jsonb := '[]';
  e            jsonb;
  v_eid        text;
  v_es         timestamptz;
  v_ee         timestamptz;
  v_num        integer;
  v_sqlstate   text;
  v_cname      text;
  v_line       text;
  v_result     jsonb;
BEGIN
  -- a. Serialise every tick on one fixed key; released at transaction end.
  PERFORM pg_advisory_xact_lock(hashtext('ops.tick'));

  SELECT value INTO v_cfg FROM ops.protocol_rules WHERE key = 'window';
  IF v_cfg IS NULL THEN RAISE EXCEPTION 'protocol_rules key "window" is missing'; END IF;
  v_len       := make_interval(hours => (v_cfg->>'length_h')::int);
  v_resume    := make_interval(mins  => (v_cfg->>'resume_gap_min')::int);
  v_retention := make_interval(days  => (v_cfg->>'tick_retention_d')::int);

  IF p_source IS NULL THEN RAISE EXCEPTION 'p_source is required'; END IF;
  IF (p_reset_at IS NULL) <> (p_reset_source IS NULL) THEN
    RAISE EXCEPTION 'p_reset_at and p_reset_source must be given together';
  END IF;
  IF p_calendar IS NOT NULL AND jsonb_typeof(p_calendar) <> 'array' THEN
    RAISE EXCEPTION 'p_calendar must be a JSON array of {id, start, end, title, description}';
  END IF;

  -- b. Lazy upkeep: fold expired ticks into daily counts (day in Africa/Nairobi), then drop them.
  WITH old AS (
    DELETE FROM ops.ticks WHERE at < now() - v_retention RETURNING at, source)
  INSERT INTO ops.tick_daily AS d (day, source, ticks)
  SELECT (at AT TIME ZONE 'Africa/Nairobi')::date, source, count(*)::int FROM old GROUP BY 1, 2
  ON CONFLICT (day, source) DO UPDATE SET ticks = d.ticks + EXCLUDED.ticks;

  SELECT * INTO w FROM ops.windows WHERE now() >= started_at AND now() < resets_at FOR UPDATE;
  v_was_live := FOUND;

  -- c. Correction. A reset that is not in the future is never applied.
  IF p_reset_at IS NOT NULL AND p_reset_at <= now() THEN
    v_conflict := jsonb_build_object('reason', 'reset_not_future', 'reset_at', p_reset_at,
                                     'source', p_reset_source);
  ELSIF p_reset_at IS NOT NULL AND v_was_live THEN
    IF ops._window_rank(p_reset_source) < ops._window_rank(w.start_source) THEN
      IF p_reset_at <> w.resets_at THEN
        v_conflict := jsonb_build_object('reason', 'rank', 'window', ops._wlabel(w.number),
                                         'current', w.start_source, 'resets_at', w.resets_at,
                                         'source', p_reset_source, 'reset_at', p_reset_at);
      END IF;
    ELSE
      v_old_reset := w.resets_at;
      BEGIN
        -- a linked window with no recorded event reset keeps the old one, so the pending fix_cal survives (0038)
        UPDATE ops.windows
           SET started_at = p_reset_at - v_len, resets_at = p_reset_at, start_source = p_reset_source,
               calendar_resets_at = CASE WHEN calendar_event_id IS NOT NULL AND calendar_resets_at IS NULL
                                         THEN v_old_reset ELSE calendar_resets_at END
         WHERE id = w.id
        RETURNING * INTO w;
        -- an applied correction answers fix_cal (linked event now wrong) or ok, never resume
        v_state := CASE WHEN w.calendar_event_id IS NOT NULL AND w.resets_at <> v_old_reset
                        THEN 'fix_cal' ELSE 'ok' END;
      EXCEPTION WHEN check_violation OR exclusion_violation THEN
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        v_conflict := jsonb_strip_nulls(jsonb_build_object(
          'reason', CASE v_cname WHEN 'windows_first_contact_check' THEN 'first_contact'
                                 WHEN 'windows_no_overlap' THEN 'overlap' ELSE v_cname END,
          'window', ops._wlabel(w.number), 'source', p_reset_source, 'reset_at', p_reset_at,
          'first_contact_at', CASE WHEN v_cname = 'windows_first_contact_check' THEN w.first_contact_at END,
          'overlaps', (SELECT ops._wlabel(o.number) FROM ops.windows o
                        WHERE o.id <> w.id AND v_cname = 'windows_no_overlap'
                          AND tstzrange(o.started_at, o.resets_at) && tstzrange(p_reset_at - v_len, p_reset_at)
                        ORDER BY o.started_at LIMIT 1)));
      END;
    END IF;
  END IF;

  IF NOT v_was_live THEN
    -- e. No live window. A chat tick with a calendar first reconciles ended [degraded] events.
    IF p_source = 'chat' AND p_calendar IS NOT NULL THEN
      FOR e IN SELECT value FROM jsonb_array_elements(p_calendar) LOOP
        v_eid := NULL;
        BEGIN
          v_eid := e->>'id';
          v_es  := (e->>'start')::timestamptz;
          v_ee  := (e->>'end')::timestamptz;
          IF v_eid IS NULL OR v_es IS NULL OR v_ee IS NULL THEN
            v_conflicts := v_conflicts || jsonb_build_object('event_id', v_eid, 'detail', 'missing id, start or end');
          ELSE
            v_events := v_events || jsonb_build_object(
              'id', v_eid, 'start', v_es, 'end', v_ee,
              'tagged', position('[degraded]' IN lower(coalesce(e->>'title', ''))) > 0);
          END IF;
        EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
          v_conflicts := v_conflicts || jsonb_build_object('event_id', v_eid, 'detail', 'unreadable start or end');
        END;
      END LOOP;

      FOR e IN SELECT value FROM jsonb_array_elements(v_events)
                WHERE (value->>'tagged')::boolean AND (value->>'end')::timestamptz <= now() LOOP
        v_eid := e->>'id'; v_es := (e->>'start')::timestamptz; v_ee := (e->>'end')::timestamptz;
        IF EXISTS (SELECT 1 FROM ops.windows WHERE calendar_event_id = v_eid) THEN
          v_skipped := v_skipped || to_jsonb(v_eid);
          CONTINUE;
        END IF;
        BEGIN
          INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser, calendar_event_id)
          VALUES (v_es, v_ee, 'degraded', v_es, 'calendar', v_eid)
          RETURNING number INTO v_num;
          v_imported := v_imported || jsonb_build_object('event_id', v_eid, 'window', ops._wlabel(v_num));
        EXCEPTION WHEN exclusion_violation OR check_violation OR unique_violation THEN
          GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_cname = CONSTRAINT_NAME;
          v_conflicts := v_conflicts || jsonb_build_object('event_id', v_eid, 'detail',
            CASE v_sqlstate
              WHEN '23P01' THEN 'overlaps ' || coalesce((SELECT ops._wlabel(o.number) FROM ops.windows o
                                  WHERE tstzrange(o.started_at, o.resets_at) && tstzrange(v_es, v_ee)
                                  ORDER BY o.started_at LIMIT 1), 'another window')
              WHEN '23505' THEN 'event already linked'
              ELSE 'invalid span (' || v_cname || ')' END);
        END;
      END LOOP;
    END IF;

    -- c (no live window). A future reset creates the window it describes.
    IF p_reset_at IS NOT NULL AND v_conflict IS NULL THEN
      BEGIN
        INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser)
        VALUES (p_reset_at - v_len, p_reset_at, p_reset_source, now(), p_source)
        RETURNING * INTO w;
        v_state := 'new';
      EXCEPTION WHEN check_violation OR exclusion_violation THEN
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        v_conflict := jsonb_strip_nulls(jsonb_build_object(
          'reason', CASE v_cname WHEN 'windows_first_contact_check' THEN 'start_in_future'
                                 WHEN 'windows_no_overlap' THEN 'overlap' ELSE v_cname END,
          'source', p_reset_source, 'reset_at', p_reset_at,
          'overlaps', (SELECT ops._wlabel(o.number) FROM ops.windows o
                        WHERE v_cname = 'windows_no_overlap'
                          AND tstzrange(o.started_at, o.resets_at) && tstzrange(p_reset_at - v_len, p_reset_at)
                        ORDER BY o.started_at LIMIT 1)));
      END;
    END IF;

    IF w.id IS NULL THEN
      IF p_source = 'chat' AND p_calendar IS NULL THEN
        v_state := 'need_cal';
      ELSE
        IF p_source = 'chat' THEN
          -- adopt an event that covers now (most recent start first)
          FOR e IN SELECT value FROM jsonb_array_elements(v_events)
                    WHERE (value->>'start')::timestamptz <= now() AND (value->>'end')::timestamptz > now()
                    ORDER BY (value->>'start')::timestamptz DESC LOOP
            v_eid := e->>'id'; v_es := (e->>'start')::timestamptz; v_ee := (e->>'end')::timestamptz;
            IF EXISTS (SELECT 1 FROM ops.windows WHERE calendar_event_id = v_eid) THEN
              v_skipped := v_skipped || to_jsonb(v_eid);
              CONTINUE;
            END IF;
            BEGIN
              INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser, calendar_event_id)
              VALUES (v_es, v_ee,
                      CASE WHEN (e->>'tagged')::boolean THEN 'degraded' ELSE 'stated' END::ops.window_start_source,
                      v_es, 'calendar', v_eid)
              RETURNING * INTO w;
              EXIT;
            EXCEPTION WHEN exclusion_violation OR check_violation OR unique_violation THEN
              v_conflicts := v_conflicts || jsonb_build_object('event_id', v_eid, 'detail',
                'cannot adopt: ' || coalesce((SELECT 'overlaps ' || ops._wlabel(o.number) FROM ops.windows o
                                     WHERE tstzrange(o.started_at, o.resets_at) && tstzrange(v_es, v_ee)
                                     ORDER BY o.started_at LIMIT 1), SQLERRM));
            END;
          END LOOP;
        END IF;
        IF w.id IS NULL THEN
          INSERT INTO ops.windows (started_at, resets_at, start_source, first_contact_at, initialiser)
          VALUES (now(), now() + v_len, 'inferred', now(), p_source)
          RETURNING * INTO w;
        END IF;
        v_state := 'new';
      END IF;
    END IF;
  END IF;

  -- d. Live window state; gap is measured from the window's last tick (else its first contact).
  IF v_was_live THEN
    v_last := coalesce((SELECT max(at) FROM ops.ticks WHERE window_id = w.id), w.first_contact_at, w.started_at);
    v_gap := now() - v_last;
    IF v_state IS NULL THEN
      v_state := CASE WHEN v_gap >= v_resume THEN 'resume' ELSE 'ok' END;
    END IF;
    -- the linked event still carries another reset: chat keeps hearing fix_cal until the planner relinks (0038)
    IF p_source = 'chat' AND v_state = 'ok' AND w.calendar_event_id IS NOT NULL
       AND w.calendar_resets_at IS NOT NULL AND w.calendar_resets_at <> w.resets_at THEN
      v_state := 'fix_cal';
    END IF;
  ELSIF v_state = 'need_cal' THEN
    v_last := (SELECT max(at) FROM ops.ticks);
    v_gap := now() - v_last;
  END IF;

  -- Directives, most urgent first.
  IF v_conflict IS NOT NULL THEN v_codes := array_append(v_codes, 'CONFLICT'); END IF;
  IF v_state = 'need_cal' THEN v_codes := array_append(v_codes, 'LIST_CAL'); END IF;
  IF p_source = 'chat' AND w.id IS NOT NULL AND w.calendar_event_id IS NULL THEN
    v_codes := array_append(v_codes, 'CAL_CREATE');
  END IF;
  v_directive := v_codes[1];
  v_detail := CASE v_directive
                WHEN 'CONFLICT' THEN v_conflict
                WHEN 'LIST_CAL' THEN jsonb_build_object('last_activity', v_last)
                ELSE NULL END;
  IF cardinality(v_codes) > 1 THEN
    v_detail := coalesce(v_detail, '{}') || jsonb_build_object('also', to_jsonb(v_codes[2:]));
  END IF;
  IF v_directive = 'CONFLICT' AND 'LIST_CAL' = ANY (v_codes) THEN
    v_detail := v_detail || jsonb_build_object('last_activity', v_last);
  END IF;

  -- f. Log the tick.
  INSERT INTO ops.ticks (window_id, source, client, chat_ref, state)
  VALUES (w.id, p_source, p_client, p_chat_ref, v_state);

  -- g. One-line summary, times in Africa/Nairobi.
  IF v_state = 'new' THEN
    SELECT * INTO v_prev FROM ops.windows
     WHERE id <> w.id AND started_at < w.started_at ORDER BY started_at DESC LIMIT 1;
    IF v_prev.id IS NOT NULL THEN
      v_prev_last := coalesce((SELECT max(at) FROM ops.ticks WHERE window_id = v_prev.id), v_prev.first_contact_at);
    END IF;
  END IF;
  v_line := CASE v_state
    WHEN 'ok'       THEN format('ok %s · %s left', ops._wlabel(w.number), ops._fmt_dur(w.resets_at - now()))
    WHEN 'resume'   THEN format('resume %s · idle %s · %s left', ops._wlabel(w.number), ops._fmt_dur(v_gap),
                                ops._fmt_dur(w.resets_at - now()))
    WHEN 'fix_cal'  THEN format('fix_cal %s · resets %s (%s) · %s left', ops._wlabel(w.number),
                                ops._fmt_time(w.resets_at), w.start_source, ops._fmt_dur(w.resets_at - now()))
    WHEN 'need_cal' THEN 'need_cal · ' || coalesce('last activity ' || ops._fmt_dur(v_gap) || ' ago',
                                                    'no activity recorded')
    WHEN 'new'      THEN format('new %s · from %s (%s)', ops._wlabel(w.number), ops._fmt_time(w.started_at),
                                w.start_source)
                         || CASE WHEN v_prev.id IS NULL THEN ''
                                 ELSE ' · prev ' || ops._wlabel(v_prev.number)
                                      || coalesce(' last active ' || ops._fmt_time(v_prev_last), '') END
  END;
  IF v_conflict IS NOT NULL THEN v_line := v_line || ' · CONFLICT'; END IF;

  v_result := jsonb_build_object(
    'state', v_state,
    'window', CASE WHEN w.id IS NULL THEN NULL ELSE jsonb_build_object(
                'number', w.number, 'id', w.id, 'started_at', w.started_at, 'resets_at', w.resets_at,
                'start_source', w.start_source, 'calendar_event_id', w.calendar_event_id) END,
    'gap', floor(extract(epoch FROM v_gap) / 60)::int,
    'remaining', CASE WHEN w.id IS NULL THEN NULL ELSE floor(extract(epoch FROM w.resets_at - now()) / 60)::int END,
    'directive', v_directive,
    'detail', v_detail,
    'line', v_line);
  IF p_source = 'chat' AND p_calendar IS NOT NULL AND NOT v_was_live THEN
    v_result := v_result || jsonb_build_object('imported', v_imported, 'skipped', v_skipped,
                                               'conflicts', v_conflicts);
  END IF;
  RETURN v_result;
END $$;

-- ── 5. snapshots: owner only, written through record_usage
CREATE TABLE ops.usage_snapshots (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  captured_at          timestamptz NOT NULL DEFAULT now(),
  client               text NOT NULL,
  session_ref          text,
  five_hour_pct        numeric(5,2),
  five_hour_resets_at  timestamptz,
  seven_day_pct        numeric(5,2),
  seven_day_resets_at  timestamptz,
  window_id            uuid REFERENCES ops.windows(id),
  tick_state           text,
  tick_detail          jsonb,
  CONSTRAINT usage_snapshots_five_hour_pct_check  CHECK (five_hour_pct IS NULL OR five_hour_pct BETWEEN 0 AND 100),
  CONSTRAINT usage_snapshots_seven_day_pct_check  CHECK (seven_day_pct IS NULL OR seven_day_pct BETWEEN 0 AND 100),
  CONSTRAINT usage_snapshots_five_hour_pair_check CHECK ((five_hour_pct IS NULL) = (five_hour_resets_at IS NULL)),
  CONSTRAINT usage_snapshots_seven_day_pair_check CHECK ((seven_day_pct IS NULL) = (seven_day_resets_at IS NULL)),
  CONSTRAINT usage_snapshots_present_check        CHECK (five_hour_pct IS NOT NULL OR seven_day_pct IS NOT NULL)
);
CREATE INDEX usage_snapshots_captured_at_idx ON ops.usage_snapshots (captured_at);
REVOKE ALL ON ops.usage_snapshots FROM PUBLIC;
COMMENT ON TABLE ops.usage_snapshots IS
  'Usage reader (b9cbaad8): Claude plan-usage readings from the Code status line (rate_limits five_hour and seven_day); owner only, written through record_usage.';

-- ── 6. writer (executor only)
CREATE FUNCTION ops.record_usage(p_client text, p_session_ref text, p_five_hour_pct numeric,
                                 p_five_hour_resets_at timestamptz, p_seven_day_pct numeric,
                                 p_seven_day_resets_at timestamptz)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_last ops.usage_snapshots;
  v_id   bigint;
  r      jsonb;
BEGIN
  IF length(btrim(coalesce(p_client, ''))) = 0 THEN
    RAISE EXCEPTION 'p_client is required' USING ERRCODE = 'check_violation';
  END IF;
  IF p_five_hour_pct NOT BETWEEN 0 AND 100 OR p_seven_day_pct NOT BETWEEN 0 AND 100 THEN
    RAISE EXCEPTION 'used percentages must be between 0 and 100' USING ERRCODE = 'check_violation';
  END IF;
  IF (p_five_hour_pct IS NULL) <> (p_five_hour_resets_at IS NULL)
     OR (p_seven_day_pct IS NULL) <> (p_seven_day_resets_at IS NULL) THEN
    RAISE EXCEPTION 'each used percentage needs its resets_at, and each resets_at its used percentage'
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_five_hour_pct IS NULL AND p_seven_day_pct IS NULL THEN
    RAISE EXCEPTION 'a reading needs the five-hour or the seven-day window' USING ERRCODE = 'check_violation';
  END IF;

  -- an unchanged reading is not stored and corrects nothing
  SELECT * INTO v_last FROM ops.usage_snapshots ORDER BY captured_at DESC, id DESC LIMIT 1;
  IF FOUND AND v_last.five_hour_pct IS NOT DISTINCT FROM p_five_hour_pct::numeric(5,2)
     AND v_last.five_hour_resets_at IS NOT DISTINCT FROM p_five_hour_resets_at
     AND v_last.seven_day_pct IS NOT DISTINCT FROM p_seven_day_pct::numeric(5,2)
     AND v_last.seven_day_resets_at IS NOT DISTINCT FROM p_seven_day_resets_at THEN
    RETURN jsonb_build_object('recorded', false);
  END IF;

  INSERT INTO ops.usage_snapshots (client, session_ref, five_hour_pct, five_hour_resets_at, seven_day_pct,
                                   seven_day_resets_at)
  VALUES (p_client, p_session_ref, p_five_hour_pct, p_five_hour_resets_at, p_seven_day_pct, p_seven_day_resets_at)
  RETURNING id INTO v_id;

  -- a five-hour reset still ahead corrects the current window as an observed source
  IF p_five_hour_resets_at > now() THEN
    r := ops.tick('code', p_client, p_reset_at => p_five_hour_resets_at, p_reset_source => 'observed');
    UPDATE ops.usage_snapshots
       SET window_id = (r->'window'->>'id')::uuid, tick_state = r->>'state', tick_detail = nullif(r->'detail', 'null')
     WHERE id = v_id;
  END IF;

  RETURN jsonb_build_object('recorded', true, 'id', v_id,
                            'tick', CASE WHEN r IS NULL THEN NULL ELSE jsonb_build_object(
                                      'state', r->'state', 'directive', r->'directive', 'line', r->'line') END);
END $$;
REVOKE ALL ON FUNCTION ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz) TO ops_executor;
COMMENT ON FUNCTION ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz) IS
  'Usage reader (b9cbaad8): stores a status-line usage reading unless it equals the newest; a future five-hour reset corrects the current window through tick (code, observed). Executor only.';

-- ── 7. reader: the newest snapshot whose five-hour window has not reset
CREATE FUNCTION ops.usage_now()
RETURNS TABLE(captured_at timestamptz, age_s integer, client text, five_hour_pct numeric, five_hour_resets_at timestamptz,
              seven_day_pct numeric, seven_day_resets_at timestamptz, window_number integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT u.captured_at, floor(extract(epoch FROM now() - u.captured_at))::integer, u.client, u.five_hour_pct,
         u.five_hour_resets_at, u.seven_day_pct, u.seven_day_resets_at, w.number
    FROM ops.usage_snapshots u
    LEFT JOIN ops.windows w ON w.id = u.window_id
   WHERE u.five_hour_resets_at > now()
   ORDER BY u.captured_at DESC, u.id DESC
   LIMIT 1;
$$;
REVOKE ALL ON FUNCTION ops.usage_now() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.usage_now() TO ops_planner, ops_executor;
COMMENT ON FUNCTION ops.usage_now() IS
  'Usage reader (b9cbaad8): the newest usage snapshot whose five-hour window has not reset; zero rows if none.';

-- ── 8. per-dispatch usage, derived when read; snapshots without a five-hour reading are not used
CREATE VIEW ops.dispatch_usage AS
SELECT d.id, d.dispatch_type, d.claimed_at, d.completed_at,
       s.id AS start_snapshot_id, s.captured_at AS start_captured_at, s.five_hour_pct AS start_five_hour_pct,
       e.id AS end_snapshot_id, e.captured_at AS end_captured_at, e.five_hour_pct AS end_five_hour_pct,
       CASE WHEN s.five_hour_resets_at = e.five_hour_resets_at THEN e.five_hour_pct - s.five_hour_pct END
         AS five_hour_delta,
       CASE WHEN s.id IS NULL OR e.id IS NULL THEN 'no_snapshot'
            WHEN s.five_hour_resets_at <> e.five_hour_resets_at THEN 'window_crossed' END AS delta_note
  FROM ops.dispatches d
  LEFT JOIN LATERAL (SELECT u.* FROM ops.usage_snapshots u
                      WHERE u.five_hour_pct IS NOT NULL AND u.captured_at <= d.claimed_at
                      ORDER BY u.captured_at DESC, u.id DESC LIMIT 1) s ON true
  LEFT JOIN LATERAL (SELECT u.* FROM ops.usage_snapshots u
                      WHERE u.five_hour_pct IS NOT NULL AND u.captured_at <= d.completed_at + interval '5 minutes'
                      ORDER BY u.captured_at DESC, u.id DESC LIMIT 1) e ON true
 WHERE d.claimed_at IS NOT NULL AND d.completed_at IS NOT NULL;
REVOKE ALL ON ops.dispatch_usage FROM PUBLIC;
GRANT SELECT ON ops.dispatch_usage TO ops_planner;
COMMENT ON VIEW ops.dispatch_usage IS
  'Usage reader (b9cbaad8): five-hour usage per finished dispatch, from the newest snapshot at claim and the newest by completion + 5 minutes; the delta includes all account activity in the interval (chat and other sessions). NULL with delta_note no_snapshot or window_crossed.';

-- ── 9. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_bad text;
BEGIN
  -- column and backfill
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'ops.windows'::regclass AND attname = 'calendar_resets_at'
                    AND atttypid = 'timestamptz'::regtype AND NOT attnotnull AND NOT attisdropped) THEN
    RAISE EXCEPTION '0038: ops.windows.calendar_resets_at missing or not a nullable timestamptz';
  END IF;
  IF (SELECT count(*) FROM ops.windows WHERE calendar_resets_at IS NOT NULL)
       <> (SELECT count(*) FROM ops.windows WHERE calendar_event_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM ops.windows WHERE calendar_event_id IS NOT NULL
                   AND calendar_resets_at IS DISTINCT FROM resets_at) THEN
    RAISE EXCEPTION '0038: calendar_resets_at backfill does not match the linked windows';
  END IF;

  -- tick and window_link_event: signature, definer, search_path, owner, ACL and comment as before
  IF (SELECT string_agg(pg_get_function_arguments(p.oid) || ' ' || pg_get_function_result(p.oid) || ' ' || p.prosecdef::text
                        || ' ' || coalesce(p.proconfig::text, '') || ' ' || pg_get_userbyid(p.proowner) || ' '
                        || coalesce(p.proacl::text, '') || ' ' || coalesce(obj_description(p.oid, 'pg_proc'), ''),
                        ' | ' ORDER BY p.proname)
        FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname IN ('tick', 'window_link_event'))
     IS DISTINCT FROM current_setting('ops_m0038.window_fns') THEN
    RAISE EXCEPTION '0038: ops.tick or ops.window_link_event catalog changed';
  END IF;

  -- new objects: owner, definer, search_path, comment
  IF (SELECT count(*) FROM pg_proc p
       WHERE p.oid IN ('ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz)'::regprocedure,
                       'ops.usage_now()'::regprocedure)
         AND p.prosecdef AND p.proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(p.proowner) = v_owner
         AND obj_description(p.oid, 'pg_proc') LIKE 'Usage reader (b9cbaad8): %') <> 2
     OR (SELECT count(*) FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname IN ('record_usage', 'usage_now')) <> 2
     OR (SELECT count(*) FROM pg_class c
          WHERE c.oid IN ('ops.usage_snapshots'::regclass, 'ops.dispatch_usage'::regclass)
            AND pg_get_userbyid(c.relowner) = v_owner AND obj_description(c.oid, 'pg_class') LIKE 'Usage reader (b9cbaad8): %') <> 2 THEN
    RAISE EXCEPTION '0038: record_usage, usage_now, usage_snapshots or dispatch_usage owner, definer, search_path or comment wrong';
  END IF;

  -- grants
  IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
        FROM pg_proc p, aclexplode(p.proacl) a
       WHERE p.oid = 'ops.record_usage(text, text, numeric, timestamptz, numeric, timestamptz)'::regprocedure
         AND a.grantee <> p.proowner) <> ARRAY['ops_executor']
     OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                   ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
           FROM pg_proc p, aclexplode(p.proacl) a
          WHERE p.oid = 'ops.usage_now()'::regprocedure AND a.grantee <> p.proowner) <> ARRAY['ops_executor', 'ops_planner']
     OR (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                   || ' ' || a.privilege_type), '{}')
           FROM pg_class c, aclexplode(c.relacl) a
          WHERE c.oid = 'ops.dispatch_usage'::regclass AND a.grantee <> c.relowner) <> ARRAY['ops_planner SELECT']
     OR EXISTS (SELECT 1 FROM pg_class c, aclexplode(c.relacl) a
                 WHERE c.oid = 'ops.usage_snapshots'::regclass AND a.grantee <> c.relowner) THEN
    RAISE EXCEPTION '0038: ACL of record_usage, usage_now, dispatch_usage or usage_snapshots wrong';
  END IF;
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0038.executor_reads') THEN
    RAISE EXCEPTION '0038: ops_executor SELECT set changed';
  END IF;
  IF (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
       WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))
     IS DISTINCT FROM (SELECT array_agg(DISTINCT f ORDER BY f)
                         FROM unnest(current_setting('ops_m0038.executor_fns')::text[] || ARRAY['record_usage', 'usage_now']) f) THEN
    RAISE EXCEPTION '0038: ops_executor EXECUTE set is not the old set plus record_usage and usage_now';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND (has_table_privilege('ops_planner', c.oid, p) OR has_table_privilege('ops_executor', c.oid, p));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0038: ops_planner or ops_executor holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules)
     IS DISTINCT FROM current_setting('ops_m0038.rules_md5') THEN
    RAISE EXCEPTION '0038: protocol_rules changed';
  END IF;
  RAISE NOTICE '0038 checks passed';
END $$;

-- ── 10. ledger
INSERT INTO ops.schema_migrations (version) VALUES ('0038_usage_snapshots');

COMMIT;
