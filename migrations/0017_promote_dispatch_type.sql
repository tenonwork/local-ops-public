-- 0017_promote_dispatch_type
-- Dispatch 0fe30a14. Release pipeline bootstrap, database side. Protocol version 4 -> 5.
-- Decisions (inlined in the dispatch):
--   15d47a9a (supersedes 7ec602fc) production promotes move into a release pipeline: migrations accumulate in
--            staging (local_ops_rehearsal); on operator approval the planner creates a promote dispatch, records
--            prod_apply_approved against it, and the executor runs it. This migration, which adds the promote
--            type, is the one bootstrap exception: it is promoted on a typed operator instruction.
--   bcc002fd approval is one gate row naming the whole set (version:checksum pairs), anchored to the promote
--            dispatch; production reach is enforced in the runner (a later dispatch; scripts/ not changed here).
-- (1) dispatch_types: new portable type promote, commit_policy none (batched alone, as investigation-class).
-- (2) hard_boundaries: rule 1 (executor production access) and rule 2 (read-only types) reworded in place;
--     every other rule and the order are kept.
-- (3) protocol_changelog version 5.
-- Writes: one dispatch_types row, one protocol_rules update, one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0016, and promote does not exist yet
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0016_spine_m5a_cleanup' THEN
    RAISE EXCEPTION '0017: expected newest ledger version 0016_spine_m5a_cleanup, found %', v_newest;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.dispatch_types WHERE type = 'promote') THEN
    RAISE EXCEPTION '0017: dispatch type promote already exists';
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION '0017: expected protocol version 4, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  PERFORM set_config('ops_m0017.rule_count',
    (SELECT jsonb_array_length(value -> 'rules') FROM ops.protocol_rules WHERE key = 'hard_boundaries')::text, true);
END $$;

-- ── 1. promote dispatch type
INSERT INTO ops.dispatch_types (type, description, commit_policy, execution_rules, active, project_id)
VALUES (
  'promote',
  'Promote the approved migration set to production through node scripts/migrate.ts promote. No repo file changes.',
  'none',
  '{"phases": ["read", "dry_run", "promote", "verify", "report"], "writes": "production database only, through node scripts/migrate.ts promote <dispatch_id>; no repo files", "requires": "a prod_apply_approved gate recorded by the planner against this dispatch, naming every version and checksum in the set"}'::jsonb,
  true,
  NULL
);

-- ── 2. hard_boundaries rules 1 and 2, matched by exact text, replaced in place
DO $$
DECLARE
  v_old1 constant text := 'No production access from the executor.';
  v_new1 constant text := 'No production access from the executor except through node scripts/migrate.ts refresh-rehearsal (read-only dump of production) and node scripts/migrate.ts promote, and promote only within a promote dispatch whose approval the planner has recorded.';
  v_old2 constant text := 'Read-only types write nothing but their report.';
  v_new2 constant text := 'Read-only types (investigation) write nothing but their report.';
  v_rules jsonb;
BEGIN
  SELECT value -> 'rules' INTO v_rules FROM ops.protocol_rules WHERE key = 'hard_boundaries';
  IF (SELECT count(*) FROM jsonb_array_elements_text(v_rules) r WHERE r = v_old1) <> 1 THEN
    RAISE EXCEPTION '0017: hard_boundaries rule "%" not found exactly once', v_old1;
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements_text(v_rules) r WHERE r = v_old2) <> 1 THEN
    RAISE EXCEPTION '0017: hard_boundaries rule "%" not found exactly once', v_old2;
  END IF;

  UPDATE ops.protocol_rules
  SET value = jsonb_set(value, '{rules}', (
        SELECT jsonb_agg(CASE r WHEN v_old1 THEN v_new1 WHEN v_old2 THEN v_new2 ELSE r END ORDER BY n)
          FROM jsonb_array_elements_text(v_rules) WITH ORDINALITY AS t(r, n))),
      version = version + 1,
      updated_at = now()
  WHERE key = 'hard_boundaries';
END $$;

-- ── 3. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  5,
  ARRAY['hard_boundaries'],
  'Executor production access limited to migrate.ts refresh-rehearsal and promote, promote only within an approved promote dispatch; read-only types named (investigation). New dispatch type promote (decisions 15d47a9a, bcc002fd).'
);

-- ── 4. checks
DO $$
DECLARE v_rules jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.dispatch_types
                  WHERE type = 'promote' AND commit_policy = 'none' AND active AND project_id IS NULL) THEN
    RAISE EXCEPTION '0017: promote type missing or not commit_policy none / active / portable';
  END IF;

  SELECT value -> 'rules' INTO v_rules FROM ops.protocol_rules WHERE key = 'hard_boundaries';
  IF (SELECT count(*) FROM jsonb_array_elements_text(v_rules) r
       WHERE r = 'No production access from the executor except through node scripts/migrate.ts refresh-rehearsal (read-only dump of production) and node scripts/migrate.ts promote, and promote only within a promote dispatch whose approval the planner has recorded.') <> 1
     OR (SELECT count(*) FROM jsonb_array_elements_text(v_rules) r
          WHERE r = 'Read-only types (investigation) write nothing but their report.') <> 1
     OR (SELECT count(*) FROM jsonb_array_elements_text(v_rules) r
          WHERE r IN ('No production access from the executor.', 'Read-only types write nothing but their report.')) <> 0 THEN
    RAISE EXCEPTION '0017: hard_boundaries does not hold exactly the new rule 1 and rule 2 texts';
  END IF;
  IF jsonb_array_length(v_rules) <> current_setting('ops_m0017.rule_count')::int THEN
    RAISE EXCEPTION '0017: hard_boundaries rule count changed: % -> %',
      current_setting('ops_m0017.rule_count'), jsonb_array_length(v_rules);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 5 AND rule_keys = ARRAY['hard_boundaries']) THEN
    RAISE EXCEPTION '0017: protocol_changelog version 5 missing';
  END IF;
  RAISE NOTICE '0017 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0017_promote_dispatch_type');

COMMIT;
