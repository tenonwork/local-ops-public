-- 0020_planner_supersedes_rule
-- Dispatch 165d3af3. Staged on 0019; promoted by a separate promote dispatch after planner review.
-- Protocol version 6 -> 7.
-- Decision 24895d45: a decision's supersedes field means replaces (full restatement only); a partial refinement
-- names the old id in its text and leaves supersedes empty; any planner write that sets supersedes waits for the
-- operator's explicit yes. The rule's durable home is the protocol_rules key planner_supersedes.
-- Decision a487976a: this migration adds only the rule; the promote dispatch type row is unchanged.
-- The executor does not apply this rule; it only stores it.
-- A new rule keeps its own version 1 (0007 convention); only the protocol version moves.
-- Writes: one protocol_rules row, one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0019, protocol version 6, no planner_supersedes rule yet;
--       records an md5 of every existing protocol_rules row for the check in step 3
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0019_planner_evidence_rule' THEN
    RAISE EXCEPTION '0020: expected newest ledger version 0019_planner_evidence_rule, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 6 THEN
    RAISE EXCEPTION '0020: expected protocol version 6, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'planner_supersedes') THEN
    RAISE EXCEPTION '0020: protocol rule planner_supersedes already exists';
  END IF;
  PERFORM set_config('ops_m0020.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
END $$;

-- ── 1. the rule (version left at its default of 1)
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'planner_supersedes',
  jsonb_build_object('rule', 'A decision''s supersedes field means replaces: the planner sets it only when the new decision restates the old one in full, changed parts included. A partial refinement names the old decision''s id in its text ("Refines <id8> (n)") and leaves supersedes empty. Any planner write that sets supersedes (log_decision, or a decision item in close_session) is an oversight trigger: the planner shows the operator the payload beside the superseded decision''s text and waits for an explicit yes.')
);

-- ── 2. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  7,
  ARRAY['planner_supersedes'],
  'New rule planner_supersedes: supersedes means replaces (full restatement only; partial refinements name the old id without it); any planner write that sets supersedes waits for the operator''s yes (decision 24895d45).'
);

-- ── 3. checks
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'planner_supersedes' AND version = 1
                    AND value ->> 'rule' = 'A decision''s supersedes field means replaces: the planner sets it only when the new decision restates the old one in full, changed parts included. A partial refinement names the old decision''s id in its text ("Refines <id8> (n)") and leaves supersedes empty. Any planner write that sets supersedes (log_decision, or a decision item in close_session) is an oversight trigger: the planner shows the operator the payload beside the superseded decision''s text and waits for an explicit yes.') THEN
    RAISE EXCEPTION '0020: planner_supersedes row missing, not at version 1, or rule text differs';
  END IF;
  IF (SELECT count(*) FROM ops.protocol_changelog WHERE version = 7) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 7 AND rule_keys = ARRAY['planner_supersedes']) THEN
    RAISE EXCEPTION '0020: expected exactly one protocol_changelog row at version 7 with rule_keys {planner_supersedes}';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'planner_supersedes')
     IS DISTINCT FROM current_setting('ops_m0020.rules_md5') THEN
    RAISE EXCEPTION '0020: other protocol_rules rows changed';
  END IF;
  RAISE NOTICE '0020 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0020_planner_supersedes_rule');

COMMIT;
