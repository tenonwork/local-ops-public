-- 0019_planner_evidence_rule
-- Dispatch e1c6d3c0 (re-dispatch of dd0cc9f6). M5b release 1, staged on 0018; promoted together with 0018.
-- Protocol version 5 -> 6.
-- Decision 6d9b48ed (backlog e6cf8b24): every factual claim the planner writes is sourced. The rule's durable home
-- is the protocol_rules key planner_evidence (until now the text lived in the ops chat skill, §6 Evidence).
-- The executor does not apply this rule; it only stores it.
-- A new rule keeps its own version 1 (0007 convention); only the protocol version moves.
-- Writes: one protocol_rules row, one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0018, protocol version 5, no planner_evidence rule yet;
--       records an md5 of every existing protocol_rules row for the check in step 3
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0018_node_keyed_functions' THEN
    RAISE EXCEPTION '0019: expected newest ledger version 0018_node_keyed_functions, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION '0019: expected protocol version 5, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'planner_evidence') THEN
    RAISE EXCEPTION '0019: protocol rule planner_evidence already exists';
  END IF;
  PERFORM set_config('ops_m0019.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
END $$;

-- ── 1. the rule (version left at its default of 1)
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'planner_evidence',
  jsonb_build_object('rule', 'Every factual claim the planner writes (backlog item, decision, session summary, review, message to the operator) names its source: a query, a report line, a tool result, or a file read this session. A claim without one is written as a hypothesis ("unverified: ...") and is never the basis for a severity, a decision or a dispatch premise.')
);

-- ── 2. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  6,
  ARRAY['planner_evidence'],
  'New rule planner_evidence: planner claims name their source; unsourced claims are hypotheses and never the basis for a severity, decision or dispatch premise (decision 6d9b48ed, backlog e6cf8b24).'
);

-- ── 3. checks
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'planner_evidence' AND version = 1
                    AND value ->> 'rule' = 'Every factual claim the planner writes (backlog item, decision, session summary, review, message to the operator) names its source: a query, a report line, a tool result, or a file read this session. A claim without one is written as a hypothesis ("unverified: ...") and is never the basis for a severity, a decision or a dispatch premise.') THEN
    RAISE EXCEPTION '0019: planner_evidence row missing, not at version 1, or rule text differs';
  END IF;
  IF (SELECT count(*) FROM ops.protocol_changelog WHERE version = 6) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 6 AND rule_keys = ARRAY['planner_evidence']) THEN
    RAISE EXCEPTION '0019: expected exactly one protocol_changelog row at version 6 with rule_keys {planner_evidence}';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'planner_evidence')
     IS DISTINCT FROM current_setting('ops_m0019.rules_md5') THEN
    RAISE EXCEPTION '0019: other protocol_rules rows changed';
  END IF;
  RAISE NOTICE '0019 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0019_planner_evidence_rule');

COMMIT;
