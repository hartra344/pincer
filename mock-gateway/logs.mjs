// Gateway logs: logs.tail reads the current log file by byte offset, like the Gateway's
// src/gateway/server-methods/logs.ts + src/logging/log-tail.ts. The "file" lives in memory; a timer
// appends a few tslog-shaped JSON lines every second so polling clients see a live tail.
// MOCK_NO_LOGS=1 makes the mock look like a Gateway without logs.tail.
export const LOGS_METHODS = ['logs.tail'];
const READ_SCOPES = ['operator.read', 'operator.write', 'operator.admin'];
const PARAM_KEYS = new Set(['cursor', 'limit', 'maxBytes']);
const DEFAULT_LIMIT = 500;
const MAX_LIMIT = 5000;
const DEFAULT_MAX_BYTES = 250_000;
const MAX_BYTES = 1_000_000;
const LEVEL_IDS = { TRACE: 1, DEBUG: 2, INFO: 3, WARN: 4, ERROR: 5, FATAL: 6 };

export function logsDisabled() {
  return process.env.MOCK_NO_LOGS === '1';
}

function logPath(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `/tmp/openclaw/openclaw-${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}.log`;
}

export function logLine(level, subsystem, message, date = new Date(), { meta, repeatName = false } = {}) {
  const name = JSON.stringify({ subsystem });
  const time = date.toISOString();
  const levelName = level.toUpperCase();
  const args = [...(repeatName ? [name] : []), ...(meta ? [meta] : []), message];
  const obj = {
    ...Object.fromEntries(args.map((arg, i) => [String(i), arg])),
    _meta: {
      runtime: 'node',
      runtimeVersion: '24.3.0',
      hostname: 'unknown',
      name,
      parentNames: ['openclaw'],
      date: time,
      logLevelId: LEVEL_IDS[levelName] ?? 3,
      logLevelName: levelName,
    },
    time,
  };
  return JSON.stringify(obj);
}

function appendRaw(logs, line) {
  logs.lines.push(line);
  logs.starts.push(logs.size);
  logs.size += Buffer.byteLength(line, 'utf8') + 1;
}

export function appendLogLine(logs, level, subsystem, message, options) {
  appendRaw(logs, logLine(level, subsystem, message, options?.date ?? new Date(), options));
}

const AMBIENT = [
  ['debug', 'gateway', (n) => `tick → ${n} operator clients`],
  ['info', 'channels/discord', (n) => `message in #general from sam (${n} chars)`],
  ['trace', 'gateway', (n) => `sessions.list served in ${n}ms`],
  ['debug', 'channels/discord', (n) => `heartbeat ack in ${n}ms`],
  ['info', 'agent', (n) => `run_bg${n}: heartbeat check finished, nothing to report`],
  ['debug', 'cron', (n) => `morning-briefing: next run in ${n} minutes`],
  ['info', 'plugins', (n) => `weather: refreshed forecast for Seattle (${n} locations)`],
  ['warn', 'channels/telegram', (n) => `rate limited by Telegram, retrying in ${n}s`],
  ['debug', 'gateway', (n) => `config hot-reload: no changes (${n} files watched)`],
  ['info', 'gateway', (n) => `ws client connected (conn_${n}, operator)`],
  ['warn', 'plugins', (n) => `browser: page load took ${n}.4s (slow)`],
  ['error', 'channels/discord', (n) => `attachment upload failed (HTTP 5${String(n % 100).padStart(2, '0')}), will retry`],
];

function ambient(logs, date) {
  const [level, subsystem, format] = AMBIENT[logs.counter % AMBIENT.length];
  appendLogLine(logs, level, subsystem, format(2 + ((logs.counter * 37 + 11) % 97)), { date });
  logs.counter += 1;
}

function seed(logs, base) {
  const start = base - 90 * 60_000;
  let t = start;
  const at = (ms) => new Date((t += ms));
  const boot = [
    ['info', 'gateway', 'OpenClaw 2026.9.2 starting (pid 4121, node 24.3.0)'],
    ['debug', 'gateway', 'config loaded from ~/.openclaw/openclaw.json (revision 42)'],
    ['info', 'gateway', 'listening on ws://127.0.0.1:18789'],
    ['debug', 'plugins', 'loading 5 plugins'],
    ['info', 'channels/discord', 'connected as Claw#0042 (2 servers)'],
    ['info', 'cron', 'scheduler started: 3 jobs (1 paused)'],
  ];
  for (const [level, subsystem, message] of boot) appendLogLine(logs, level, subsystem, message, { date: at(400) });
  appendLogLine(logs, 'info', 'gateway', 'control UI served at /', { date: at(300), repeatName: true });
  appendRaw(logs, '(node:4121) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.');
  appendRaw(logs, '\u001b[33mwarn\u001b[39m \u001b[2m[doctor]\u001b[22m Tailscale Serve certificate renews in 9 days');
  appendLogLine(logs, 'info', 'gateway', 'ws client connected (conn_1, operator)', {
    date: at(4000),
    meta: { client: 'openclaw-control-ui', scopes: ['operator.read', 'operator.write'] },
  });
  for (let i = 0; i < 120; i += 1) {
    const date = new Date(start + (1 + i * 0.7) * 60_000);
    if (i === 30) appendLogLine(logs, 'error', 'cron', 'disk-check failed: exit code 1 (df: /Volumes/Backup: No such file or directory)', { date });
    else if (i === 60) appendLogLine(logs, 'fatal', 'plugins', 'browser: worker crashed (SIGSEGV); restarting worker', { date });
    else if (i === 90) appendLogLine(logs, 'debug', 'agent', `prompt assembled: ${'Summarize new papers on retrieval-augmented generation. '.repeat(60)}`, { date });
    else ambient(logs, date);
  }
}

export function createLogsState(base = Date.now()) {
  const logs = { dayOffset: 0, file: logPath(new Date(base)), lines: [], starts: [], size: 0, counter: 0, failNext: 0 };
  seed(logs, base);
  logs.timer = setInterval(() => {
    const count = 1 + Math.floor(Math.random() * 3);
    for (let i = 0; i < count; i += 1) ambient(logs, new Date());
  }, 1000);
  logs.timer.unref?.();
  return logs;
}

export function stopLogs(logs) {
  if (logs?.timer) clearInterval(logs.timer);
}

// Index of the first line starting at or after `offset`.
function lowerBound(starts, offset) {
  let low = 0;
  let high = starts.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (starts[mid] < offset) low = mid + 1;
    else high = mid;
  }
  return low;
}

// Mirrors readLogSlice: tail on first read, re-anchor on shrink/rotation, fast-forward when too far behind.
export function readLogSlice(logs, { cursor, limit = DEFAULT_LIMIT, maxBytes = DEFAULT_MAX_BYTES }) {
  const { size } = logs;
  let start;
  let truncated = false;
  let reset = false;
  let skippedBytes;
  if (cursor === undefined) {
    start = Math.max(0, size - maxBytes);
    truncated = start > 0;
  } else if (cursor > size) {
    reset = true;
    start = Math.max(0, size - maxBytes);
    truncated = start > 0;
  } else if (size - cursor > maxBytes) {
    reset = true;
    truncated = true;
    const bounded = Math.max(0, size - maxBytes);
    skippedBytes = bounded - cursor;
    start = bounded;
  } else {
    start = cursor;
  }
  const result = { file: logs.file, cursor: size, size, lines: [], truncated, reset };
  if (skippedBytes !== undefined) result.skippedBytes = skippedBytes;
  if (size <= start) return result;
  let lines = logs.lines.slice(lowerBound(logs.starts, start));
  if (lines.length > limit) {
    lines = lines.slice(-limit);
    result.truncated = true;
  }
  result.lines = lines;
  return result;
}

function validParams(params) {
  if (!params || typeof params !== 'object' || Array.isArray(params)) return 'expected an object';
  const unknown = Object.keys(params).find((key) => !PARAM_KEYS.has(key));
  if (unknown) return `unexpected property ${unknown}`;
  const ranges = { cursor: [0, Number.MAX_SAFE_INTEGER], limit: [1, MAX_LIMIT], maxBytes: [1, MAX_BYTES] };
  for (const [key, [min, max]] of Object.entries(ranges)) {
    const value = params[key];
    if (value !== undefined && (!Number.isInteger(value) || value < min || value > max)) {
      return `${key} must be an integer in ${min}…${max}`;
    }
  }
  return undefined;
}

// Test hooks in chat.send, matched in the message text:
// [mock:rotate-logs] switches to the next day's file, [mock:truncate-logs] empties the current file,
// [mock:log-burst] appends 6000 lines at once, [mock:logs-unavailable] fails the next two reads.
export function noteChatForLogs(state, sessionKey, message, runId) {
  const logs = state.logsState;
  if (!logs) return;
  if (message.includes('[mock:rotate-logs]')) {
    logs.dayOffset += 1;
    logs.file = logPath(new Date(Date.now() + logs.dayOffset * 86_400_000));
    logs.lines = [];
    logs.starts = [];
    logs.size = 0;
    appendLogLine(logs, 'info', 'gateway', `log file opened: ${logs.file}`);
  }
  if (message.includes('[mock:truncate-logs]')) {
    logs.lines = [];
    logs.starts = [];
    logs.size = 0;
  }
  if (message.includes('[mock:log-burst]')) {
    const now = new Date();
    for (let i = 0; i < 6000; i += 1) {
      appendLogLine(logs, 'debug', 'agent', `burst line ${i + 1} of 6000: tool output chunk (${'x'.repeat(40)})`, { date: now });
    }
  }
  if (message.includes('[mock:logs-unavailable]')) logs.failNext = 2;
  appendLogLine(logs, 'info', 'gateway', `chat.send ${sessionKey} → ${runId}`);
}

export function noteApprovalForLogs(state, approval) {
  if (!state.logsState) return;
  appendLogLine(state.logsState, 'warn', 'exec', `approval ${approval.id} waiting for a reviewer: ${approval.request.command}`);
}

export function handleLogsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method, params = {} } = msg;
  if (!LOGS_METHODS.includes(method) || logsDisabled()) return false;
  if (!(conn.scopes ?? []).some((scope) => READ_SCOPES.includes(scope))) {
    sendErr(conn, id, 'FORBIDDEN', 'missing scope: operator.read', { code: 'MISSING_SCOPE', scope: 'operator.read' });
    return true;
  }
  const problem = validParams(params);
  if (problem) return sendErr(conn, id, 'INVALID_REQUEST', `invalid logs.tail params: ${problem}`), true;
  const logs = state.logsState;
  if (logs.failNext > 0) {
    logs.failNext -= 1;
    sendErr(conn, id, 'UNAVAILABLE', `log read failed: EACCES: permission denied, open '${logs.file}'`);
    return true;
  }
  sendRes(conn, id, readLogSlice(logs, params));
  return true;
}
