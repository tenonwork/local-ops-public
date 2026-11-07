// Integration test for the context-document tools against the rehearsal database (migration 0033): a review document
// lands draft and resolve_context refuses it, approve_doc with the returned sha approves it and resolve_context serves
// it, a derived document with an 8-hex decision prefix lands approved, a function refusal comes back as a validation
// error with the database's exact message, and a retired document is unknown to resolve_context. On a project the
// test creates, on one connection inside a transaction that is always rolled back; tool statements run under
// savepoints, as in vision.rehearsal.test.ts, and as the URL's role.
// Skipped unless LOCAL_OPS_REHEARSAL_URL is set; refuses the production database local_ops.
//
//   LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes } from 'node:crypto';
import pg from 'pg';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { registerPlanner } from './tools/planner.ts';

const url = process.env.LOCAL_OPS_REHEARSAL_URL ?? '';
const skip = url === '' && 'LOCAL_OPS_REHEARSAL_URL not set';
type Json = Record<string, any>;

test('rehearsal: write_doc (review, derived), approve_doc, retire_doc and resolve_context', { skip }, async () => {
  assert.notEqual(new URL(url).pathname, '/local_ops', 'integration tests refuse the production database local_ops');
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  await db.query('BEGIN');
  let n = 0;
  const guarded = async (text: string, values?: unknown[]) => {
    const sp = `t${n++}`;
    await db.query(`SAVEPOINT ${sp}`);
    try {
      const r = await db.query(text, values);
      await db.query(`RELEASE SAVEPOINT ${sp}`);
      return r;
    } catch (err) {
      await db.query(`ROLLBACK TO SAVEPOINT ${sp}`);
      throw err;
    }
  };
  const txClient = {
    query: (text: string, values?: unknown[]) =>
      text === 'BEGIN' ? db.query('SAVEPOINT tx')
        : text === 'COMMIT' ? db.query('RELEASE SAVEPOINT tx')
        : text === 'ROLLBACK' ? db.query('ROLLBACK TO SAVEPOINT tx')
        : db.query(text, values),
    release() {},
  };
  const pool = { query: guarded, connect: async () => txClient } as unknown as pg.Pool;
  const server = new McpServer({ name: 'local_ops', version: '0.1.0' });
  registerPlanner(server, pool);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: 'docs-it', version: '1.0.0' });
  await client.connect(b);
  const call = async (name: string, args: Json) => {
    const r = (await client.callTool({ name, arguments: args })) as CallToolResult;
    return { isError: r.isError === true, text: r.content.map((c) => (c.type === 'text' ? c.text : '')).join('\n') };
  };
  const ok = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, false, `${name}: ${r.text}`);
    return JSON.parse(r.text);
  };
  const refused = async (name: string, args: Json) => {
    const r = await call(name, args);
    assert.equal(r.isError, true, `${name} should have been refused: ${r.text}`);
    return r.text;
  };
  try {
    const present = (await db.query(
      "SELECT to_regprocedure('ops.write_doc(ltree,text,text,text,text,text,text,uuid[],uuid[],uuid)') IS NOT NULL AS present"))
      .rows[0].present;
    assert.equal(present, true, 'rehearsal has ops.write_doc (0033)');

    const hex = randomBytes(4).toString('hex');
    const projectPath = `global.it-doc-${hex}`;
    const corePath = `${projectPath}.core`;
    await ok('create_project', { parent_path: 'global', key: `it-doc-${hex}`, name: 'docs integration', summary: 'it' });
    await ok('create_component', { parent_path: projectPath, key: 'core', kind: 'service', repo_ref: 'it', verify_cmd: 'true', summary: 'it' });
    const { session_id } = await ok('open_session', { node_path: projectPath, kind: 'planning' });
    const seg = session_id.slice(0, 8);

    // Review: a draft, not served until approved with the sha of its bytes.
    const key = `IT_DOC_${hex.toUpperCase()}`;
    const content = `# Guide\n\nreview body ${hex}\n`;
    const draft = await ok('write_doc', {
      node_path: projectPath, doc_key: key, doc_type: 'manual', title: 'guide', content, basis: 'review', segment_id: seg,
    });
    assert.equal(draft.trust_status, 'draft');
    assert.equal(draft.created, true);
    assert.equal(draft.content_sha256, createHash('sha256').update(content, 'utf8').digest('hex'));
    assert.match(await refused('resolve_context', { node_path: corePath, ref: key }), /has no approved version/);

    const approved = await ok('approve_doc', {
      node_path: projectPath, doc_key: key, content_sha256: draft.content_sha256, segment_id: seg,
    });
    assert.equal(approved.id, draft.id);
    const trust = await db.query('SELECT trust_status FROM ops.context_documents WHERE id = $1', [draft.id]);
    assert.equal(trust.rows[0].trust_status, 'approved');
    assert.equal(await ok('resolve_context', { node_path: corePath, ref: key }), content, 'served from the ancestor');

    // Derived: approved on write, its source given as an 8-hex decision prefix.
    const dec = await ok('log_decision', { node_path: projectPath, decision: 'docs it', segment_id: session_id });
    const derivedKey = `${key}_D`;
    const derived = await ok('write_doc', {
      node_path: corePath, doc_key: derivedKey, doc_type: 'manual', title: 'derived', content: 'derived body',
      summary: 's', basis: 'derived', decision_ids: [dec.id.slice(0, 8).toUpperCase()], segment_id: seg,
    });
    assert.equal(derived.trust_status, 'approved');
    const version = await db.query(
      `SELECT basis, source_decision_ids FROM ops.document_versions WHERE document_id = $1 ORDER BY version DESC LIMIT 1`,
      [derived.id]);
    assert.deepEqual(version.rows[0], { basis: 'derived', source_decision_ids: [dec.id] });
    assert.equal(await ok('resolve_context', { node_path: corePath, ref: derivedKey }), 'derived body');

    // A function refusal is a validation error carrying the database's message.
    assert.equal(await refused('write_doc', {
      node_path: corePath, doc_key: `${key}_X`, doc_type: `nope_${hex}`, title: 't', content: 'c', basis: 'review',
      segment_id: seg,
    }), `Validation error (23514): doc_type nope_${hex} is not registered`);
    assert.equal(await refused('approve_doc', {
      node_path: projectPath, doc_key: key, content_sha256: draft.content_sha256, segment_id: seg,
    }), `Validation error (23514): document ${key} at ${projectPath} is already approved`);

    // Retired: resolve_context no longer knows the key.
    const retired = await ok('retire_doc', { node_path: projectPath, doc_key: key, reason: 'probe done', segment_id: seg });
    assert.equal(retired.id, draft.id);
    assert.ok(retired.retired_at);
    assert.match(await refused('resolve_context', { node_path: corePath, ref: key }), new RegExp(`unknown context ref ${key}`));
    assert.equal(await refused('retire_doc', { node_path: projectPath, doc_key: key, reason: 'again', segment_id: seg }),
      `Validation error (23514): document ${key} at ${projectPath} is already retired`);
  } finally {
    await client.close().catch(() => undefined);
    await server.close().catch(() => undefined);
    await db.query('ROLLBACK').catch(() => undefined);
    await db.end();
  }
});
