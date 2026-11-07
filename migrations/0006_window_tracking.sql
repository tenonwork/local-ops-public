-- 0006_window_tracking
-- Dispatch 7e9659d2 (window-tracking build 3c34b680, dispatch 2). Decisions f9b97b91 (lazy evaluation),
-- 51b95381 (tick protocol), 9ef23a2f (telemetry), c80fd5b9 (degraded-mode reconciliation), as amended
-- 2026-10-06: window_import folded into tick, Code contact opens an inferred window immediately,
-- corrections follow a source ranking, segment closure deferred to spine M1, rollup keeps no per-window
-- last activity. Window fields carried from 7aac02c7.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── Enums
CREATE TYPE ops.window_start_source AS ENUM ('inferred', 'stated', 'observed', 'degraded');
CREATE TYPE ops.contact_source      AS ENUM ('chat', 'code', 'user', 'calendar', 'scheduled');

-- ── Tables
CREATE TABLE ops.windows (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  number             integer GENERATED ALWAYS AS IDENTITY UNIQUE,
  started_at         timestamptz NOT NULL,
  resets_at          timestamptz NOT NULL,
  start_source       ops.window_start_source NOT NULL,
  first_contact_at   timestamptz,
  initialiser        ops.contact_source NOT NULL,
  calendar_event_id  text UNIQUE,
  recorded_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT windows_span_check          CHECK (resets_at > started_at),
  CONSTRAINT windows_first_contact_check CHECK (first_contact_at >= started_at),
  CONSTRAINT windows_no_overlap          EXCLUDE USING gist (tstzrange(started_at, resets_at) WITH &&)
);

CREATE TABLE ops.ticks (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  window_id  uuid REFERENCES ops.windows(id),
  source     ops.contact_source NOT NULL,
  client     text,
  chat_ref   text,
  state      text NOT NULL CHECK (state IN ('ok', 'resume', 'need_cal', 'new', 'fix_cal')),
  CONSTRAINT ticks_window_check CHECK ((window_id IS NULL) = (state = 'need_cal'))
);
CREATE INDEX ticks_window_at_idx ON ops.ticks (window_id, at);
CREATE INDEX ticks_at_idx        ON ops.ticks (at);

CREATE TABLE ops.tick_daily (
  day     date NOT NULL,
  source  ops.contact_source NOT NULL,
  ticks   integer NOT NULL CHECK (ticks >= 0),
  PRIMARY KEY (day, source)
);

-- ── Protocol rule
INSERT INTO ops.protocol_rules (key, value) VALUES
('window',
 '{"length_h": 5, "resume_gap_min": 30, "tick_retention_d": 30}');

-- ── View
CREATE VIEW ops.window_state AS
SELECT w.number, w.id, w.started_at, w.resets_at, w.start_source, w.initialiser, w.calendar_event_id,
       (now() >= w.started_at AND now() < w.resets_at) AS live,
       t.last_activity,
       t.tick_count
  FROM ops.windows w
  LEFT JOIN LATERAL (SELECT max(k.at) AS last_activity, count(*)::int AS tick_count
                       FROM ops.ticks k WHERE k.window_id = w.id) t ON true;

-- ── Helpers (owner-only; called from the security definer functions below)
CREATE FUNCTION ops._window_rank(p ops.window_start_source)
RETURNS integer LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p WHEN 'observed' THEN 3 WHEN 'stated' THEN 2 WHEN 'degraded' THEN 1 ELSE 0 END;
$$;

CREATE FUNCTION ops._wlabel(p_number integer)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT 'W' || CASE WHEN p_number < 1000 THEN lpad(p_number::text, 3, '0') ELSE p_number::text END;
$$;

-- '47m' under an hour, else '2h14'
CREATE FUNCTION ops._fmt_dur(p interval)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE WHEN m < 60 THEN m || 'm' ELSE (m / 60) || 'h' || lpad((m % 60)::text, 2, '0') END
    FROM (SELECT greatest(floor(extract(epoch FROM p) / 60), 0)::bigint AS m) s;
$$;

CREATE FUNCTION ops._fmt_time(p timestamptz)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT to_char(p AT TIME ZONE 'Africa/Nairobi', 'HH24:MI');
$$;

-- ── tick(): the single entry point for window state. Returns
-- {state, window{number,id,started_at,resets_at,start_source,calendar_event_id}, gap, remaining,
--  directive, detail, line} plus {imported, skipped, conflicts} when a calendar was processed.
-- gap and remaining are whole minutes. directive is the most urgent of CONFLICT > LIST_CAL > CAL_CREATE;
-- detail.also lists any lower ones that also apply.
CREATE FUNCTION ops.tick(p_source ops.contact_source, p_client text, p_chat_ref text DEFAULT NULL,
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
        UPDATE ops.windows
           SET started_at = p_reset_at - v_len, resets_at = p_reset_at, start_source = p_reset_source
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

-- ── Link a calendar event to a window (idempotent for the same id)
CREATE FUNCTION ops.window_link_event(p_number integer, p_event_id text)
RETURNS ops.windows LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE w ops.windows;
BEGIN
  IF length(btrim(coalesce(p_event_id, ''))) = 0 THEN RAISE EXCEPTION 'event id required'; END IF;
  SELECT * INTO w FROM ops.windows WHERE number = p_number FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown window %', ops._wlabel(p_number); END IF;
  IF w.calendar_event_id IS NOT NULL AND w.calendar_event_id <> p_event_id THEN
    RAISE EXCEPTION 'window % is already linked to event %', ops._wlabel(w.number), w.calendar_event_id;
  END IF;
  UPDATE ops.windows SET calendar_event_id = p_event_id WHERE id = w.id RETURNING * INTO w;
  RETURN w;
END $$;

-- ── Grants: nothing to PUBLIC; writes only through tick() and window_link_event()
REVOKE ALL ON ops.windows, ops.ticks, ops.tick_daily, ops.window_state FROM PUBLIC;
REVOKE ALL ON FUNCTION
  ops._window_rank(ops.window_start_source), ops._wlabel(integer), ops._fmt_dur(interval),
  ops._fmt_time(timestamptz),
  ops.tick(ops.contact_source, text, text, timestamptz, ops.window_start_source, jsonb),
  ops.window_link_event(integer, text)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  ops.tick(ops.contact_source, text, text, timestamptz, ops.window_start_source, jsonb)
TO ops_planner, ops_executor;
GRANT EXECUTE ON FUNCTION ops.window_link_event(integer, text) TO ops_planner;
GRANT SELECT ON ops.window_state TO ops_planner, ops_executor;

INSERT INTO ops.schema_migrations (version) VALUES ('0006_window_tracking');

COMMIT;
