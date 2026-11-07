# CLAUDE.md

## Executor: claiming work

- Queue keys for this repo: `node_path=global.local-ops.core`. Never look them up; never call `query` (it is denied in `.claude/settings.json`).
- Claim sequence (local_ops MCP tools, parameters as in `mcp/src/tools/executor.ts`):
  1. `get_pending(node_path: "global.local-ops.core")`: returns the batch, capped. With `id` (a dispatch id or its first 8 characters) it returns only that pending dispatch, wherever it sits in the queue.
  2. `claim_dispatch(id)`: only an id that `get_pending` returned in this process. Beside the context, the claim result carries `work_log`: `{ rows, already_delivered }` (recent work-log entries on the node and its ancestors, rows overlapping the dispatch's `task_files` first; capped by protocol rule work_log_delivery), or `null` when the work log is absent in the database.
  3. Read the dispatch prompt in the claim result.
  4. `get_dispatch_type(type)`: the dispatch's `dispatch_type` (commit_policy, execution_rules).
  5. Execute.
  6. `complete_dispatch(id, result, report, work?)` (`work` is the work-log entry `{ entry_type, title, description?, files_changed[], follow_ups[] (items {"text": "..."}), test_summary?, external_refs[] }`, logged in one transaction with the completion; required for local/push dispatches (the database refuses completion without a work-log row), optional for commit_policy none types; result one line; report STATUS / FILES / DONE / VERIFY / COMMIT / INCIDENTS / FOLLOW-UPS; INCIDENTS is mandatory, "none" if none; every follow-up is tagged [side-effect] or [discovery]) or `fail_dispatch(id, error, refused_premise?)` (error says what went wrong and where execution stopped; `refused_premise: true` for a false premise).
- Project skill `/ops-execute` (`.claude/skills/ops-execute/SKILL.md`) runs this sequence for one dispatch per invocation: the next pending one, or, with an 8-character id argument (`/ops-execute <id8>`, as the autorun watcher launches it), only the pending dispatch whose id starts with it, never another.
- The executor's allowed local_ops tools are those five queue tools plus `resolve_context`: `get_pending`, `claim_dispatch`, `get_dispatch_type`, `complete_dispatch`, `fail_dispatch`, and `resolve_context` (read-only; every dispatch type, read-only ones included, may call it to load global node context in the read-first phase). `tick` is also registered on the executor server (server.ts registerTick) but dispatches do not call it: it writes window telemetry, and every executor tool call already runs a passive tick.
- Read-first order: global node context (the MANUAL on the global node, by context refs) -> CLAUDE.md -> task files only. Source: ops.protocol_rules read_first_order v2 (0030); keep this line identical to it.
- Investigation and promote dispatches write nothing and need no work-log row; their report in the queue is the log. Investigation findings are recorded in local-ops and, on review, promoted to an existing node's context or a new node with operator confirmation. Committing types (commit_policy local or push) log through `work` on `complete_dispatch` (the work log, ops.work_log).

## Executor rules: production credential

- The production credential (`local_ops`, from `.env` `DATABASE_URL` / pgpass) is used only through `node scripts/migrate.ts refresh-rehearsal` and `node scripts/migrate.ts promote <dispatch_id>`.
- Never run ad hoc `psql`, `pg_dump`, `pg_restore` or any other client against `local_ops`.
- Run `promote` only while executing a claimed dispatch of type `promote`, and only on that dispatch's own id: `--dry-run` first, then the real run once the dry run passes. Never on any other dispatch's id, and never outside a promote dispatch. The approval (`prod_apply_approved`, naming the whole set as `versions=<stem>:<sha256>,...`) is recorded by the planner against the promote dispatch; the executor never records it. One production attempt per promote dispatch: if `promote` refuses because a `prod_apply` gate exists, stop and report.
- Rehearsal work uses `ops_dev` on `local_ops_rehearsal` only. Never set `PGPASSWORD` for another role.

## Schema rules

- Every write goes through a SECURITY DEFINER function in schema ops (SET search_path = ops, pg_temp; owned by the ops schema owner; REVOKE ALL FROM PUBLIC; explicit GRANT EXECUTE). No role writes a table directly. Planner writers grant ops_planner only, take the session last (segment_id) and check it as log_decision does against the target node.
- Component scope is enforced by one trigger function, ops._component_scope(), on sessions, decisions, dispatches, context_documents and backlog_items: a row with component_id carries that component's project_id, and a backlog item's home_node_id or a document's node_id lies in the component's node subtree. Put new component-scoped tables under the same trigger; never repeat the check in functions.
- Node-keyed functions take the path first as p_node_path public.ltree with no default; one overload per name. MCP tools call them in named notation (p_node_path => $n::public.ltree).
- Context documents are never deleted and a doc_key is never freed (retire instead). document_versions rows are written only by the context_documents triggers, never by hand.
- Derived values stay derived: decision gists are computed by ops.current_decisions, never stored; node summaries are written only through set_node_summary, never derived from documents.
- A planner MCP tool over a migration not yet in production detects its function at call time (to_regprocedure on a fixed signature string) and, while it is absent, returns '<capability> not installed (migration NNNN is not applied)' and sends nothing else.
- This section holds standing rules only. What a migration or dispatch changed belongs in its work-log entry.

## Test conventions

- `tests/sql/0017_promote_dispatch_type.sql` pins hard_boundaries rules 3-5 and the 0004 secret rule by exact text. Any later migration that amends a hard_boundaries rule must, in the same dispatch, gate that 0017 block skip-on-newer (assert unchanged while 0017 is the newest ledger version; once it is not, skip with a NOTICE) and assert the new text in its own `tests/sql` file. Assertions are never deleted.
- Tests that create decisions or dispatches supply a session of the same project (session_id is NOT NULL); tests that complete a committing dispatch call ops.log_work first.
- Rehearsal recipes. MCP: LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/. migrate.ts: every status, dry run or apply against rehearsal carries DATABASE_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal (plus MIGRATE_EXPECT_DB=local_ops_rehearsal for apply); a bare migrate.ts call resolves to production from .env.
