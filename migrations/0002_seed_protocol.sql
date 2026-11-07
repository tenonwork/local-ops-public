-- 0002_seed_protocol.sql
-- Seeds the portable protocol: dispatch type taxonomy + protocol rules v1.
-- Run as the schema owner. Deployment-specific values are excluded.
-- Token/cost tracking deliberately absent from report_format: design reopened separately.

BEGIN;

INSERT INTO ops.dispatch_types (type, description, commit_policy, execution_rules) VALUES
('investigation',
 'Read-only diagnosis. Establishes facts before any implementation dispatch. May refuse a false premise.',
 'none',
 '{"phases": ["read", "analyse", "report"], "writes": "none (report only)"}'),
('repair',
 'Fix defective behaviour with a known cause.',
 'local',
 '{"phases": ["read", "implement", "verify", "commit", "report"], "writes": "files named in the dispatch scope"}'),
('addition',
 'Add a new capability.',
 'local',
 '{"phases": ["read", "implement", "verify", "commit", "report"], "writes": "files named in the dispatch scope"}'),
('modification',
 'Change existing behaviour that is not defective.',
 'local',
 '{"phases": ["read", "implement", "verify", "commit", "report"], "writes": "files named in the dispatch scope"}'),
('docs',
 'Documentation-only change. No code or behaviour changes.',
 'local',
 '{"phases": ["read", "edit", "commit", "report"], "writes": "documentation files only"}'),
('chore',
 'Housekeeping with no behaviour change (config, tooling, formatting, log trim).',
 'local',
 '{"phases": ["read", "edit", "verify", "commit", "report"], "writes": "files named in the dispatch scope"}'),
('scaffold',
 'Create a repository, branch or project skeleton where creating the remote is the point.',
 'push',
 '{"phases": ["create", "structure", "initial_commit", "push", "report"], "writes": "new repository or branch only"}'),
('push',
 'Push existing, human-reviewed local commits. No file changes.',
 'push',
 '{"phases": ["read", "push", "report"], "writes": "none (git push only)"}');

INSERT INTO ops.protocol_rules (key, value) VALUES
('session_stale_after',
 '{"hours": 12, "rule": "Active sessions older than this are auto-closed as stale when a new session opens for the same project."}'),
('batch_defaults',
 '{"implementation_max": 3, "investigation_max": 1, "rule": "Per run: up to implementation_max implementation-class items OR investigation_max investigations. projects.params may override. Executor reports the remaining count and stops at the cap."}'),
('verification',
 '{"rule": "The verify phase runs the component''s verify_cmd. A failing verify blocks commit. A component with no verify_cmd cannot receive repair/addition/modification/chore dispatches until one is set."}'),
('report_format',
 '{"fields": ["STATUS", "FILES", "DONE", "VERIFY", "COMMIT", "FOLLOW-UPS"], "rule": "COMMIT states hash and local|pushed|none. The report text goes to complete_dispatch(report); result holds a one-line summary; failures go to fail_dispatch with the error and where execution stopped."}'),
('standing_authorization',
 '{"rule": "The run trigger authorizes fetch, claim, execute and complete without per-item confirmation. It removes confirmation questions only, never safety stops."}'),
('hard_boundaries',
 '{"rules": ["No production access from the executor.", "Read-only types write nothing but their report.", "Touching a file outside scope means stop and report.", "No unlisted dispatch types; a needed new type is reported, and the planner adds it.", "Implementation types commit locally only; pushing happens only through a push dispatch created after human confirmation."]}'),
('recovery_protocol',
 '{"wrong_files": "stop and report", "breaking_change": "revert and report", "unresolved_issue": "record it and recommend a next step", "environment_error": "report to the planner before a new dispatch is created", "false_premise": "stop, fail_dispatch with refused_premise = true, explain what was found"}'),
('prompt_contract',
 '{"rule": "One concern per dispatch: mandatory read-first phase, explicit scope, files to touch, files not to touch, stopping condition, verification phase. Investigation precedes implementation as separate dispatches. dispatch_type is always set explicitly. New dependencies, versions and tool choices are researched planner-side; dispatches pin the choice."}'),
('context_refs_policy',
 '{"rule": "Keep context_refs minimal; every ref is re-read on every turn. Prefer DOC_KEY#Heading section refs over whole documents where a section suffices. Load the union of refs once per run, not once per claim."}');

INSERT INTO ops.protocol_changelog (version, rule_keys, changes) VALUES
(1,
 ARRAY['session_stale_after', 'batch_defaults', 'verification', 'report_format', 'standing_authorization',
       'hard_boundaries', 'recovery_protocol', 'prompt_contract', 'context_refs_policy'],
 'Initial portable protocol, derived from a prior private deployment with deployment-specific values removed. Types commit, release and content excluded. typecheck generalised to component verify_cmd. COST removed from report_format pending the token-tracking design.');

INSERT INTO ops.schema_migrations (version) VALUES ('0002_seed_protocol');

COMMIT;
