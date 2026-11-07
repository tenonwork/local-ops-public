// local-ops MCP bridge: one stdio server, role-selected by --role planner|executor.
// Usage: node src/server.ts --role planner|executor
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createPool, log, type Role } from './db.ts';
import { CONTACT_USAGE, contactFor, installPassiveTick, parseContactSetting } from './tick.ts';
import { registerExecutor } from './tools/executor.ts';
import { registerPlanner } from './tools/planner.ts';
import { registerTick, registerWindowLink } from './tools/window.ts';

function parseRole(argv: string[]): Role {
  const i = argv.indexOf('--role');
  const role = i >= 0 ? argv[i + 1] : undefined;
  if (role !== 'planner' && role !== 'executor') {
    log('usage: node src/server.ts --role planner|executor');
    process.exit(2);
  }
  return role;
}

function parseContact(value: string | undefined): boolean {
  try {
    return parseContactSetting(value);
  } catch {
    log(`usage: ${CONTACT_USAGE}`);
    process.exit(2);
  }
}

const role = parseRole(process.argv.slice(2));
// Read once at startup, before the pool exists: an invalid value exits 2 before connecting.
const ticking = parseContact(process.env.LOCAL_OPS_CONTACT);
const pool = createPool(role);
const server = new McpServer({ name: 'local_ops', version: '0.1.0' });

// Contact source is read per call: clientInfo is known only after initialize.
const contact = () => contactFor(server.server.getClientVersion());

// Must run before any registration so every tool gets the passive tick.
installPassiveTick(server, pool, contact, undefined, ticking);
if (role === 'planner') registerPlanner(server, pool);
else registerExecutor(server, pool);
// LOCAL_OPS_CONTACT=none: no explicit tick tool either, so this process never calls ops.tick.
if (ticking) registerTick(server, pool, contact);
if (role === 'planner') registerWindowLink(server, pool);

async function shutdown(): Promise<void> {
  await server.close().catch(() => undefined);
  await pool.end().catch(() => undefined);
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.stdin.on('close', shutdown);

await server.connect(new StdioServerTransport());
log(`ready: role=${role} user=ops_${role}${ticking ? '' : ' contact=none'}`);
