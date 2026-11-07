-- 0030_read_first_order_v2
-- Dispatch a0e9e3c4. Work-log release, migration 3 of 4. Staged on 0029; 0028-0031 are promoted later as one set.
-- Protocol version 9 -> 10.
-- Decision 2346fdf9 (refines a467374f): the work log replaces CLAUDE_LOG.md outright. CLAUDE_LOG.md leaves the
-- read-first order; claim_dispatch delivers the ops.work_log rows relevant to the dispatch (rule work_log_delivery,
-- added by 0028). Rules live in ops.protocol_rules, one home per rule; an amended rule is updated in place with
-- version + 1 and a protocol_changelog row (0017 precedent).
-- Writes: one protocol_rules update (read_first_order v1 -> v2), one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0029, protocol version 9, read_first_order at version 1 with exactly
--       the 0025 value, no changelog row at version 10; records an md5 of every other protocol_rules row for step 3
DO $$
DECLARE v_newest text;
        v_v1 constant jsonb := jsonb_build_object(
          'order', jsonb_build_array('global node context', 'CLAUDE.md', 'CLAUDE_LOG.md', 'task files'),
          'rule', 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then CLAUDE_LOG.md, then the task files only. Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.');
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0029_dispatch_task_files' THEN
    RAISE EXCEPTION '0030: expected newest ledger version 0029_dispatch_task_files, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION '0030: expected protocol version 9, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'read_first_order' AND version = 1
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['order', 'rule']
                    AND value::text = v_v1::text) THEN
    RAISE EXCEPTION '0030: read_first_order missing, not at version 1, or its value differs from the 0025 value';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 10) THEN
    RAISE EXCEPTION '0030: a protocol_changelog row at version 10 already exists';
  END IF;
  PERFORM set_config('ops_m0030.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
       FROM ops.protocol_rules WHERE key <> 'read_first_order'), true);
END $$;

-- ── 1. the rule, version 2
UPDATE ops.protocol_rules
SET value = jsonb_build_object(
      'order', jsonb_build_array('global node context', 'CLAUDE.md', 'task files'),
      'rule', 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then the task files only. CLAUDE_LOG.md is not read: the change history is ops.work_log, and claim_dispatch delivers the rows relevant to the dispatch''s node and task files (work_log_delivery). Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.'),
    version = 2,
    updated_at = now()
WHERE key = 'read_first_order';

-- ── 2. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  10,
  ARRAY['read_first_order'],
  'read_first_order v2: CLAUDE_LOG.md leaves the read-first order; the work log (ops.work_log, delivered at claim per work_log_delivery) replaces it (decisions 2346fdf9, a467374f).'
);

-- ── 3. checks
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'read_first_order' AND version = 2
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['order', 'rule']
                    AND value -> 'order' = jsonb_build_array('global node context', 'CLAUDE.md', 'task files')
                    AND value ->> 'rule' = 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then the task files only. CLAUDE_LOG.md is not read: the change history is ops.work_log, and claim_dispatch delivers the rows relevant to the dispatch''s node and task files (work_log_delivery). Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.') THEN
    RAISE EXCEPTION '0030: read_first_order row missing, not at version 2, keys not exactly {order, rule}, or values differ';
  END IF;
  IF (SELECT count(*) FROM ops.protocol_changelog WHERE version = 10) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 10 AND rule_keys = ARRAY['read_first_order']) THEN
    RAISE EXCEPTION '0030: expected exactly one protocol_changelog row at version 10 with rule_keys {read_first_order}';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'read_first_order')
     IS DISTINCT FROM current_setting('ops_m0030.rules_md5') THEN
    RAISE EXCEPTION '0030: other protocol_rules rows changed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'work_log_delivery') THEN
    RAISE EXCEPTION '0030: protocol rule work_log_delivery missing';
  END IF;
  RAISE NOTICE '0030 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0030_read_first_order_v2');

COMMIT;
