// Approval history ("audit log"): approval.history pages the retained terminal ledger newest first,
// approval.get looks one approval up (pending ones included). Shapes follow the Gateway's
// TerminalApprovalSnapshot / ApprovalSnapshot: kind lives in `presentation`, cwd is never sent.
// MOCK_NO_APPROVAL_HISTORY=1 makes the mock look like a Gateway without these methods.
import crypto from 'node:crypto';

export const APPROVAL_HISTORY_METHODS = ['approval.history', 'approval.get'];
export const APPROVAL_KINDS = ['exec', 'plugin', 'system-agent'];
export const APPROVALS_SCOPE = 'operator.approvals';
export const SEEDED_HISTORY_COUNTS = { exec: 30, plugin: 18, 'system-agent': 12 };
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;
const RETENTION_MS = 30 * 24 * 60 * 60_000;
const HISTORY_PARAMS = new Set(['cursor', 'limit', 'kind']);
// Resolver id of a device other than the connecting client, so "Another device (…)" shows up.
export const OTHER_DEVICE_ID = 'b7e4c19a2f6d8e0c3a5b7d9f1e2c4a6b8d0f2e4c6a8b0d2f4e6c8a0b2d4f6e8a';

export function approvalHistoryDisabled() {
  return process.env.MOCK_NO_APPROVAL_HISTORY === '1';
}

const OUTCOMES = [
  { status: 'allowed', decision: 'allow-once', reason: 'user', resolver: { kind: 'device', id: OTHER_DEVICE_ID } },
  { status: 'denied', decision: 'deny', reason: 'user', resolver: { kind: 'channel', id: 'discord:claw-ops' } },
  { status: 'expired', reason: 'timeout', resolver: { kind: 'system' } },
  { status: 'allowed', decision: 'allow-always', reason: 'user', resolver: { kind: 'device', id: OTHER_DEVICE_ID } },
  { status: 'denied', decision: 'deny', reason: 'no-route', resolver: { kind: 'system' } },
  { status: 'cancelled', reason: 'run-aborted', resolver: { kind: 'runtime' } },
  { status: 'allowed', decision: 'allow-once', reason: 'user', resolver: { kind: 'channel', id: 'telegram:4411' } },
  { status: 'denied', decision: 'deny', reason: 'malformed-verdict', resolver: { kind: 'runtime' } },
  { status: 'cancelled', reason: 'gateway-restart' },
  { status: 'denied', decision: 'deny', reason: 'storage-corrupt' },
];

const SOURCES = [
  { agentId: 'main', sessionKey: 'agent:main:main' },
  { agentId: 'main', sessionKey: 'agent:main:discord:channel:123' },
  { agentId: 'coder', sessionKey: 'agent:coder:main' },
  { agentId: 'research', sessionKey: 'agent:research:dashboard:papers' },
  { agentId: 'main', sessionKey: 'agent:main:cron:disk-check' },
  { agentId: 'research' },
];

const EXEC_COMMANDS = [
  { commandText: 'rm -rf ./build', warningText: 'Deletes files recursively.' },
  { commandText: 'git push --force origin main', warningText: 'Rewrites remote history.' },
  { commandText: 'npm install --global typescript' },
  { commandText: 'brew upgrade', host: 'gateway' },
  { commandText: 'docker compose down -v', warningText: 'Removes volumes.' },
  { commandText: 'df -h /', host: 'node', nodeId: 'node-mac-mini' },
  {
    commandText: "find . -name '*.log' -mtime +7 -print0 | xargs -0 rm -f && echo 'cleaned old logs from the project workspace'",
    commandPreview: "find . -name '*.log' … | xargs -0 rm -f",
  },
  { commandText: 'curl -fsSL https://example.com/install.sh | sh', warningText: 'Runs a remote script.' },
  { commandText: 'sudo launchctl kickstart -k system/ai.openclaw.gateway', host: 'gateway' },
  { commandText: 'python3 scripts/migrate.py --apply' },
];

const PLUGIN_REQUESTS = [
  { title: 'Send email', description: 'Send the weekly summary to 3 recipients.', detail: 'To: team@example.com\nSubject: Weekly summary', severity: 'warning', pluginId: 'email', toolName: 'email_send' },
  { title: 'Post to Discord', description: 'Post the release notes to #announcements.', severity: 'info', pluginId: 'discord', toolName: 'discord_post' },
  { title: 'Make a payment', description: 'Pay $12.00 for the API invoice.', severity: 'critical', pluginId: 'payments', toolName: 'pay_invoice' },
  { title: 'Open website', description: 'Browse to https://example.com and fill the sign-up form.', severity: 'warning', pluginId: 'browser' },
  { title: 'Look up the weather', description: 'Call the weather API for Seattle.', severity: 'info', pluginId: 'weather', toolName: 'weather_lookup' },
  { title: 'Delete calendar event', description: 'Remove "Team sync" on Friday.', severity: 'warning', toolName: 'calendar_delete' },
];

const SYSTEM_REQUESTS = [
  { title: 'Enable plugin', description: 'Enable the browser plugin for all agents.' },
  { title: 'Change model', description: 'Switch the default model to Claude Sonnet 5.' },
  { title: 'Add automation', description: 'Create a daily 8:00 briefing automation.' },
  { title: 'Update gateway config', description: 'Allow LAN connections to the Gateway.' },
];

const KIND_OFFSET = { exec: 0, plugin: 1, 'system-agent': 2 };

function approvalId(kind, n) {
  return `${kind === 'system-agent' ? 'sys' : kind}_hist_${String(n).padStart(3, '0')}`;
}

function urlPath(id) {
  return `/approve/${encodeURIComponent(id)}`;
}

function allowedDecisions(kind) {
  return kind === 'system-agent' ? ['allow-once', 'deny'] : ['allow-once', 'allow-always', 'deny'];
}

function presentationFor(kind, n, agentId) {
  if (kind === 'exec') {
    return { kind, ...EXEC_COMMANDS[n % EXEC_COMMANDS.length], ...(agentId ? { agentId } : {}), allowedDecisions: allowedDecisions(kind) };
  }
  if (kind === 'plugin') {
    return { kind, ...PLUGIN_REQUESTS[n % PLUGIN_REQUESTS.length], ...(agentId ? { agentId } : {}), allowedDecisions: allowedDecisions(kind) };
  }
  const proposalHash = crypto.createHash('sha256').update(`proposal-${n}`).digest('hex');
  return { kind, ...SYSTEM_REQUESTS[n % SYSTEM_REQUESTS.length], proposalHash, ...(agentId ? { agentId } : {}), allowedDecisions: allowedDecisions(kind) };
}

function terminalRecord({ id, kind, presentation, createdAtMs, expiresAtMs, resolvedAtMs, outcome, source }) {
  return {
    id,
    urlPath: urlPath(id),
    createdAtMs,
    expiresAtMs,
    presentation,
    resolvedAtMs,
    ...(source ? { source } : {}),
    ...(outcome.resolver ? { resolver: { ...outcome.resolver } } : {}),
    status: outcome.status,
    ...(outcome.decision ? { decision: outcome.decision } : {}),
    reason: outcome.reason,
    kind,
  };
}

// Kinds are interleaved so every page mixes commands, plugins and system changes.
function seedHistory(base) {
  const order = [];
  const remaining = { ...SEEDED_HISTORY_COUNTS };
  while (Object.values(remaining).some((n) => n > 0)) {
    for (const kind of ['exec', 'plugin', 'exec', 'system-agent', 'plugin', 'exec']) {
      if (remaining[kind] > 0) {
        order.push(kind);
        remaining[kind] -= 1;
      }
    }
  }
  const perKind = { exec: 0, plugin: 0, 'system-agent': 0 };
  const total = order.length;
  const spanMs = RETENTION_MS - 24 * 60 * 60_000;
  return order.map((kind, i) => {
    const n = perKind[kind]++;
    const resolvedAtMs = base - 5 * 60_000 - Math.round((i * spanMs) / total) - (i % 7) * 97_000;
    const picked = OUTCOMES[(n * 3 + KIND_OFFSET[kind]) % OUTCOMES.length];
    // System changes can only be allowed once.
    const outcome = kind === 'system-agent' && picked.decision === 'allow-always' ? { ...picked, decision: 'allow-once' } : picked;
    const createdAtMs = resolvedAtMs - (outcome.status === 'expired' ? 120_000 : 5_000 + (i % 11) * 3_000);
    const src = SOURCES[(i + n) % SOURCES.length];
    // Some records carry the agent only in the presentation, and a few have no source at all.
    const presentationAgent = i % 4 === 0 ? src.agentId : undefined;
    let source;
    if (i % 13 !== 12) source = presentationAgent ? (src.sessionKey ? { sessionKey: src.sessionKey } : undefined) : { ...src };
    return terminalRecord({
      id: approvalId(kind, n + 1),
      kind,
      presentation: presentationFor(kind, n, presentationAgent),
      createdAtMs,
      expiresAtMs: outcome.status === 'expired' ? resolvedAtMs : createdAtMs + 120_000,
      resolvedAtMs,
      outcome,
      source,
    });
  });
}

export function createApprovalHistoryState(base = Date.now()) {
  return { records: seedHistory(base) };
}

// The wire snapshot drops the mock-internal top-level `kind`; it lives in `presentation.kind`.
function publicSnapshot(record) {
  const { kind, ...snapshot } = record;
  return structuredClone(snapshot);
}

function pendingSnapshot(approval) {
  const request = approval.request ?? {};
  const presentation = {
    kind: 'exec',
    commandText: String(request.command ?? 'unknown command'),
    ...(request.agentId ? { agentId: request.agentId } : {}),
    allowedDecisions: allowedDecisions('exec'),
  };
  return {
    id: approval.id,
    urlPath: urlPath(approval.id),
    createdAtMs: approval.createdAtMs,
    expiresAtMs: approval.expiresAtMs,
    presentation,
    status: 'pending',
    ...(request.sessionKey ? { sourceSessionKey: request.sessionKey } : {}),
  };
}

// Records a resolved exec approval at the top of the ledger.
export function recordExecResolution(state, approval, decision, deviceId) {
  const request = approval.request ?? {};
  const allowed = decision === 'allow-once' || decision === 'allow-always';
  const source = {
    ...(request.agentId ? { agentId: request.agentId } : {}),
    ...(request.sessionKey ? { sessionKey: request.sessionKey } : {}),
  };
  const record = terminalRecord({
    id: approval.id,
    kind: 'exec',
    presentation: pendingSnapshot(approval).presentation,
    createdAtMs: approval.createdAtMs,
    expiresAtMs: approval.expiresAtMs,
    resolvedAtMs: Date.now(),
    outcome: {
      status: allowed ? 'allowed' : 'denied',
      decision,
      reason: 'user',
      ...(deviceId ? { resolver: { kind: 'device', id: deviceId } } : {}),
    },
    source: Object.keys(source).length ? source : undefined,
  });
  const history = state.approvalHistoryState.records;
  const existing = history.findIndex((r) => r.id === record.id);
  if (existing >= 0) history.splice(existing, 1);
  history.unshift(record);
  return record;
}

function encodeCursor(kind, lastId) {
  return Buffer.from(JSON.stringify({ v: 1, k: kind ?? null, after: lastId }), 'utf8').toString('base64url');
}

function decodeCursor(cursor) {
  try {
    const parsed = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
    if (parsed?.v !== 1 || typeof parsed.after !== 'string') return undefined;
    return parsed;
  } catch {
    return undefined;
  }
}

export function handleApprovalHistoryRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method, params = {} } = msg;
  if (!APPROVAL_HISTORY_METHODS.includes(method) || approvalHistoryDisabled()) return false;
  if (!(conn.scopes ?? []).includes(APPROVALS_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${APPROVALS_SCOPE}`, { code: 'MISSING_SCOPE', scope: APPROVALS_SCOPE });
    return true;
  }
  const invalid = (message, details) => sendErr(conn, id, 'INVALID_REQUEST', message, details);
  const history = state.approvalHistoryState.records;
  switch (method) {
    case 'approval.history': {
      const badParams =
        !params || typeof params !== 'object' || Array.isArray(params)
        || Object.keys(params).some((key) => !HISTORY_PARAMS.has(key))
        || (params.limit !== undefined && (!Number.isInteger(params.limit) || params.limit < 1 || params.limit > MAX_LIMIT))
        || (params.kind !== undefined && !APPROVAL_KINDS.includes(params.kind))
        || (params.cursor !== undefined && (typeof params.cursor !== 'string' || params.cursor.length < 1 || params.cursor.length > 512));
      if (badParams) return invalid('invalid approval.history params'), true;
      const kind = params.kind;
      const limit = params.limit ?? DEFAULT_LIMIT;
      const cutoff = Date.now() - RETENTION_MS;
      const items = history.filter((r) => r.resolvedAtMs >= cutoff && (!kind || r.kind === kind));
      let start = 0;
      if (params.cursor !== undefined) {
        const cursor = decodeCursor(params.cursor);
        const index = cursor && (cursor.k ?? undefined) === kind ? items.findIndex((r) => r.id === cursor.after) : -1;
        if (index < 0) return invalid('invalid approval.history cursor'), true;
        start = index + 1;
      }
      const slice = items.slice(start, start + limit);
      const hasMore = start + slice.length < items.length;
      sendRes(conn, id, {
        items: slice.map(publicSnapshot),
        ...(hasMore && slice.length ? { nextCursor: encodeCursor(kind, slice.at(-1).id) } : {}),
      });
      return true;
    }
    case 'approval.get': {
      if (!params || typeof params.id !== 'string' || !params.id || Object.keys(params).some((key) => key !== 'id')) {
        return invalid('invalid approval.get params'), true;
      }
      const pending = state.pendingApprovals.get(params.id);
      if (pending) {
        sendRes(conn, id, { approval: pendingSnapshot(pending) });
        return true;
      }
      const record = history.find((r) => r.id === params.id);
      if (!record) return invalid('approval not found', { reason: 'APPROVAL_NOT_FOUND' }), true;
      sendRes(conn, id, { approval: publicSnapshot(record) });
      return true;
    }
    default:
      return false;
  }
}
