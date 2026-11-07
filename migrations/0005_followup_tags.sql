-- 0005_followup_tags
-- Decisions a74992b5 + ccb4c217 (planning session d0f5814f). Protocol version 2 -> 3.
-- report_format: every FOLLOW-UP is tagged [side-effect] or [discovery]; the executor never assigns priority.

BEGIN;

DO $$
DECLARE n integer;
BEGIN
  UPDATE ops.protocol_rules
  SET value = jsonb_set(
        value,
        '{rule}',
        to_jsonb(
          (value ->> 'rule')
          || ' Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before. The executor never assigns priority; the planner sets the priority of discoveries at review.'
        )
      ),
      version = version + 1,
      updated_at = now()
  WHERE key = 'report_format' AND version = 2;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN
    RAISE EXCEPTION '0005: expected report_format at version 2, updated % rows', n;
  END IF;
END $$;

INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  3,
  ARRAY['report_format'],
  'FOLLOW-UPS items tagged [side-effect] or [discovery]; priority assigned by the planner at review, not the executor (decisions a74992b5, ccb4c217).'
);

INSERT INTO ops.schema_migrations (version) VALUES ('0005_followup_tags');

COMMIT;
