-- 0032_vision_items
-- Dispatch 301dd74c. Vision release (decisions 6cef3bf3, 08908ad9, 9144f3ef), a release of its own; promoted by a
-- separate promote dispatch after planner review. Protocol version 10 -> 11. Purely additive: no existing function,
-- table, grant or rule changes (step 7 checks that).
-- Build status lives in one table, ops.vision_items (one tree per subject: a root, one item per theme, then items):
--   * ops.vision_items: key, parent, home node, title, intent, acceptance, status (idea / designed / partial /
--     shipped / true_closed / abandoned), phase (setup / tune / test / import / later), seq, sources, status note;
--     abandoned needs abandoned_reason, true_closed needs true_close_evidence and true_closed_at.
--   * ops.vision_requires: the database objects an item needs (function, table, view, rule, column, doc); presence
--     is computed on read by the view ops.vision_requires_status, never stored.
--   * ops.vision_decisions (relation), ops.vision_backlog (role blocks | improves), ops.vision_dispatches (an item,
--     or a none_reason, never both): one link table per kind with real foreign keys (decision_nodes pattern).
--   * ops.vision_status_log: every status change with time, session and reason.
--   * ops.vision_status: one row per item with its children's rollup and link counts.
--   * Writers, planner-only SECURITY DEFINER, each taking a session checked as ops.log_decision checks it:
--     vision_upsert, vision_link, vision_unlink, vision_set_status, vision_true_close; reader ops.vision_check().
--   * Protocol rule vision_check (rule version 1); protocol_changelog version 11.
-- Grants: SELECT on the tables and views and EXECUTE on the six functions to ops_planner only; no role but the owner
-- writes a vision table; ops_executor and PUBLIC get nothing. ops.create_dispatch is unchanged: the MCP
-- create_dispatch tool (a later dispatch) calls ops.create_dispatch and ops.vision_link in one transaction.

BEGIN;

-- ── 1. guard; snapshots for step 7
DO $$
DECLARE v_newest text;
BEGIN
  SELECT version INTO v_newest FROM ops.schema_migrations ORDER BY version DESC LIMIT 1;
  IF v_newest IS DISTINCT FROM '0031_work_log_backfill' THEN
    RAISE EXCEPTION '0032: expected newest ledger version 0031_work_log_backfill, found %', v_newest;
  END IF;
  IF (SELECT max(version) FROM ops.protocol_changelog) IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION '0032: expected protocol version 10, found %', (SELECT max(version) FROM ops.protocol_changelog);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'ops'::regnamespace AND relname LIKE 'vision%')
     OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname LIKE 'vision%') THEN
    RAISE EXCEPTION '0032: a relation or function named vision* already exists in ops';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'vision_check') THEN
    RAISE EXCEPTION '0032: protocol rule vision_check already exists';
  END IF;
  IF EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 11) THEN
    RAISE EXCEPTION '0032: protocol_changelog version 11 already exists';
  END IF;

  PERFORM set_config('ops_m0032.rules_md5',
    (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key)) FROM ops.protocol_rules), true);
  PERFORM set_config('ops_m0032.executor_reads',
    (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
      WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
        AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text, true);
  PERFORM set_config('ops_m0032.executor_fns',
    (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
      WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text, true);
  IF EXISTS (SELECT 1 FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
              WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
                AND has_table_privilege('ops_planner', c.oid, p)) THEN
    RAISE EXCEPTION '0032: ops_planner holds a table write privilege in ops';
  END IF;
END $$;

-- ── 2. tables
CREATE TABLE ops.vision_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key                  text NOT NULL UNIQUE CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  parent_id            uuid REFERENCES ops.vision_items(id) CHECK (parent_id <> id),
  home_node_id         uuid NOT NULL REFERENCES ops.nodes(id),
  title                text NOT NULL CHECK (length(btrim(title)) > 0),
  intent               text NOT NULL CHECK (length(btrim(intent)) > 0),
  acceptance           text NOT NULL CHECK (length(btrim(acceptance)) > 0),
  status               text NOT NULL CHECK (status IN ('idea', 'designed', 'partial', 'shipped', 'true_closed', 'abandoned')),
  phase                text NOT NULL CHECK (phase IN ('setup', 'tune', 'test', 'import', 'later')),
  seq                  integer NOT NULL DEFAULT 0 CHECK (seq >= 0),
  sources              text[] NOT NULL DEFAULT '{}',
  status_note          text CHECK (status_note IS NULL OR length(btrim(status_note)) > 0),
  abandoned_reason     text,
  true_close_evidence  text,
  true_closed_at       timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  updated_session_id   uuid NOT NULL REFERENCES ops.sessions(id),
  CONSTRAINT vision_items_sources_clean CHECK (
    array_position(sources, NULL) IS NULL
    AND (cardinality(sources) = 0
         OR (E'\x01' || array_to_string(sources, E'\x01') || E'\x01') !~ E'\x01 *\x01')),
  CONSTRAINT vision_items_abandoned_reason CHECK (
    (status = 'abandoned') = (abandoned_reason IS NOT NULL AND length(btrim(abandoned_reason)) > 0)),
  CONSTRAINT vision_items_true_close CHECK (
    (status = 'true_closed') = (true_close_evidence IS NOT NULL AND length(btrim(true_close_evidence)) > 0
                                AND true_closed_at IS NOT NULL))
);
CREATE INDEX vision_items_parent_idx ON ops.vision_items (parent_id);
CREATE INDEX vision_items_home_node_idx ON ops.vision_items (home_node_id);
COMMENT ON TABLE ops.vision_items IS
  'Vision (08908ad9, 9144f3ef): build status, one tree per subject; written only through the vision writer functions.';

CREATE TABLE ops.vision_requires (
  item_id  uuid NOT NULL REFERENCES ops.vision_items(id) ON DELETE CASCADE,
  kind     text NOT NULL CHECK (kind IN ('function', 'table', 'view', 'rule', 'column', 'doc')),
  name     text NOT NULL CHECK (length(btrim(name)) > 0),
  PRIMARY KEY (item_id, kind, name),
  CONSTRAINT vision_requires_column_name CHECK (kind <> 'column' OR name ~ '^[^.[:space:]]+\.[^.[:space:]]+$'),
  CONSTRAINT vision_requires_doc_name CHECK (kind <> 'doc' OR name ~ '^[^:[:space:]]+:[^:[:space:]]+$')
);
COMMENT ON TABLE ops.vision_requires IS
  'Vision (08908ad9, 9144f3ef): the database objects an item needs (column <table>.<column>, doc <node path>:<doc_type>); presence is computed by vision_requires_status.';

CREATE TABLE ops.vision_decisions (
  item_id      uuid NOT NULL REFERENCES ops.vision_items(id),
  decision_id  uuid NOT NULL REFERENCES ops.decisions(id),
  relation     text NOT NULL CHECK (relation IN ('defines', 'refines', 'sequencing', 'milestone', 'constrains',
                                                 'process_rule', 'superseded', 'abandons')),
  session_id   uuid NOT NULL REFERENCES ops.sessions(id),
  linked_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, decision_id)
);
CREATE INDEX vision_decisions_decision_idx ON ops.vision_decisions (decision_id);
COMMENT ON TABLE ops.vision_decisions IS
  'Vision (08908ad9, 9144f3ef): decision links of vision items, with their relation.';

CREATE TABLE ops.vision_backlog (
  item_id     uuid NOT NULL REFERENCES ops.vision_items(id),
  backlog_id  uuid NOT NULL REFERENCES ops.backlog_items(id),
  role        text NOT NULL CHECK (role IN ('blocks', 'improves')),
  session_id  uuid NOT NULL REFERENCES ops.sessions(id),
  linked_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (item_id, backlog_id)
);
CREATE INDEX vision_backlog_backlog_idx ON ops.vision_backlog (backlog_id);
COMMENT ON TABLE ops.vision_backlog IS
  'Vision (08908ad9, 9144f3ef): backlog links of vision items; an open blocks link holds the item below shipped.';

CREATE TABLE ops.vision_dispatches (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id  uuid NOT NULL REFERENCES ops.dispatches(id),
  item_id      uuid REFERENCES ops.vision_items(id),
  none_reason  text CHECK (none_reason IS NULL OR length(btrim(none_reason)) > 0),
  session_id   uuid NOT NULL REFERENCES ops.sessions(id),
  linked_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vision_dispatches_item_or_none CHECK ((item_id IS NULL) = (none_reason IS NOT NULL))
);
CREATE UNIQUE INDEX vision_dispatches_item_uq ON ops.vision_dispatches (dispatch_id, item_id) WHERE item_id IS NOT NULL;
CREATE UNIQUE INDEX vision_dispatches_none_uq ON ops.vision_dispatches (dispatch_id) WHERE item_id IS NULL;
COMMENT ON TABLE ops.vision_dispatches IS
  'Vision (08908ad9, 9144f3ef): the vision items a dispatch advances, or one none row with its reason, never both.';

CREATE TABLE ops.vision_status_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id      uuid NOT NULL REFERENCES ops.vision_items(id),
  from_status  text,
  to_status    text NOT NULL CHECK (to_status IN ('idea', 'designed', 'partial', 'shipped', 'true_closed', 'abandoned')),
  reason       text NOT NULL CHECK (length(btrim(reason)) > 0),
  session_id   uuid NOT NULL REFERENCES ops.sessions(id),
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX vision_status_log_item_at_idx ON ops.vision_status_log (item_id, at);
COMMENT ON TABLE ops.vision_status_log IS
  'Vision (08908ad9, 9144f3ef): every vision item status change (from_status NULL on creation) with time, session and reason.';

-- ── 3. views
CREATE VIEW ops.vision_requires_status AS
SELECT i.key AS item_key, r.kind, r.name,
       CASE r.kind
         WHEN 'function' THEN EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                       WHERE p.pronamespace = 'ops'::regnamespace AND p.proname = r.name)
         WHEN 'table' THEN EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                    WHERE c.relnamespace = 'ops'::regnamespace AND c.relname = r.name
                                      AND c.relkind IN ('r', 'p'))
         WHEN 'view' THEN EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                                   WHERE c.relnamespace = 'ops'::regnamespace AND c.relname = r.name
                                     AND c.relkind IN ('v', 'm'))
         WHEN 'rule' THEN EXISTS (SELECT 1 FROM ops.protocol_rules pr WHERE pr.key = r.name)
         WHEN 'column' THEN EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                                      JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                                     WHERE c.relnamespace = 'ops'::regnamespace
                                       AND c.relname = split_part(r.name, '.', 1)
                                       AND a.attname = split_part(r.name, '.', 2)
                                       AND a.attnum > 0 AND NOT a.attisdropped)
         WHEN 'doc' THEN EXISTS (SELECT 1 FROM ops.context_documents d JOIN ops.nodes n ON n.id = d.node_id
                                  WHERE n.path::text = split_part(r.name, ':', 1)
                                    AND d.doc_type = split_part(r.name, ':', 2))
       END AS present
  FROM ops.vision_requires r
  JOIN ops.vision_items i ON i.id = r.item_id;
COMMENT ON VIEW ops.vision_requires_status IS
  'Vision (08908ad9, 9144f3ef): each item requirement and whether the object exists now (computed on read).';

CREATE VIEW ops.vision_status AS
SELECT i.key, p.key AS parent_key, n.path AS home_path, i.title, i.status, i.phase, i.seq,
       CASE WHEN ch.total = 0 THEN NULL
            WHEN ch.live = 0 THEN 'abandoned'
            WHEN ch.true_closed = ch.live THEN 'true_closed'
            WHEN ch.shipped + ch.true_closed = ch.live THEN 'shipped'
            WHEN ch.shipped + ch.true_closed + ch.partial > 0 THEN 'partial'
            WHEN ch.designed > 0 THEN 'designed'
            ELSE 'idea' END AS rollup_status,
       ch.total AS children,
       rq.total AS requires_total, rq.missing AS requires_missing,
       (SELECT count(*) FROM ops.vision_decisions vd WHERE vd.item_id = i.id) AS decisions,
       bl.open_blocks AS backlog_open_blocks, bl.open_improves AS backlog_open_improves, bl.closed AS backlog_closed,
       (SELECT count(DISTINCT vx.dispatch_id) FROM ops.vision_dispatches vx WHERE vx.item_id = i.id) AS dispatches,
       i.updated_at
  FROM ops.vision_items i
  JOIN ops.nodes n ON n.id = i.home_node_id
  LEFT JOIN ops.vision_items p ON p.id = i.parent_id
 CROSS JOIN LATERAL (
       SELECT count(*) AS total,
              count(*) FILTER (WHERE c.status <> 'abandoned') AS live,
              count(*) FILTER (WHERE c.status = 'true_closed') AS true_closed,
              count(*) FILTER (WHERE c.status = 'shipped') AS shipped,
              count(*) FILTER (WHERE c.status = 'partial') AS partial,
              count(*) FILTER (WHERE c.status = 'designed') AS designed
         FROM ops.vision_items c WHERE c.parent_id = i.id) ch
 CROSS JOIN LATERAL (
       SELECT count(*) AS total, count(*) FILTER (WHERE NOT rs.present) AS missing
         FROM ops.vision_requires_status rs WHERE rs.item_key = i.key) rq
 CROSS JOIN LATERAL (
       SELECT count(*) FILTER (WHERE b.status = 'open' AND vb.role = 'blocks') AS open_blocks,
              count(*) FILTER (WHERE b.status = 'open' AND vb.role = 'improves') AS open_improves,
              count(*) FILTER (WHERE b.status <> 'open') AS closed
         FROM ops.vision_backlog vb JOIN ops.backlog_items b ON b.id = vb.backlog_id WHERE vb.item_id = i.id) bl;
COMMENT ON VIEW ops.vision_status IS
  'Vision (08908ad9, 9144f3ef): one row per item: stored status, children rollup (abandoned children left out), requirement and link counts.';

-- ── 4. functions
-- private helpers (owner only): the log_decision session check against a node, a string field of a JSON object,
-- and the open blocks-linked backlog items of an item (id8s, comma separated; NULL when none)
CREATE FUNCTION ops._vision_session(p_session uuid, p_node_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE n ops.nodes; v_root ops.nodes; s ops.sessions;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO n FROM ops.nodes WHERE id = p_node_id;
  v_root := ops._node(public.subpath(n.path, 0, least(2, public.nlevel(n.path))));
  SELECT * INTO s FROM ops.sessions WHERE id = p_session;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session % does not exist', p_session USING ERRCODE = 'check_violation';
  END IF;
  IF NOT coalesce((SELECT path FROM ops.nodes WHERE id = coalesce(s.node_id, ops._derived_node(s.component_id, s.project_id)))
                  OPERATOR(public.<@) v_root.path, false) THEN
    RAISE EXCEPTION 'session % is outside % (the scope of %)', p_session, v_root.path, n.path
      USING ERRCODE = 'check_violation';
  END IF;
END $$;
REVOKE ALL ON FUNCTION ops._vision_session(uuid, uuid) FROM PUBLIC;

CREATE FUNCTION ops._vision_str(p_ctx text, p_obj jsonb, p_field text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  IF p_obj->p_field IS NULL OR jsonb_typeof(p_obj->p_field) = 'null' THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_obj->p_field) <> 'string' THEN
    RAISE EXCEPTION '%: % must be a string', p_ctx, p_field USING ERRCODE = 'check_violation';
  END IF;
  RETURN p_obj->>p_field;
END $$;
REVOKE ALL ON FUNCTION ops._vision_str(text, jsonb, text) FROM PUBLIC;

CREATE FUNCTION ops._vision_open_blockers(p_item uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
  SELECT string_agg(left(b.id::text, 8), ', ' ORDER BY b.id::text)
    FROM ops.vision_backlog vb JOIN ops.backlog_items b ON b.id = vb.backlog_id
   WHERE vb.item_id = p_item AND vb.role = 'blocks' AND b.status = 'open';
$$;
REVOKE ALL ON FUNCTION ops._vision_open_blockers(uuid) FROM PUBLIC;

-- a. vision_upsert: insert or update items in array order
CREATE FUNCTION ops.vision_upsert(p_items jsonb, p_session uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE e jsonb; i integer := 0; f text; v_key text; v_ctx text; v_str text; v_bad text; v_found boolean;
        o ops.vision_items; n ops.vision_items; v_ppath public.ltree; v_hpath public.ltree; v_reason text;
        v_req text[]; v_old_req text[]; v_req_given boolean; v_changed boolean;
        v_ins integer := 0; v_upd integer := 0; v_chg integer := 0;
        v_allowed text[] := ARRAY['key', 'parent_key', 'home_node_path', 'title', 'intent', 'acceptance', 'status',
                                  'status_reason', 'phase', 'seq', 'sources', 'requires', 'status_note', 'abandoned_reason'];
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'vision_upsert: p_items must be a non-empty JSON array of objects' USING ERRCODE = 'check_violation';
  END IF;
  FOR e IN SELECT t.x FROM jsonb_array_elements(p_items) WITH ORDINALITY t(x, ord) ORDER BY t.ord LOOP
    i := i + 1;
    IF jsonb_typeof(e) <> 'object' THEN
      RAISE EXCEPTION 'vision_upsert: element % is not a JSON object', i USING ERRCODE = 'check_violation';
    END IF;
    IF jsonb_typeof(e->'key') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'vision_upsert: element % has no key (a string)', i USING ERRCODE = 'check_violation';
    END IF;
    v_key := e->>'key';
    v_ctx := 'vision item ' || v_key;
    SELECT string_agg(k, ', ' ORDER BY k) INTO v_bad FROM jsonb_object_keys(e) k WHERE k <> ALL (v_allowed);
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '%: unknown field %', v_ctx, v_bad USING ERRCODE = 'check_violation';
    END IF;
    IF v_key !~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$' THEN
      RAISE EXCEPTION '%: key must be dot-separated lower-case segments', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    FOREACH f IN ARRAY ARRAY['home_node_path', 'title', 'intent', 'acceptance', 'status', 'phase', 'seq', 'sources',
                             'requires'] LOOP
      IF e ? f AND jsonb_typeof(e->f) = 'null' THEN
        RAISE EXCEPTION '%: % cannot be null', v_ctx, f USING ERRCODE = 'check_violation';
      END IF;
    END LOOP;

    SELECT * INTO o FROM ops.vision_items WHERE key = v_key FOR UPDATE;
    v_found := FOUND;
    IF v_found THEN
      n := o;
    ELSE
      FOREACH f IN ARRAY ARRAY['parent_key', 'home_node_path', 'title', 'intent', 'acceptance', 'status', 'phase'] LOOP
        IF NOT e ? f THEN
          RAISE EXCEPTION '%: a new item requires %', v_ctx,
            CASE f WHEN 'parent_key' THEN 'parent_key (null for a tree root)' ELSE f END USING ERRCODE = 'check_violation';
        END IF;
      END LOOP;
      n := NULL;
      n.key := v_key;
      n.seq := 0;
      n.sources := '{}';
    END IF;

    IF e ? 'parent_key' THEN
      v_str := ops._vision_str(v_ctx, e, 'parent_key');
      IF v_str IS NULL THEN
        n.parent_id := NULL;
      ELSE
        SELECT id INTO n.parent_id FROM ops.vision_items WHERE key = v_str;
        IF NOT FOUND THEN
          RAISE EXCEPTION '%: parent_key % does not exist', v_ctx, v_str USING ERRCODE = 'check_violation';
        END IF;
      END IF;
    END IF;
    IF e ? 'home_node_path' THEN
      n.home_node_id := (ops._node(ops._vision_str(v_ctx, e, 'home_node_path')::public.ltree)).id;
    END IF;
    FOREACH f IN ARRAY ARRAY['title', 'intent', 'acceptance'] LOOP
      IF e ? f THEN
        v_str := ops._vision_str(v_ctx, e, f);
        IF length(btrim(v_str)) = 0 THEN
          RAISE EXCEPTION '%: % is blank', v_ctx, f USING ERRCODE = 'check_violation';
        END IF;
        CASE f WHEN 'title' THEN n.title := v_str; WHEN 'intent' THEN n.intent := v_str; ELSE n.acceptance := v_str; END CASE;
      END IF;
    END LOOP;
    IF e ? 'status' THEN
      n.status := ops._vision_str(v_ctx, e, 'status');
      IF n.status NOT IN ('idea', 'designed', 'partial', 'shipped', 'true_closed', 'abandoned') THEN
        RAISE EXCEPTION '%: status % is not one of idea, designed, partial, shipped, true_closed, abandoned', v_ctx, n.status
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    IF e ? 'phase' THEN
      n.phase := ops._vision_str(v_ctx, e, 'phase');
      IF n.phase NOT IN ('setup', 'tune', 'test', 'import', 'later') THEN
        RAISE EXCEPTION '%: phase % is not one of setup, tune, test, import, later', v_ctx, n.phase
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    IF e ? 'seq' THEN
      IF jsonb_typeof(e->'seq') <> 'number' OR (e->>'seq') !~ '^[0-9]{1,9}$' THEN
        RAISE EXCEPTION '%: seq must be a non-negative integer', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      n.seq := (e->>'seq')::integer;
    END IF;
    IF e ? 'sources' THEN
      IF jsonb_typeof(e->'sources') <> 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(e->'sources') x
                     WHERE jsonb_typeof(x) <> 'string' OR btrim(x #>> '{}') = '') THEN
        RAISE EXCEPTION '%: sources must be an array of non-blank strings', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      n.sources := ARRAY(SELECT t.x #>> '{}' FROM jsonb_array_elements(e->'sources') WITH ORDINALITY t(x, ord) ORDER BY t.ord);
    END IF;
    v_req_given := e ? 'requires';
    IF v_req_given THEN
      IF jsonb_typeof(e->'requires') <> 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(e->'requires') x WHERE jsonb_typeof(x) <> 'string') THEN
        RAISE EXCEPTION '%: requires must be an array of "kind:name" strings', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      SELECT min(x #>> '{}') INTO v_bad
        FROM jsonb_array_elements(e->'requires') x
       WHERE NOT (split_part(x #>> '{}', ':', 1) IN ('function', 'table', 'view', 'rule', 'column', 'doc')
                  AND length(btrim(substr(x #>> '{}', strpos(x #>> '{}', ':') + 1))) > 0
                  AND (split_part(x #>> '{}', ':', 1) <> 'column'
                       OR substr(x #>> '{}', strpos(x #>> '{}', ':') + 1) ~ '^[^.[:space:]]+\.[^.[:space:]]+$')
                  AND (split_part(x #>> '{}', ':', 1) <> 'doc'
                       OR substr(x #>> '{}', strpos(x #>> '{}', ':') + 1) ~ '^[^:[:space:]]+:[^:[:space:]]+$'));
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '%: malformed requirement "%"', v_ctx, v_bad USING ERRCODE = 'check_violation';
      END IF;
      v_req := ARRAY(SELECT DISTINCT x #>> '{}' FROM jsonb_array_elements(e->'requires') x ORDER BY 1);
    END IF;
    IF e ? 'status_note' THEN
      n.status_note := ops._vision_str(v_ctx, e, 'status_note');
      IF length(btrim(n.status_note)) = 0 THEN
        RAISE EXCEPTION '%: status_note is blank', v_ctx USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    v_reason := ops._vision_str(v_ctx, e, 'status_reason');
    IF length(btrim(v_reason)) = 0 THEN
      RAISE EXCEPTION '%: status_reason is blank', v_ctx USING ERRCODE = 'check_violation';
    END IF;

    -- session: the item's home node (and its old home when it moves)
    PERFORM ops._vision_session(p_session, n.home_node_id);
    IF v_found AND o.home_node_id <> n.home_node_id THEN
      PERFORM ops._vision_session(p_session, o.home_node_id);
    END IF;

    -- status rules
    IF n.status = 'true_closed' AND (NOT v_found OR o.status <> 'true_closed') THEN
      RAISE EXCEPTION '%: status true_closed is set only by vision_true_close', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    IF n.status = 'shipped' AND v_found AND o.status <> 'shipped' THEN
      v_bad := ops._vision_open_blockers(o.id);
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '%: cannot be shipped while blocking backlog items are open: %', v_ctx, v_bad
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    IF e ? 'abandoned_reason' THEN
      v_str := ops._vision_str(v_ctx, e, 'abandoned_reason');
      IF v_str IS NOT NULL AND n.status <> 'abandoned' THEN
        RAISE EXCEPTION '%: abandoned_reason is set only on an abandoned item', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      n.abandoned_reason := v_str;
    END IF;
    IF n.status = 'abandoned' THEN
      IF n.abandoned_reason IS NULL OR length(btrim(n.abandoned_reason)) = 0 THEN
        RAISE EXCEPTION '%: status abandoned requires abandoned_reason', v_ctx USING ERRCODE = 'check_violation';
      END IF;
    ELSE
      n.abandoned_reason := NULL;
    END IF;
    IF n.status <> 'true_closed' THEN
      n.true_close_evidence := NULL;
      n.true_closed_at := NULL;
    END IF;

    -- tree rules: no cycle; home inside the parent's home subtree; children's homes inside this home
    IF v_found AND n.parent_id IS NOT NULL AND EXISTS (
         WITH RECURSIVE up AS (SELECT id, parent_id FROM ops.vision_items WHERE id = n.parent_id
                               UNION SELECT v.id, v.parent_id FROM ops.vision_items v JOIN up ON v.id = up.parent_id)
         SELECT 1 FROM up WHERE up.id = o.id) THEN
      RAISE EXCEPTION '%: parent_key % would make a cycle', v_ctx, e->>'parent_key' USING ERRCODE = 'check_violation';
    END IF;
    SELECT path INTO v_hpath FROM ops.nodes WHERE id = n.home_node_id;
    IF n.parent_id IS NOT NULL THEN
      SELECT nn.path, pp.key INTO v_ppath, v_str
        FROM ops.vision_items pp JOIN ops.nodes nn ON nn.id = pp.home_node_id WHERE pp.id = n.parent_id;
      IF NOT v_hpath OPERATOR(public.<@) v_ppath THEN
        RAISE EXCEPTION '%: home node % is outside the home subtree % of parent %', v_ctx, v_hpath, v_ppath, v_str
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
    IF v_found THEN
      SELECT c.key || ' (home ' || cn.path::text || ')' INTO v_bad
        FROM ops.vision_items c JOIN ops.nodes cn ON cn.id = c.home_node_id
       WHERE c.parent_id = o.id AND NOT cn.path OPERATOR(public.<@) v_hpath
       ORDER BY c.key LIMIT 1;
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '%: home node % would leave child % outside it', v_ctx, v_hpath, v_bad
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;

    -- write
    IF NOT v_found THEN
      INSERT INTO ops.vision_items (key, parent_id, home_node_id, title, intent, acceptance, status, phase, seq, sources,
                                    status_note, abandoned_reason, updated_session_id)
      VALUES (n.key, n.parent_id, n.home_node_id, n.title, n.intent, n.acceptance, n.status, n.phase, n.seq, n.sources,
              n.status_note, n.abandoned_reason, p_session)
      RETURNING * INTO n;
      INSERT INTO ops.vision_status_log (item_id, from_status, to_status, reason, session_id)
      VALUES (n.id, NULL, n.status, coalesce(v_reason, 'created'), p_session);
      IF v_req_given THEN
        INSERT INTO ops.vision_requires (item_id, kind, name)
        SELECT n.id, split_part(r, ':', 1), substr(r, strpos(r, ':') + 1) FROM unnest(v_req) r;
      END IF;
      v_ins := v_ins + 1;
    ELSE
      v_old_req := ARRAY(SELECT kind || ':' || name FROM ops.vision_requires WHERE item_id = o.id ORDER BY 1);
      v_changed := (n.parent_id, n.home_node_id, n.title, n.intent, n.acceptance, n.status, n.phase, n.seq, n.sources,
                    n.status_note, n.abandoned_reason, n.true_close_evidence, n.true_closed_at)
                   IS DISTINCT FROM
                   (o.parent_id, o.home_node_id, o.title, o.intent, o.acceptance, o.status, o.phase, o.seq, o.sources,
                    o.status_note, o.abandoned_reason, o.true_close_evidence, o.true_closed_at)
                   OR (v_req_given AND v_req IS DISTINCT FROM v_old_req);
      IF v_changed THEN
        UPDATE ops.vision_items
           SET parent_id = n.parent_id, home_node_id = n.home_node_id, title = n.title, intent = n.intent,
               acceptance = n.acceptance, status = n.status, phase = n.phase, seq = n.seq, sources = n.sources,
               status_note = n.status_note, abandoned_reason = n.abandoned_reason,
               true_close_evidence = n.true_close_evidence, true_closed_at = n.true_closed_at,
               updated_at = now(), updated_session_id = p_session
         WHERE id = o.id;
        IF v_req_given AND v_req IS DISTINCT FROM v_old_req THEN
          DELETE FROM ops.vision_requires WHERE item_id = o.id;
          INSERT INTO ops.vision_requires (item_id, kind, name)
          SELECT o.id, split_part(r, ':', 1), substr(r, strpos(r, ':') + 1) FROM unnest(v_req) r;
        END IF;
        v_upd := v_upd + 1;
      END IF;
      IF n.status <> o.status THEN
        INSERT INTO ops.vision_status_log (item_id, from_status, to_status, reason, session_id)
        VALUES (o.id, o.status, n.status, coalesce(v_reason, 'upsert'), p_session);
        v_chg := v_chg + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'status_changes', v_chg);
END $$;
REVOKE ALL ON FUNCTION ops.vision_upsert(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_upsert(jsonb, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.vision_upsert(jsonb, uuid) IS
  'Vision (08908ad9, 9144f3ef): insert or update vision items in array order; status log on insert and on every status change; true_closed only through vision_true_close.';

-- b. vision_link: decision, backlog and dispatch links; re-linking a pair updates its relation, role or reason
CREATE FUNCTION ops.vision_link(p_links jsonb, p_session uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE e jsonb; i integer := 0; v_ctx text; v_kind text; v_str text; v_ref uuid; v_bad text; v_val text; v_old text;
        v_item ops.vision_items; v_has_item boolean; d ops.dispatches; v_linked integer := 0; v_updated integer := 0;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  IF p_links IS NULL OR jsonb_typeof(p_links) <> 'array' OR jsonb_array_length(p_links) = 0 THEN
    RAISE EXCEPTION 'vision_link: p_links must be a non-empty JSON array of objects' USING ERRCODE = 'check_violation';
  END IF;
  FOR e IN SELECT t.x FROM jsonb_array_elements(p_links) WITH ORDINALITY t(x, ord) ORDER BY t.ord LOOP
    i := i + 1;
    v_ctx := 'vision_link element ' || i;
    IF jsonb_typeof(e) <> 'object' THEN
      RAISE EXCEPTION '%: not a JSON object', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    v_kind := ops._vision_str(v_ctx, e, 'kind');
    IF v_kind IS NULL OR v_kind NOT IN ('decision', 'backlog', 'dispatch') THEN
      RAISE EXCEPTION '%: kind must be decision, backlog or dispatch', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    SELECT string_agg(k, ', ' ORDER BY k) INTO v_bad FROM jsonb_object_keys(e) k
     WHERE k <> ALL (ARRAY['item_key', 'kind', 'ref', CASE v_kind WHEN 'decision' THEN 'relation'
                                                                   WHEN 'backlog' THEN 'role' ELSE 'none_reason' END]);
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '%: unknown field % for kind %', v_ctx, v_bad, v_kind USING ERRCODE = 'check_violation';
    END IF;
    v_str := ops._vision_str(v_ctx, e, 'ref');
    IF v_str IS NULL OR v_str !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION '%: ref must be a uuid', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    v_ref := v_str::uuid;
    v_item := NULL;
    v_str := ops._vision_str(v_ctx, e, 'item_key');
    IF v_str IS NOT NULL THEN
      SELECT * INTO v_item FROM ops.vision_items WHERE key = v_str;
      IF NOT FOUND THEN
        RAISE EXCEPTION '%: vision item % does not exist', v_ctx, v_str USING ERRCODE = 'check_violation';
      END IF;
    END IF;

    IF v_kind IN ('decision', 'backlog') THEN
      IF v_item.id IS NULL THEN
        RAISE EXCEPTION '%: kind % requires item_key', v_ctx, v_kind USING ERRCODE = 'check_violation';
      END IF;
      v_val := ops._vision_str(v_ctx, e, CASE v_kind WHEN 'decision' THEN 'relation' ELSE 'role' END);
      IF v_kind = 'decision' AND (v_val IS NULL OR v_val NOT IN ('defines', 'refines', 'sequencing', 'milestone',
                                                                 'constrains', 'process_rule', 'superseded', 'abandons')) THEN
        RAISE EXCEPTION '%: relation must be one of defines, refines, sequencing, milestone, constrains, process_rule, superseded, abandons', v_ctx
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_kind = 'backlog' AND (v_val IS NULL OR v_val NOT IN ('blocks', 'improves')) THEN
        RAISE EXCEPTION '%: role must be blocks or improves', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      IF v_kind = 'decision' AND NOT EXISTS (SELECT 1 FROM ops.decisions WHERE id = v_ref) THEN
        RAISE EXCEPTION '%: decision % does not exist', v_ctx, v_ref USING ERRCODE = 'check_violation';
      END IF;
      IF v_kind = 'backlog' AND NOT EXISTS (SELECT 1 FROM ops.backlog_items WHERE id = v_ref) THEN
        RAISE EXCEPTION '%: backlog item % does not exist', v_ctx, v_ref USING ERRCODE = 'check_violation';
      END IF;
      PERFORM ops._vision_session(p_session, v_item.home_node_id);
      IF v_kind = 'decision' THEN
        SELECT relation INTO v_old FROM ops.vision_decisions WHERE item_id = v_item.id AND decision_id = v_ref;
        IF NOT FOUND THEN
          INSERT INTO ops.vision_decisions (item_id, decision_id, relation, session_id)
          VALUES (v_item.id, v_ref, v_val, p_session);
          v_linked := v_linked + 1;
        ELSIF v_old <> v_val THEN
          UPDATE ops.vision_decisions SET relation = v_val, session_id = p_session, linked_at = now()
           WHERE item_id = v_item.id AND decision_id = v_ref;
          v_updated := v_updated + 1;
        END IF;
      ELSE
        SELECT role INTO v_old FROM ops.vision_backlog WHERE item_id = v_item.id AND backlog_id = v_ref;
        IF NOT FOUND THEN
          INSERT INTO ops.vision_backlog (item_id, backlog_id, role, session_id) VALUES (v_item.id, v_ref, v_val, p_session);
          v_linked := v_linked + 1;
        ELSIF v_old <> v_val THEN
          UPDATE ops.vision_backlog SET role = v_val, session_id = p_session, linked_at = now()
           WHERE item_id = v_item.id AND backlog_id = v_ref;
          v_updated := v_updated + 1;
        END IF;
      END IF;
    ELSE
      v_val := ops._vision_str(v_ctx, e, 'none_reason');
      IF (v_item.id IS NULL) = (v_val IS NULL) THEN
        RAISE EXCEPTION '%: kind dispatch takes exactly one of item_key and none_reason', v_ctx
          USING ERRCODE = 'check_violation';
      END IF;
      IF length(btrim(v_val)) = 0 THEN
        RAISE EXCEPTION '%: none_reason is blank', v_ctx USING ERRCODE = 'check_violation';
      END IF;
      SELECT * INTO d FROM ops.dispatches WHERE id = v_ref;
      IF NOT FOUND THEN
        RAISE EXCEPTION '%: dispatch % does not exist', v_ctx, v_ref USING ERRCODE = 'check_violation';
      END IF;
      IF v_item.id IS NOT NULL THEN
        PERFORM ops._vision_session(p_session, v_item.home_node_id);
        IF NOT EXISTS (SELECT 1 FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id = v_item.id) THEN
          INSERT INTO ops.vision_dispatches (dispatch_id, item_id, session_id) VALUES (v_ref, v_item.id, p_session);
          v_linked := v_linked + 1;
        END IF;
        DELETE FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id IS NULL;
      ELSE
        PERFORM ops._vision_session(p_session, (SELECT node_id FROM ops.components WHERE id = d.component_id));
        SELECT exists(SELECT 1 FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id IS NOT NULL) INTO v_has_item;
        IF v_has_item THEN
          RAISE EXCEPTION '%: dispatch % has item links; a none row is refused', v_ctx, v_ref USING ERRCODE = 'check_violation';
        END IF;
        SELECT none_reason INTO v_old FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id IS NULL;
        IF NOT FOUND THEN
          INSERT INTO ops.vision_dispatches (dispatch_id, none_reason, session_id) VALUES (v_ref, v_val, p_session);
          v_linked := v_linked + 1;
        ELSIF v_old <> v_val THEN
          UPDATE ops.vision_dispatches SET none_reason = v_val, session_id = p_session, linked_at = now()
           WHERE dispatch_id = v_ref AND item_id IS NULL;
          v_updated := v_updated + 1;
        END IF;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('linked', v_linked, 'updated', v_updated);
END $$;
REVOKE ALL ON FUNCTION ops.vision_link(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_link(jsonb, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.vision_link(jsonb, uuid) IS
  'Vision (08908ad9, 9144f3ef): link vision items to decisions (relation), backlog items (role) and dispatches (an item or a none_reason); re-linking updates.';

-- c. vision_unlink: remove the named links; an element that matches no link refuses the whole call
CREATE FUNCTION ops.vision_unlink(p_links jsonb, p_session uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE e jsonb; i integer := 0; v_ctx text; v_kind text; v_str text; v_ref uuid; v_bad text; v_item ops.vision_items;
        v_node uuid; v_n integer; v_removed integer := 0;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  IF p_links IS NULL OR jsonb_typeof(p_links) <> 'array' OR jsonb_array_length(p_links) = 0 THEN
    RAISE EXCEPTION 'vision_unlink: p_links must be a non-empty JSON array of objects' USING ERRCODE = 'check_violation';
  END IF;
  FOR e IN SELECT t.x FROM jsonb_array_elements(p_links) WITH ORDINALITY t(x, ord) ORDER BY t.ord LOOP
    i := i + 1;
    v_ctx := 'vision_unlink element ' || i;
    IF jsonb_typeof(e) <> 'object' THEN
      RAISE EXCEPTION '%: not a JSON object', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    SELECT string_agg(k, ', ' ORDER BY k) INTO v_bad FROM jsonb_object_keys(e) k WHERE k <> ALL (ARRAY['item_key', 'kind', 'ref']);
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION '%: unknown field %', v_ctx, v_bad USING ERRCODE = 'check_violation';
    END IF;
    v_kind := ops._vision_str(v_ctx, e, 'kind');
    IF v_kind IS NULL OR v_kind NOT IN ('decision', 'backlog', 'dispatch') THEN
      RAISE EXCEPTION '%: kind must be decision, backlog or dispatch', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    v_str := ops._vision_str(v_ctx, e, 'ref');
    IF v_str IS NULL OR v_str !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION '%: ref must be a uuid', v_ctx USING ERRCODE = 'check_violation';
    END IF;
    v_ref := v_str::uuid;
    v_item := NULL;
    v_str := ops._vision_str(v_ctx, e, 'item_key');
    IF v_str IS NOT NULL THEN
      SELECT * INTO v_item FROM ops.vision_items WHERE key = v_str;
      IF NOT FOUND THEN
        RAISE EXCEPTION '%: vision item % does not exist', v_ctx, v_str USING ERRCODE = 'check_violation';
      END IF;
    ELSIF v_kind <> 'dispatch' THEN
      RAISE EXCEPTION '%: kind % requires item_key', v_ctx, v_kind USING ERRCODE = 'check_violation';
    END IF;

    IF v_item.id IS NOT NULL THEN
      PERFORM ops._vision_session(p_session, v_item.home_node_id);
    ELSE
      SELECT c.node_id INTO v_node FROM ops.dispatches d JOIN ops.components c ON c.id = d.component_id WHERE d.id = v_ref;
      IF NOT FOUND THEN
        RAISE EXCEPTION '%: dispatch % has no none row', v_ctx, v_ref USING ERRCODE = 'check_violation';
      END IF;
      PERFORM ops._vision_session(p_session, v_node);
    END IF;

    CASE v_kind
      WHEN 'decision' THEN DELETE FROM ops.vision_decisions WHERE item_id = v_item.id AND decision_id = v_ref;
      WHEN 'backlog' THEN DELETE FROM ops.vision_backlog WHERE item_id = v_item.id AND backlog_id = v_ref;
      ELSE
        IF v_item.id IS NULL THEN
          DELETE FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id IS NULL;
        ELSE
          DELETE FROM ops.vision_dispatches WHERE dispatch_id = v_ref AND item_id = v_item.id;
        END IF;
    END CASE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
      IF v_item.id IS NULL THEN
        RAISE EXCEPTION '%: dispatch % has no none row', v_ctx, v_ref USING ERRCODE = 'check_violation';
      END IF;
      RAISE EXCEPTION '%: no % link from vision item % to %', v_ctx, v_kind, v_item.key, v_ref USING ERRCODE = 'check_violation';
    END IF;
    v_removed := v_removed + v_n;
  END LOOP;
  RETURN v_removed;
END $$;
REVOKE ALL ON FUNCTION ops.vision_unlink(jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_unlink(jsonb, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.vision_unlink(jsonb, uuid) IS
  'Vision (08908ad9, 9144f3ef): remove the named vision links; an element that matches no link refuses the whole call.';

-- d. vision_set_status: one status change with its reason
CREATE FUNCTION ops.vision_set_status(p_key text, p_status text, p_reason text, p_session uuid,
                                      p_abandoned_reason text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE o ops.vision_items; v_bad text;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o FROM ops.vision_items WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'vision item % does not exist', p_key USING ERRCODE = 'check_violation';
  END IF;
  PERFORM ops._vision_session(p_session, o.home_node_id);
  IF length(btrim(coalesce(p_reason, ''))) = 0 THEN
    RAISE EXCEPTION 'vision item %: reason is required', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('idea', 'designed', 'partial', 'shipped', 'true_closed', 'abandoned') THEN
    RAISE EXCEPTION 'vision item %: status % is not one of idea, designed, partial, shipped, true_closed, abandoned',
      p_key, p_status USING ERRCODE = 'check_violation';
  END IF;
  IF p_abandoned_reason IS NOT NULL AND p_status <> 'abandoned' THEN
    RAISE EXCEPTION 'vision item %: abandoned_reason is set only on an abandoned item', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_status = o.status THEN
    RETURN false;
  END IF;
  IF p_status = 'true_closed' THEN
    RAISE EXCEPTION 'vision item %: status true_closed is set only by vision_true_close', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF p_status = 'shipped' THEN
    v_bad := ops._vision_open_blockers(o.id);
    IF v_bad IS NOT NULL THEN
      RAISE EXCEPTION 'vision item %: cannot be shipped while blocking backlog items are open: %', p_key, v_bad
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  IF p_status = 'abandoned' AND length(btrim(coalesce(p_abandoned_reason, ''))) = 0 THEN
    RAISE EXCEPTION 'vision item %: status abandoned requires abandoned_reason', p_key USING ERRCODE = 'check_violation';
  END IF;
  UPDATE ops.vision_items
     SET status = p_status, abandoned_reason = CASE WHEN p_status = 'abandoned' THEN p_abandoned_reason END,
         true_close_evidence = NULL, true_closed_at = NULL, updated_at = now(), updated_session_id = p_session
   WHERE id = o.id;
  INSERT INTO ops.vision_status_log (item_id, from_status, to_status, reason, session_id)
  VALUES (o.id, o.status, p_status, p_reason, p_session);
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION ops.vision_set_status(text, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_set_status(text, text, text, uuid, text) TO ops_planner;
COMMENT ON FUNCTION ops.vision_set_status(text, text, text, uuid, text) IS
  'Vision (08908ad9, 9144f3ef): change one item''s status with a reason (false when unchanged); true_closed only through vision_true_close.';

-- e. vision_true_close: shipped -> true_closed with evidence
CREATE FUNCTION ops.vision_true_close(p_key text, p_evidence text, p_session uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, pg_temp AS $$
DECLARE o ops.vision_items; v_bad text;
BEGIN
  IF p_session IS NULL THEN
    RAISE EXCEPTION 'session is required (segment_id)' USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO o FROM ops.vision_items WHERE key = p_key FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'vision item % does not exist', p_key USING ERRCODE = 'check_violation';
  END IF;
  PERFORM ops._vision_session(p_session, o.home_node_id);
  IF length(btrim(coalesce(p_evidence, ''))) = 0 THEN
    RAISE EXCEPTION 'vision item %: evidence is required', p_key USING ERRCODE = 'check_violation';
  END IF;
  IF o.status <> 'shipped' THEN
    RAISE EXCEPTION 'vision item %: is %, not shipped', p_key, o.status USING ERRCODE = 'check_violation';
  END IF;
  v_bad := ops._vision_open_blockers(o.id);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'vision item %: cannot be true-closed while blocking backlog items are open: %', p_key, v_bad
      USING ERRCODE = 'check_violation';
  END IF;
  UPDATE ops.vision_items
     SET status = 'true_closed', true_closed_at = now(), true_close_evidence = p_evidence, updated_at = now(),
         updated_session_id = p_session
   WHERE id = o.id;
  INSERT INTO ops.vision_status_log (item_id, from_status, to_status, reason, session_id)
  VALUES (o.id, 'shipped', 'true_closed', p_evidence, p_session);
END $$;
REVOKE ALL ON FUNCTION ops.vision_true_close(text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_true_close(text, text, uuid) TO ops_planner;
COMMENT ON FUNCTION ops.vision_true_close(text, text, uuid) IS
  'Vision (08908ad9, 9144f3ef): true-close a shipped item with evidence; called only after the operator''s explicit yes.';

-- f. vision_check: drift and gaps, computed on read
CREATE FUNCTION ops.vision_check()
RETURNS TABLE (check_kind text, item_key text, ref uuid, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, pg_temp AS $$
BEGIN
  RETURN QUERY
  SELECT q.k, q.ik, q.r, q.dt FROM (
    SELECT 'missing_object'::text AS k, i.key AS ik, NULL::uuid AS r, rs.kind || ':' || rs.name AS dt
      FROM ops.vision_items i JOIN ops.vision_requires_status rs ON rs.item_key = i.key
     WHERE i.status IN ('shipped', 'true_closed') AND NOT rs.present
    UNION ALL
    SELECT 'open_blocker', i.key, b.id, b.title
      FROM ops.vision_items i JOIN ops.vision_backlog vb ON vb.item_id = i.id
      JOIN ops.backlog_items b ON b.id = vb.backlog_id
     WHERE i.status IN ('shipped', 'true_closed') AND vb.role = 'blocks' AND b.status = 'open'
    UNION ALL
    SELECT 'status_lag', s.key, NULL, 'all ' || s.requires_total || ' required objects exist'
      FROM ops.vision_status s
     WHERE s.status IN ('idea', 'designed') AND s.requires_total > 0 AND s.requires_missing = 0
    UNION ALL
    SELECT 'rollup_mismatch', s.key, NULL, 'stored ' || s.status || ', children ' || s.rollup_status
      FROM ops.vision_status s
     WHERE s.rollup_status IS NOT NULL AND s.status <> s.rollup_status
    UNION ALL
    SELECT 'abandoned_parent', c.key, NULL, p.key
      FROM ops.vision_items c JOIN ops.vision_items p ON p.id = c.parent_id
     WHERE p.status = 'abandoned' AND c.status <> 'abandoned'
    UNION ALL
    SELECT 'unlinked_decision', NULL, dc.id, left(dc.decision, 80)
      FROM ops.decisions dc WHERE NOT EXISTS (SELECT 1 FROM ops.vision_decisions vd WHERE vd.decision_id = dc.id)
    UNION ALL
    SELECT 'unlinked_backlog', NULL, b.id, left(b.title, 80)
      FROM ops.backlog_items b WHERE NOT EXISTS (SELECT 1 FROM ops.vision_backlog vb WHERE vb.backlog_id = b.id)
    UNION ALL
    SELECT 'unlinked_dispatch', NULL, d.id, left(d.title, 80)
      FROM ops.dispatches d WHERE NOT EXISTS (SELECT 1 FROM ops.vision_dispatches vx WHERE vx.dispatch_id = d.id)
    UNION ALL
    SELECT 'none_reason', NULL, vx.dispatch_id, vx.none_reason
      FROM ops.vision_dispatches vx WHERE vx.item_id IS NULL
  ) q
  ORDER BY q.k, q.ik NULLS LAST, q.r, q.dt;
END $$;
REVOKE ALL ON FUNCTION ops.vision_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.vision_check() TO ops_planner;
COMMENT ON FUNCTION ops.vision_check() IS
  'Vision (08908ad9, 9144f3ef): missing_object, open_blocker, status_lag, rollup_mismatch, abandoned_parent, unlinked_decision / _backlog / _dispatch and none_reason rows, computed on read.';

-- ── 5. grants: SELECT to ops_planner only; nothing for ops_executor or PUBLIC
REVOKE ALL ON ops.vision_items, ops.vision_requires, ops.vision_decisions, ops.vision_backlog, ops.vision_dispatches,
              ops.vision_status_log, ops.vision_requires_status, ops.vision_status FROM PUBLIC;
GRANT SELECT ON ops.vision_items, ops.vision_requires, ops.vision_decisions, ops.vision_backlog, ops.vision_dispatches,
                ops.vision_status_log, ops.vision_requires_status, ops.vision_status TO ops_planner;

-- ── 6. protocol rule vision_check (version left at its default of 1) and changelog
INSERT INTO ops.protocol_rules (key, value)
VALUES (
  'vision_check',
  jsonb_build_object(
    'rule', 'Build status lives only in ops.vision_items and changes only through the vision writer functions (vision_upsert, vision_set_status, vision_true_close; links through vision_link and vision_unlink). Every proposal and every dispatch names the vision item it advances, or states none with a reason; the planner''s create_dispatch tool records it in ops.vision_dispatches. An item is shipped only when none of its blocking backlog items is open; a true close needs the acceptance passed in real use, evidence and the operator''s explicit yes. The planner runs ops.vision_check() at milestone boundaries and before any true close, and raises what it reports.')
);
INSERT INTO ops.protocol_changelog (version, rule_keys, changes)
VALUES (
  11,
  ARRAY['vision_check'],
  'vision_check v1: build status lives in ops.vision_items; every proposal and dispatch names its vision item or a none-reason; vision_check() at milestones and before a true close (decisions 6cef3bf3, 08908ad9, 9144f3ef).'
);

-- ── 7. checks: any failure aborts the migration
DO $$
DECLARE v_owner text := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
        v_tables text[] := ARRAY['vision_backlog', 'vision_decisions', 'vision_dispatches', 'vision_items',
                                 'vision_requires', 'vision_status_log'];
        v_views text[] := ARRAY['vision_requires_status', 'vision_status'];
        v_fns regprocedure[] := ARRAY['ops.vision_upsert(jsonb, uuid)'::regprocedure, 'ops.vision_link(jsonb, uuid)',
                                      'ops.vision_unlink(jsonb, uuid)', 'ops.vision_set_status(text, text, text, uuid, text)',
                                      'ops.vision_true_close(text, text, uuid)', 'ops.vision_check()'];
        v_helpers regprocedure[] := ARRAY['ops._vision_session(uuid, uuid)'::regprocedure,
                                          'ops._vision_str(text, jsonb, text)', 'ops._vision_open_blockers(uuid)'];
        v_fn regprocedure; v_rel text; v_bad text; v_n uuid; v_s uuid; v_b uuid; v_j jsonb; v_e text;
BEGIN
  -- catalog of steps 2-6
  FOREACH v_rel IN ARRAY v_tables || v_views LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = to_regclass('ops.' || v_rel)
                      AND c.relkind = CASE WHEN v_rel = ANY (v_views) THEN 'v' ELSE 'r' END
                      AND pg_get_userbyid(c.relowner) = v_owner
                      AND obj_description(c.oid, 'pg_class') LIKE 'Vision (08908ad9, 9144f3ef): %') THEN
      RAISE EXCEPTION '0032: ops.% missing, wrong kind, owner or comment', v_rel;
    END IF;
    IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                  || ':' || a.privilege_type), '{}')
          FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = to_regclass('ops.' || v_rel) AND a.grantee <> c.relowner)
       <> ARRAY['ops_planner:SELECT'] THEN
      RAISE EXCEPTION '0032: ops.% ACL is not owner plus ops_planner SELECT', v_rel;
    END IF;
  END LOOP;
  IF (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute
       WHERE attrelid = 'ops.vision_status'::regclass AND attnum > 0)
     <> ARRAY['key', 'parent_key', 'home_path', 'title', 'status', 'phase', 'seq', 'rollup_status', 'children',
              'requires_total', 'requires_missing', 'decisions', 'backlog_open_blocks', 'backlog_open_improves',
              'backlog_closed', 'dispatches', 'updated_at']
     OR (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute
          WHERE attrelid = 'ops.vision_requires_status'::regclass AND attnum > 0)
     <> ARRAY['item_key', 'kind', 'name', 'present'] THEN
    RAISE EXCEPTION '0032: view columns differ from the specification';
  END IF;
  FOREACH v_fn IN ARRAY v_fns LOOP
    IF NOT (SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                   AND obj_description(oid, 'pg_proc') LIKE 'Vision (08908ad9, 9144f3ef): %'
              FROM pg_proc WHERE oid = v_fn) THEN
      RAISE EXCEPTION '0032: % is not SECURITY DEFINER with search_path ops, pg_temp owned by % with its comment', v_fn, v_owner;
    END IF;
    IF (SELECT coalesce(array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END), '{}')
          FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner) <> ARRAY['ops_planner'] THEN
      RAISE EXCEPTION '0032: % ACL is not owner plus ops_planner', v_fn;
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY v_helpers LOOP
    IF NOT (SELECT prosecdef AND pg_get_userbyid(proowner) = v_owner FROM pg_proc WHERE oid = v_fn)
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner) THEN
      RAISE EXCEPTION '0032: helper % is not owner-only', v_fn;
    END IF;
  END LOOP;
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'ops.vision_check()'::regprocedure) <> 's' THEN
    RAISE EXCEPTION '0032: vision_check is not STABLE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.protocol_rules WHERE key = 'vision_check' AND version = 1
                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(value) k) = ARRAY['rule'])
     OR (SELECT count(*) FROM ops.protocol_changelog WHERE version = 11) <> 1
     OR NOT EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 11 AND rule_keys = ARRAY['vision_check'])
     OR (SELECT max(version) FROM ops.protocol_changelog) <> 11 THEN
    RAISE EXCEPTION '0032: vision_check rule or protocol_changelog version 11 missing or wrong';
  END IF;

  -- nothing else changed
  IF (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname), '{}') FROM pg_class c
       WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
         AND has_table_privilege('ops_executor', c.oid, 'SELECT'))::text <> current_setting('ops_m0032.executor_reads')
     OR (SELECT coalesce(array_agg(DISTINCT p.proname::text ORDER BY p.proname::text), '{}') FROM pg_proc p
          WHERE p.pronamespace = 'ops'::regnamespace AND has_function_privilege('ops_executor', p.oid, 'EXECUTE'))::text
        <> current_setting('ops_m0032.executor_fns') THEN
    RAISE EXCEPTION '0032: ops_executor SELECT or EXECUTE set changed';
  END IF;
  SELECT string_agg(c.relname || ' ' || p, ', ') INTO v_bad
    FROM pg_class c, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) p
   WHERE c.relnamespace = 'ops'::regnamespace AND c.relkind IN ('r', 'v', 'p', 'm', 'f')
     AND has_table_privilege('ops_planner', c.oid, p);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '0032: ops_planner holds table writes: %', v_bad;
  END IF;
  IF (SELECT md5(string_agg(key || version::text || value::text, '|' ORDER BY key))
        FROM ops.protocol_rules WHERE key <> 'vision_check')
     IS DISTINCT FROM current_setting('ops_m0032.rules_md5') THEN
    RAISE EXCEPTION '0032: other protocol_rules rows changed';
  END IF;

  -- behaviour on a probe node under global with its own session, rolled back by a sentinel
  BEGIN
    INSERT INTO ops.nodes (parent_id, key, kind, title)
    VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0032probe', 'node', '0032 probe') RETURNING id INTO v_n;
    v_s := ops.open_session(p_node_path => 'global.t0032probe'::public.ltree, p_kind => 'planning');
    v_j := ops.vision_upsert(jsonb_build_array(
      jsonb_build_object('key', 't0032probe', 'parent_key', NULL, 'home_node_path', 'global.t0032probe', 'title', 'probe',
                         'intent', 'i', 'acceptance', 'a', 'status', 'partial', 'phase', 'setup'),
      jsonb_build_object('key', 't0032probe.present', 'parent_key', 't0032probe', 'home_node_path', 'global.t0032probe',
                         'title', 'present', 'intent', 'i', 'acceptance', 'a', 'status', 'designed', 'phase', 'setup',
                         'requires', jsonb_build_array('table:nodes')),
      jsonb_build_object('key', 't0032probe.missing', 'parent_key', 't0032probe', 'home_node_path', 'global.t0032probe',
                         'title', 'missing', 'intent', 'i', 'acceptance', 'a', 'status', 'shipped', 'phase', 'setup',
                         'requires', jsonb_build_array('function:no_such_fn_t0032')),
      jsonb_build_object('key', 't0032probe.blocked', 'parent_key', 't0032probe', 'home_node_path', 'global.t0032probe',
                         'title', 'blocked', 'intent', 'i', 'acceptance', 'a', 'status', 'designed', 'phase', 'setup')), v_s);
    IF v_j IS DISTINCT FROM '{"inserted": 4, "updated": 0, "status_changes": 0}'::jsonb THEN
      RAISE EXCEPTION USING ERRCODE = 'P0932', MESSAGE = 'upsert result ' || coalesce(v_j::text, 'null');
    END IF;
    v_b := (ops.add_backlog_item('global.t0032probe'::public.ltree, 'task', '0032 probe blocker')).id;
    PERFORM ops.vision_link(jsonb_build_array(jsonb_build_object('item_key', 't0032probe.blocked', 'kind', 'backlog',
                                                                 'ref', v_b, 'role', 'blocks')), v_s);
    BEGIN
      PERFORM ops.vision_set_status('t0032probe.blocked', 'shipped', '0032 probe', v_s);
      v_e := 'success';
    EXCEPTION WHEN OTHERS THEN
      v_e := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_e IS DISTINCT FROM '23514 vision item t0032probe.blocked: cannot be shipped while blocking backlog items are open: '
                            || left(v_b::text, 8) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0932', MESSAGE = 'shipped with an open blocker: ' || coalesce(v_e, 'null');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ops.vision_check() WHERE check_kind = 'missing_object' AND item_key = 't0032probe.missing'
                      AND detail = 'function:no_such_fn_t0032')
       OR NOT EXISTS (SELECT 1 FROM ops.vision_check() WHERE check_kind = 'status_lag' AND item_key = 't0032probe.present'
                         AND detail = 'all 1 required objects exist') THEN
      RAISE EXCEPTION USING ERRCODE = 'P0932', MESSAGE = 'vision_check lacks missing_object or status_lag';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0932', MESSAGE = 'true';
  EXCEPTION WHEN SQLSTATE 'P0932' THEN
    v_bad := SQLERRM;
  END;
  IF v_bad IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION '0032: vision probe failed (%)', v_bad;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.nodes WHERE path::text = 'global.t0032probe')
     OR EXISTS (SELECT 1 FROM ops.vision_items) OR EXISTS (SELECT 1 FROM ops.vision_requires)
     OR EXISTS (SELECT 1 FROM ops.vision_backlog) OR EXISTS (SELECT 1 FROM ops.vision_status_log)
     OR EXISTS (SELECT 1 FROM ops.backlog_items WHERE title = '0032 probe blocker') THEN
    RAISE EXCEPTION '0032: probe rows were not rolled back';
  END IF;
  RAISE NOTICE '0032 checks passed';
END $$;

INSERT INTO ops.schema_migrations (version) VALUES ('0032_vision_items');

COMMIT;
