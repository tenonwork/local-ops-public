-- 0004_secret_handling_incidents
-- Lands backlog 3e509fc8 (planning session d0f5814f). Protocol version 1 -> 2.
-- (1) hard_boundaries: executor must never print secret-bearing files.
-- (2) report_format: mandatory INCIDENTS section, also on failures.
-- Repaired to the runner contract (BEGIN/COMMIT + ledger row) after an out-of-band apply; see 95ccaf96.

BEGIN;

UPDATE ops.protocol_rules
SET value = jsonb_set(
      value,
      '{rules}',
      (value -> 'rules') || jsonb_build_array(
        'Never print, cat, echo, open in output or log the contents of secret-bearing files (.env, .env.*, pgpass.conf, credential or key files). Check key names or presence only, never values. If a secret appears in output anyway, stop and record it under INCIDENTS.'
      )
    ),
    version = version + 1,
    updated_at = now()
WHERE key = 'hard_boundaries';

UPDATE ops.protocol_rules
SET value = jsonb_build_object(
      'rule', 'COMMIT states hash and local|pushed|none. INCIDENTS is mandatory: write "none", or list each incident (secret exposure, out-of-scope file touched, production contact, safety stop) with what happened, what was exposed or affected, and what was done about it. The report text goes to complete_dispatch(report); result holds a one-line summary; failures go to fail_dispatch with the error and where execution stopped, and still include INCIDENTS.',
      'fields', jsonb_build_array('STATUS', 'FILES', 'DONE', 'VERIFY', 'COMMIT', 'INCIDENTS', 'FOLLOW-UPS')
    ),
    version = version + 1,
    updated_at = now()
WHERE key = 'report_format';

INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  2,
  ARRAY['hard_boundaries', 'report_format'],
  'Executor secret-handling rule added to hard_boundaries; mandatory INCIDENTS section added to report_format, including on failures (backlog 3e509fc8).'
);

INSERT INTO ops.schema_migrations (version) VALUES ('0004_secret_handling_incidents');

COMMIT;
