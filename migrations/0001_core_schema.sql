-- 0001_core_schema.sql
-- local-ops core schema: thinnest skeleton for the cold-start test.
-- Run as local_ops (owner). Requires 0000_roles.sql applied first.
-- Traceability: inputs #1-#10 from the framework's origin system, 2026-09-24.

BEGIN;

CREATE SCHEMA ops;
REVOKE ALL ON SCHEMA ops FROM PUBLIC;

-- ── Migration ledger (repo files are authority; this records what an instance has applied)
CREATE TABLE ops.schema_migrations (
  version     text PRIMARY KEY,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

-- ── Enums
CREATE TYPE ops.provenance      AS ENUM ('recorded', 'reconstructed');                 -- #9
CREATE TYPE ops.session_status  AS ENUM ('active', 'closed');
CREATE TYPE ops.close_reason    AS ENUM ('normal', 'stale', 'erosion');                -- #5
CREATE TYPE ops.dispatch_status AS ENUM ('pending', 'claimed', 'done', 'failed',
                                         'refused_premise', 'cancelled');              -- #6
CREATE TYPE ops.commit_policy   AS ENUM ('none', 'local', 'push');
CREATE TYPE ops.gate_result     AS ENUM ('pass', 'fail');

-- ── Registry
CREATE TABLE ops.projects (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key         text NOT NULL UNIQUE CHECK (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  name        text NOT NULL,
  params      jsonb NOT NULL DEFAULT '{}',                                            -- #8
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.components (                                                         -- #2
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid NOT NULL REFERENCES ops.projects(id),
  key         text NOT NULL CHECK (key ~ '^[a-z0-9][a-z0-9_-]*$'),
  kind        text NOT NULL,
  repo_ref    text,
  verify_cmd  text,                                                                   -- #8
  params      jsonb NOT NULL DEFAULT '{}',                                            -- #8
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, key),
  UNIQUE (id, project_id)            -- target for composite FKs: component must belong to project
);

-- ── Protocol layer (#1). Operator preferences deliberately excluded.
CREATE TABLE ops.protocol_rules (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  version     integer NOT NULL DEFAULT 1,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.protocol_changelog (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  version     integer NOT NULL,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  rule_keys   text[] NOT NULL DEFAULT '{}',
  changes     text NOT NULL
);

CREATE TABLE ops.dispatch_types (
  type             text PRIMARY KEY,
  description      text NOT NULL,
  commit_policy    ops.commit_policy NOT NULL,
  execution_rules  jsonb NOT NULL DEFAULT '{}',
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- ── Project memory
CREATE TABLE ops.sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES ops.projects(id),
  component_id  uuid,
  kind          text NOT NULL CHECK (kind IN ('planning', 'execution')),
  status        ops.session_status NOT NULL DEFAULT 'active',
  close_reason  ops.close_reason,
  summary       text,
  next_step     text,
  provenance    ops.provenance NOT NULL DEFAULT 'recorded',
  occurred_at   timestamptz NOT NULL DEFAULT now(),   -- when the session happened
  recorded_at   timestamptz NOT NULL DEFAULT now(),   -- when this row was written
  closed_at     timestamptz,
  FOREIGN KEY (component_id, project_id) REFERENCES ops.components(id, project_id),
  CHECK ((status = 'closed') = (close_reason IS NOT NULL AND closed_at IS NOT NULL))
);

CREATE TABLE ops.decisions (                                                          -- #3
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id             uuid NOT NULL REFERENCES ops.projects(id),
  component_id           uuid,
  session_id             uuid REFERENCES ops.sessions(id),
  decision               text NOT NULL CHECK (length(btrim(decision)) > 0),
  rationale              text,
  rejected_alternatives  jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(rejected_alternatives) = 'array'),
  revisit_condition      text,
  scope                  text,
  supersedes             uuid REFERENCES ops.decisions(id),
  provenance             ops.provenance NOT NULL DEFAULT 'recorded',
  occurred_at            timestamptz NOT NULL DEFAULT now(),
  recorded_at            timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (component_id, project_id) REFERENCES ops.components(id, project_id)
);

CREATE TABLE ops.dispatches (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES ops.projects(id),
  component_id   uuid NOT NULL,                        -- isolation: every dispatch has a component
  dispatch_type  text NOT NULL REFERENCES ops.dispatch_types(type),
  session_id     uuid REFERENCES ops.sessions(id),     -- originating planning session
  title          text NOT NULL,
  prompt         text NOT NULL,
  context_refs   text[] NOT NULL DEFAULT '{}',         -- 'DOC_KEY' or 'DOC_KEY#Heading'
  priority       integer NOT NULL DEFAULT 100,
  status         ops.dispatch_status NOT NULL DEFAULT 'pending',
  claimed_by     text,                                 -- #7 attribution: agent session id
  claimed_at     timestamptz,                          -- #7 attribution window start
  completed_at   timestamptz,                          -- #7 attribution window end
  result         text,
  report         text,
  error          text,
  reviewed_at    timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (component_id, project_id) REFERENCES ops.components(id, project_id),
  CHECK (status = 'pending' OR claimed_at IS NOT NULL OR status = 'cancelled'),
  CHECK (status NOT IN ('done', 'failed', 'refused_premise') OR completed_at IS NOT NULL)
);
CREATE INDEX dispatches_pending_idx ON ops.dispatches (project_id, component_id, priority)
  WHERE status = 'pending';

CREATE TABLE ops.dispatch_costs (                                                     -- #7 derived only
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dispatch_id         uuid NOT NULL REFERENCES ops.dispatches(id),
  method              text NOT NULL,     -- e.g. 'transcript_window', 'otel_session'
  source              text NOT NULL,     -- tool + version that produced the figures
  input_tokens        bigint,
  output_tokens       bigint,
  cache_write_tokens  bigint,
  cache_read_tokens   bigint,
  usd_estimate        numeric(12,4),     -- API-equivalent, not billed spend
  derived_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dispatch_id, method)
);

CREATE TABLE ops.gate_events (                                                        -- #4
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dispatch_id  uuid REFERENCES ops.dispatches(id),
  session_id   uuid REFERENCES ops.sessions(id),
  gate_key     text NOT NULL,
  result       ops.gate_result NOT NULL,
  overridden   boolean NOT NULL DEFAULT false,
  override_by  text,
  reason       text,
  at           timestamptz NOT NULL DEFAULT now(),
  CHECK (dispatch_id IS NOT NULL OR session_id IS NOT NULL),
  CHECK (NOT overridden OR result = 'fail'),
  CHECK (NOT overridden OR (override_by IS NOT NULL AND length(btrim(coalesce(reason, ''))) > 0))
);

CREATE TABLE ops.context_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES ops.projects(id),
  component_id  uuid,
  doc_key       text NOT NULL CHECK (doc_key ~ '^[A-Z0-9_]+$'),
  title         text NOT NULL,
  content       text NOT NULL,
  summary       text,
  version       integer NOT NULL DEFAULT 1,
  provenance    ops.provenance NOT NULL DEFAULT 'recorded',
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (project_id, doc_key),
  FOREIGN KEY (component_id, project_id) REFERENCES ops.components(id, project_id)
);

CREATE TABLE ops.backlog_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES ops.projects(id),
  component_id  uuid,
  title         text NOT NULL,
  detail        text,
  status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'dropped')),
  source        text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz,
  FOREIGN KEY (component_id, project_id) REFERENCES ops.components(id, project_id)
);

-- ── Helpers
CREATE FUNCTION ops._component(p_project_key text, p_component_key text)
RETURNS ops.components LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components;
BEGIN
  IF p_project_key IS NULL OR p_component_key IS NULL THEN
    RAISE EXCEPTION 'project_key and component_key are both required';
  END IF;
  SELECT cm.* INTO c FROM ops.components cm JOIN ops.projects p ON p.id = cm.project_id
   WHERE p.key = p_project_key AND cm.key = p_component_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown component %/%', p_project_key, p_component_key;
  END IF;
  RETURN c;
END $$;

-- ── Sessions (#5, #3)
CREATE FUNCTION ops.open_session(p_project_key text, p_component_key text, p_kind text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_project uuid; v_component uuid; v_id uuid;
  v_stale_hours integer := coalesce(
    (SELECT (value->>'hours')::int FROM ops.protocol_rules WHERE key = 'session_stale_after'), 12);
BEGIN
  SELECT id INTO v_project FROM ops.projects WHERE key = p_project_key;
  IF v_project IS NULL THEN RAISE EXCEPTION 'unknown project %', p_project_key; END IF;
  IF p_component_key IS NOT NULL THEN
    v_component := (ops._component(p_project_key, p_component_key)).id;
  END IF;

  -- auto-close orphaned sessions for this project
  UPDATE ops.sessions
     SET status = 'closed', close_reason = 'stale', closed_at = now(),
         summary = coalesce(summary, 'auto-closed: stale')
   WHERE project_id = v_project AND status = 'active'
     AND occurred_at < now() - make_interval(hours => v_stale_hours);

  INSERT INTO ops.sessions (project_id, component_id, kind)
  VALUES (v_project, v_component, p_kind) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION ops.close_session(p_session uuid, p_summary text, p_next_step text,
                                  p_decisions jsonb, p_reason ops.close_reason DEFAULT 'normal')
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE s ops.sessions; d jsonb; n integer := 0;
BEGIN
  IF p_decisions IS NULL OR jsonb_typeof(p_decisions) <> 'array' THEN
    RAISE EXCEPTION 'decisions must be an explicit JSON array (use [] if none were made)';
  END IF;
  IF p_reason = 'stale' THEN
    RAISE EXCEPTION 'stale closure is automatic only';
  END IF;
  SELECT * INTO s FROM ops.sessions WHERE id = p_session FOR UPDATE;
  IF NOT FOUND OR s.status <> 'active' THEN
    RAISE EXCEPTION 'session % is not active', p_session;
  END IF;

  FOR d IN SELECT * FROM jsonb_array_elements(p_decisions) LOOP
    INSERT INTO ops.decisions (project_id, component_id, session_id, decision, rationale,
                               rejected_alternatives, revisit_condition, scope)
    VALUES (s.project_id, s.component_id, s.id, d->>'decision', d->>'rationale',
            coalesce(d->'rejected_alternatives', '[]'), d->>'revisit_condition', d->>'scope');
    n := n + 1;
  END LOOP;

  UPDATE ops.sessions
     SET status = 'closed', close_reason = p_reason, closed_at = now(),
         summary = p_summary, next_step = p_next_step
   WHERE id = p_session;
  RETURN n;
END $$;

-- ── Dispatch lifecycle (isolation + #6)
CREATE FUNCTION ops.get_pending(p_project_key text, p_component_key text)
RETURNS SETOF ops.dispatches LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE c ops.components := ops._component(p_project_key, p_component_key);
BEGIN
  RETURN QUERY SELECT * FROM ops.dispatches
   WHERE project_id = c.project_id AND component_id = c.id AND status = 'pending'
   ORDER BY priority, created_at;
END $$;

CREATE FUNCTION ops.claim_dispatch(p_id uuid, p_agent_session text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF p_agent_session IS NULL THEN RAISE EXCEPTION 'agent session id required'; END IF;
  UPDATE ops.dispatches SET status = 'claimed', claimed_by = p_agent_session, claimed_at = now()
   WHERE id = p_id AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % is not pending', p_id; END IF;
END $$;

CREATE FUNCTION ops.complete_dispatch(p_id uuid, p_result text, p_report text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  UPDATE ops.dispatches SET status = 'done', result = p_result, report = p_report, completed_at = now()
   WHERE id = p_id AND status = 'claimed';
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % is not claimed', p_id; END IF;
END $$;

CREATE FUNCTION ops.fail_dispatch(p_id uuid, p_error text, p_refused_premise boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF length(btrim(coalesce(p_error, ''))) = 0 THEN
    RAISE EXCEPTION 'error text with stop point required';
  END IF;
  UPDATE ops.dispatches
     SET status = CASE WHEN p_refused_premise THEN 'refused_premise'::ops.dispatch_status
                       ELSE 'failed'::ops.dispatch_status END,
         error = p_error, completed_at = now()
   WHERE id = p_id AND status = 'claimed';
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % is not claimed', p_id; END IF;
END $$;

CREATE FUNCTION ops.get_unreviewed_reports(p_project_key text)
RETURNS SETOF ops.dispatches LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT d.* FROM ops.dispatches d JOIN ops.projects p ON p.id = d.project_id
   WHERE p.key = p_project_key AND d.reviewed_at IS NULL
     AND d.status IN ('done', 'failed', 'refused_premise')
   ORDER BY d.completed_at;
$$;

CREATE FUNCTION ops.mark_reviewed(p_ids uuid[])
RETURNS integer LANGUAGE sql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  WITH u AS (
    UPDATE ops.dispatches SET reviewed_at = now()
     WHERE id = ANY(p_ids) AND reviewed_at IS NULL
       AND status IN ('done', 'failed', 'refused_premise')
    RETURNING 1)
  SELECT count(*)::int FROM u;
$$;

CREATE FUNCTION ops.cancel_dispatch(p_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN
    RAISE EXCEPTION 'cancellation reason required';
  END IF;
  UPDATE ops.dispatches SET status = 'cancelled', error = 'cancelled: ' || p_reason
   WHERE id = p_id AND status IN ('pending', 'claimed');
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % is not pending or claimed', p_id; END IF;
END $$;

-- ── Gates (#4)
CREATE FUNCTION ops.record_gate(p_gate_key text, p_result ops.gate_result,
                                p_dispatch uuid DEFAULT NULL, p_session uuid DEFAULT NULL,
                                p_overridden boolean DEFAULT false,
                                p_override_by text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bigint LANGUAGE sql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  INSERT INTO ops.gate_events (gate_key, result, dispatch_id, session_id, overridden, override_by, reason)
  VALUES (p_gate_key, p_result, p_dispatch, p_session, p_overridden, p_override_by, p_reason)
  RETURNING id;
$$;

-- ── Context resolution: 'DOC_KEY' → whole doc; 'DOC_KEY#Heading' → that markdown section
CREATE FUNCTION ops.resolve_context(p_project_key text, p_ref text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE
  v_key text := split_part(p_ref, '#', 1);
  v_heading text := nullif(substr(p_ref, length(v_key) + 2), '');
  v_content text; v_line text; v_level int := 0; v_hlevel int; v_out text := ''; v_in boolean := false;
BEGIN
  SELECT cd.content INTO v_content FROM ops.context_documents cd
    JOIN ops.projects p ON p.id = cd.project_id
   WHERE p.key = p_project_key AND cd.doc_key = v_key;
  IF v_content IS NULL THEN RAISE EXCEPTION 'unknown context ref %', p_ref; END IF;
  IF v_heading IS NULL THEN RETURN v_content; END IF;

  FOREACH v_line IN ARRAY string_to_array(v_content, E'\n') LOOP
    v_hlevel := length(substring(v_line from '^(#+)\s'));
    IF v_in AND v_hlevel IS NOT NULL AND v_hlevel <= v_level THEN EXIT; END IF;
    IF NOT v_in AND v_hlevel IS NOT NULL
       AND lower(btrim(regexp_replace(v_line, '^#+\s+', ''))) = lower(btrim(v_heading)) THEN
      v_in := true; v_level := v_hlevel;
    END IF;
    IF v_in THEN v_out := v_out || v_line || E'\n'; END IF;
  END LOOP;
  IF NOT v_in THEN RAISE EXCEPTION 'heading "%" not found in %', v_heading, v_key; END IF;
  RETURN rtrim(v_out, E'\n');
END $$;

-- ── Grants: nothing to PUBLIC; functions are the executor's only write path
REVOKE ALL ON ALL TABLES    IN SCHEMA ops FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ops FROM PUBLIC;
GRANT USAGE ON SCHEMA ops TO ops_planner, ops_executor;

-- Planner: reads everything; writes registry, protocol, memory, dispatch creation, derived costs
GRANT SELECT ON ALL TABLES IN SCHEMA ops TO ops_planner;
GRANT INSERT, UPDATE ON ops.projects, ops.components, ops.protocol_rules, ops.dispatch_types,
                        ops.context_documents, ops.backlog_items TO ops_planner;
-- decisions are append-only: change = new row with supersedes -> old row
GRANT INSERT ON ops.decisions, ops.protocol_changelog, ops.dispatch_costs, ops.dispatches TO ops_planner;
-- dispatch status changes only through lifecycle functions (cancel_dispatch for the planner)
GRANT EXECUTE ON FUNCTION
  ops.open_session(text, text, text),
  ops.close_session(uuid, text, text, jsonb, ops.close_reason),
  ops.get_unreviewed_reports(text), ops.mark_reviewed(uuid[]), ops.cancel_dispatch(uuid, text),
  ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text),
  ops.resolve_context(text, text)
TO ops_planner;

-- Executor: reads protocol + context; all writes through functions; never writes costs
GRANT SELECT ON ops.projects, ops.components, ops.protocol_rules, ops.dispatch_types,
                 ops.context_documents TO ops_executor;
GRANT EXECUTE ON FUNCTION
  ops.get_pending(text, text), ops.claim_dispatch(uuid, text),
  ops.complete_dispatch(uuid, text, text), ops.fail_dispatch(uuid, text, boolean),
  ops.record_gate(text, ops.gate_result, uuid, uuid, boolean, text, text),
  ops.resolve_context(text, text)
TO ops_executor;

INSERT INTO ops.schema_migrations (version) VALUES ('0001_core_schema');

COMMIT;
