-- 0007_window_grants_changelog
-- Dispatch cde92aea (window-tracking build 3c34b680, dispatch 2b). Closes two follow-ups from 7e9659d2.
-- (1) ops_planner reads windows, ticks and tick_daily, per 0001's "planner reads everything".
--     ops_executor stays limited to window_state and tick(). No write grants.
-- (2) Protocol version 3 -> 4 for the 'window' rule added in 0006. A new rule keeps its own version 1,
--     as the rules seeded by 0002 did; only the protocol version moves.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

GRANT SELECT ON ops.windows, ops.ticks, ops.tick_daily TO ops_planner;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'window' AND version = 1) THEN
    RAISE EXCEPTION '0007: expected protocol rule window at version 1';
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION '0007: expected protocol version 3, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
END $$;

INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  4,
  ARRAY['window'],
  'New rule window {length_h 5, resume_gap_min 30, tick_retention_d 30}: window length, resume gap and tick retention read by ops.tick() (decisions f9b97b91, 51b95381, 9ef23a2f, c80fd5b9, 7f875eab).'
);

INSERT INTO ops.schema_migrations (version) VALUES ('0007_window_grants_changelog');

COMMIT;
