# local-ops MCP bridge

One stdio MCP server over the `ops` schema. You pick the role at launch with `--role planner|executor`. The server connects as `ops_planner` or `ops_executor` and registers only that role's tools. Database privileges do the enforcing; this server adds the protocol checks listed below.

Node 26 runs the TypeScript directly (native type stripping), so there is no build step.

## Setup

```sh
npm --prefix mcp ci
npm --prefix mcp run typecheck      # tsc --noEmit
```

Dependency versions are pinned: `@modelcontextprotocol/sdk` 1.30.1, `pg` 8.23.0, `zod` 4.6.5; dev: `typescript` 7.0.2, `@types/pg` 8.23.1.

## Connection and passwords

The defaults are `localhost:5432`, database `local_ops`. The user comes from the role. You can override the host, port and database with `LOCAL_OPS_HOST`, `LOCAL_OPS_PORT` and `LOCAL_OPS_DB`. The pool holds at most 2 connections.

No password is kept in code or config. `pg` reads it from pgpass: `%APPDATA%\postgresql\pgpass.conf` on Windows, `~/.pgpass` elsewhere, or `PGPASSFILE` if set. Add one line per role:

```
localhost:5432:local_ops:ops_planner:<password>
localhost:5432:local_ops:ops_executor:<password>
```

On first connect, `pg` 8.x writes a `DeprecationWarning` about pgpass to stderr. It's harmless. All logging goes to stderr because stdout carries the protocol.

## Registration

**Claude Code** uses the repo-root `.mcp.json`, which registers server `local_ops` with the executor role:

```json
{ "mcpServers": { "local_ops": { "command": "node", "args": ["mcp/src/server.ts", "--role", "executor"] } } }
```

**Claude Desktop** uses the planner role. Add this to `claude_desktop_config.json` (`%APPDATA%\Claude\claude_desktop_config.json`), with an absolute path:

```json
{
  "mcpServers": {
    "local_ops": {
      "command": "node",
      "args": ["C:\\path\\to\\local-ops\\mcp\\src\\server.ts", "--role", "planner"]
    }
  }
}
```

## Tools

Tools address the node tree by path. `node_path` (and `parent_path` for `create_project` / `create_component`) is a node path such as `global.local-ops.core`: keys joined by dots, each matching `^[a-z0-9][a-z0-9_-]*$`. The server passes it to the node-keyed `ops` functions of migration 0018 in named notation (`p_node_path => $1::public.ltree`). That is a convention that keeps each call explicit; the project-keyed overloads it once disambiguated from were dropped in migration 0021. No tool takes a project or component key. An unknown path is a validation error.

Both roles have:

- `resolve_context(node_path, ref)` calls `ops.resolve_context`: the document on the nearest ancestor-or-self node of `node_path` that holds the doc key.
- `tick(reset_at?, reset_source?, calendar?, chat_ref?)` calls `ops.tick` (migration 0006). It returns the one-line summary first, then the full JSON. `reset_at` (ISO 8601 with offset) and `reset_source` (`stated` | `observed`) go together or not at all. `calendar` is an array of `{id, start, end, title?, description?}`.

**Planner only:**

- `query(sql)`: runs one statement in a `READ ONLY` transaction with `statement_timeout = 5s`, then always rolls back. It returns at most 200 rows and reports whether it truncated. The server uses the extended protocol, so text with several statements is rejected.
- `record_gate(...)` calls `ops.record_gate`. `dispatch_id` and `segment_id` are each a full UUID or 8-character id prefix.
- `window_link_event(number, event_id)` calls `ops.window_link_event`. It is not registered on the executor, which has no grant on it.

The executor registers exactly `get_pending`, `claim_dispatch`, `complete_dispatch`, `fail_dispatch`, `get_dispatch_type`, `resolve_context` and `tick`. It has no `query` or `record_gate`: no dispatch type uses executor-side gates, and `prod_apply` gates are written by `scripts/migrate.ts` over its own connection. (The database grant of `ops.record_gate` to `ops_executor` is unchanged.)

## Window tracking

**Contact source.** `p_source` comes from `clientInfo.name` in the MCP initialize request, looked up in `CLIENT_SOURCES` in `src/tick.ts`: `claude-code` maps to `code`, and any other name maps to `chat`. The raw name is recorded as `p_client`. If there is no clientInfo name, the source is `chat` and the client is `unknown`.

**Passive tick.** Every other tool call, in both roles, first runs `ops.tick(source, client)`. `tick` and `window_link_event` are skipped, because they tick themselves.

- The passive tick is one autocommit statement on the pool, and it finishes before the tool's handler starts. It never runs inside the tool's transaction, so `query` stays `READ ONLY`.
- It is fail-open. An error is logged to stderr and the tool call goes ahead unchanged.
- If the passive state is anything other than `ok`, one text block is appended to the tool result: `[tick] <line> · directive <code>`. `<code>` is `none` when there is no directive.

**`LOCAL_OPS_CONTACT`.** A launch-config environment variable for non-Claude executors (such as OpenAI Codex), which would otherwise record a `chat` contact in Claude usage windows on every call. It is set in that client's MCP launch config (the `env` of its `local_ops` server entry), not in the repo, and is read once at startup, independent of `clientInfo.name`.

- Unset: window tracking as described above, in both roles.
- `none`: this process records no contacts. No passive tick runs and no `[tick]` block is appended; the per-call stderr line is still written. The `tick` tool is not registered, so the process never calls `ops.tick`. The ready line ends in ` contact=none`. `claimed_by` is unchanged.
- Any other value, including an empty string or `None`: the server logs `usage: LOCAL_OPS_CONTACT must be unset or none` and exits with code 2 before connecting, so a typo never falls back to ticking.

The claude.ai instruction texts that tell chats when to tick are specific to the private deployment and are not part of this edition; the `tick` tool description in `src/tools/tick.ts` is the runtime contract.

## Tests

```sh
node --test mcp/src/                       # unit tests: fake pool, in-memory MCP transport, no database
LOCAL_OPS_REHEARSAL_URL=postgresql://ops_dev@localhost:5432/local_ops_rehearsal node --test mcp/src/
```

The second command also runs `tick.rehearsal.test.ts`. That test refuses any database other than `local_ops_rehearsal`, and it runs on one connection inside a transaction that it always rolls back. It needs no live window in rehearsal. Unset `PGPASSWORD` first so that pgpass supplies the password.

## Restarting after a code change

The servers load code only at startup.

- **Claude Code (executor):** run `/mcp` and reconnect `local_ops`, or restart the Claude Code session.
- **Claude Desktop (planner):** quit Claude Desktop fully (tray icon → Quit; closing the window is not enough), then start it again.

**Executor:**

- `get_pending(node_path)` calls `ops.get_pending` for exactly the component at `node_path` (not its subtree) and trims the result to the batch cap from `protocol_rules.batch_defaults`. The project whose node is the path's depth-2 ancestor (`subpath(node_path, 0, 2)`) can override the cap with `projects.params.batch_defaults`; with no such project the protocol defaults apply.
  - If the first row is investigation-class (`commit_policy = 'none'`), it returns 1 row.
  - Otherwise it returns up to `implementation_max` rows and stops before the first investigation-class row.
  - Rows are cached in memory, because `ops_executor` can't `SELECT ops.dispatches`.
- `claim_dispatch(id)` works only on ids that `get_pending` returned in this process. It enforces a per-process claim counter against the same cap, and a run can't mix investigation and implementation claims.
  - It resolves every `context_ref` before claiming, at the `node_path` that `get_pending` was called with. Each ref is resolved once per run and path, and cached.
  - It calls `ops.claim_dispatch` with `agent_session = <clientInfo.name>:<pid>:<process start ISO>`, the name read from the MCP initialize request at claim time (`unknown` when missing or blank). The same value comes back as `claimed_by` and `dispatch.claimed_by`.
  - If `ops.claim_dispatch` refuses with 23514 (for example a promote whose `prod_apply_approved` pass was revoked after `get_pending`), the tool error says the database refused the claim, that nothing was claimed and no batch slot was used, and carries the database message. Other errors pass through unchanged.
  - It returns the dispatch, its `dispatch_types` row and the context that hasn't been delivered yet.
  - It also returns `work_log`: `{ rows, already_delivered }` from `ops.get_work_log` at the `get_pending` `node_path` (rows tagged to that node or an ancestor; rows whose `files_changed` overlap the dispatch's `task_files` first, then newest; capped by protocol rule `work_log_delivery`), leaving out rows already delivered this run and listing their ids in `already_delivered`. It is `null` when `ops.get_work_log` is absent, feature-detected per call with `to_regprocedure`. The lookup runs before the claim, so a failure leaves no claim. `task_files` is set by the planner's `create_dispatch(..., task_files)`, which sends `p_task_files` only when the list is non-empty.
- `complete_dispatch(id, result, report, work?)` and `fail_dispatch(id, error, refused_premise)` accept only ids this process claimed.
  - `work` is the work-log entry `{ entry_type, title, description?, files_changed, follow_ups, test_summary?, external_refs }`. When `ops.log_work` exists, `ops.log_work` and `ops.complete_dispatch` run in one transaction (a refused completion leaves no log row) and the result carries `work_log_id`. When it is absent, the dispatch completes and the result says `not recorded: ops.log_work is absent in this database`.
  - Once a database has migration 0028, it refuses to complete a dispatch whose type has commit_policy `local` or `push` without `work`; `work` is optional for commit_policy `none`.
- `get_dispatch_type(type)` reads one `ops.dispatch_types` row.

**Planner:**

- `open_session(node_path, kind, scope?)` calls `ops.open_session`. It first auto-closes stale active sessions of the same node. The session is anchored to the opened node, which may be the global node or a node outside any project; it carries a project only when the node has a depth-2 project. `reconstruct_session(node_path, ...)` opens its session the same way.
- `close_session` wraps `ops.close_session` (unchanged; it takes `segment_id`, not a path).
- `cancel_dispatch(id, reason)` calls `ops.cancel_dispatch`. `id` is a full UUID or 8-character id prefix.
- `get_unreviewed_reports(node_path)` returns finished, unreviewed dispatches whose component node is in the subtree of `node_path`.
- `mark_reviewed(node_path, ids)` takes each id as a full UUID or 8-character id prefix. It first checks that every id is a dispatch whose component node is in the subtree of `node_path` (otherwise `not dispatches under node <path>: <ids>`), then calls `ops.mark_reviewed`.
- `list_queue(node_path, status?, limit=50)` lists dispatches whose component node is in the subtree of `node_path`, without their prompt and report bodies. Each row names its component by node path (`component_path`).
- `list_backlog(node_path, status?, kind?)` lists backlog items whose home node is in the subtree of `node_path`; `kind` is the `backlog_items.kind` column. Each row carries `component_path` (null without a component) and `source_dispatch_id`.
- The writer tools are listed below.
- Vision tools (migration 0032; registered by the planner only): `vision_upsert(items, segment_id)`, `vision_link(links, segment_id)`, `vision_unlink(links, segment_id)`, `vision_set_status(key, status, reason, abandoned_reason?, segment_id)`, `vision_true_close(key, evidence, segment_id)`, `vision_check()` and `vision_status(under?)`. Each checks its function (`to_regprocedure`) or view (`to_regclass`) at call time; while 0032 is absent it returns `vision table not installed (migration 0032 is not applied)` and sends nothing else. `vision_status` returns `ops.vision_status` rows ordered by key; with `under`, that item and its descendants by `parent_id` (an unknown key is `vision item <key> does not exist`).
- Context-document tools (migration 0033; registered by the planner only): `write_doc(node_path, doc_key, doc_type, title, content, summary?, basis, decision_ids?, dispatch_ids?, segment_id)`, `approve_doc(node_path, doc_key, content_sha256, segment_id)` and `retire_doc(node_path, doc_key, reason, segment_id)` over `ops.write_doc`, `ops.approve_doc` and `ops.retire_doc`. Each checks its function (`to_regprocedure`) at call time; while 0033 is absent it returns `context-document writer not installed (migration 0033 is not applied)` and sends nothing else.

## Writers

Each writer tool is one named-notation call to its `ops` function (migrations 0014 and 0018). The database does the checks below; a refusal comes back as `Validation error (<code>): <database message>`.

| Tool | Checks |
|---|---|
| `create_dispatch` | `node_path` is the component's node path. Status is forced to `pending`. The component must be active. The dispatch type must exist and be active. Every `context_ref` must resolve at `node_path` (nearest ancestor-or-self). An implementation-class type (`commit_policy <> 'none'`) needs the component to have a `verify_cmd`. `segment_id` (the session id) is required and must lie within the scope of `node_path` (its depth-2 ancestor); it is a full UUID or 8-character id prefix. `task_files` is optional: the repo-relative files the dispatch expects to touch; `p_task_files` is sent only when non-empty, and a blank or NULL element is refused by the database with 23514. Once `ops.vision_link(jsonb,uuid)` exists (0032), exactly one of `vision_item` (an item key) and `vision_none_reason` (non-blank) is required (else an input validation error before any write), and `ops.create_dispatch` then `ops.vision_link` (`{item_key \| none_reason, kind: 'dispatch', ref: <new id>}`, the same session) run in one transaction: a refused link leaves no dispatch. Before 0032 both inputs are ignored. The result is the dispatch row. |
| `log_decision` | Homed at `node_path`. Append-only. `segment_id` (the session id) is required. `supersedes` and `segment_id` must lie within the scope of `node_path`; each is a full UUID or 8-character id prefix. There is no update tool. Optional `vision_item` and `vision_relation` (both or neither): once 0032 is installed, the decision and its `ops.vision_link` (`kind: 'decision'`, the decision's session) run in one transaction; before 0032 they are ignored. |
| `add_backlog_item` | Homed at `node_path`. `source = "kind:<kind>"`, plus `"\|dispatch:<uuid>"` when a source dispatch is given, and that dispatch must lie within the scope of `node_path`. `source_dispatch_id` is a full UUID or 8-character id prefix. Optional `vision_item` and `vision_role` (`blocks` \| `improves`; both or neither) with `segment_id` (optional otherwise): once 0032 is installed, the item and its `ops.vision_link` (`kind: 'backlog'`) run in one transaction; before 0032 they are ignored. |
| `vision_upsert` | `items` (objects passed through as JSON) and `segment_id` (required; full UUID or 8-character id prefix) to `ops.vision_upsert`, which validates every field. Returns `{inserted, updated, status_changes}`. |
| `vision_link` / `vision_unlink` | `links`: `{item_key?, kind (decision \| backlog \| dispatch), ref, relation? \| role? \| none_reason?}` (unlink: `{item_key?, kind, ref}`); each `ref` is a full UUID or 8-character id prefix resolved against decisions, backlog_items or dispatches by `kind` (input `links[i].ref`). `segment_id` required. Link returns `{linked, updated}`, unlink `{removed}`. |
| `vision_set_status` | `ops.vision_set_status(key, status, reason, segment_id, abandoned_reason?)`; shipped is refused while a blocking backlog item is open. Returns `{key, changed}`. |
| `vision_true_close` | `ops.vision_true_close(key, evidence, segment_id)`: only after the operator's explicit yes, with the evidence that the acceptance passed in real use. |
| `write_doc` | Creates or updates the document at (`node_path`, `doc_key`). `doc_key` matches `^[A-Z0-9_]+$`; `basis` is `derived` (lands approved; needs at least one source: a non-superseded decision or a dispatch with a reviewed report) or `review` (lands draft for `approve_doc`); rule `doc_approval`. `decision_ids` / `dispatch_ids` items and `segment_id` (required) are full UUIDs or 8-character id prefixes, resolved before the call (input `decision_ids[i]` / `dispatch_ids[i]`). Returns `{id, version, trust_status, created, reactivated, content_sha256}`. |
| `approve_doc` | The document at exactly `node_path`; `content_sha256` is 64 lowercase hex and must match the stored content. Only after the operator's explicit yes naming the `doc_key` and sha256 (rule `doc_approval`). `segment_id` required. Returns `{id, version}`. |
| `retire_doc` | The document at exactly `node_path`, with a non-blank `reason`; documents are never deleted. Only after the operator's explicit yes, unless a logged decision names the retirement (rule `doc_approval`). `segment_id` required. Returns `{id, retired_at}`. |
| `update_backlog_item` | `id` is a full UUID or 8-character id prefix. Sets `closed_at` on done or dropped, and clears it on reopen. Optional `severity`; omitted leaves it unchanged. |
| `create_project` | `parent_path` is required and must be the global node (`global`). `key` must match `^[a-z0-9][a-z0-9_-]*$`. |
| `create_component` | `parent_path` is required and must be a project node or a plain node outside any component, such as `global.local-ops` (a plain node since migration 0023). |

Database errors come back as tool errors carrying the Postgres message. The server never retries and never falls back.
