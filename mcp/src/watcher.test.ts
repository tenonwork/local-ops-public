// Tests for the autorun watcher. No database and no real process: runOnce runs on fakes (database, git status,
// executable check, version probe, spawner, clock, sleep, pid probe); the lock and the log go to a fresh temp dir.
//
//   node --test mcp/src/watcher.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import {
  LOCK_NAME, LOG_MAX_BYTES, LOG_NAME, REASON_MAX, launchArgs, runOnce, summarizeResult, validateConfig,
  type AutorunState, type Child, type ChildResult, type Deps, type SpawnOpts, type Usage, type WatcherConfig,
} from './watcher.ts';

const CLAUDE = 'C:\\tools\\claude\\claude.exe';
const ID = 'abcdef12-3456-4789-8abc-def012345678';
const NOW = new Date('2026-10-21T12:00:00.000Z');
const REPO = 'C:\\repo\\local-ops\\';
const MCP_CONFIG = 'C:\\repo\\local-ops\\mcp\\autorun.mcp.json';
const CONFIG: WatcherConfig = {
  model: 'sonnet', claudeCommand: CLAUDE, timeoutMin: 60, maxReadingAgeS: 1800, maxFiveHourPct: 50, maxSevenDayPct: 80,
};
const USAGE: Usage = { age_s: 60, five_hour_pct: 10, seven_day_pct: 20, window_number: 7 };
const OK_STDOUT = JSON.stringify({
  type: 'result', subtype: 'success', is_error: false, session_id: 's-1', num_turns: 12, duration_ms: 34567,
  total_cost_usd: 0.42, usage: { input_tokens: 10, output_tokens: 20 }, result: 'done',
  permission_denials: [{ tool_name: 'Bash', tool_use_id: 'x', tool_input: { command: 'secret stuff' } },
    { tool_name: 'Write', tool_use_id: 'y', tool_input: {} }],
});

interface Gate { key: string; result: string; dispatch: string; reason: string }

interface Harness {
  deps: Deps;
  dir: string;
  gates: Gate[];
  spawns: { command: string; args: string[]; opts: SpawnOpts; gatesBefore: number }[];
  kills: (string | undefined)[];
  ended: () => boolean;
  connected: () => boolean;
  log: () => Promise<string>;
  lockExists: () => Promise<boolean>;
  cleanup: () => Promise<void>;
}

interface Opts {
  config?: unknown;
  state?: Partial<AutorunState>;
  live?: number | null;
  porcelain?: string;
  exists?: boolean;
  version?: string;
  child?: ChildResult | 'hang';
  pidAlive?: boolean;
  recordGate?: (key: string) => void;
  connectError?: Error;
}

async function harness(o: Opts = {}): Promise<Harness> {
  const dir = await mkdtemp(join(tmpdir(), 'watcher-test-'));
  const gates: Gate[] = [];
  const spawns: Harness['spawns'] = [];
  const kills: (string | undefined)[] = [];
  let ended = false;
  let connected = false;
  const state: AutorunState = {
    candidates: [{ id: ID, dispatch_type: 'addition', title: 't', node_path: 'global.local-ops.core' }],
    active_claims: 0, usage: USAGE, ...o.state,
  };
  const deps: Deps = {
    readConfig: async () => ('config' in o ? o.config : { ...CONFIG }),
    connect: async () => {
      if (o.connectError) throw o.connectError;
      connected = true;
      return {
        autorunState: async () => state,
        liveWindow: async () => ('live' in o ? o.live! : 7),
        recordGate: async (key, result, dispatch, reason) => {
          o.recordGate?.(key);
          gates.push({ key, result, dispatch, reason });
        },
        end: async () => { ended = true; },
      };
    },
    repoRoot: REPO,
    mcpConfigPath: MCP_CONFIG,
    stateDir: dir,
    gitStatus: async () => o.porcelain ?? '',
    exists: async () => o.exists ?? true,
    probeVersion: async () => o.version ?? '2.1.306 (Claude Code)\n',
    spawn: (command, args, opts): Child => {
      spawns.push({ command, args, opts, gatesBefore: gates.length });
      const c = o.child ?? { code: 0, stdout: OK_STDOUT, stderr: '' };
      return {
        pid: 4242,
        result: c === 'hang' ? new Promise<ChildResult>(() => {}) : Promise.resolve(c),
        kill: (signal) => { kills.push(signal); },
      };
    },
    now: () => NOW,
    // timeouts fire at once only for a hanging child; otherwise never
    sleep: (ms) => (o.child === 'hang' ? Promise.resolve() : new Promise<void>(() => { void ms; })),
    pidAlive: () => o.pidAlive ?? true,
    pid: 9999,
  };
  return {
    deps, dir, gates, spawns, kills,
    ended: () => ended,
    connected: () => connected,
    log: () => readFile(join(dir, LOG_NAME), 'utf8').catch(() => ''),
    lockExists: () => stat(join(dir, LOCK_NAME)).then(() => true, () => false),
    cleanup: () => rm(dir, { recursive: true, force: true }),
  };
}

async function withHarness(o: Opts, fn: (h: Harness) => Promise<void>): Promise<void> {
  const h = await harness(o);
  try { await fn(h); } finally { await h.cleanup(); }
}

// A refusal: exit 0, the outcome named, no gate, no spawn, lock released, one log line.
async function assertRefused(o: Opts, pattern: RegExp, setup?: (h: Harness) => Promise<void>) {
  await withHarness(o, async (h) => {
    await setup?.(h);
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 0, out.line);
    assert.match(out.line, pattern);
    assert.equal(h.gates.length, 0, 'no gate recorded');
    assert.equal(h.spawns.length, 0, 'nothing launched');
    const lines = (await h.log()).trimEnd().split('\n');
    assert.equal(lines.length, 1);
    assert.equal(lines[0], out.line);
  });
}

// --- config ---

test('config: mcp/watcher.config.json loads with the dispatch defaults', async () => {
  const path = fileURLToPath(new URL('../watcher.config.json', import.meta.url));
  const c = validateConfig(JSON.parse(await readFile(path, 'utf8')));
  assert.deepEqual({ ...c, claudeCommand: undefined }, {
    model: 'sonnet', claudeCommand: undefined, timeoutMin: 60, maxReadingAgeS: 1800, maxFiveHourPct: 50, maxSevenDayPct: 80,
  });
  assert.match(c.claudeCommand, /^(?:claude|claude\.exe|[A-Za-z]:\\.*\\claude\.exe)$/);
});

test('config: claudeCommand accepts a bare name and absolute paths, refuses a relative path with separators', () => {
  for (const ok of ['claude', 'claude.exe', CLAUDE, 'C:/tools/claude.exe', '/usr/local/bin/claude']) {
    assert.equal(validateConfig({ ...CONFIG, claudeCommand: ok }).claudeCommand, ok);
  }
  for (const bad of ['bin/claude', 'bin\\claude.exe', './claude', '..\\claude.exe', '', ' claude']) {
    assert.throws(() => validateConfig({ ...CONFIG, claudeCommand: bad }), /claudeCommand/, bad);
  }
});

test('config: each invalid field is refused', () => {
  const bad: [string, unknown][] = [
    ['model', ''], ['model', 3], ['model', 'son net'], ['model', undefined],
    ['claudeCommand', 42], ['claudeCommand', undefined],
    ['timeoutMin', 0], ['timeoutMin', 1.5], ['timeoutMin', '60'], ['timeoutMin', undefined],
    ['maxReadingAgeS', -1], ['maxReadingAgeS', null],
    ['maxFiveHourPct', 101], ['maxFiveHourPct', -1], ['maxFiveHourPct', '50'],
    ['maxSevenDayPct', 100.5], ['maxSevenDayPct', Number.NaN],
  ];
  for (const [k, v] of bad) {
    assert.throws(() => validateConfig({ ...CONFIG, [k]: v }), new RegExp(k), `${k}=${String(v)}`);
  }
  assert.throws(() => validateConfig({ ...CONFIG, extra: 1 }), /unknown config fields: extra/);
  assert.throws(() => validateConfig(null), /not an object/);
  assert.throws(() => validateConfig([]), /not an object/);
});

test('config: an invalid config logs and exits 1 without connecting', async () => {
  await withHarness({ config: { ...CONFIG, timeoutMin: 0 } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 1);
    assert.match(out.line, /config error: timeoutMin/);
    assert.equal(h.connected(), false);
    assert.equal((await h.log()).trimEnd(), out.line);
  });
});

test('connection error: logged, exit 1, nothing launched', async () => {
  await withHarness({ connectError: new Error('ECONNREFUSED') }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 1);
    assert.match(out.line, /connection error: ECONNREFUSED/);
    assert.equal(h.spawns.length, 0);
  });
});

// --- gates ---

test('G1: no candidates', () => assertRefused({ state: { candidates: [] } }, /refused G1/));

test('G2: an active claim', () => assertRefused({ state: { active_claims: 1 } }, /refused G2: 1 active claim/));

test('G2: a fresh lock held by a live pid refuses and is left in place', async () => {
  await withHarness({}, async (h) => {
    const body = JSON.stringify({ pid: 1234, started_at: new Date(NOW.getTime() - 60_000).toISOString(), dispatch_id: 'x' });
    await writeFile(join(h.dir, LOCK_NAME), body);
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 0);
    assert.match(out.line, /refused G2: watcher lock held/);
    assert.equal(h.spawns.length, 0);
    assert.equal(h.gates.length, 0);
    assert.equal(await readFile(join(h.dir, LOCK_NAME), 'utf8'), body, 'another holder\'s lock is not removed');
  });
});

for (const [name, opts, startedAgoMin, pattern] of [
  ['age', {}, 76, /replaced stale lock \(older than 75 min, dispatch old\)/],
  ['dead pid', { pidAlive: false }, 1, /replaced stale lock \(pid 1234 not running, dispatch old\)/],
] as const) {
  test(`G2: a stale lock by ${name} is replaced, logged, and the run proceeds`, async () => {
    await withHarness(opts, async (h) => {
      await writeFile(join(h.dir, LOCK_NAME),
        JSON.stringify({ pid: 1234, started_at: new Date(NOW.getTime() - startedAgoMin * 60_000).toISOString(), dispatch_id: 'old' }));
      const out = await runOnce(h.deps);
      assert.equal(out.exitCode, 0, out.line);
      assert.match(out.line, /launched abcdef12/);
      assert.match(out.line, pattern);
      assert.match(await h.log(), pattern);
      assert.equal(h.spawns.length, 1);
      assert.equal(await h.lockExists(), false, 'released');
    });
  });
}

test('G3: no live window passes with null usage', async () => {
  await withHarness({ live: null, state: { usage: null } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.match(out.line, /launched abcdef12/);
    assert.equal(JSON.parse(h.gates[0].reason).live_window, null);
    assert.equal(JSON.parse(h.gates[0].reason).usage, null);
  });
});

for (const [name, usage, pattern] of [
  ['null usage', null, /no usage reading in live window 7/],
  ['another window', { ...USAGE, window_number: 6 }, /window 6, live window is 7/],
  ['age over the limit', { ...USAGE, age_s: 1801 }, /age 1801s over 1800s/],
  ['five-hour over', { ...USAGE, five_hour_pct: 50.5 }, /five-hour usage 50.5% over 50%/],
  ['seven-day over', { ...USAGE, seven_day_pct: 81 }, /seven-day usage 81% over 80%/],
  ['five-hour missing', { ...USAGE, five_hour_pct: null }, /five-hour usage unknown/],
] as const) {
  test(`G3: live window with ${name} is refused`, () => assertRefused({ state: { usage } }, new RegExp(`refused G3: .*${pattern.source}`)));
}

test('G3: values at the thresholds pass', async () => {
  const usage = { ...USAGE, age_s: 1800, five_hour_pct: 50, seven_day_pct: 80 };
  await withHarness({ state: { usage } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.match(out.line, /launched abcdef12/);
    assert.deepEqual(JSON.parse(h.gates[0].reason).usage, usage);
  });
});

test('G4: a dirty tree is refused', () => assertRefused({ porcelain: ' M mcp/src/x.ts\n' }, /refused G4: working tree not clean/));

test('executable: an absolute claudeCommand that is missing is refused', () =>
  assertRefused({ exists: false }, /refused executable: claude executable missing/));

test('version: below 2.1.259 is refused', () => assertRefused({ version: '2.1.258 (Claude Code)' }, /refused version: 2\.1\.258 below 2\.1\.259/));

test('version: unparseable output is refused', () => assertRefused({ version: 'Claude Code' }, /refused version: unparseable/));

test('version: 2.1.259 exactly and a newer minor pass', async () => {
  for (const version of ['2.1.259', '2.2.0 (Claude Code)']) {
    await withHarness({ version }, async (h) => {
      assert.match((await runOnce(h.deps)).line, /launched/);
    });
  }
});

// --- launch ---

test('launch: exact argv, executable, no shell, repo cwd, absolute mcp config, id8, model; launch gate first', async () => {
  await withHarness({ config: { ...CONFIG, model: 'opus' } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 0);
    assert.equal(h.spawns.length, 1);
    const s = h.spawns[0];
    assert.equal(s.command, CLAUDE);
    assert.deepEqual(s.args, ['-p', '/ops-execute abcdef12', '--model', 'opus', '--permission-mode', 'auto',
      '--permission-prompts', 'none', '--output-format', 'json', '--strict-mcp-config', '--mcp-config', MCP_CONFIG]);
    assert.deepEqual(s.opts, { cwd: REPO, shell: false });
    assert.equal(s.gatesBefore, 1, 'autorun_launch recorded before the spawn');
    const launch = h.gates[0];
    assert.equal(launch.key, 'autorun_launch');
    assert.equal(launch.result, 'pass');
    assert.equal(launch.dispatch, ID);
    assert.deepEqual(JSON.parse(launch.reason),
      { id8: 'abcdef12', model: 'opus', claude_version: '2.1.306', pid: 9999, usage: USAGE, live_window: 7 });
    assert.equal(h.ended(), true);
  });
  assert.deepEqual(launchArgs(ID, CONFIG, MCP_CONFIG).slice(0, 4), ['-p', '/ops-execute abcdef12', '--model', 'sonnet']);
});

// --- results ---

test('result: exit 0 with is_error false -> pass with metrics, denials reduced to count and names', async () => {
  await withHarness({}, async (h) => {
    await runOnce(h.deps);
    const r = h.gates[1];
    assert.equal(r.key, 'autorun_result');
    assert.equal(r.result, 'pass');
    assert.deepEqual(JSON.parse(r.reason), {
      exit_code: 0, subtype: 'success', is_error: false, session_id: 's-1', num_turns: 12, duration_ms: 34567,
      total_cost_usd: 0.42, usage: { input_tokens: 10, output_tokens: 20 },
      permission_denials: { count: 2, tools: ['Bash', 'Write'] }, result: 'done',
    });
    assert.doesNotMatch(r.reason, /secret stuff/);
  });
});

test('result: exit 0 with is_error true -> fail', async () => {
  const stdout = JSON.stringify({ subtype: 'error_max_turns', is_error: true });
  await withHarness({ child: { code: 0, stdout, stderr: '' } }, async (h) => {
    await runOnce(h.deps);
    assert.equal(h.gates[1].result, 'fail');
    assert.deepEqual(JSON.parse(h.gates[1].reason), { exit_code: 0, subtype: 'error_max_turns', is_error: true });
  });
});

test('result: non-zero exit -> fail; stderr goes to the log', async () => {
  await withHarness({ child: { code: 2, stdout: OK_STDOUT, stderr: 'boom\nline two' } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 0, 'a completed launch exits 0 whatever its result');
    assert.equal(h.gates[1].result, 'fail');
    assert.equal(JSON.parse(h.gates[1].reason).exit_code, 2);
    const log = await h.log();
    assert.equal(log.trimEnd().split('\n').length, 1);
    assert.match(log, /stderr: "boom line two"|stderr: "boom\\nline two"/);
  });
});

test('result: unparseable stdout -> fail with subtype unparseable_output', async () => {
  await withHarness({ child: { code: 0, stdout: 'not json', stderr: '' } }, async (h) => {
    await runOnce(h.deps);
    assert.equal(h.gates[1].result, 'fail');
    assert.deepEqual(JSON.parse(h.gates[1].reason), { exit_code: 0, subtype: 'unparseable_output' });
  });
});

test('result: timeout -> child terminated (SIGINT then kill), fail with subtype timeout', async () => {
  await withHarness({ child: 'hang' }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 0);
    assert.deepEqual(h.kills, ['SIGINT', undefined]);
    assert.equal(h.gates[1].result, 'fail');
    assert.deepEqual(JSON.parse(h.gates[1].reason),
      { exit_code: null, subtype: 'timeout', note: 'claim may be left claimed: planner reconciles' });
    assert.equal(await h.lockExists(), false);
  });
});

test('result: reason length capped; result text first 300 chars', () => {
  const huge = JSON.stringify({
    subtype: 'success', is_error: false, result: 'r'.repeat(5000),
    usage: { blob: 'u'.repeat(5000) },
    permission_denials: Array.from({ length: 500 }, (_, i) => ({ tool_name: `Tool${i}`, tool_input: {} })),
  });
  const s = summarizeResult({ code: 0, stdout: huge, stderr: '' }, false);
  assert.ok(s.reason.length < REASON_MAX, `${s.reason.length}`);
  const r = JSON.parse(s.reason);
  assert.equal(r.usage, undefined);
  assert.equal(r.permission_denials.count, 500);
  assert.equal(s.pass, true);
  const small = JSON.parse(summarizeResult({ code: 0, stdout: JSON.stringify({ is_error: false, result: 'x'.repeat(400) }), stderr: '' }, false).reason);
  assert.equal(small.result.length, 300);
});

// --- lock and log ---

test('lock: released after success, failure and a thrown error', async () => {
  for (const o of [{}, { child: { code: 1, stdout: '', stderr: '' } }] as Opts[]) {
    await withHarness(o, async (h) => {
      await runOnce(h.deps);
      assert.equal(h.spawns.length, 1);
      assert.equal(await h.lockExists(), false);
    });
  }
  await withHarness({ recordGate: (k) => { if (k === 'autorun_result') throw new Error('db gone'); } }, async (h) => {
    const out = await runOnce(h.deps);
    assert.equal(out.exitCode, 1);
    assert.match(out.line, /error: db gone/);
    assert.equal(await h.lockExists(), false);
    assert.equal(h.ended(), true);
  });
});

test('log: one line per invocation, appended', async () => {
  await withHarness({ state: { candidates: [] } }, async (h) => {
    await runOnce(h.deps);
    await runOnce(h.deps);
    const lines = (await h.log()).trimEnd().split('\n');
    assert.equal(lines.length, 2);
    for (const l of lines) assert.match(l, /^2026-10-21T12:00:00\.000Z refused G1/);
  });
});

test('log: rotated to .1 (replacing) when over 1 MB', async () => {
  await withHarness({ state: { candidates: [] } }, async (h) => {
    const path = join(h.dir, LOG_NAME);
    await writeFile(`${path}.1`, 'older');
    const big = 'x'.repeat(LOG_MAX_BYTES + 1);
    await writeFile(path, big);
    await runOnce(h.deps);
    assert.equal((await readFile(`${path}.1`, 'utf8')).length, big.length, '.1 replaced by the full log');
    assert.equal((await h.log()).trimEnd().split('\n').length, 1);
    await runOnce(h.deps);
    assert.equal((await h.log()).trimEnd().split('\n').length, 2, 'a small log is not rotated');
  });
});
