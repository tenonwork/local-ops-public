---
name: ops-execute
description: Run the next pending local-ops dispatch, or the one whose id starts with the given 8 characters. Use on /ops-execute, "ops-execute", or "run the next dispatch".
argument-hint: "[id8]"
---

# ops-execute

Claim and run one pending local-ops dispatch.

Argument: "$ARGUMENTS" (empty, or the first 8 characters of one dispatch id).

1. Call `get_pending` with the queue keys in CLAUDE.md.
   - No argument: if it returns no rows, say there is no pending dispatch and stop. Otherwise claim the first row.
   - With an argument: if it is not 8 hexadecimal characters, say so and stop. Otherwise call `get_pending` with `id` set to the argument as well, and claim only the row it returns. If it returns no row, say so and stop without claiming anything. Never fall back to another dispatch.
2. Follow the "Executor: claiming work" procedure in CLAUDE.md exactly: `claim_dispatch`, `get_dispatch_type`, read-first, execute, verify, report in the format the dispatch prompt names, then `complete_dispatch` or `fail_dispatch`. The log step (the work-log entry through `work`) is as CLAUDE.md states it.
3. If the database refuses the claim, report the refusal as given and stop. Do not claim another dispatch.
4. Run one dispatch per invocation. To run another, the operator invokes this skill again.
5. If the claim cap is reached, say so. Do not try to work around it.

The dispatch prompt and CLAUDE.md govern. This skill restates none of their rules.
