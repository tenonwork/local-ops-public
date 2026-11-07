-- 0009_spine_m2_columns
-- Dispatch 1704329e. M2 of the staged spine (685cce74): nullable columns on existing tables. M1 (0008) created
-- the new tables; B backfills, M3 adds defaults, NOT NULL and UNIQUE after checks, M4 adds functions with
-- shims, M5 cleans up.
-- Decisions:
--   5633b4b2 every column added to an existing table belongs to M2: sessions segment columns and path_id,
--            dispatch_types.project_id, backlog_items home_node_id/severity/kind/resolved_by,
--            context_documents node_id/doc_type/trust columns, decisions.trust_status.
--   8ee27f17 every new column is nullable with no default (a constant default on ADD COLUMN fills existing
--            rows, which is a hidden backfill). B fills rows; M3 adds defaults and NOT NULL. usage_open and
--            usage_close are percentages 0-100, nullable, check-bounded.
--   abaddc75 segment task status is its own column sessions.task_status (open | unfinished | closed);
--            sessions.status (active | closed) stays the row lifecycle and is untouched.
--   e64cc4b0 the segment handoff reference is sessions.resumed_from (FK sessions.id), the segment this one
--            continues.
--   3c34b680 / d63be90f ops.sessions rows are segments, ids kept. A segment gains window_id (FK ops.windows),
--            scope (global | project), task status, usage at open and close, the handoff reference and
--            path_id.
--   0d63966b R7 / c61b66ea dispatch_types gains nullable project_id (null = portable); type stays the PK, so
--            type names stay unique across scopes.
--   Stage 2 spine spec: project_id becomes nullable on sessions, decisions, context_documents, backlog_items
--            and components (framework rows hang off the global node with no project; the local-ops project
--            row is deleted in B after its rows move). dispatches.project_id stays NOT NULL.
--   8faeee76 extension objects are schema-qualified; M2 adds no ltree columns.
-- Composite FKs (component_id, project_id) -> components(id, project_id) are MATCH SIMPLE: a row with
-- project_id null is not checked against its component at all. M3/M4 restore that rule.
-- No existing column changes other than project_id DROP NOT NULL; no rows, functions, triggers or grants
-- change. Table-level planner INSERT/UPDATE grants cover the new columns.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── Enums (ops.trust_status comes from 0008)
CREATE TYPE ops.segment_scope    AS ENUM ('global', 'project');
CREATE TYPE ops.task_status      AS ENUM ('open', 'unfinished', 'closed');
CREATE TYPE ops.backlog_severity AS ENUM ('low', 'medium', 'high', 'critical', 'untriaged');
CREATE TYPE ops.backlog_kind     AS ENUM ('task', 'followup', 'proposal', 'discussion', 'allowed_bug');

-- ── Sessions (segments)
ALTER TABLE ops.sessions
  ADD COLUMN window_id     uuid REFERENCES ops.windows(id),
  ADD COLUMN scope         ops.segment_scope,
  ADD COLUMN task_status   ops.task_status,
  ADD COLUMN usage_open    numeric(5,2) CONSTRAINT sessions_usage_open_check  CHECK (usage_open  BETWEEN 0 AND 100),
  ADD COLUMN usage_close   numeric(5,2) CONSTRAINT sessions_usage_close_check CHECK (usage_close BETWEEN 0 AND 100),
  ADD COLUMN resumed_from  uuid REFERENCES ops.sessions(id),
  ADD COLUMN path_id       uuid REFERENCES ops.path_log(id),
  ALTER COLUMN project_id DROP NOT NULL;
CREATE INDEX sessions_window_idx ON ops.sessions (window_id);

-- ── Registry
ALTER TABLE ops.projects
  ADD COLUMN node_id uuid REFERENCES ops.nodes(id);          -- UNIQUE and NOT NULL arrive in M3

ALTER TABLE ops.components
  ADD COLUMN node_id uuid REFERENCES ops.nodes(id),
  ALTER COLUMN project_id DROP NOT NULL;

ALTER TABLE ops.dispatch_types
  ADD COLUMN project_id uuid REFERENCES ops.projects(id);   -- permanently nullable: null = portable

-- ── Context documents
ALTER TABLE ops.context_documents
  ADD COLUMN node_id       uuid REFERENCES ops.nodes(id),
  ADD COLUMN doc_type      text REFERENCES ops.doc_types(key),
  ADD COLUMN trust_status  ops.trust_status,
  ADD COLUMN reviewed_at   timestamptz,
  ADD COLUMN stale_since   timestamptz,
  ADD COLUMN use_count     integer CONSTRAINT context_documents_use_count_check CHECK (use_count >= 0),
  ADD COLUMN last_used_at  timestamptz,
  ALTER COLUMN project_id DROP NOT NULL;
CREATE INDEX context_documents_node_idx ON ops.context_documents (node_id);   -- UNIQUE (node_id, doc_type) in M3

-- ── Decisions
ALTER TABLE ops.decisions
  ADD COLUMN trust_status ops.trust_status,
  ALTER COLUMN project_id DROP NOT NULL;

-- ── Backlog
ALTER TABLE ops.backlog_items
  ADD COLUMN home_node_id  uuid REFERENCES ops.nodes(id),
  ADD COLUMN severity      ops.backlog_severity,
  ADD COLUMN kind          ops.backlog_kind,
  ADD COLUMN resolved_by   uuid REFERENCES ops.work_log(id),
  ALTER COLUMN project_id DROP NOT NULL;
CREATE INDEX backlog_items_home_node_idx ON ops.backlog_items (home_node_id);

INSERT INTO ops.schema_migrations (version) VALUES ('0009_spine_m2_columns');

COMMIT;
