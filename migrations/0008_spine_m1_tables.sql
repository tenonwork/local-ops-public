-- 0008_spine_m1_tables
-- Dispatch 233e7323. M1 of the staged spine (685cce74): new objects only. M2 adds nullable columns to
-- existing tables, B backfills, M3 adds constraints after checks, M4 adds functions with shims, M5 cleans up.
-- Decisions:
--   5633b4b2 M1 creates extensions, new tables, the four link tables and the node_links view; no existing
--            table is altered (every new column on an existing table is M2).
--   68b68b89 document_versions starts empty; no trigger on context_documents (the fill trigger is M4).
--   b4b9b351 session_docs: append-only versioned rows keyed by segment (sessions.id); no trust columns;
--            never served by the loader.
--   290df264 seeds: entry_types feature, fix, refactor, migration, config, data, docs, investigation, chore;
--            doc_types manual. Nothing else.
--   8faeee76 ltree and pg_trgm in public, created here (IF NOT EXISTS). Every ops function pins
--            search_path = ops, pg_temp, so types, operators and functions from them are schema-qualified
--            (public.ltree, OPERATOR(public.||), OPERATOR(public.<@), public.nlevel()).
--   3c34b680 / d63be90f ops.sessions rows are segments, ids kept; session_docs and path_log key on sessions.id.
--   0d63966b R9 document versions record change_kind (addition | update) and source decision ids.
-- No writes are granted: planner reads every new object, executor reads nodes, doc_types, entry_types and
-- node_paths. Writes arrive as M4 functions.
-- No owner role is named: objects belong to the applying role (local_ops in production, ops_dev in rehearsal).

BEGIN;

-- ── Extensions
CREATE EXTENSION IF NOT EXISTS ltree   SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;

-- ── Enums
CREATE TYPE ops.node_kind      AS ENUM ('global', 'project', 'node');
CREATE TYPE ops.node_status    AS ENUM ('active', 'archived');
CREATE TYPE ops.trust_status   AS ENUM ('approved', 'imported', 'draft');
CREATE TYPE ops.change_kind    AS ENUM ('addition', 'update');
CREATE TYPE ops.work_origin    AS ENUM ('chat', 'code', 'operator');
CREATE TYPE ops.claim_class    AS ENUM ('mechanical', 'interpretive');
CREATE TYPE ops.finding_status AS ENUM ('open', 'auto_verified', 'approved', 'rejected', 'promoted', 'superseded');
CREATE TYPE ops.block_scope    AS ENUM ('node', 'subtree');
CREATE TYPE ops.path_outcome   AS ENUM ('accepted', 'corrected', 'rejected');

-- ── Context tree
CREATE TABLE ops.nodes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id     uuid REFERENCES ops.nodes(id),
  key           text NOT NULL CHECK (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  path          public.ltree NOT NULL UNIQUE,              -- set by nodes_before_insert
  kind          ops.node_kind NOT NULL,
  title         text NOT NULL,
  summary       text,
  component_id  uuid UNIQUE REFERENCES ops.components(id),
  status        ops.node_status NOT NULL DEFAULT 'active',
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (parent_id, key),
  CONSTRAINT nodes_parent_kind_check CHECK ((parent_id IS NULL) = (kind = 'global'))
);
CREATE UNIQUE INDEX nodes_one_global ON ops.nodes ((true)) WHERE kind = 'global';
CREATE INDEX nodes_path_gist ON ops.nodes USING gist (path public.gist_ltree_ops);

-- path = key for the global node, else parent.path || key; any supplied path is overwritten.
CREATE FUNCTION ops._nodes_before_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = ops, pg_temp AS $$
DECLARE p ops.nodes;
BEGIN
  -- the key CHECK runs after this trigger; test it here so a bad key is not an ltree syntax error
  IF NEW.key IS NULL OR NEW.key !~ '^[a-z0-9][a-z0-9_-]*$' THEN
    RAISE EXCEPTION 'invalid node key "%"', NEW.key USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.kind = 'global' THEN
    IF NEW.parent_id IS NOT NULL THEN
      RAISE EXCEPTION 'the global node cannot have a parent' USING ERRCODE = 'check_violation';
    END IF;
    NEW.path := NEW.key::public.ltree;
    RETURN NEW;
  END IF;

  IF NEW.parent_id IS NULL THEN
    RAISE EXCEPTION '% node "%" needs a parent', NEW.kind, NEW.key USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO p FROM ops.nodes WHERE id = NEW.parent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parent node % does not exist', NEW.parent_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF p.status = 'archived' THEN
    RAISE EXCEPTION 'parent node % is archived', p.path::text USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.kind = 'project' AND p.kind <> 'global' THEN
    RAISE EXCEPTION 'project node "%" must sit under the global node, not %', NEW.key, p.path::text
      USING ERRCODE = 'check_violation';
  END IF;
  NEW.path := p.path OPERATOR(public.||) NEW.key::public.ltree;
  RETURN NEW;
END $$;

-- re-parenting arrives with move_node in M4
CREATE FUNCTION ops._nodes_before_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = ops, pg_temp AS $$
BEGIN
  IF NEW.parent_id IS DISTINCT FROM OLD.parent_id OR NEW.key IS DISTINCT FROM OLD.key
     OR NEW.path::text IS DISTINCT FROM OLD.path::text      -- ltree's = lives in public, off this search_path
     OR NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'node %: parent_id, key, path and kind cannot change', OLD.path::text
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER nodes_before_insert BEFORE INSERT ON ops.nodes
  FOR EACH ROW EXECUTE FUNCTION ops._nodes_before_insert();
CREATE TRIGGER nodes_before_update BEFORE UPDATE ON ops.nodes
  FOR EACH ROW EXECUTE FUNCTION ops._nodes_before_update();

-- ── Registries
CREATE TABLE ops.doc_types (
  key                 text PRIMARY KEY CHECK (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  label               text NOT NULL,
  description         text NOT NULL CHECK (length(btrim(description)) > 0),
  created_in_session  uuid REFERENCES ops.sessions(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.entry_types (
  key                 text PRIMARY KEY CHECK (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  label               text NOT NULL,
  description         text NOT NULL CHECK (length(btrim(description)) > 0),
  created_in_session  uuid REFERENCES ops.sessions(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- ── Document versions (empty; filled by the M4 trigger on context_documents)
CREATE TABLE ops.document_versions (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  document_id          uuid NOT NULL REFERENCES ops.context_documents(id),
  version              integer NOT NULL,
  content              text NOT NULL,
  summary              text,
  trust_status         ops.trust_status NOT NULL,
  change_kind          ops.change_kind NOT NULL,
  source_decision_ids  uuid[] NOT NULL DEFAULT '{}',
  changed_at           timestamptz NOT NULL DEFAULT now(),
  changed_by_session   uuid REFERENCES ops.sessions(id),
  changed_by_dispatch  uuid REFERENCES ops.dispatches(id),
  UNIQUE (document_id, version)
);

-- ── History
CREATE TABLE ops.work_log (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  origin         ops.work_origin NOT NULL,
  entry_type     text NOT NULL REFERENCES ops.entry_types(key),
  title          text NOT NULL CHECK (length(btrim(title)) > 0),
  description    text,
  follow_ups     jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(follow_ups) = 'array'),
  files_changed  text[] NOT NULL DEFAULT '{}',
  external_refs  jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(external_refs) = 'array'),
  test_summary   text,
  dispatch_id    uuid REFERENCES ops.dispatches(id),
  session_id     uuid REFERENCES ops.sessions(id),
  provenance     ops.provenance NOT NULL DEFAULT 'recorded'
);

CREATE TABLE ops.findings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim             text NOT NULL CHECK (length(btrim(claim)) > 0),
  evidence          jsonb NOT NULL CHECK (jsonb_typeof(evidence) = 'array' AND evidence <> '[]'::jsonb),
  claim_class       ops.claim_class NOT NULL,
  status            ops.finding_status NOT NULL DEFAULT 'open',
  last_verified_at  timestamptz,
  promoted_to       uuid REFERENCES ops.context_documents(id),
  source_session    uuid REFERENCES ops.sessions(id),
  source_dispatch   uuid REFERENCES ops.dispatches(id),
  use_count         integer NOT NULL DEFAULT 0 CHECK (use_count >= 0),
  last_used_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT findings_promoted_check CHECK (status <> 'promoted' OR promoted_to IS NOT NULL)
);

CREATE FUNCTION ops._findings_before_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = ops, pg_temp AS $$
BEGIN
  IF NEW.claim IS DISTINCT FROM OLD.claim OR NEW.evidence IS DISTINCT FROM OLD.evidence THEN
    RAISE EXCEPTION 'finding %: claim and evidence are immutable', OLD.id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER findings_before_update BEFORE UPDATE ON ops.findings
  FOR EACH ROW EXECUTE FUNCTION ops._findings_before_update();

-- ── Node links
CREATE TABLE ops.work_log_nodes (
  work_log_id  uuid NOT NULL REFERENCES ops.work_log(id),
  node_id      uuid NOT NULL REFERENCES ops.nodes(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (work_log_id, node_id)
);
CREATE INDEX work_log_nodes_node_idx ON ops.work_log_nodes (node_id);

CREATE TABLE ops.finding_nodes (
  finding_id  uuid NOT NULL REFERENCES ops.findings(id),
  node_id     uuid NOT NULL REFERENCES ops.nodes(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (finding_id, node_id)
);
CREATE INDEX finding_nodes_node_idx ON ops.finding_nodes (node_id);

CREATE TABLE ops.decision_nodes (
  decision_id  uuid NOT NULL REFERENCES ops.decisions(id),
  node_id      uuid NOT NULL REFERENCES ops.nodes(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (decision_id, node_id)
);
CREATE INDEX decision_nodes_node_idx ON ops.decision_nodes (node_id);

CREATE TABLE ops.dispatch_nodes (
  dispatch_id  uuid NOT NULL REFERENCES ops.dispatches(id),
  node_id      uuid NOT NULL REFERENCES ops.nodes(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dispatch_id, node_id)
);
CREATE INDEX dispatch_nodes_node_idx ON ops.dispatch_nodes (node_id);

CREATE VIEW ops.node_links AS
SELECT 'work_log'::text AS kind, work_log_id AS entry_id, node_id, created_at FROM ops.work_log_nodes
UNION ALL
SELECT 'finding', finding_id, node_id, created_at FROM ops.finding_nodes
UNION ALL
SELECT 'decision', decision_id, node_id, created_at FROM ops.decision_nodes
UNION ALL
SELECT 'dispatch', dispatch_id, node_id, created_at FROM ops.dispatch_nodes;

-- ── Backlog blocks
CREATE TABLE ops.backlog_blocks (
  item_id     uuid NOT NULL REFERENCES ops.backlog_items(id),
  node_id     uuid NOT NULL REFERENCES ops.nodes(id),
  scope       ops.block_scope NOT NULL,
  reason      text NOT NULL CHECK (length(btrim(reason)) > 0),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, node_id)
);

-- ── Routing
CREATE TABLE ops.node_paths (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  node_id       uuid NOT NULL REFERENCES ops.nodes(id),
  component_id  uuid NOT NULL REFERENCES ops.components(id),
  glob          text NOT NULL,
  UNIQUE (component_id, glob)
);

CREATE TABLE ops.path_log (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id       uuid NOT NULL REFERENCES ops.sessions(id),
  prompt_summary   text NOT NULL,
  proposed         jsonb NOT NULL,
  final            jsonb,
  outcome          ops.path_outcome,                         -- null until confirmed
  correction_note  text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT path_log_outcome_check CHECK ((outcome IS NULL) = (final IS NULL))
);

-- ── Session docs (append-only; never served by the loader)
CREATE TABLE ops.session_docs (
  segment_id    uuid NOT NULL REFERENCES ops.sessions(id),
  version       integer NOT NULL CHECK (version >= 1),
  content       text NOT NULL,
  decision_ids  uuid[] NOT NULL DEFAULT '{}',
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (segment_id, version)
);

-- ── Seeds
INSERT INTO ops.entry_types (key, label, description) VALUES
('feature',       'Feature',       'New capability: a tool, table, function or behaviour that did not exist before.'),
('fix',           'Fix',           'Correction of behaviour that was wrong, broken or contrary to a decision.'),
('refactor',      'Refactor',      'Restructuring with no change in behaviour.'),
('migration',     'Migration',     'Schema change shipped as a numbered migration file.'),
('config',        'Config',        'Settings, environment, roles, grants or tool configuration outside the schema.'),
('data',          'Data',          'Rows written, corrected or backfilled without a schema change.'),
('docs',          'Docs',          'Documentation, instruction texts, README or log changes only.'),
('investigation', 'Investigation', 'Read-only inquiry whose output is findings, not changes.'),
('chore',         'Chore',         'Housekeeping: dependencies, line endings, cleanup with no functional effect.');

INSERT INTO ops.doc_types (key, label, description) VALUES
('manual', 'Manual', 'Reference document describing how a project or component works and how to operate it.');

-- ── Grants: nothing to PUBLIC; reads only, writes arrive as M4 functions
REVOKE ALL ON ops.nodes, ops.doc_types, ops.entry_types, ops.document_versions, ops.work_log, ops.findings,
              ops.work_log_nodes, ops.finding_nodes, ops.decision_nodes, ops.dispatch_nodes, ops.node_links,
              ops.backlog_blocks, ops.node_paths, ops.path_log, ops.session_docs
FROM PUBLIC;
REVOKE ALL ON FUNCTION
  ops._nodes_before_insert(), ops._nodes_before_update(), ops._findings_before_update()
FROM PUBLIC;

GRANT SELECT ON ops.nodes, ops.doc_types, ops.entry_types, ops.document_versions, ops.work_log, ops.findings,
                ops.work_log_nodes, ops.finding_nodes, ops.decision_nodes, ops.dispatch_nodes, ops.node_links,
                ops.backlog_blocks, ops.node_paths, ops.path_log, ops.session_docs
TO ops_planner;
GRANT SELECT ON ops.nodes, ops.doc_types, ops.entry_types, ops.node_paths TO ops_executor;

INSERT INTO ops.schema_migrations (version) VALUES ('0008_spine_m1_tables');

COMMIT;
