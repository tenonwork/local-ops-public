-- tests/sql/0032_vision_items.sql
-- Tests for migrations/0032_vision_items.sql. Run as the schema owner against a non-production database where 0032 is
-- applied:
--   psql -X -q -v ON_ERROR_STOP=1 postgresql://ops_dev@localhost:5432/local_ops_rehearsal -f tests/sql/0032_vision_items.sql
-- Everything runs in one transaction that ends in ROLLBACK, so the file is rerunnable and leaves no rows.
-- The transaction runs with search_path = ops, pg_temp, as every ops function does, so ltree values are compared
-- as text or with OPERATOR(public.<op>).
-- Each assertion is a DO block that raises on failure; ON_ERROR_STOP turns that into exit 3.
-- State-independent: the file creates its own nodes global.t0032a (with component ca) and global.t0032b, a session on
-- each, and its own decision, backlog item and dispatch fixtures; it asserts only on vision items, links and records it
-- creates (vision_check rows are filtered to them), never on global counts. Grants are checked at catalog level
-- (b28e2660): ops_dev is not a member of ops_planner.

\encoding UTF8
\set ON_ERROR_STOP 1

DO $$ BEGIN
  IF current_database() = 'local_ops' THEN
    RAISE EXCEPTION 'refusing to run tests against production (local_ops)';
  END IF;
END $$;

-- row counts before the transaction, kept in a session setting so the final check can read them
DO $$ BEGIN
  PERFORM set_config('ops_test.counts_before', (SELECT jsonb_build_object(
    'vision_items', (SELECT count(*) FROM ops.vision_items), 'vision_requires', (SELECT count(*) FROM ops.vision_requires),
    'vision_decisions', (SELECT count(*) FROM ops.vision_decisions), 'vision_backlog', (SELECT count(*) FROM ops.vision_backlog),
    'vision_dispatches', (SELECT count(*) FROM ops.vision_dispatches),
    'vision_status_log', (SELECT count(*) FROM ops.vision_status_log),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules), 'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog),
    'nodes', (SELECT count(*) FROM ops.nodes), 'components', (SELECT count(*) FROM ops.components),
    'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items), 'dispatches', (SELECT count(*) FROM ops.dispatches)))::text,
    false);
END $$;

BEGIN;
SET LOCAL search_path = ops, pg_temp;

CREATE FUNCTION pg_temp.check(p_ok boolean, p_what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', p_what; END IF;
END $$;

-- runs p_sql in a subtransaction; returns 'SQLSTATE message' on error, NULL on success
CREATE FUNCTION pg_temp.err(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END $$;

CREATE FUNCTION pg_temp.id(p_name text) RETURNS uuid LANGUAGE sql AS $$
  SELECT current_setting('ops_test.' || p_name)::uuid;
$$;

-- a new item object homed on global.t0032a (or p_extra's home), status idea, phase setup
CREATE FUNCTION pg_temp.new_item(p_key text, p_parent text, p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('key', p_key, 'parent_key', p_parent, 'home_node_path', 'global.t0032a', 'title', 'T ' || p_key,
                            'intent', 'I ' || p_key, 'acceptance', 'A ' || p_key, 'status', 'idea', 'phase', 'setup') || p_extra;
$$;

CREATE FUNCTION pg_temp.up(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT ops.vision_upsert(p_items, pg_temp.id('s'));
$$;

CREATE FUNCTION pg_temp.up_err(p_items jsonb, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.vision_upsert(%L::jsonb, %L::uuid)', p_items, p_session));
$$;

CREATE FUNCTION pg_temp.up_err(p_items jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.up_err(p_items, pg_temp.id('s'));
$$;

CREATE FUNCTION pg_temp.link(p_links jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT ops.vision_link(p_links, pg_temp.id('s'));
$$;

CREATE FUNCTION pg_temp.link_err(p_links jsonb, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.vision_link(%L::jsonb, %L::uuid)', p_links, p_session));
$$;

CREATE FUNCTION pg_temp.link_err(p_links jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.link_err(p_links, pg_temp.id('s'));
$$;

CREATE FUNCTION pg_temp.unlink_err(p_links jsonb, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.vision_unlink(%L::jsonb, %L::uuid)', p_links, p_session));
$$;

CREATE FUNCTION pg_temp.unlink_err(p_links jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.unlink_err(p_links, pg_temp.id('s'));
$$;

CREATE FUNCTION pg_temp.set_err(p_key text, p_status text, p_reason text, p_session uuid, p_abandoned text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.vision_set_status(%L, %L, %L, %L::uuid, %L)', p_key, p_status, p_reason, p_session, p_abandoned));
$$;

CREATE FUNCTION pg_temp.close_err(p_key text, p_evidence text, p_session uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.err(format('SELECT ops.vision_true_close(%L, %L, %L::uuid)', p_key, p_evidence, p_session));
$$;

CREATE FUNCTION pg_temp.item(p_key text) RETURNS ops.vision_items LANGUAGE sql AS $$
  SELECT * FROM ops.vision_items WHERE key = p_key;
$$;

CREATE FUNCTION pg_temp.logs(p_key text) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM ops.vision_status_log l JOIN ops.vision_items i ON i.id = l.item_id WHERE i.key = p_key;
$$;

CREATE FUNCTION pg_temp.reqs(p_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(r.kind || ':' || r.name ORDER BY r.kind || ':' || r.name), '{}')
    FROM ops.vision_requires r JOIN ops.vision_items i ON i.id = r.item_id WHERE i.key = p_key;
$$;

CREATE FUNCTION pg_temp.backlog(p_title text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.add_backlog_item('global.t0032a'::public.ltree, 'task', p_title)).id;
$$;

CREATE FUNCTION pg_temp.dispatch(p_title text) RETURNS uuid LANGUAGE sql AS $$
  SELECT (ops.create_dispatch(p_node_path => 'global.t0032a.ca'::public.ltree, p_dispatch_type => 'modification',
                              p_title => p_title, p_prompt => 'p', p_session => pg_temp.id('s'))).id;
$$;

-- vision_check rows for the given item keys or refs
CREATE FUNCTION pg_temp.vc(p_keys text[], p_refs uuid[]) RETURNS text[] LANGUAGE sql AS $$
  SELECT coalesce(array_agg(check_kind || '|' || coalesce(item_key, '-') || '|' || coalesce(ref::text, '-') || '|' || detail
                            ORDER BY check_kind, item_key, ref, detail), '{}')
    FROM ops.vision_check() WHERE item_key = ANY (p_keys) OR ref = ANY (p_refs);
$$;

-- 0. fixtures: nodes global.t0032a (component ca) and global.t0032b, a session on each, decision, backlog, dispatches
DO $$
DECLARE c ops.components;
BEGIN
  PERFORM pg_temp.check(current_setting('search_path') = 'ops, pg_temp', 'search_path is ops, pg_temp');
  INSERT INTO ops.nodes (parent_id, key, kind, title)
  VALUES ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0032a', 'node', 'T0032 A'),
         ((SELECT id FROM ops.nodes WHERE path::text = 'global'), 't0032b', 'node', 'T0032 B');
  c := ops.create_component('global.t0032a'::public.ltree, 'ca', 'service', NULL, 'npm test');
  PERFORM set_config('ops_test.s', ops.open_session(p_node_path => 'global.t0032a'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.sb', ops.open_session(p_node_path => 'global.t0032b'::public.ltree, p_kind => 'planning')::text, true);
  PERFORM set_config('ops_test.dec', (ops.log_decision(p_node_path => 'global.t0032a'::public.ltree,
    p_decision => 't0032 fixture decision: a long text so that vision_check cuts it at eighty characters, not later than that',
    p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.dec2', (ops.log_decision(p_node_path => 'global.t0032a'::public.ltree,
    p_decision => 't0032 second decision', p_session => pg_temp.id('s'))).id::text, true);
  PERFORM set_config('ops_test.bl', pg_temp.backlog('t0032 fixture backlog')::text, true);
  PERFORM set_config('ops_test.d1', pg_temp.dispatch('t0032 fixture dispatch 1')::text, true);
  PERFORM set_config('ops_test.d2', pg_temp.dispatch('t0032 fixture dispatch 2')::text, true);
  RAISE NOTICE 'ok   0 fixtures (global.t0032a/ca, global.t0032b, sessions, decisions, backlog item, dispatches)';
END $$;

-- a. catalog 0032 establishes (bounded: asserted while 0032 is the newest migration)
DO $$
DECLARE newest text := (SELECT max(version) FROM ops.schema_migrations); v_owner text; v_fn regprocedure; v_rel text;
BEGIN
  IF NOT (newest >= '0032' AND newest < '0033') THEN
    RAISE NOTICE 'skip a catalog of 0032 (newest migration is %)', newest;
    RETURN;
  END IF;
  v_owner := (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'ops');
  -- catalog text (constraint, index and type names) is rendered with schema-qualified names: no ops on the path here
  PERFORM set_config('search_path', 'pg_catalog, pg_temp', true);

  -- tables and views: kind, owner, columns, comment
  PERFORM pg_temp.check((SELECT array_agg(c.relname::text || ':' || c.relkind::text ORDER BY c.relname) FROM pg_class c
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relname LIKE 'vision%' AND c.relkind IN ('r', 'v', 'p', 'm'))
                        = ARRAY['vision_backlog:r', 'vision_decisions:r', 'vision_dispatches:r', 'vision_items:r',
                                'vision_requires:r', 'vision_requires_status:v', 'vision_status:v', 'vision_status_log:r'],
                        'a the six tables and two views');
  FOREACH v_rel IN ARRAY ARRAY['vision_backlog', 'vision_decisions', 'vision_dispatches', 'vision_items', 'vision_requires',
                               'vision_requires_status', 'vision_status', 'vision_status_log'] LOOP
    PERFORM pg_temp.check((SELECT pg_get_userbyid(relowner) = v_owner
                                  AND obj_description(oid, 'pg_class') LIKE 'Vision (08908ad9, 9144f3ef): %'
                             FROM pg_class WHERE oid = ('ops.' || v_rel)::regclass), 'a owner and comment of ' || v_rel);
  END LOOP;
  PERFORM pg_temp.check((SELECT array_agg(c.relname || ': ' || x.cols ORDER BY c.relname) FROM pg_class c
                           CROSS JOIN LATERAL (SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
                                                                 || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END, ', ' ORDER BY a.attnum) AS cols
                                                 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) x
                          WHERE c.relnamespace = 'ops'::regnamespace AND c.relname LIKE 'vision%' AND c.relkind IN ('r', 'v'))
                        = ARRAY[
    'vision_backlog: item_id uuid not null, backlog_id uuid not null, role text not null, session_id uuid not null, linked_at timestamp with time zone not null',
    'vision_decisions: item_id uuid not null, decision_id uuid not null, relation text not null, session_id uuid not null, linked_at timestamp with time zone not null',
    'vision_dispatches: id uuid not null, dispatch_id uuid not null, item_id uuid, none_reason text, session_id uuid not null, linked_at timestamp with time zone not null',
    'vision_items: id uuid not null, key text not null, parent_id uuid, home_node_id uuid not null, title text not null, intent text not null, acceptance text not null, status text not null, phase text not null, seq integer not null, sources text[] not null, status_note text, abandoned_reason text, true_close_evidence text, true_closed_at timestamp with time zone, created_at timestamp with time zone not null, updated_at timestamp with time zone not null, updated_session_id uuid not null',
    'vision_requires: item_id uuid not null, kind text not null, name text not null',
    'vision_requires_status: item_key text, kind text, name text, present boolean',
    'vision_status: key text, parent_key text, home_path public.ltree, title text, status text, phase text, seq integer, rollup_status text, children bigint, requires_total bigint, requires_missing bigint, decisions bigint, backlog_open_blocks bigint, backlog_open_improves bigint, backlog_closed bigint, dispatches bigint, updated_at timestamp with time zone',
    'vision_status_log: id bigint not null, item_id uuid not null, from_status text, to_status text not null, reason text not null, session_id uuid not null, at timestamp with time zone not null'],
                        'a columns of the tables and views');
  PERFORM pg_temp.check((SELECT attidentity FROM pg_attribute WHERE attrelid = 'ops.vision_status_log'::regclass AND attname = 'id') = 'a'
                        AND (SELECT pg_get_expr(adbin, adrelid) FROM pg_attrdef WHERE adrelid = 'ops.vision_items'::regclass
                               AND adnum = (SELECT attnum FROM pg_attribute WHERE attrelid = 'ops.vision_items'::regclass AND attname = 'id'))
                            = 'gen_random_uuid()',
                        'a identity and uuid defaults');

  -- constraints: every FK, PK, unique and check by definition (sources_clean by its leading clause; it holds \x01)
  PERFORM pg_temp.check((SELECT array_agg(conrelid::regclass::text || ' ' || conname || ' ' || pg_get_constraintdef(oid)
                                          ORDER BY conrelid::regclass::text, conname)
                           FROM pg_constraint WHERE conrelid::regclass::text LIKE 'ops.vision%' AND contype IN ('c', 'f', 'p', 'u')
                            AND conname <> 'vision_items_sources_clean')
                        = ARRAY[
    'ops.vision_backlog vision_backlog_backlog_id_fkey FOREIGN KEY (backlog_id) REFERENCES ops.backlog_items(id)',
    'ops.vision_backlog vision_backlog_item_id_fkey FOREIGN KEY (item_id) REFERENCES ops.vision_items(id)',
    'ops.vision_backlog vision_backlog_pkey PRIMARY KEY (item_id, backlog_id)',
    'ops.vision_backlog vision_backlog_role_check CHECK ((role = ANY (ARRAY[''blocks''::text, ''improves''::text])))',
    'ops.vision_backlog vision_backlog_session_id_fkey FOREIGN KEY (session_id) REFERENCES ops.sessions(id)',
    'ops.vision_decisions vision_decisions_decision_id_fkey FOREIGN KEY (decision_id) REFERENCES ops.decisions(id)',
    'ops.vision_decisions vision_decisions_item_id_fkey FOREIGN KEY (item_id) REFERENCES ops.vision_items(id)',
    'ops.vision_decisions vision_decisions_pkey PRIMARY KEY (item_id, decision_id)',
    'ops.vision_decisions vision_decisions_relation_check CHECK ((relation = ANY (ARRAY[''defines''::text, ''refines''::text, ''sequencing''::text, ''milestone''::text, ''constrains''::text, ''process_rule''::text, ''superseded''::text, ''abandons''::text])))',
    'ops.vision_decisions vision_decisions_session_id_fkey FOREIGN KEY (session_id) REFERENCES ops.sessions(id)',
    'ops.vision_dispatches vision_dispatches_dispatch_id_fkey FOREIGN KEY (dispatch_id) REFERENCES ops.dispatches(id)',
    'ops.vision_dispatches vision_dispatches_item_id_fkey FOREIGN KEY (item_id) REFERENCES ops.vision_items(id)',
    'ops.vision_dispatches vision_dispatches_item_or_none CHECK (((item_id IS NULL) = (none_reason IS NOT NULL)))',
    'ops.vision_dispatches vision_dispatches_none_reason_check CHECK (((none_reason IS NULL) OR (length(btrim(none_reason)) > 0)))',
    'ops.vision_dispatches vision_dispatches_pkey PRIMARY KEY (id)',
    'ops.vision_dispatches vision_dispatches_session_id_fkey FOREIGN KEY (session_id) REFERENCES ops.sessions(id)',
    'ops.vision_items vision_items_abandoned_reason CHECK (((status = ''abandoned''::text) = ((abandoned_reason IS NOT NULL) AND (length(btrim(abandoned_reason)) > 0))))',
    'ops.vision_items vision_items_acceptance_check CHECK ((length(btrim(acceptance)) > 0))',
    'ops.vision_items vision_items_check CHECK ((parent_id <> id))',
    'ops.vision_items vision_items_home_node_id_fkey FOREIGN KEY (home_node_id) REFERENCES ops.nodes(id)',
    'ops.vision_items vision_items_intent_check CHECK ((length(btrim(intent)) > 0))',
    'ops.vision_items vision_items_key_check CHECK ((key ~ ''^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$''::text))',
    'ops.vision_items vision_items_key_key UNIQUE (key)',
    'ops.vision_items vision_items_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES ops.vision_items(id)',
    'ops.vision_items vision_items_phase_check CHECK ((phase = ANY (ARRAY[''setup''::text, ''tune''::text, ''test''::text, ''import''::text, ''later''::text])))',
    'ops.vision_items vision_items_pkey PRIMARY KEY (id)',
    'ops.vision_items vision_items_seq_check CHECK ((seq >= 0))',
    'ops.vision_items vision_items_status_check CHECK ((status = ANY (ARRAY[''idea''::text, ''designed''::text, ''partial''::text, ''shipped''::text, ''true_closed''::text, ''abandoned''::text])))',
    'ops.vision_items vision_items_status_note_check CHECK (((status_note IS NULL) OR (length(btrim(status_note)) > 0)))',
    'ops.vision_items vision_items_title_check CHECK ((length(btrim(title)) > 0))',
    'ops.vision_items vision_items_true_close CHECK (((status = ''true_closed''::text) = ((true_close_evidence IS NOT NULL) AND (length(btrim(true_close_evidence)) > 0) AND (true_closed_at IS NOT NULL))))',
    'ops.vision_items vision_items_updated_session_id_fkey FOREIGN KEY (updated_session_id) REFERENCES ops.sessions(id)',
    'ops.vision_requires vision_requires_column_name CHECK (((kind <> ''column''::text) OR (name ~ ''^[^.[:space:]]+\.[^.[:space:]]+$''::text)))',
    'ops.vision_requires vision_requires_doc_name CHECK (((kind <> ''doc''::text) OR (name ~ ''^[^:[:space:]]+:[^:[:space:]]+$''::text)))',
    'ops.vision_requires vision_requires_item_id_fkey FOREIGN KEY (item_id) REFERENCES ops.vision_items(id) ON DELETE CASCADE',
    'ops.vision_requires vision_requires_kind_check CHECK ((kind = ANY (ARRAY[''function''::text, ''table''::text, ''view''::text, ''rule''::text, ''column''::text, ''doc''::text])))',
    'ops.vision_requires vision_requires_name_check CHECK ((length(btrim(name)) > 0))',
    'ops.vision_requires vision_requires_pkey PRIMARY KEY (item_id, kind, name)',
    'ops.vision_status_log vision_status_log_item_id_fkey FOREIGN KEY (item_id) REFERENCES ops.vision_items(id)',
    'ops.vision_status_log vision_status_log_pkey PRIMARY KEY (id)',
    'ops.vision_status_log vision_status_log_reason_check CHECK ((length(btrim(reason)) > 0))',
    'ops.vision_status_log vision_status_log_session_id_fkey FOREIGN KEY (session_id) REFERENCES ops.sessions(id)',
    'ops.vision_status_log vision_status_log_to_status_check CHECK ((to_status = ANY (ARRAY[''idea''::text, ''designed''::text, ''partial''::text, ''shipped''::text, ''true_closed''::text, ''abandoned''::text])))'],
                        'a constraints of the vision tables');
  PERFORM pg_temp.check((SELECT pg_get_constraintdef(oid) LIKE 'CHECK (((array_position(sources, NULL::text) IS NULL) AND ((cardinality(sources) = 0) OR %'
                           FROM pg_constraint WHERE conname = 'vision_items_sources_clean' AND conrelid = 'ops.vision_items'::regclass),
                        'a vision_items_sources_clean');
  PERFORM pg_temp.check((SELECT array_agg(pg_get_indexdef(i.indexrelid) ORDER BY pg_get_indexdef(i.indexrelid)) FROM pg_index i
                          WHERE i.indrelid::regclass::text LIKE 'ops.vision%' AND NOT i.indisprimary
                            AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid))
                        = ARRAY[
    'CREATE INDEX vision_backlog_backlog_idx ON ops.vision_backlog USING btree (backlog_id)',
    'CREATE INDEX vision_decisions_decision_idx ON ops.vision_decisions USING btree (decision_id)',
    'CREATE INDEX vision_items_home_node_idx ON ops.vision_items USING btree (home_node_id)',
    'CREATE INDEX vision_items_parent_idx ON ops.vision_items USING btree (parent_id)',
    'CREATE INDEX vision_status_log_item_at_idx ON ops.vision_status_log USING btree (item_id, at)',
    'CREATE UNIQUE INDEX vision_dispatches_item_uq ON ops.vision_dispatches USING btree (dispatch_id, item_id) WHERE (item_id IS NOT NULL)',
    'CREATE UNIQUE INDEX vision_dispatches_none_uq ON ops.vision_dispatches USING btree (dispatch_id) WHERE (item_id IS NULL)'],
                        'a indexes beside the keys');

  -- functions: identity arguments, results, volatility, SECURITY DEFINER, search_path, owner, comment
  PERFORM pg_temp.check((SELECT array_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') '
                                          || pg_get_function_result(p.oid) || ' ' || p.provolatile::text ORDER BY p.proname)
                           FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname LIKE '%vision%')
                        = ARRAY[
    '_vision_open_blockers(p_item uuid) text s',
    '_vision_session(p_session uuid, p_node_id uuid) void s',
    '_vision_str(p_ctx text, p_obj jsonb, p_field text) text i',
    'vision_check() TABLE(check_kind text, item_key text, ref uuid, detail text) s',
    'vision_link(p_links jsonb, p_session uuid) jsonb v',
    'vision_set_status(p_key text, p_status text, p_reason text, p_session uuid, p_abandoned_reason text) boolean v',
    'vision_true_close(p_key text, p_evidence text, p_session uuid) void v',
    'vision_unlink(p_links jsonb, p_session uuid) integer v',
    'vision_upsert(p_items jsonb, p_session uuid) jsonb v'],
                        'a function signatures, results and volatility');
  PERFORM pg_temp.check((SELECT pg_get_function_arguments(oid) LIKE '%p_abandoned_reason text DEFAULT NULL::text'
                           FROM pg_proc WHERE oid = 'ops.vision_set_status(text, text, text, uuid, text)'::regprocedure),
                        'a vision_set_status p_abandoned_reason defaults to NULL');
  FOR v_fn IN SELECT oid::regprocedure FROM pg_proc WHERE pronamespace = 'ops'::regnamespace AND proname LIKE '%vision%' LOOP
    PERFORM pg_temp.check((SELECT prosecdef AND proconfig = ARRAY['search_path=ops, pg_temp'] AND pg_get_userbyid(proowner) = v_owner
                                  AND prolang = (SELECT oid FROM pg_language WHERE lanname = CASE WHEN v_fn::text LIKE 'ops._vision_open%' THEN 'sql' ELSE 'plpgsql' END)
                             FROM pg_proc WHERE oid = v_fn), 'a secdef, search_path, owner, language of ' || v_fn::text);
    IF v_fn::text LIKE 'ops.vision%' THEN
      PERFORM pg_temp.check(obj_description(v_fn, 'pg_proc') LIKE 'Vision (08908ad9, 9144f3ef): %', 'a comment of ' || v_fn::text);
      PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END)
                               FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner)
                            = ARRAY['ops_planner'], 'a ACL owner plus ops_planner on ' || v_fn::text);
    ELSE
      PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = v_fn AND a.grantee <> p.proowner)
                            AND (SELECT proacl IS NOT NULL FROM pg_proc WHERE oid = v_fn), 'a helper owner-only: ' || v_fn::text);
    END IF;
  END LOOP;
  PERFORM pg_temp.check(obj_description('ops.vision_true_close(text, text, uuid)'::regprocedure, 'pg_proc')
                        LIKE '%only after the operator''s explicit yes%', 'a vision_true_close comment names the operator''s yes');
  FOREACH v_rel IN ARRAY ARRAY['vision_backlog', 'vision_decisions', 'vision_dispatches', 'vision_items', 'vision_requires',
                               'vision_requires_status', 'vision_status', 'vision_status_log'] LOOP
    PERFORM pg_temp.check((SELECT array_agg(DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
                                            || ':' || a.privilege_type)
                             FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = ('ops.' || v_rel)::regclass AND a.grantee <> c.relowner)
                          = ARRAY['ops_planner:SELECT'], 'a ACL owner plus ops_planner SELECT on ' || v_rel);
  END LOOP;

  -- rule vision_check v1 and changelog version 11
  PERFORM pg_temp.check((SELECT version = 1 AND value = jsonb_build_object('rule',
    'Build status lives only in ops.vision_items and changes only through the vision writer functions (vision_upsert, vision_set_status, vision_true_close; links through vision_link and vision_unlink). Every proposal and every dispatch names the vision item it advances, or states none with a reason; the planner''s create_dispatch tool records it in ops.vision_dispatches. An item is shipped only when none of its blocking backlog items is open; a true close needs the acceptance passed in real use, evidence and the operator''s explicit yes. The planner runs ops.vision_check() at milestone boundaries and before any true close, and raises what it reports.')
                           FROM ops.protocol_rules WHERE key = 'vision_check'), 'a rule vision_check v1 text');
  PERFORM pg_temp.check((SELECT max(version) FROM ops.protocol_changelog) = 11
                        AND (SELECT count(*) FROM ops.protocol_changelog WHERE version = 11) = 1
                        AND EXISTS (SELECT 1 FROM ops.protocol_changelog WHERE version = 11 AND rule_keys = ARRAY['vision_check']
                                       AND changes = 'vision_check v1: build status lives in ops.vision_items; every proposal and dispatch names its vision item or a none-reason; vision_check() at milestones and before a true close (decisions 6cef3bf3, 08908ad9, 9144f3ef).'),
                        'a protocol_changelog version 11');
  PERFORM set_config('search_path', 'ops, pg_temp', true);
  RAISE NOTICE 'ok   a catalog: six tables, two views, constraints, indexes, nine functions, ACLs, rule vision_check v1, changelog 11';
END $$;

-- b. grants (always asserted): planner reads and executes, writes nothing; executor and PUBLIC get nothing
DO $$
DECLARE v_rel text; v_fn text; p text;
BEGIN
  FOREACH v_rel IN ARRAY ARRAY['vision_backlog', 'vision_decisions', 'vision_dispatches', 'vision_items', 'vision_requires',
                               'vision_requires_status', 'vision_status', 'vision_status_log'] LOOP
    PERFORM pg_temp.check(has_table_privilege('ops_planner', 'ops.' || v_rel, 'SELECT'), 'b planner SELECT on ' || v_rel);
    FOREACH p IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
      PERFORM pg_temp.check(NOT has_table_privilege('ops_planner', 'ops.' || v_rel, p), 'b planner has no ' || p || ' on ' || v_rel);
    END LOOP;
    FOREACH p IN ARRAY ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] LOOP
      PERFORM pg_temp.check(NOT has_table_privilege('ops_executor', 'ops.' || v_rel, p), 'b executor has no ' || p || ' on ' || v_rel);
      PERFORM pg_temp.check(NOT has_table_privilege('public', 'ops.' || v_rel, p), 'b PUBLIC has no ' || p || ' on ' || v_rel);
    END LOOP;
  END LOOP;
  FOREACH v_fn IN ARRAY ARRAY['ops.vision_upsert(jsonb, uuid)', 'ops.vision_link(jsonb, uuid)', 'ops.vision_unlink(jsonb, uuid)',
                              'ops.vision_set_status(text, text, text, uuid, text)', 'ops.vision_true_close(text, text, uuid)',
                              'ops.vision_check()'] LOOP
    PERFORM pg_temp.check(has_function_privilege('ops_planner', v_fn, 'EXECUTE'), 'b planner executes ' || v_fn);
  END LOOP;
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname LIKE '%vision%'
                                       AND (has_function_privilege('ops_executor', p.oid, 'EXECUTE')
                                            OR has_function_privilege('public', p.oid, 'EXECUTE'))),
                        'b executor and PUBLIC execute no vision function');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'ops'::regnamespace AND p.proname LIKE '\_vision%'
                                       AND has_function_privilege('ops_planner', p.oid, 'EXECUTE')),
                        'b planner executes no private helper');
  RAISE NOTICE 'ok   b grants: ops_planner SELECT and EXECUTE only; ops_executor and PUBLIC nothing on any vision object';
END $$;

-- c. vision_upsert
DO $$
DECLARE s uuid := pg_temp.id('s'); sb uuid := pg_temp.id('sb'); v_u uuid := gen_random_uuid(); j jsonb; e text;
        r ops.vision_items; r2 ops.vision_items; v_log bigint; v_b uuid;
BEGIN
  -- insert a root and two children (one under the component node), in array order
  j := pg_temp.up(jsonb_build_array(
         pg_temp.new_item('t0032c', NULL, '{"status": "partial", "seq": 1, "sources": ["design 93b049b0", "chat"], "status_note": "note"}'),
         pg_temp.new_item('t0032c.one', 't0032c', '{"status": "designed", "requires": ["table:nodes", "function:vision_check"]}'),
         pg_temp.new_item('t0032c.two', 't0032c', '{"home_node_path": "global.t0032a.ca", "phase": "later", "status_reason": "seeded"}')));
  PERFORM pg_temp.check(j = '{"inserted": 3, "updated": 0, "status_changes": 0}', 'c insert result: ' || j::text);
  r := pg_temp.item('t0032c');
  PERFORM pg_temp.check(r.parent_id IS NULL AND r.status = 'partial' AND r.seq = 1 AND r.sources = ARRAY['design 93b049b0', 'chat']
                        AND r.status_note = 'note' AND r.title = 'T t0032c' AND r.intent = 'I t0032c' AND r.acceptance = 'A t0032c'
                        AND r.phase = 'setup' AND r.updated_session_id = s AND r.abandoned_reason IS NULL
                        AND r.true_closed_at IS NULL AND r.home_node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0032a'),
                        'c root row: ' || row_to_json(r)::text);
  PERFORM pg_temp.check((pg_temp.item('t0032c.one')).parent_id = r.id AND (pg_temp.item('t0032c.two')).parent_id = r.id
                        AND (pg_temp.item('t0032c.two')).home_node_id = (SELECT id FROM ops.nodes WHERE path::text = 'global.t0032a.ca')
                        AND (pg_temp.item('t0032c.two')).seq = 0 AND (pg_temp.item('t0032c.two')).sources = '{}',
                        'c children rows');
  PERFORM pg_temp.check(pg_temp.reqs('t0032c.one') = ARRAY['function:vision_check', 'table:nodes'] AND pg_temp.reqs('t0032c') = '{}',
                        'c requires stored');
  PERFORM pg_temp.check((SELECT array_agg(coalesce(l.from_status, '-') || '>' || l.to_status || ' ' || l.reason || ' ' || (l.session_id = s)::text
                                          ORDER BY i.key)
                           FROM ops.vision_status_log l JOIN ops.vision_items i ON i.id = l.item_id WHERE i.key LIKE 't0032c%')
                        = ARRAY['->partial created true', '->designed created true', '->idea seeded true'],
                        'c one creation log row per item (reason status_reason or created)');

  -- a re-run is idempotent
  v_log := (SELECT count(*) FROM ops.vision_status_log);
  r := pg_temp.item('t0032c');
  j := pg_temp.up(jsonb_build_array(
         pg_temp.new_item('t0032c', NULL, '{"status": "partial", "seq": 1, "sources": ["design 93b049b0", "chat"], "status_note": "note"}'),
         pg_temp.new_item('t0032c.one', 't0032c', '{"status": "designed", "requires": ["table:nodes", "function:vision_check", "table:nodes"]}'),
         pg_temp.new_item('t0032c.two', 't0032c', '{"home_node_path": "global.t0032a.ca", "phase": "later", "status_reason": "seeded"}')));
  PERFORM pg_temp.check(j = '{"inserted": 0, "updated": 0, "status_changes": 0}', 'c re-run result: ' || j::text);
  PERFORM pg_temp.check((SELECT count(*) FROM ops.vision_items WHERE key LIKE 't0032c%') = 3
                        AND (SELECT count(*) FROM ops.vision_status_log) = v_log
                        AND (pg_temp.item('t0032c')).updated_at = r.updated_at
                        AND pg_temp.reqs('t0032c.one') = ARRAY['function:vision_check', 'table:nodes'],
                        'c re-run: no duplicates, no log rows, no write');

  -- a partial update leaves absent fields unchanged; JSON null clears status_note; requires unchanged when absent
  j := pg_temp.up('[{"key": "t0032c", "title": "Root renamed"}, {"key": "t0032c.one", "seq": 4}]');
  PERFORM pg_temp.check(j = '{"inserted": 0, "updated": 2, "status_changes": 0}', 'c partial update result: ' || j::text);
  r2 := pg_temp.item('t0032c');
  PERFORM pg_temp.check(r2.title = 'Root renamed' AND r2.intent = r.intent AND r2.status = r.status AND r2.seq = r.seq
                        AND r2.sources = r.sources AND r2.status_note = 'note' AND r2.phase = r.phase AND r2.parent_id IS NULL,
                        'c partial update keeps absent fields');
  PERFORM pg_temp.check((pg_temp.item('t0032c.one')).seq = 4 AND pg_temp.reqs('t0032c.one') = ARRAY['function:vision_check', 'table:nodes'],
                        'c requires unchanged when absent');
  j := pg_temp.up('[{"key": "t0032c", "status_note": null}]');
  PERFORM pg_temp.check((pg_temp.item('t0032c')).status_note IS NULL AND j = '{"inserted": 0, "updated": 1, "status_changes": 0}',
                        'c JSON null clears status_note');
  -- requires replaced when present
  PERFORM pg_temp.up('[{"key": "t0032c.one", "requires": ["view:vision_status", "column:nodes.path"]}]');
  PERFORM pg_temp.check(pg_temp.reqs('t0032c.one') = ARRAY['column:nodes.path', 'view:vision_status'], 'c requires replaced');
  PERFORM pg_temp.up('[{"key": "t0032c.one", "requires": []}]');
  PERFORM pg_temp.check(pg_temp.reqs('t0032c.one') = '{}', 'c requires replaced by an empty set');
  -- a status change logs one row with status_reason or 'upsert'
  j := pg_temp.up('[{"key": "t0032c.two", "status": "designed"}, {"key": "t0032c.one", "status": "partial", "status_reason": "half done"}]');
  PERFORM pg_temp.check(j = '{"inserted": 0, "updated": 2, "status_changes": 2}', 'c status change result: ' || j::text);
  PERFORM pg_temp.check((SELECT array_agg(l.from_status || '>' || l.to_status || ' ' || l.reason ORDER BY i.key)
                           FROM ops.vision_status_log l JOIN ops.vision_items i ON i.id = l.item_id
                          WHERE i.key IN ('t0032c.one', 't0032c.two') AND l.from_status IS NOT NULL)
                        = ARRAY['designed>partial half done', 'idea>designed upsert'], 'c status change log rows');
  -- parent_key null makes an item a root; abandoned via upsert, and leaving it clears the reason
  PERFORM pg_temp.up('[{"key": "t0032c.two", "parent_key": null}]');
  PERFORM pg_temp.check((pg_temp.item('t0032c.two')).parent_id IS NULL, 'c parent_key null makes a root');
  PERFORM pg_temp.up('[{"key": "t0032c.two", "status": "abandoned", "abandoned_reason": "dropped in t0032"}]');
  PERFORM pg_temp.check((pg_temp.item('t0032c.two')).abandoned_reason = 'dropped in t0032', 'c abandoned via upsert');
  PERFORM pg_temp.up('[{"key": "t0032c.two", "status": "idea"}]');
  PERFORM pg_temp.check((pg_temp.item('t0032c.two')).status = 'idea' AND (pg_temp.item('t0032c.two')).abandoned_reason IS NULL,
                        'c leaving abandoned clears abandoned_reason');

  -- refusals
  e := pg_temp.up_err('[]');
  PERFORM pg_temp.check(e = '23514 vision_upsert: p_items must be a non-empty JSON array of objects', 'c empty array: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('{"key": "t0032c"}');
  PERFORM pg_temp.check(e = '23514 vision_upsert: p_items must be a non-empty JSON array of objects', 'c not an array: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c"}, 5]');
  PERFORM pg_temp.check(e = '23514 vision_upsert: element 2 is not a JSON object', 'c element not object: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"title": "x"}]');
  PERFORM pg_temp.check(e = '23514 vision_upsert: element 1 has no key (a string)', 'c no key: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "bogus": 1, "aaa": 2}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: unknown field aaa, bogus', 'c unknown field: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "T0032.bad"}]');
  PERFORM pg_temp.check(e = '23514 vision item T0032.bad: key must be dot-separated lower-case segments', 'c malformed key: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "title": null}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: title cannot be null', 'c null title: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": null}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: requires cannot be null', 'c null requires: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.new', 't0032c') - 'parent_key'));
  PERFORM pg_temp.check(e = '23514 vision item t0032c.new: a new item requires parent_key (null for a tree root)', 'c new without parent_key: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.new', 't0032c') - 'acceptance'));
  PERFORM pg_temp.check(e = '23514 vision item t0032c.new: a new item requires acceptance', 'c new without acceptance: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.new', 't0032c.nosuch')));
  PERFORM pg_temp.check(e = '23514 vision item t0032c.new: parent_key t0032c.nosuch does not exist', 'c unknown parent: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.new', 't0032c', '{"home_node_path": "global.t0032a.nosuch"}')));
  PERFORM pg_temp.check(e = 'P0001 unknown node global.t0032a.nosuch', 'c unknown home node: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "title": "  "}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: title is blank', 'c blank title: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "intent": 5}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: intent must be a string', 'c non-string intent: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "status": "done"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: status done is not one of idea, designed, partial, shipped, true_closed, abandoned', 'c bad status: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "phase": "now"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: phase now is not one of setup, tune, test, import, later', 'c bad phase: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "seq": -1}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: seq must be a non-negative integer', 'c negative seq: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "seq": 1.5}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: seq must be a non-negative integer', 'c fractional seq: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "sources": ["ok", " "]}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: sources must be an array of non-blank strings', 'c blank source: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": "table:nodes"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: requires must be an array of "kind:name" strings', 'c requires not array: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": ["table:nodes", "column:nodot"]}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: malformed requirement "column:nodot"', 'c malformed column requirement: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": ["doc:global.t0032a"]}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: malformed requirement "doc:global.t0032a"', 'c malformed doc requirement: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": ["index:x"]}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: malformed requirement "index:x"', 'c unknown requirement kind: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "requires": ["table: "]}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: malformed requirement "table: "', 'c blank requirement name: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "status_note": ""}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: status_note is blank', 'c blank status_note: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "status": "designed", "status_reason": " "}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: status_reason is blank', 'c blank status_reason: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "status": "true_closed"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: status true_closed is set only by vision_true_close', 'c true_closed: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.new', 't0032c', '{"status": "true_closed"}')));
  PERFORM pg_temp.check(e = '23514 vision item t0032c.new: status true_closed is set only by vision_true_close', 'c new true_closed: ' || coalesce(e, 'success'));
  v_b := pg_temp.backlog('t0032 c blocker');
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032c.one', 'kind', 'backlog', 'ref', v_b, 'role', 'blocks')));
  e := pg_temp.up_err('[{"key": "t0032c.one", "status": "shipped"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c.one: cannot be shipped while blocking backlog items are open: ' || left(v_b::text, 8),
                        'c shipped with an open blocker: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c.one", "status": "abandoned"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c.one: status abandoned requires abandoned_reason', 'c abandoned without reason: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c.one", "abandoned_reason": "x"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c.one: abandoned_reason is set only on an abandoned item', 'c abandoned_reason on a live item: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "parent_key": "t0032c.one"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: parent_key t0032c.one would make a cycle', 'c cycle: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "parent_key": "t0032c"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: parent_key t0032c would make a cycle', 'c self parent: ' || coalesce(e, 'success'));
  PERFORM pg_temp.up(jsonb_build_array(pg_temp.new_item('t0032c.ca', 't0032c', '{"home_node_path": "global.t0032a.ca"}')));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.ca.up', 't0032c.ca')));
  PERFORM pg_temp.check(e = '23514 vision item t0032c.ca.up: home node global.t0032a is outside the home subtree global.t0032a.ca of parent t0032c.ca',
                        'c home outside the parent''s subtree: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "home_node_path": "global.t0032a.ca"}]');
  PERFORM pg_temp.check(e = '23514 vision item t0032c: home node global.t0032a.ca would leave child t0032c.one (home global.t0032a) outside it',
                        'c a move that leaves a child outside: ' || coalesce(e, 'success'));
  -- session refusals (log_decision texts)
  e := pg_temp.up_err('[{"key": "t0032c", "title": "x"}]', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'c null session: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c", "title": "x"}]', v_u);
  PERFORM pg_temp.check(e = '23514 session ' || v_u || ' does not exist', 'c unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.up_err('[{"key": "t0032c.ca", "title": "x"}]', sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a.ca)', 'c session outside: ' || coalesce(e, 'success'));
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032cb', NULL, '{"home_node_path": "global.t0032b"}')));
  PERFORM pg_temp.check(e = '23514 session ' || s || ' is outside global.t0032b (the scope of global.t0032b)', 'c new item outside the session: ' || coalesce(e, 'success'));
  -- a refused element refuses the whole call
  e := pg_temp.up_err(jsonb_build_array(pg_temp.new_item('t0032c.partial', 't0032c'), '{"key": "t0032c", "phase": "x"}'::jsonb));
  PERFORM pg_temp.check(e LIKE '23514 vision item t0032c: phase x %' AND pg_temp.item('t0032c.partial') IS NULL, 'c refused call writes nothing');
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.vision_items WHERE key IN ('t0032c.new', 't0032cb', 't0032c.ca.up')), 'c refused items absent');
  RAISE NOTICE 'ok   c vision_upsert: insert, idempotent re-run, partial update, null clears, requires replace, status log, every refusal';
END $$;

-- d. vision_link and vision_unlink
DO $$
DECLARE s uuid := pg_temp.id('s'); sb uuid := pg_temp.id('sb'); dec uuid := pg_temp.id('dec'); bl uuid := pg_temp.id('bl');
        d1 uuid := pg_temp.id('d1'); v_u uuid := gen_random_uuid(); j jsonb; e text; n integer; v_item uuid;
BEGIN
  PERFORM pg_temp.up(jsonb_build_array(pg_temp.new_item('t0032d', NULL), pg_temp.new_item('t0032d.x', 't0032d'),
                                       pg_temp.new_item('t0032d.ca', 't0032d', '{"home_node_path": "global.t0032a.ca"}')));
  v_item := (pg_temp.item('t0032d')).id;
  -- each kind
  j := pg_temp.link(jsonb_build_array(
         jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'defines'),
         jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', bl, 'role', 'blocks'),
         jsonb_build_object('kind', 'dispatch', 'ref', d1, 'none_reason', 'housekeeping')));
  PERFORM pg_temp.check(j = '{"linked": 3, "updated": 0}', 'd link result: ' || j::text);
  PERFORM pg_temp.check((SELECT relation = 'defines' AND session_id = s FROM ops.vision_decisions WHERE item_id = v_item AND decision_id = dec)
                        AND (SELECT role = 'blocks' FROM ops.vision_backlog WHERE item_id = v_item AND backlog_id = bl)
                        AND (SELECT none_reason = 'housekeeping' AND item_id IS NULL FROM ops.vision_dispatches WHERE dispatch_id = d1),
                        'd link rows');
  -- re-link updates relation, role and reason; an identical re-link changes nothing
  j := pg_temp.link(jsonb_build_array(
         jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'refines'),
         jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', bl, 'role', 'improves'),
         jsonb_build_object('kind', 'dispatch', 'ref', d1, 'none_reason', 'chore only')));
  PERFORM pg_temp.check(j = '{"linked": 0, "updated": 3}', 'd re-link result: ' || j::text);
  PERFORM pg_temp.check((SELECT relation FROM ops.vision_decisions WHERE item_id = v_item AND decision_id = dec) = 'refines'
                        AND (SELECT role FROM ops.vision_backlog WHERE item_id = v_item AND backlog_id = bl) = 'improves'
                        AND (SELECT none_reason FROM ops.vision_dispatches WHERE dispatch_id = d1) = 'chore only'
                        AND (SELECT count(*) FROM ops.vision_decisions WHERE decision_id = dec) = 1,
                        'd re-link updated in place');
  j := pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'refines')));
  PERFORM pg_temp.check(j = '{"linked": 0, "updated": 0}', 'd identical re-link: ' || j::text);
  -- an item link on a dispatch removes its none row; a none row is refused while item links exist
  j := pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032d.x', 'kind', 'dispatch', 'ref', d1),
                                      jsonb_build_object('item_key', 't0032d', 'kind', 'dispatch', 'ref', d1)));
  PERFORM pg_temp.check(j = '{"linked": 2, "updated": 0}', 'd dispatch item links: ' || j::text);
  PERFORM pg_temp.check(NOT EXISTS (SELECT 1 FROM ops.vision_dispatches WHERE dispatch_id = d1 AND item_id IS NULL)
                        AND (SELECT count(*) FROM ops.vision_dispatches WHERE dispatch_id = d1) = 2, 'd item link removed the none row');
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', d1, 'none_reason', 'r')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: dispatch ' || d1 || ' has item links; a none row is refused', 'd none with item links: ' || coalesce(e, 'success'));

  -- link refusals
  e := pg_temp.link_err('[]');
  PERFORM pg_temp.check(e = '23514 vision_link: p_links must be a non-empty JSON array of objects', 'd empty: ' || coalesce(e, 'success'));
  e := pg_temp.link_err('["x"]');
  PERFORM pg_temp.check(e = '23514 vision_link element 1: not a JSON object', 'd not object: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'node', 'ref', dec)));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: kind must be decision, backlog or dispatch', 'd bad kind: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'role', 'blocks')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: unknown field role for kind decision', 'd role on a decision: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', left(dec::text, 8), 'relation', 'defines')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: ref must be a uuid', 'd id8 ref: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d.nosuch', 'kind', 'decision', 'ref', dec, 'relation', 'defines')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: vision item t0032d.nosuch does not exist', 'd unknown item: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', v_u, 'relation', 'defines')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: decision ' || v_u || ' does not exist', 'd unknown decision: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', v_u, 'role', 'blocks')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: backlog item ' || v_u || ' does not exist', 'd unknown backlog: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'dispatch', 'ref', v_u)));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: dispatch ' || v_u || ' does not exist', 'd unknown dispatch: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'blocks')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: relation must be one of defines, refines, sequencing, milestone, constrains, process_rule, superseded, abandons',
                        'd bad relation: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec)));
  PERFORM pg_temp.check(e LIKE '23514 vision_link element 1: relation must be one of %', 'd missing relation: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', bl, 'role', 'defines')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: role must be blocks or improves', 'd bad role: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('kind', 'backlog', 'ref', bl, 'role', 'blocks')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: kind backlog requires item_key', 'd backlog without item: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'dispatch', 'ref', d1, 'none_reason', 'r')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: kind dispatch takes exactly one of item_key and none_reason', 'd dispatch both: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', d1)));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: kind dispatch takes exactly one of item_key and none_reason', 'd dispatch neither: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', pg_temp.id('d2'), 'none_reason', ' ')));
  PERFORM pg_temp.check(e = '23514 vision_link element 1: none_reason is blank', 'd blank none_reason: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', pg_temp.id('dec2'), 'relation', 'defines'),
                                          jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', bl, 'role', 'x')));
  PERFORM pg_temp.check(e = '23514 vision_link element 2: role must be blocks or improves'
                        AND NOT EXISTS (SELECT 1 FROM ops.vision_decisions WHERE decision_id = pg_temp.id('dec2')),
                        'd a refused element refuses the whole call: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'defines')), NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'd null session: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'defines')), v_u);
  PERFORM pg_temp.check(e = '23514 session ' || v_u || ' does not exist', 'd unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'defines')), sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a)', 'd session outside: ' || coalesce(e, 'success'));
  e := pg_temp.link_err(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', pg_temp.id('d2'), 'none_reason', 'r')), sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a.ca)', 'd none row session against the dispatch node: ' || coalesce(e, 'success'));

  -- unlink removes exactly the named link
  n := ops.vision_unlink(jsonb_build_array(jsonb_build_object('item_key', 't0032d.x', 'kind', 'dispatch', 'ref', d1),
                                           jsonb_build_object('item_key', 't0032d', 'kind', 'backlog', 'ref', bl)), s);
  PERFORM pg_temp.check(n = 2, 'd unlink count ' || n);
  PERFORM pg_temp.check((SELECT array_agg(item_id) FROM ops.vision_dispatches WHERE dispatch_id = d1) = ARRAY[v_item]
                        AND NOT EXISTS (SELECT 1 FROM ops.vision_backlog WHERE backlog_id = bl)
                        AND EXISTS (SELECT 1 FROM ops.vision_decisions WHERE decision_id = dec), 'd unlink removed exactly the named links');
  e := pg_temp.unlink_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec),
                                            jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec)));
  PERFORM pg_temp.check(e = '23514 vision_unlink element 2: no decision link from vision item t0032d to ' || dec
                        AND EXISTS (SELECT 1 FROM ops.vision_decisions WHERE decision_id = dec), 'd a missing link refuses the whole call: ' || coalesce(e, 'success'));
  e := pg_temp.unlink_err(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', d1)));
  PERFORM pg_temp.check(e = '23514 vision_unlink element 1: dispatch ' || d1 || ' has no none row', 'd no none row: ' || coalesce(e, 'success'));
  e := pg_temp.unlink_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec, 'relation', 'defines')));
  PERFORM pg_temp.check(e = '23514 vision_unlink element 1: unknown field relation', 'd unlink unknown field: ' || coalesce(e, 'success'));
  e := pg_temp.unlink_err(jsonb_build_array(jsonb_build_object('kind', 'backlog', 'ref', bl)));
  PERFORM pg_temp.check(e = '23514 vision_unlink element 1: kind backlog requires item_key', 'd unlink backlog without item: ' || coalesce(e, 'success'));
  e := pg_temp.unlink_err('[]');
  PERFORM pg_temp.check(e = '23514 vision_unlink: p_links must be a non-empty JSON array of objects', 'd unlink empty: ' || coalesce(e, 'success'));
  e := pg_temp.unlink_err(jsonb_build_array(jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec)), sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a)', 'd unlink session outside: ' || coalesce(e, 'success'));
  -- a none row unlinks by kind dispatch and no item_key
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', pg_temp.id('d2'), 'none_reason', 'r')));
  n := ops.vision_unlink(jsonb_build_array(jsonb_build_object('kind', 'dispatch', 'ref', pg_temp.id('d2'), 'item_key', NULL),
                                           jsonb_build_object('item_key', 't0032d', 'kind', 'decision', 'ref', dec)), s);
  PERFORM pg_temp.check(n = 2 AND NOT EXISTS (SELECT 1 FROM ops.vision_dispatches WHERE dispatch_id = pg_temp.id('d2'))
                        AND NOT EXISTS (SELECT 1 FROM ops.vision_decisions WHERE decision_id = dec), 'd none row and decision unlinked');
  RAISE NOTICE 'ok   d vision_link and vision_unlink: each kind, re-link updates, none row rules, refusals, exact unlink';
END $$;

-- e. vision_set_status and vision_true_close
DO $$
DECLARE s uuid := pg_temp.id('s'); sb uuid := pg_temp.id('sb'); v_u uuid := gen_random_uuid(); e text; b1 uuid; b2 uuid; b3 uuid;
        r ops.vision_items; v_log bigint;
BEGIN
  PERFORM pg_temp.up(jsonb_build_array(pg_temp.new_item('t0032e', NULL, '{"status": "designed"}'),
                                       pg_temp.new_item('t0032e.imp', 't0032e', '{"status": "designed"}'),
                                       pg_temp.new_item('t0032e.ab', 't0032e')));
  b1 := pg_temp.backlog('t0032 e blocker');
  b2 := pg_temp.backlog('t0032 e improver');
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032e', 'kind', 'backlog', 'ref', b1, 'role', 'blocks'),
                                         jsonb_build_object('item_key', 't0032e.imp', 'kind', 'backlog', 'ref', b2, 'role', 'improves')));
  -- shipped: refused with an open blocks link, allowed with only improves links, allowed once the blocker is closed
  e := pg_temp.set_err('t0032e', 'shipped', 'built', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e: cannot be shipped while blocking backlog items are open: ' || left(b1::text, 8),
                        'e shipped with an open blocker: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(ops.vision_set_status('t0032e.imp', 'shipped', 'built with improvements pending', s), 'e shipped with only improves links');
  PERFORM ops.update_backlog_item(b1, 'done');
  PERFORM pg_temp.check(ops.vision_set_status('t0032e', 'shipped', 'built', s), 'e shipped with the blocker closed');
  -- unchanged status returns false and logs nothing
  v_log := pg_temp.logs('t0032e');
  PERFORM pg_temp.check(NOT ops.vision_set_status('t0032e', 'shipped', 'again', s) AND pg_temp.logs('t0032e') = v_log,
                        'e unchanged status: false, no log');
  -- abandoned needs a reason; leaving abandoned clears it
  e := pg_temp.set_err('t0032e.ab', 'abandoned', 'dropped', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: status abandoned requires abandoned_reason', 'e abandoned without reason: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'abandoned', 'dropped', s, ' ');
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: status abandoned requires abandoned_reason', 'e abandoned with a blank reason: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'designed', 'x', s, 'why');
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: abandoned_reason is set only on an abandoned item', 'e abandoned_reason on a live status: ' || coalesce(e, 'success'));
  PERFORM pg_temp.check(ops.vision_set_status('t0032e.ab', 'abandoned', 'dropped', s, 'superseded by t0032e'), 'e abandoned with reason');
  PERFORM pg_temp.check((pg_temp.item('t0032e.ab')).abandoned_reason = 'superseded by t0032e', 'e abandoned_reason stored');
  PERFORM pg_temp.check(ops.vision_set_status('t0032e.ab', 'idea', 'revived', s)
                        AND (pg_temp.item('t0032e.ab')).abandoned_reason IS NULL, 'e leaving abandoned clears the reason');
  -- other set_status refusals
  e := pg_temp.set_err('t0032e.ab', 'designed', ' ', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: reason is required', 'e blank reason: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'done', 'x', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: status done is not one of idea, designed, partial, shipped, true_closed, abandoned', 'e bad status: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e', 'true_closed', 'x', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e: status true_closed is set only by vision_true_close', 'e set true_closed: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.nosuch', 'idea', 'x', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.nosuch does not exist', 'e unknown item: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'designed', 'x', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'e null session: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'designed', 'x', v_u);
  PERFORM pg_temp.check(e = '23514 session ' || v_u || ' does not exist', 'e unknown session: ' || coalesce(e, 'success'));
  e := pg_temp.set_err('t0032e.ab', 'designed', 'x', sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a)', 'e session outside: ' || coalesce(e, 'success'));

  -- true close: refused unless shipped, without evidence, with an open blocker; then allowed
  e := pg_temp.close_err('t0032e.ab', 'used for a week', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.ab: is idea, not shipped', 'e true close of an idea: ' || coalesce(e, 'success'));
  e := pg_temp.close_err('t0032e', ' ', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e: evidence is required', 'e true close without evidence: ' || coalesce(e, 'success'));
  b3 := pg_temp.backlog('t0032 e late blocker');
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032e', 'kind', 'backlog', 'ref', b3, 'role', 'blocks')));
  e := pg_temp.close_err('t0032e', 'used for a week', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e: cannot be true-closed while blocking backlog items are open: ' || left(b3::text, 8),
                        'e true close with an open blocker: ' || coalesce(e, 'success'));
  e := pg_temp.close_err('t0032e', 'used for a week', NULL);
  PERFORM pg_temp.check(e = '23514 session is required (segment_id)', 'e true close null session: ' || coalesce(e, 'success'));
  e := pg_temp.close_err('t0032e', 'used for a week', sb);
  PERFORM pg_temp.check(e = '23514 session ' || sb || ' is outside global.t0032a (the scope of global.t0032a)', 'e true close session outside: ' || coalesce(e, 'success'));
  e := pg_temp.close_err('t0032e.nosuch', 'x', s);
  PERFORM pg_temp.check(e = '23514 vision item t0032e.nosuch does not exist', 'e true close unknown item: ' || coalesce(e, 'success'));
  PERFORM ops.update_backlog_item(b3, 'dropped');
  PERFORM ops.vision_true_close('t0032e', 'used for a week', s);
  r := pg_temp.item('t0032e');
  PERFORM pg_temp.check(r.status = 'true_closed' AND r.true_close_evidence = 'used for a week' AND r.true_closed_at IS NOT NULL
                        AND r.updated_session_id = s, 'e true-closed row');
  -- true_closed stays through an upsert that names it; reopening clears the true-close fields
  PERFORM pg_temp.check(pg_temp.up('[{"key": "t0032e", "status": "true_closed"}]') = '{"inserted": 0, "updated": 0, "status_changes": 0}',
                        'e upsert naming the current true_closed status is a no-op');
  PERFORM pg_temp.check(ops.vision_set_status('t0032e', 'partial', 'regression found', s), 'e reopen');
  r := pg_temp.item('t0032e');
  PERFORM pg_temp.check(r.status = 'partial' AND r.true_close_evidence IS NULL AND r.true_closed_at IS NULL, 'e reopening clears the true-close fields');
  -- every change logged with session and reason
  PERFORM pg_temp.check((SELECT array_agg(coalesce(l.from_status, '-') || '>' || l.to_status || ' ' || l.reason ORDER BY l.id)
                           FROM ops.vision_status_log l WHERE l.item_id = r.id AND l.session_id = s)
                        = ARRAY['->designed created', 'designed>shipped built', 'shipped>true_closed used for a week',
                                'true_closed>partial regression found'], 'e status log of t0032e');
  PERFORM pg_temp.check((SELECT array_agg(coalesce(l.from_status, '-') || '>' || l.to_status || ' ' || l.reason ORDER BY l.id)
                           FROM ops.vision_status_log l WHERE l.item_id = (pg_temp.item('t0032e.ab')).id)
                        = ARRAY['->idea created', 'idea>abandoned dropped', 'abandoned>idea revived'], 'e status log of t0032e.ab');
  RAISE NOTICE 'ok   e vision_set_status and vision_true_close: shipped rule, abandoned reason, unchanged false, true close rules, reopen, log';
END $$;

-- f. vision_check on the fixtures
DO $$
DECLARE dec uuid := pg_temp.id('dec'); bl uuid := pg_temp.id('bl'); d2 uuid := pg_temp.id('d2'); d3 uuid; b uuid; v_keys text[];
BEGIN
  PERFORM pg_temp.up(jsonb_build_array(
    pg_temp.new_item('t0032f', NULL),
    pg_temp.new_item('t0032f.miss', 't0032f', '{"status": "shipped", "requires": ["function:no_such_fn_t0032", "table:nodes"]}'),
    pg_temp.new_item('t0032f.lag', 't0032f', '{"status": "designed", "requires": ["table:nodes", "rule:vision_check"]}'),
    pg_temp.new_item('t0032f.gone', 't0032f', '{"status": "abandoned", "abandoned_reason": "t0032"}'),
    pg_temp.new_item('t0032f.gone.kid', 't0032f.gone')));
  b := pg_temp.backlog('t0032 f open blocker');
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032f.miss', 'kind', 'backlog', 'ref', b, 'role', 'blocks'),
                                         jsonb_build_object('kind', 'dispatch', 'ref', d2, 'none_reason', 't0032 f housekeeping')));
  v_keys := ARRAY['t0032f', 't0032f.miss', 't0032f.lag', 't0032f.gone', 't0032f.gone.kid'];
  PERFORM pg_temp.check(pg_temp.vc(v_keys, ARRAY[b, d2]) = ARRAY[
      'abandoned_parent|t0032f.gone.kid|-|t0032f.gone',
      'missing_object|t0032f.miss|-|function:no_such_fn_t0032',
      'none_reason|-|' || d2 || '|t0032 f housekeeping',
      'open_blocker|t0032f.miss|' || b || '|t0032 f open blocker',
      'rollup_mismatch|t0032f|-|stored idea, children partial',
      'rollup_mismatch|t0032f.gone|-|stored abandoned, children idea',
      'status_lag|t0032f.lag|-|all 2 required objects exist'],
    'f vision_check rows: ' || array_to_string(pg_temp.vc(v_keys, ARRAY[b, d2]), ' ; '));
  -- vision_check order: check_kind, item_key nulls last, ref, detail
  PERFORM pg_temp.check((SELECT array_agg(rn ORDER BY rn) = array_agg(rn ORDER BY check_kind, item_key NULLS LAST, ref, detail)
                           FROM ops.vision_check() WITH ORDINALITY v(check_kind, item_key, ref, detail, rn)),
                        'f vision_check ordered by check_kind, item_key nulls last, ref, detail');
  -- unlinked records appear, and disappear once linked (dec and bl were unlinked again in d; d3 is new)
  d3 := pg_temp.dispatch('t0032 fixture dispatch 3');
  PERFORM pg_temp.check(pg_temp.vc('{}', ARRAY[dec, bl, d3]) = ARRAY[
      'unlinked_backlog|-|' || bl || '|t0032 fixture backlog',
      'unlinked_decision|-|' || dec || '|' || left('t0032 fixture decision: a long text so that vision_check cuts it at eighty characters, not later than that', 80),
      'unlinked_dispatch|-|' || d3 || '|t0032 fixture dispatch 3'],
    'f unlinked fixture records: ' || array_to_string(pg_temp.vc('{}', ARRAY[dec, bl, d3]), ' ; '));
  PERFORM pg_temp.link(jsonb_build_array(jsonb_build_object('item_key', 't0032f', 'kind', 'decision', 'ref', dec, 'relation', 'milestone'),
                                         jsonb_build_object('item_key', 't0032f', 'kind', 'backlog', 'ref', bl, 'role', 'improves'),
                                         jsonb_build_object('item_key', 't0032f', 'kind', 'dispatch', 'ref', d3)));
  PERFORM pg_temp.check(pg_temp.vc('{}', ARRAY[dec, bl, d3]) = '{}', 'f linked records are no longer reported');
  PERFORM pg_temp.check(pg_temp.vc('{}', ARRAY[pg_temp.id('d1')]) = '{}', 'f a dispatch with item links is not unlinked');
  RAISE NOTICE 'ok   f vision_check: missing_object, open_blocker, status_lag, rollup_mismatch, abandoned_parent, none_reason, unlinked';
END $$;

-- g. vision_status and vision_requires_status on the fixtures
DO $$
DECLARE s uuid := pg_temp.id('s'); v ops.vision_status; b1 uuid; b2 uuid; b3 uuid;
BEGIN
  PERFORM pg_temp.up(jsonb_build_array(pg_temp.new_item('t0032g', NULL),
                                       pg_temp.new_item('t0032g.c1', 't0032g'), pg_temp.new_item('t0032g.c2', 't0032g')));
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g.c1') IS NULL, 'g no children: rollup NULL');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'idea', 'g all idea');
  PERFORM pg_temp.up('[{"key": "t0032g.c1", "status": "designed"}]');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'designed', 'g any designed');
  PERFORM pg_temp.up('[{"key": "t0032g.c1", "status": "partial"}]');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'partial', 'g any partial');
  PERFORM pg_temp.up('[{"key": "t0032g.c1", "status": "shipped"}]');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'partial', 'g shipped and idea: partial');
  PERFORM pg_temp.up('[{"key": "t0032g.c2", "status": "shipped"}]');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'shipped', 'g all shipped');
  PERFORM ops.vision_true_close('t0032g.c1', 'e1', s);
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'shipped', 'g true_closed and shipped: shipped');
  PERFORM ops.vision_true_close('t0032g.c2', 'e2', s);
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'true_closed', 'g all true_closed');
  PERFORM ops.vision_set_status('t0032g.c2', 'abandoned', 'dropped', s, 'not needed');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'true_closed', 'g abandoned children left out');
  PERFORM ops.vision_set_status('t0032g.c1', 'abandoned', 'dropped', s, 'not needed');
  PERFORM pg_temp.check((SELECT rollup_status FROM ops.vision_status WHERE key = 't0032g') = 'abandoned', 'g no live children: abandoned');

  -- counts
  PERFORM pg_temp.up(jsonb_build_array(pg_temp.new_item('t0032g.n', 't0032g', jsonb_build_object(
    'home_node_path', 'global.t0032a.ca', 'phase', 'tune', 'seq', 7, 'requires', jsonb_build_array(
      'function:vision_check', 'function:no_such_fn_t0032', 'table:nodes', 'table:vision_status', 'view:vision_status',
      'view:nodes', 'rule:vision_check', 'rule:no_such_rule_t0032', 'column:nodes.path', 'column:nodes.no_such_col_t0032',
      'doc:global.t0032a:manual')))));
  b1 := pg_temp.backlog('t0032 g blocks open');
  b2 := pg_temp.backlog('t0032 g improves open');
  b3 := pg_temp.backlog('t0032 g closed');
  PERFORM ops.update_backlog_item(b3, 'done');
  PERFORM pg_temp.link(jsonb_build_array(
    jsonb_build_object('item_key', 't0032g.n', 'kind', 'backlog', 'ref', b1, 'role', 'blocks'),
    jsonb_build_object('item_key', 't0032g.n', 'kind', 'backlog', 'ref', b2, 'role', 'improves'),
    jsonb_build_object('item_key', 't0032g.n', 'kind', 'backlog', 'ref', b3, 'role', 'blocks'),
    jsonb_build_object('item_key', 't0032g.n', 'kind', 'decision', 'ref', pg_temp.id('dec2'), 'relation', 'constrains'),
    jsonb_build_object('item_key', 't0032g.n', 'kind', 'dispatch', 'ref', pg_temp.id('d2'))));
  SELECT * INTO v FROM ops.vision_status WHERE key = 't0032g.n';
  PERFORM pg_temp.check(v.parent_key = 't0032g' AND v.home_path::text = 'global.t0032a.ca' AND v.title = 'T t0032g.n'
                        AND v.status = 'idea' AND v.phase = 'tune' AND v.seq = 7 AND v.rollup_status IS NULL AND v.children = 0
                        AND v.requires_total = 11 AND v.requires_missing = 6 AND v.decisions = 1 AND v.backlog_open_blocks = 1
                        AND v.backlog_open_improves = 1 AND v.backlog_closed = 1 AND v.dispatches = 1
                        AND v.updated_at = (pg_temp.item('t0032g.n')).updated_at,
                        'g vision_status counts: ' || row_to_json(v)::text);
  PERFORM pg_temp.check((SELECT children FROM ops.vision_status WHERE key = 't0032g') = 3, 'g children counts abandoned ones');
  PERFORM pg_temp.check((SELECT array_agg(kind || ':' || name || '=' || present ORDER BY kind, name) FROM ops.vision_requires_status
                          WHERE item_key = 't0032g.n') = ARRAY[
      'column:nodes.no_such_col_t0032=false', 'column:nodes.path=true', 'doc:global.t0032a:manual=false',
      'function:no_such_fn_t0032=false', 'function:vision_check=true', 'rule:no_such_rule_t0032=false', 'rule:vision_check=true',
      'table:nodes=true', 'table:vision_status=false', 'view:nodes=false', 'view:vision_status=true'],
    'g vision_requires_status present per kind');
  RAISE NOTICE 'ok   g vision_status rollup and counts; vision_requires_status for every requirement kind';
END $$;

ROLLBACK;

-- h. no leftover rows
DO $$ BEGIN
  IF (SELECT jsonb_build_object(
    'vision_items', (SELECT count(*) FROM ops.vision_items), 'vision_requires', (SELECT count(*) FROM ops.vision_requires),
    'vision_decisions', (SELECT count(*) FROM ops.vision_decisions), 'vision_backlog', (SELECT count(*) FROM ops.vision_backlog),
    'vision_dispatches', (SELECT count(*) FROM ops.vision_dispatches),
    'vision_status_log', (SELECT count(*) FROM ops.vision_status_log),
    'protocol_rules', (SELECT count(*) FROM ops.protocol_rules), 'protocol_changelog', (SELECT count(*) FROM ops.protocol_changelog),
    'nodes', (SELECT count(*) FROM ops.nodes), 'components', (SELECT count(*) FROM ops.components),
    'sessions', (SELECT count(*) FROM ops.sessions), 'decisions', (SELECT count(*) FROM ops.decisions),
    'backlog_items', (SELECT count(*) FROM ops.backlog_items), 'dispatches', (SELECT count(*) FROM ops.dispatches)))
     <> current_setting('ops_test.counts_before')::jsonb THEN
    RAISE EXCEPTION 'FAIL: rows left behind after ROLLBACK';
  END IF;
  RAISE NOTICE 'ok   h no leftover rows; 0032 tests passed';
END $$;
