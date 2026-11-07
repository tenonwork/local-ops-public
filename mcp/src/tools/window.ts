// Window tools: explicit tick (both roles) and window_link_event (planner only; ops_executor has no grant).
import * as z from 'zod';
import type pg from 'pg';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { CheckError, describe, fail, rows, tool } from '../db.ts';
import { tick, type Contact } from '../tick.ts';

const calendarEvent = z.object({
  id: z.string().min(1),
  start: z.string().min(1),
  end: z.string().min(1),
  title: z.string().optional(),
  description: z.string().optional(),
});

export function registerTick(server: McpServer, pool: pg.Pool, contact: () => Contact): void {
  server.registerTool('tick', {
    description: [
      'Record a contact and read the usage window (ops.tick). Call it first, before other work: on the first prompt of every chat, and on every prompt in framework work.',
      'Returns the one-line summary, then the JSON. Act on the directive, then tick again; repeat until directive is null.',
      'LIST_CAL: list events on the "Claude Sessions — Global" calendar with no time parameters, then tick again with them as `calendar` ([] if none).',
      'CAL_CREATE: create the event on that calendar: title "Claude window W###", start = window.started_at, end = window.resets_at, no reminders, description "ops:window W### provenance=<start_source> first_contact=<ISO> surface=<chat|code>". Then call window_link_event(number, event_id).',
      'CONFLICT: show the detail to the operator and stop. Do not resolve it.',
      'State fix_cal (window start corrected): move the linked event to the new started_at / resets_at.',
      'State resume (gap of 30 min or more): before new work, restate the latest session\'s next_step.',
      'reset_at (ISO 8601 with offset) and reset_source go together or not at all: stated if the operator gave the time, observed for a usage stamp.',
    ].join('\n'),
    inputSchema: {
      reset_at: z.iso.datetime({ offset: true }).optional(),
      reset_source: z.enum(['stated', 'observed']).optional(),
      calendar: z.array(calendarEvent).optional(),
      chat_ref: z.string().min(1).optional(),
    },
  }, async (a) => {
    try {
      if ((a.reset_at === undefined) !== (a.reset_source === undefined)) {
        throw new CheckError('reset_at and reset_source must be given together');
      }
      const t = await tick(pool, contact(), a);
      return { content: [
        { type: 'text', text: String(t.line) },
        { type: 'text', text: JSON.stringify(t, null, 2) },
      ] };
    } catch (err) {
      return fail(describe(err));
    }
  });
}

export function registerWindowLink(server: McpServer, pool: pg.Pool): void {
  server.registerTool('window_link_event', {
    description: 'Link a calendar event to a window by number (ops.window_link_event), after creating the event for a CAL_CREATE directive. Idempotent for the same event id.',
    inputSchema: { number: z.number().int().min(1), event_id: z.string().min(1) },
  }, tool(async ({ number, event_id }) =>
    (await rows(pool, 'SELECT (ops.window_link_event($1, $2)).*', [number, event_id]))[0]));
}
