// Executor tools. ops_executor cannot SELECT ops.dispatches, so rows returned by
// get_pending are cached in process memory and claims are gated on that cache.
import * as z from 'zod';
import pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, describe, inTransaction, rows, tool, type Row } from '../db.ts';
import { contactFor } from '../tick.ts';
import { idRef, nodePath, registerResolveContext, uuid } from './common.ts';

type BatchClass = 'investigation' | 'implementation';

interface Caps { implementation_max: number; investigation_max: number }

interface CachedDispatch {
  row: Row;
  nodePath: string;
  batchClass: BatchClass;
  caps: Caps;
}

const SERVER_START = new Date(performance.timeOrigin).toISOString();

// claimed_by: `<clientInfo.name>:<pid>:<server start>`, 'unknown' for a missing or blank name. Read per claim:
// clientInfo exists only after initialize. A watcher-launched run (mcp/autorun.mcp.json sets LOCAL_OPS_AUTORUN=1)
// prefixes 'autorun:', which ops.claim_dispatch gates on autorun_approved; the prefix comes from launch config only.
function agentSession(server: McpServer): string {
  const base = `${contactFor(server.server.getClientVersion()).client}:${process.pid}:${SERVER_START}`;
  return process.env.LOCAL_OPS_AUTORUN === '1' ? `autorun:${base}` : base;
}

const cache = new Map<string, CachedDispatch>();
const claimed = new Set<string>();
const resolved = new Map<string, string>();   // `${node path}\0${ref}` -> text
const delivered = new Set<string>();          // refs already returned by claim_dispatch this run
const deliveredLog = new Set<string>();       // work_log ids already returned by claim_dispatch this run
let claimCount = 0;
let runClass: BatchClass | null = null;

function capInt(v: unknown, fallback: number): number {
  const n = Number(v);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}

// protocol_rules.batch_defaults, overridden by projects.params.batch_defaults when the path's depth-2 ancestor
// (subpath(path, 0, 2)) is a project node with a projects row; otherwise (as for global.local-ops, a plain node since
// 0023) the protocol defaults apply.
async function loadCaps(pool: pg.Pool, path: string): Promise<Caps> {
  const [rule] = await rows(pool, "SELECT value FROM ops.protocol_rules WHERE key = 'batch_defaults'");
  const [proj] = await rows(pool,
    `SELECT p.params FROM ops.projects p JOIN ops.nodes n ON n.id = p.node_id
      WHERE n.path OPERATOR(public.=) public.subpath($1::public.ltree, 0, least(2, public.nlevel($1::public.ltree)))`,
    [path]);
  const base = (rule?.value ?? {}) as Row;
  const override = ((proj?.params as Row | undefined)?.batch_defaults ?? {}) as Row;
  const implementation_max = capInt(base.implementation_max, 3);
  const investigation_max = capInt(base.investigation_max, 1);
  return {
    implementation_max: capInt(override.implementation_max, implementation_max),
    investigation_max: capInt(override.investigation_max, investigation_max),
  };
}

// Work-log functions (migrations 0028-0029). The server reads mcp/src fresh at every session start, so this code
// runs against production before the promote that creates them: each tool checks at call time and, when a function
// is absent (no row, or present = false), behaves as it did before the function existed.
const LOG_WORK = 'ops.log_work(uuid,text,text,text,text[],jsonb,text,jsonb)';
const GET_WORK_LOG = 'ops.get_work_log(public.ltree,text[],integer)';

async function present(pool: pg.Pool, signature: typeof LOG_WORK | typeof GET_WORK_LOG): Promise<boolean> {
  const [r] = await rows(pool, `SELECT to_regprocedure('${signature}') IS NOT NULL AS present`);
  return r?.present === true;
}

const nonBlank = z.string().regex(/\S/, 'must not be blank');

const work = z.object({
  entry_type: nonBlank,
  title: nonBlank,
  description: z.string().optional(),
  files_changed: z.array(z.string()).default([]),
  follow_ups: z.array(z.unknown()).default([]),
  test_summary: z.string().optional(),
  external_refs: z.array(z.unknown()).default([]),
});

export function registerExecutor(server: McpServer, pool: pg.Pool): void {
  // resolve_context only: query and record_gate are planner-only.
  registerResolveContext(server, pool);

  server.registerTool('get_pending', {
    description: 'Fetch the next batch of pending dispatches for the component at node_path (ops.get_pending; exactly that component, not its subtree), capped by protocol batch_defaults (a project overrides them in projects.params.batch_defaults): one investigation-class item (commit_policy none), or up to implementation_max implementation items stopping before the first investigation. Returned rows are cached for claim_dispatch. With id (a full UUID or its first 8 characters), returns only that pending dispatch as its own batch, wherever it sits in the queue.',
    inputSchema: { node_path: nodePath, id: idRef.optional() },
  }, tool(async ({ node_path, id }) => {
    const pending = await rows(pool, 'SELECT * FROM ops.get_pending(p_node_path => $1::public.ltree)', [node_path]);
    const caps = await loadCaps(pool, node_path);
    const policy = new Map((await rows(pool, 'SELECT type, commit_policy FROM ops.dispatch_types'))
      .map((t) => [t.type as string, t.commit_policy as string]));
    const isInvestigation = (r: Row) => policy.get(r.dispatch_type as string) === 'none';

    // By id: matched in the tool on ops.get_pending's rows (no lookup), cached like a batch so claim_dispatch's
    // cap and run-class checks apply unchanged.
    if (id !== undefined) {
      const want = id.toLowerCase();
      const hits = pending.filter((r) => {
        const rid = String(r.id).toLowerCase();
        return want.length === 8 ? rid.startsWith(want) : rid === want;
      });
      if (hits.length > 1) {
        throw new CheckError(`id prefix ${id} matches ${hits.length} pending dispatches at ${node_path}; pass the full id`);
      }
      const common = { caps, claimed_this_process: claimCount, run_class: runClass, pending_total: pending.length };
      if (hits.length === 0) {
        return {
          batch_class: null, ...common, returned: 0, remaining_pending: pending.length, rows: [],
          selected_by_id: true, note: `no pending dispatch at ${node_path} matches ${id}`,
        };
      }
      const [hit] = hits;
      const hitClass: BatchClass = isInvestigation(hit) ? 'investigation' : 'implementation';
      cache.set(hit.id as string, { row: hit, nodePath: node_path, batchClass: hitClass, caps });
      return {
        batch_class: hitClass, ...common, returned: 1, remaining_pending: pending.length - 1, rows: [hit],
        selected_by_id: true,
      };
    }

    let batch: Row[] = [];
    let batchClass: BatchClass | null = null;
    if (pending.length > 0 && isInvestigation(pending[0])) {
      batchClass = 'investigation';
      batch = pending.slice(0, Math.min(1, caps.investigation_max));
    } else if (pending.length > 0) {
      batchClass = 'implementation';
      for (const r of pending) {
        if (batch.length >= caps.implementation_max || isInvestigation(r)) break;
        batch.push(r);
      }
    }
    for (const r of batch) {
      cache.set(r.id as string, { row: r, nodePath: node_path, batchClass: batchClass!, caps });
    }
    return {
      batch_class: batchClass,
      caps,
      claimed_this_process: claimCount,
      run_class: runClass,
      pending_total: pending.length,
      returned: batch.length,
      remaining_pending: pending.length - batch.length,
      rows: batch,
    };
  }));

  server.registerTool('claim_dispatch', {
    description: 'Claim a dispatch returned by get_pending in this process (ops.claim_dispatch). Enforces the per-run batch cap. Returns the dispatch, its dispatch_types row, the context for refs not already delivered this run, resolved at the get_pending node_path (nearest ancestor-or-self), and work_log: { rows, already_delivered } from ops.get_work_log at that node_path (rows tagged to it or an ancestor; rows whose files_changed overlap the dispatch task_files first, then newest; capped by protocol rule work_log_delivery), leaving out rows already delivered this run and listing their ids in already_delivered. work_log is null when ops.get_work_log is absent in the database.',
    inputSchema: { id: uuid },
  }, tool(async ({ id }) => {
    const entry = cache.get(id);
    if (!entry) throw new CheckError(`dispatch ${id} was not returned by get_pending in this process`);
    if (claimed.has(id)) throw new CheckError(`dispatch ${id} is already claimed by this process`);
    if (runClass !== null && runClass !== entry.batchClass) {
      throw new CheckError(`this run is ${runClass}-class; cannot claim a ${entry.batchClass}-class dispatch`);
    }
    const cap = entry.batchClass === 'investigation' ? entry.caps.investigation_max : entry.caps.implementation_max;
    if (claimCount >= cap) {
      throw new CheckError(`batch cap reached: ${claimCount}/${cap} ${entry.batchClass} claims this run`);
    }

    // Resolve context before claiming so a broken ref fails without leaving a claim behind.
    const refs = [...new Set((entry.row.context_refs as string[] | null) ?? [])];
    const context: { ref: string; text: string }[] = [];
    const alreadyLoaded: string[] = [];
    for (const ref of refs) {
      const k = `${entry.nodePath}\0${ref}`;
      if (delivered.has(k)) { alreadyLoaded.push(ref); continue; }
      if (!resolved.has(k)) {
        const [r] = await rows(pool, 'SELECT ops.resolve_context(p_node_path => $1::public.ltree, p_ref => $2) AS text',
          [entry.nodePath, ref]);
        resolved.set(k, r.text as string);
      }
      context.push({ ref, text: resolved.get(k)! });
    }

    // The work log likewise before claiming: a lookup failure leaves no claim and uses no slot.
    let workLog: { rows: Row[]; already_delivered: string[] } | null = null;
    if (await present(pool, GET_WORK_LOG)) {
      const found = await rows(pool,
        'SELECT * FROM ops.get_work_log(p_node_path => $1::public.ltree, p_files => $2::text[], p_limit => NULL)',
        [entry.nodePath, (entry.row.task_files as string[] | null | undefined) ?? []]);
      workLog = {
        rows: found.filter((r) => !deliveredLog.has(r.id as string)),
        already_delivered: found.filter((r) => deliveredLog.has(r.id as string)).map((r) => r.id as string),
      };
    }

    // A refusal here (e.g. a promote whose approval was revoked after get_pending) leaves no claim and uses no slot.
    const agent = agentSession(server);
    try {
      await rows(pool, 'SELECT ops.claim_dispatch($1, $2)', [id, agent]);
    } catch (err) {
      if (err instanceof pg.DatabaseError && err.code === '23514') {
        throw new CheckError(`the database refused the claim of dispatch ${id}: nothing was claimed and no batch slot `
          + `was used (${claimCount}/${cap} claims this run). ${describe(err)}`);
      }
      throw err;
    }
    claimed.add(id);
    claimCount += 1;
    runClass = entry.batchClass;
    for (const c of context) delivered.add(`${entry.nodePath}\0${c.ref}`);
    for (const r of workLog?.rows ?? []) deliveredLog.add(r.id as string);

    const [dispatchType] = await rows(pool, 'SELECT * FROM ops.dispatch_types WHERE type = $1',
      [entry.row.dispatch_type]);
    return {
      claimed_by: agent,
      claims_this_run: `${claimCount}/${cap}`,
      dispatch: { ...entry.row, status: 'claimed', claimed_by: agent },
      dispatch_type: dispatchType,
      context,
      context_already_loaded: alreadyLoaded,
      work_log: workLog,
    };
  }));

  function requireClaimed(id: string): void {
    if (!claimed.has(id)) throw new CheckError(`dispatch ${id} was not claimed by this process`);
  }

  server.registerTool('complete_dispatch', {
    description: 'Complete a dispatch claimed by this process (ops.complete_dispatch). result = one-line summary; report = full report text (STATUS / FILES / DONE / VERIFY / COMMIT / INCIDENTS / FOLLOW-UPS). work = the work-log entry { entry_type, title, description?, files_changed, follow_ups, test_summary?, external_refs }: ops.log_work and ops.complete_dispatch run in one transaction, so a refused completion leaves no log row; the result carries work_log_id. The database refuses to complete a dispatch whose type has commit_policy local or push without a work-log entry; work is optional for commit_policy none. When ops.log_work is absent in the database, work is not recorded and the result says so.',
    inputSchema: { id: uuid, result: z.string().min(1), report: z.string().min(1), work: work.optional() },
  }, tool(async ({ id, result, report, work: w }) => {
    requireClaimed(id);
    if (w !== undefined && await present(pool, LOG_WORK)) {
      const workLogId = await inTransaction(pool, async (client) => {
        const logged = await client.query('SELECT ops.log_work($1, $2, $3, $4, $5::text[], $6::jsonb, $7, $8::jsonb) AS id',
          [id, w.entry_type, w.title, w.description ?? null, w.files_changed, JSON.stringify(w.follow_ups),
           w.test_summary ?? null, JSON.stringify(w.external_refs)]);
        await client.query('SELECT ops.complete_dispatch($1, $2, $3)', [id, result, report]);
        return logged.rows[0].id as string;
      });
      claimed.delete(id);
      return { id, status: 'done', work_log_id: workLogId };
    }
    await rows(pool, 'SELECT ops.complete_dispatch($1, $2, $3)', [id, result, report]);
    claimed.delete(id);
    return w === undefined ? { id, status: 'done' }
      : { id, status: 'done', work_log: 'not recorded: ops.log_work is absent in this database' };
  }));

  server.registerTool('fail_dispatch', {
    description: 'Fail a dispatch claimed by this process (ops.fail_dispatch). error must say what went wrong and where execution stopped; refused_premise=true for a false premise.',
    inputSchema: { id: uuid, error: z.string().min(1), refused_premise: z.boolean().default(false) },
  }, tool(async ({ id, error, refused_premise }) => {
    requireClaimed(id);
    await rows(pool, 'SELECT ops.fail_dispatch($1, $2, $3)', [id, error, refused_premise]);
    claimed.delete(id);
    return { id, status: refused_premise ? 'refused_premise' : 'failed' };
  }));

  server.registerTool('get_dispatch_type', {
    description: 'Read one ops.dispatch_types row (description, commit_policy, execution_rules, active).',
    inputSchema: { type: z.string().min(1) },
  }, tool(async ({ type }) => {
    const [r] = await rows(pool, 'SELECT * FROM ops.dispatch_types WHERE type = $1', [type]);
    if (!r) throw new CheckError(`unknown dispatch type ${type}`);
    return r;
  }));
}
