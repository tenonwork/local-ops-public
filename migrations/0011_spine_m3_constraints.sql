-- 0011_spine_m3_constraints
-- Dispatch 2e817d8e. M3 of the staged spine (685cce74): constraints after checks. M1 (0008) created the new
-- tables, M2 (0009) the nullable columns, B (0010) the backfill; M4 adds functions with shims, M5 cleans up.
-- Decisions:
--   275da438 NOT NULL only on M2 columns that can take a static default. backlog_items.home_node_id and
--            backlog_items.kind stay nullable (NOT NULL in M4, once the MCP tools write them); projects.node_id
--            and components.node_id stay nullable (create_project / create_component do not write them yet).
--            ops._spine_backfill() is called first to catch up rows written since 0010, and is kept: M4 drops it.
--   b01977b7 defaults: sessions.scope 'global', sessions.task_status 'open', backlog_items.severity 'untriaged',
--            decisions.trust_status 'approved', context_documents.trust_status 'approved'.
--            dispatch_types.project_id stays nullable (null = global type).
--   6b29db79 a closed session with task_status 'open' is drift; corrected once here with the 2eecc405 mapping
--            (closed -> closed, stale -> unfinished).
--   2eecc405 sessions.window_id, resumed_from, usage_open, usage_close and path_id stay nullable, no default.
--   112120be the component-belongs-to-project rule (011b32a8) is not part of 0011.
--   8faeee76 ltree lives in public; 0011 compares no ltree values.
-- context_documents has 0 rows, so node_id and doc_type take NOT NULL with no default and no fill.
-- Writes: the helper's fill (NULL M2 columns, missing nodes and links) and the step 3 task_status correction.
-- The md5 fingerprint of the pre-M2 columns (same method as 0010) proves nothing else changed; the sessions
-- rows step 3 corrects are excluded by id (task_status is an M2 column, so this only narrows the check).
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── fingerprint of the pre-M2 columns, before any write; step 3 rows are known now (the helper never
--    sets task_status 'open' on a closed session) and are excluded from the sessions part by id
DO $$
DECLARE v_ids uuid[];
BEGIN
  SELECT coalesce(array_agg(id ORDER BY id), '{}') INTO v_ids
    FROM ops.sessions WHERE status = 'closed' AND task_status = 'open';
  PERFORM set_config('ops_spine_m3.step3_ids', v_ids::text, true);
  PERFORM set_config('ops_spine_m3.fp_before', (
    SELECT jsonb_build_object(
      'sessions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['window_id', 'scope', 'task_status', 'usage_open',
                     'usage_close', 'resumed_from', 'path_id'])::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.sessions t WHERE t.id <> ALL (v_ids)),
      'decisions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'trust_status')::text, E'\n' ORDER BY t.id), ''))
                      FROM ops.decisions t),
      'backlog_items', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['home_node_id', 'severity', 'kind',
                          'resolved_by'])::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
      'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
      'projects', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.projects t),
      'components', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                       FROM ops.components t))::text), true);
  RAISE NOTICE 'fingerprint before: %', current_setting('ops_spine_m3.fp_before');
  RAISE NOTICE 'closed sessions with task_status open: %', cardinality(v_ids);
END $$;

-- ── 2. catch-up fill of rows written since 0010
DO $$ BEGIN
  RAISE NOTICE 'spine backfill: %', ops._spine_backfill();
END $$;

-- ── 3. task_status drift on closed sessions (2eecc405 / 6b29db79)
DO $$
DECLARE v_ids uuid[];
BEGIN
  WITH u AS (
    UPDATE ops.sessions
       SET task_status = CASE WHEN close_reason = 'stale' THEN 'unfinished' ELSE 'closed' END::ops.task_status
     WHERE status = 'closed' AND task_status = 'open'
    RETURNING id)
  SELECT coalesce(array_agg(id ORDER BY id), '{}') INTO v_ids FROM u;
  IF v_ids <> current_setting('ops_spine_m3.step3_ids')::uuid[] THEN
    RAISE EXCEPTION 'task_status correction touched % rows, expected %', v_ids, current_setting('ops_spine_m3.step3_ids');
  END IF;
  RAISE NOTICE 'task_status corrected on % closed sessions', cardinality(v_ids);
END $$;

-- ── 4. defaults and NOT NULL
ALTER TABLE ops.sessions
  ALTER COLUMN scope       SET DEFAULT 'global',
  ALTER COLUMN scope       SET NOT NULL,
  ALTER COLUMN task_status SET DEFAULT 'open',
  ALTER COLUMN task_status SET NOT NULL;

ALTER TABLE ops.backlog_items
  ALTER COLUMN severity SET DEFAULT 'untriaged',
  ALTER COLUMN severity SET NOT NULL;

ALTER TABLE ops.decisions
  ALTER COLUMN trust_status SET DEFAULT 'approved',
  ALTER COLUMN trust_status SET NOT NULL;

ALTER TABLE ops.context_documents
  ALTER COLUMN trust_status SET DEFAULT 'approved',
  ALTER COLUMN trust_status SET NOT NULL,
  ALTER COLUMN node_id      SET NOT NULL,
  ALTER COLUMN doc_type     SET NOT NULL;

-- ── 5. unique node keys
ALTER TABLE ops.projects
  ADD CONSTRAINT projects_node_id_key UNIQUE (node_id);
ALTER TABLE ops.context_documents
  ADD CONSTRAINT context_documents_node_id_doc_type_key UNIQUE (node_id, doc_type);

-- ── 6. checks: any failure aborts the migration
DO $$
DECLARE v_after text; v_bad text; v_ids uuid[] := current_setting('ops_spine_m3.step3_ids')::uuid[];
BEGIN
  -- catalog: NOT NULL with the expected default (NULL = no default)
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_bad
    FROM (VALUES ('sessions', 'scope', 'global'), ('sessions', 'task_status', 'open'),
                 ('backlog_items', 'severity', 'untriaged'), ('decisions', 'trust_status', 'approved'),
                 ('context_documents', 'trust_status', 'approved'),
                 ('context_documents', 'node_id', NULL), ('context_documents', 'doc_type', NULL)) e(t, c, d)
    LEFT JOIN information_schema.columns k
      ON k.table_schema = 'ops' AND k.table_name = e.t AND k.column_name = e.c
   WHERE k.is_nullable IS DISTINCT FROM 'NO'
      OR split_part(k.column_default, '::', 1) IS DISTINCT FROM quote_literal(e.d);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'columns without NOT NULL and the expected default: %', v_bad;
  END IF;

  -- catalog: still nullable, no default
  SELECT string_agg(e.t || '.' || e.c, ', ') INTO v_bad
    FROM (VALUES ('backlog_items', 'home_node_id'), ('backlog_items', 'kind'), ('projects', 'node_id'),
                 ('components', 'node_id'), ('dispatch_types', 'project_id'), ('sessions', 'window_id'),
                 ('sessions', 'resumed_from'), ('sessions', 'usage_open'), ('sessions', 'usage_close'),
                 ('sessions', 'path_id')) e(t, c)
    LEFT JOIN information_schema.columns k
      ON k.table_schema = 'ops' AND k.table_name = e.t AND k.column_name = e.c
   WHERE k.is_nullable IS DISTINCT FROM 'YES' OR k.column_default IS NOT NULL;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'columns that must stay nullable with no default: %', v_bad;
  END IF;

  IF (SELECT array_agg(conname::text ORDER BY conname) FROM pg_constraint
       WHERE contype = 'u' AND conname IN ('projects_node_id_key', 'context_documents_node_id_doc_type_key')
         AND connamespace = 'ops'::regnamespace)
     IS DISTINCT FROM ARRAY['context_documents_node_id_doc_type_key', 'projects_node_id_key'] THEN
    RAISE EXCEPTION 'unique constraints missing';
  END IF;

  IF EXISTS (SELECT 1 FROM ops.sessions WHERE status = 'closed' AND task_status = 'open') THEN
    RAISE EXCEPTION 'closed sessions with task_status open remain';
  END IF;

  SELECT jsonb_build_object(
      'sessions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['window_id', 'scope', 'task_status', 'usage_open',
                     'usage_close', 'resumed_from', 'path_id'])::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.sessions t WHERE t.id <> ALL (v_ids)),
      'decisions', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'trust_status')::text, E'\n' ORDER BY t.id), ''))
                      FROM ops.decisions t),
      'backlog_items', (SELECT md5(coalesce(string_agg((to_jsonb(t) - ARRAY['home_node_id', 'severity', 'kind',
                          'resolved_by'])::text, E'\n' ORDER BY t.id), '')) FROM ops.backlog_items t),
      'dispatches', (SELECT md5(coalesce(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM ops.dispatches t),
      'projects', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                     FROM ops.projects t),
      'components', (SELECT md5(coalesce(string_agg((to_jsonb(t) - 'node_id')::text, E'\n' ORDER BY t.id), ''))
                       FROM ops.components t))::text
    INTO v_after;
  RAISE NOTICE 'fingerprint after:  %', v_after;
  IF v_after::jsonb <> current_setting('ops_spine_m3.fp_before')::jsonb THEN
    RAISE EXCEPTION '0011 changed pre-existing columns';
  END IF;
  RAISE NOTICE 'spine M3 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0011_spine_m3_constraints');

COMMIT;
