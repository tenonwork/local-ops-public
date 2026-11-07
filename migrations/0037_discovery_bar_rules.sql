-- 0037_discovery_bar_rules
-- Dispatch 1f66e921. Discovery-bar protocol rules (decision cb0e9866). Staged on 0036; promoted later with the set.
-- Protocol version 12 -> 13.
-- A finding becomes backlog work only if it meets the bar (it blocks, breaks, brings a genuine noticeable improvement,
-- causes a real problem later, gets costlier with deferral, recurs, or touches security or data integrity); below the
-- bar it is a known weakness, reported as [known-weakness] and, for committing dispatches, written into the work
-- entry's follow_ups. Within scope the executor may make a harmless fix in place, tagged [fixed-in-place].
-- Rules are updated in place with version + 1 and a protocol_changelog row (0017 and 0030 precedent).
-- Writes: two protocol_rules updates (hard_boundaries v3 -> v4, report_format v3 -> v4), one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0036, protocol version 12, hard_boundaries at version 3 with 6 rules and
--       the old rule 3 text, report_format at version 3 whose rule ends with the old FOLLOW-UPS sentences, no changelog
--       row at version 13; records an md5 of every other protocol_rules row for step 4
DO $$
DECLARE v_newest text;
        v_old_rule3 constant text := 'Touching a file outside scope means stop and report.';
        v_old_tail constant text := 'Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before. The executor never assigns priority; the planner sets the priority of discoveries at review.';
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0036_node_overview' THEN
    RAISE EXCEPTION '0037: expected newest ledger version 0036_node_overview, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 12 THEN
    RAISE EXCEPTION '0037: expected protocol version 12, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'hard_boundaries' AND version = 3
                    AND jsonb_typeof(value -> 'rules') = 'array'
                    AND jsonb_array_length(value -> 'rules') = 6
                    AND value -> 'rules' ->> 2 = v_old_rule3) THEN
    RAISE EXCEPTION '0037: hard_boundaries missing, not at version 3, not 6 rules, or rule 3 differs';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'report_format' AND version = 3
                    AND right(value ->> 'rule', length(v_old_tail)) = v_old_tail
                    AND strpos(value ->> 'rule', v_old_tail) = length(value ->> 'rule') - length(v_old_tail) + 1) THEN
    RAISE EXCEPTION '0037: report_format missing, not at version 3, or its rule does not end with the old FOLLOW-UPS sentences';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 13) THEN
    RAISE EXCEPTION '0037: a protocol_changelog row at version 13 already exists';
  END IF;
  PERFORM set_config('ops_m0037.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
       FROM ops.protocol_rules WHERE key NOT IN ('hard_boundaries', 'report_format')), true);
  PERFORM set_config('ops_m0037.hb_v3', (SELECT value::text FROM ops.protocol_rules WHERE key = 'hard_boundaries'), true);
  PERFORM set_config('ops_m0037.rf_v3', (SELECT value::text FROM ops.protocol_rules WHERE key = 'report_format'), true);
END $$;

-- ── 1. hard_boundaries, version 4: rule 3 replaced, the other five unchanged and in order
UPDATE ops.protocol_rules
SET value = jsonb_set(value, '{rules,2}', to_jsonb('Touching a file outside scope means stop and report. Within scope, a harmless fix found along the way may be made in place: comments, documentation text, typos, or a test-only fix to an assertion pinned on old state. Never a migration, a SQL function body, a grant, .claude/**, a credential, or any change in behaviour. Each such fix is listed under FOLLOW-UPS tagged [fixed-in-place] and must pass the dispatch''s verify.'::text)),
    version = 4,
    updated_at = now()
WHERE key = 'hard_boundaries';

-- ── 2. report_format, version 4: the two FOLLOW-UPS sentences at the end of the rule replaced; fields unchanged
UPDATE ops.protocol_rules
SET value = jsonb_set(value, '{rule}', to_jsonb(
      left(value ->> 'rule', length(value ->> 'rule') - length('Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before. The executor never assigns priority; the planner sets the priority of discoveries at review.'))
      || 'Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before and meets the bar (it blocks, breaks, brings a genuine noticeable improvement, causes a real problem later, gets costlier with deferral, recurs, or touches security or data integrity), [fixed-in-place] for a harmless in-scope fix (hard_boundaries), or [known-weakness] for anything below the bar. A committing dispatch also writes its known weaknesses into its work entry''s follow_ups. The executor never assigns priority; the planner sets the priority of discoveries at review.')),
    version = 4,
    updated_at = now()
WHERE key = 'report_format';

-- ── 3. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  13,
  ARRAY['hard_boundaries', 'report_format'],
  'hard_boundaries v4: harmless in-scope fixes allowed, tagged [fixed-in-place]; report_format v4: FOLLOW-UPS tags [side-effect], [discovery] (meets the bar), [fixed-in-place], [known-weakness]; known weaknesses go to the work entry''s follow_ups (decision cb0e9866).'
);

-- ── 4. checks
DO $$
DECLARE v_hb_v3 constant jsonb := current_setting('ops_m0037.hb_v3')::jsonb;
        v_rf_v3 constant jsonb := current_setting('ops_m0037.rf_v3')::jsonb;
        v_old_tail constant text := 'Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before. The executor never assigns priority; the planner sets the priority of discoveries at review.';
        v_new_tail constant text := 'Every FOLLOW-UPS item starts with a tag: [side-effect] if this dispatch caused the problem, [discovery] if it existed before and meets the bar (it blocks, breaks, brings a genuine noticeable improvement, causes a real problem later, gets costlier with deferral, recurs, or touches security or data integrity), [fixed-in-place] for a harmless in-scope fix (hard_boundaries), or [known-weakness] for anything below the bar. A committing dispatch also writes its known weaknesses into its work entry''s follow_ups. The executor never assigns priority; the planner sets the priority of discoveries at review.';
        v_new_rule3 constant text := 'Touching a file outside scope means stop and report. Within scope, a harmless fix found along the way may be made in place: comments, documentation text, typos, or a test-only fix to an assertion pinned on old state. Never a migration, a SQL function body, a grant, .claude/**, a credential, or any change in behaviour. Each such fix is listed under FOLLOW-UPS tagged [fixed-in-place] and must pass the dispatch''s verify.';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'hard_boundaries' AND version = 4
                    AND value = jsonb_set(v_hb_v3, '{rules,2}', to_jsonb(v_new_rule3))
                    AND jsonb_array_length(value -> 'rules') = 6) THEN
    RAISE EXCEPTION '0037: hard_boundaries not at version 4 or its value differs from the expected v4 value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'report_format' AND version = 4
                    AND value = jsonb_set(v_rf_v3, '{rule}', to_jsonb(
                          left(v_rf_v3 ->> 'rule', length(v_rf_v3 ->> 'rule') - length(v_old_tail)) || v_new_tail))
                    AND value -> 'fields' = v_rf_v3 -> 'fields'
                    AND right(value ->> 'rule', length(v_new_tail)) = v_new_tail
                    AND strpos(value ->> 'rule', '[discovery] if it existed before. The') = 0) THEN
    RAISE EXCEPTION '0037: report_format not at version 4 or its value differs from the expected v4 value';
  END IF;
  IF (SELECT count(*) FROM ops.protocol_changelog WHERE version = 13) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog
                     WHERE version = 13 AND rule_keys = ARRAY['hard_boundaries', 'report_format']) THEN
    RAISE EXCEPTION '0037: expected exactly one protocol_changelog row at version 13 with rule_keys {hard_boundaries, report_format}';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key NOT IN ('hard_boundaries', 'report_format'))
     IS DISTINCT FROM current_setting('ops_m0037.rules_md5') THEN
    RAISE EXCEPTION '0037: other protocol_rules rows changed';
  END IF;
  RAISE NOTICE '0037 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0037_discovery_bar_rules');

COMMIT;
