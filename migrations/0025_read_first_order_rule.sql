-- 0025_read_first_order_rule
-- Dispatch 29a28a81. Release 3, migration 2 of 4. Staged on 0024; 0024-0027 are promoted later as one set.
-- Protocol version 7 -> 8.
-- Decision b2427ed1: global context lives at the global node as context documents, not in a GLOBAL.md file.
-- Read-first order: global node context -> CLAUDE.md -> CLAUDE_LOG.md -> task files only. The global slot stays in
-- the order but is empty until the global node has context documents; until then dispatches state
-- "global node context: none yet". The executor reads global context through resolve_context / context_refs.
-- Decision 62cae5ec: rules live in ops.protocol_rules, one home per rule; read_first_order is one of them.
-- A new rule keeps its own version 1 (0007 convention); only the protocol version moves.
-- Writes: one protocol_rules row, one protocol_changelog row.

BEGIN;

-- ── 0. guard: the ledger's newest version is 0024, protocol version 7, no read_first_order rule yet;
--       records an md5 of every existing protocol_rules row for the check in step 3
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0024_promote_approval_claim_gate' THEN
    RAISE EXCEPTION '0025: expected newest ledger version 0024_promote_approval_claim_gate, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 7 THEN
    RAISE EXCEPTION '0025: expected protocol version 7, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'read_first_order') THEN
    RAISE EXCEPTION '0025: protocol rule read_first_order already exists';
  END IF;
  PERFORM set_config('ops_m0025.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
END $$;

-- ── 1. the rule (version left at its default of 1)
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'read_first_order',
  jsonb_build_object(
    'order', jsonb_build_array('global node context', 'CLAUDE.md', 'CLAUDE_LOG.md', 'task files'),
    'rule', 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then CLAUDE_LOG.md, then the task files only. Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.')
);

-- ── 2. changelog
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  8,
  ARRAY['read_first_order'],
  'New rule read_first_order: global node context (via resolve_context; "none yet" while empty) -> CLAUDE.md -> CLAUDE_LOG.md -> task files only (decisions b2427ed1, 62cae5ec).'
);

-- ── 3. checks
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules
                  WHERE key = 'read_first_order' AND version = 1
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['order', 'rule']
                    AND value -> 'order' = jsonb_build_array('global node context', 'CLAUDE.md', 'CLAUDE_LOG.md', 'task files')
                    AND value ->> 'rule' = 'Every dispatch''s READ FIRST phase loads context in this order: global node context, then CLAUDE.md, then CLAUDE_LOG.md, then the task files only. Global node context is the global node''s context documents, read through resolve_context / context_refs; it is never a file such as GLOBAL.md. While the global node has no context documents, the dispatch states "global node context: none yet" and keeps the slot.') THEN
    RAISE EXCEPTION '0025: read_first_order row missing, not at version 1, keys not exactly {order, rule}, or values differ';
  END IF;
  IF (SELECT count(*) FROM ops.protocol_changelog WHERE version = 8) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 8 AND rule_keys = ARRAY['read_first_order']) THEN
    RAISE EXCEPTION '0025: expected exactly one protocol_changelog row at version 8 with rule_keys {read_first_order}';
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'read_first_order')
     IS DISTINCT FROM current_setting('ops_m0025.rules_md5') THEN
    RAISE EXCEPTION '0025: other protocol_rules rows changed';
  END IF;
  RAISE NOTICE '0025 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0025_read_first_order_rule');

COMMIT;
