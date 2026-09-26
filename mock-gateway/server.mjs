import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { APPROVAL_HISTORY_METHODS, approvalHistoryDisabled, createApprovalHistoryState, handleApprovalHistoryRequest, recordExecResolution } from './approvals.mjs';
import { ADMIN_SCOPE, CONFIG_METHODS, createConfigState, handleConfigRequest } from './config.mjs';
import { CRON_METHODS, createCronState, handleCronRequest } from './cron.mjs';
import { EXEC_APPROVALS_METHODS, createExecApprovalsState, execApprovalsDisabled, handleExecApprovalsRequest, recordAllowAlways } from './exec-approvals.mjs';
import { createWebPushState, handleWebPushEvent, handleWebPushRequest } from './webpush.mjs';

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const METHODS = [
  'agents.list',
  'sessions.subscribe',
  'sessions.list',
  'sessions.groups.list',
  'sessions.groups.put',
  'sessions.groups.rename',
  'sessions.groups.delete',
  'sessions.messages.subscribe',
  'sessions.messages.unsubscribe',
  'chat.history',
  'chat.message.get',
  'chat.send',
  'chat.abort',
  'sessions.patch',
  'sessions.compact',
  'models.list',
  'sessions.create',
  'artifacts.download',
  'exec.approval.list',
  'exec.approval.resolve',
  ...APPROVAL_HISTORY_METHODS,
  ...EXEC_APPROVALS_METHODS,
  'question.list',
  'question.resolve',
  'users.prefs.get',
  'users.prefs.set',
  'commands.list',
  'progressCard.get',
  'progressCard.put',
  ...CONFIG_METHODS,
  ...CRON_METHODS,
];
const EVENTS = [
  'connect.challenge',
  'tick',
  'sessions.changed',
  'session.message',
  'chat',
  'agent',
  'exec.approval.requested',
  'exec.approval.resolved',
  'question.requested',
  'question.resolved',
  'users.prefs.changed',
  'plugins.changed',
  'progressCard.changed',
  'cron',
];

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
  }
  return JSON.stringify(value ?? null);
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function fromB64url(value) {
  return Buffer.from(String(value ?? ''), 'base64url');
}

function randHex(bytes = 16) {
  return crypto.randomBytes(bytes).toString('hex');
}

function shortId(prefix = '') {
  return `${prefix}${crypto.randomBytes(6).toString('hex')}`;
}

function nowMs() {
  return Date.now();
}

function textBlock(text) {
  return { type: 'text', text };
}

function thinkingBlock(thinking) {
  return { type: 'thinking', thinking };
}

function toolCallBlock(id, name, args) {
  return { type: 'toolCall', id, name, arguments: args };
}

function imageBlock(artifactId, alt = 'Mock chart') {
  return { type: 'image', artifactId, mimeType: 'image/png', alt, width: 320, height: 200 };
}

const DEFAULT_MODEL = { provider: 'anthropic', model: 'claude-opus-4-8' };
const DEFAULT_CONTEXT_TOKENS = 128_000;
const commandEntry = (name, description, { aliases = [], category, source = 'native', args, acceptsArgs } = {}) => ({
  name,
  textAliases: [name, ...aliases].map((alias) => `/${alias}`),
  description,
  ...(category ? { category } : {}),
  source,
  scope: 'both',
  acceptsArgs: acceptsArgs ?? Boolean(args?.length),
  ...(args ? { args } : {}),
});
const choices = (...values) => values.map((value) => ({ value, label: value }));
const COMMAND_CATALOG = [
  commandEntry('help', 'Show available commands.', { category: 'status' }),
  commandEntry('status', 'Show current status.', { category: 'status' }),
  commandEntry('new', 'Start a new session.', { category: 'session', acceptsArgs: true }),
  commandEntry('reset', 'Reset the current session.', { category: 'session', acceptsArgs: true }),
  commandEntry('stop', 'Stop the current run.', { category: 'session' }),
  commandEntry('restart', 'Restart OpenClaw.', { category: 'tools' }),
  commandEntry('model', 'Show or set the model.', { category: 'options', args: [{ name: 'model', description: 'Model id', type: 'string' }] }),
  commandEntry('think', 'Set thinking level.', { aliases: ['thinking', 't'], category: 'options', args: [{ name: 'level', description: 'Thinking level', type: 'string', dynamic: true }] }),
  commandEntry('verbose', 'Toggle verbose mode.', { aliases: ['v'], category: 'options', args: [{ name: 'mode', description: 'on, off, or full', type: 'string', choices: choices('on', 'off', 'full') }] }),
  commandEntry('reasoning', 'Toggle reasoning visibility.', { aliases: ['reason'], category: 'options', args: [{ name: 'mode', description: 'on, off, or stream', type: 'string', choices: choices('on', 'off', 'stream') }] }),
  { name: 'pair', nativeName: 'pair', description: 'Native-only command', source: 'native', scope: 'native', acceptsArgs: false },
  commandEntry('weather', 'Look up the weather.', { source: 'plugin', acceptsArgs: true }),
];

// `contextTokens` (the effective cap) is only sent with `includeDetails`, like the Gateway.
const MODEL_CATALOG = [
  { id: 'claude-opus-4-8', name: 'Claude Opus 4.8', provider: 'anthropic', available: true, contextWindow: 1_000_000, contextTokens: 200_000 },
  { id: 'claude-sonnet-5', name: 'Claude Sonnet 5', provider: 'anthropic', available: true, contextWindow: 1_000_000, contextTokens: 200_000 },
  { id: 'gpt-5.6-sol', name: 'GPT-5.6 Sol', provider: 'openai', available: true, contextWindow: 400_000 },
  { id: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash', provider: 'google', available: false, unavailableReason: 'missing-auth', contextWindow: 1_000_000 },
];

function modelCatalog(includeDetails) {
  return MODEL_CATALOG.map(({ contextTokens, ...model }) => (includeDetails && contextTokens ? { ...model, contextTokens } : { ...model }));
}

function makeMessage(role, content, extras = {}) {
  // Like the Gateway, assistant messages record the model that wrote them.
  const model = role === 'assistant' ? (extras.model ?? DEFAULT_MODEL) : undefined;
  return {
    role,
    content,
    timestamp: nowMs(),
    ...(model ? { provider: model.provider, model: model.model } : {}),
    __openclaw: { id: crypto.randomUUID(), ...extras.openclaw },
    ...extras.extra,
  };
}

function rowModel(row) {
  return { provider: row.modelProvider ?? DEFAULT_MODEL.provider, model: row.model ?? DEFAULT_MODEL.model };
}

function sessionDefaults() {
  return { model: DEFAULT_MODEL.model, modelProvider: DEFAULT_MODEL.provider, contextTokens: DEFAULT_CONTEXT_TOKENS };
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])));
  return Buffer.concat([len, typeBuf, data, crc]);
}

function makePng() {
  const width = 320;
  const height = 200;
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 4 + 1);
    raw[row] = 0;
    for (let x = 0; x < width; x++) {
      const i = row + 1 + x * 4;
      const bar = Math.floor(x / 40) % 2;
      raw[i] = Math.min(255, 40 + x);
      raw[i + 1] = Math.min(255, 60 + y);
      raw[i + 2] = bar ? 220 : 120;
      raw[i + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function clone(value) {
  return structuredClone(value);
}

// Like the Gateway's history projection: text fields past the cap end in a sentinel and the
// message is flagged so clients can fetch the full copy with `chat.message.get`.
const HISTORY_TEXT_MAX_CHARS = 8_000;

function projectForHistory(message, maxChars = HISTORY_TEXT_MAX_CHARS) {
  const projected = clone(message);
  if (!Array.isArray(projected.content)) return projected;
  let truncated = false;
  for (const block of projected.content) {
    if (block?.type === 'text' && typeof block.text === 'string' && block.text.length > maxChars) {
      block.text = `${block.text.slice(0, maxChars)}\n...(truncated)...`;
      truncated = true;
    }
  }
  if (truncated) projected.__openclaw = { ...projected.__openclaw, truncated: true };
  return projected;
}

function makeSessionRow(key, props, base = nowMs()) {
  return {
    key,
    sessionId: crypto.randomUUID(),
    kind: 'direct',
    label: props.label ?? null,
    displayName: props.displayName,
    derivedTitle: props.derivedTitle ?? props.label ?? 'Untitled',
    lastMessagePreview: props.lastMessagePreview ?? 'Ready when you are.',
    channel: props.channel ?? 'webchat',
    agentId: props.agentId,
    isMain: Boolean(props.isMain),
    category: props.category,
    color: props.color,
    pinned: Boolean(props.pinned),
    unread: Boolean(props.unread),
    archived: false,
    updatedAt: base - (props.age ?? 0),
    lastActivityAt: base - (props.age ?? 0),
    status: props.status ?? 'idle',
    parentSessionKey: props.parentSessionKey,
    spawnedBy: props.spawnedBy,
    hasActiveRun: false,
    activeRunIds: [],
    model: DEFAULT_MODEL.model,
    modelProvider: DEFAULT_MODEL.provider,
    modelOverrideSource: null,
    // Context snapshot and the latest run's usage, as the Gateway's session rows carry them.
    ...(props.totalTokens !== undefined
      ? { totalTokens: props.totalTokens, totalTokensFresh: true, inputTokens: props.totalTokens, outputTokens: 800 }
      : {}),
    ...(props.contextTokens !== undefined ? { contextTokens: props.contextTokens } : {}),
  };
}

function createSeedState() {
  const base = nowMs();
  const agents = new Map([
    ['main', { id: 'main', name: 'Claw', identity: { name: 'Claw', emoji: '🦞' } }],
    ['research', { id: 'research', name: 'Scout', identity: { name: 'Scout', emoji: '🔭' } }],
    ['coder', { id: 'coder', name: 'Forge', identity: { name: 'Forge', emoji: '🛠️' } }],
  ]);
  const sessions = new Map();
  const transcripts = new Map();
  const artifacts = new Map([
    ['art-chart-1', { artifactId: 'art-chart-1', mimeType: 'image/png', data: makePng() }],
  ]);

  function row(key, props) {
    const entry = makeSessionRow(key, props, base);
    sessions.set(key, entry);
    transcripts.set(key, []);
    return entry;
  }

  row('agent:main:main', {
    agentId: 'main',
    isMain: true,
    derivedTitle: 'Main',
    channel: 'webchat',
    age: 10_000,
    lastMessagePreview: 'Disk looks healthy.',
    totalTokens: 172_000,
    contextTokens: 200_000,
  });
  row('agent:main:discord:channel:123', {
    agentId: 'main',
    label: 'home-lab',
    derivedTitle: 'home-lab',
    category: 'Home',
    channel: 'discord',
    pinned: true,
    unread: true,
    age: 20_000,
    lastMessagePreview: 'Discord bridge is online.',
  });
  row('agent:main:dashboard:trip', {
    agentId: 'main',
    label: 'Japan trip',
    derivedTitle: 'Japan trip',
    category: 'Personal',
    color: 'pink',
    age: 60_000,
    lastMessagePreview: 'Kyoto day plan drafted.',
    totalTokens: 48_000,
    contextTokens: 200_000,
  });
  row('agent:research:main', {
    agentId: 'research',
    isMain: true,
    derivedTitle: 'Main',
    age: 90_000,
    lastMessagePreview: 'Research queue is clear.',
    // No contextTokens: clients fall back to models.list, then sessions.list defaults.
    totalTokens: 12_000,
  });
  row('agent:research:dashboard:papers', {
    agentId: 'research',
    label: 'Paper digest',
    derivedTitle: 'Paper digest',
    category: 'Work',
    unread: true,
    age: 120_000,
    lastMessagePreview: 'Three papers summarized.',
    totalTokens: 96_000,
    contextTokens: 200_000,
  });
  row('agent:research:subagent:abc', {
    agentId: 'research',
    label: 'Summarize arXiv 2401.x',
    derivedTitle: 'Summarize arXiv 2401.x',
    parentSessionKey: 'agent:research:dashboard:papers',
    spawnedBy: 'agent:research:dashboard:papers',
    age: 180_000,
    lastMessagePreview: 'Subagent found the main contribution.',
  });
  row('agent:coder:main', {
    agentId: 'coder',
    isMain: true,
    derivedTitle: 'Main',
    age: 240_000,
    lastMessagePreview: 'No active coding run.',
    totalTokens: 190_000,
    contextTokens: 200_000,
  });

  // Chats of the seeded automations (see cron.mjs); their runs append here.
  row('agent:main:cron:morning-briefing', {
    agentId: 'main',
    label: 'Automation: Morning briefing',
    channel: 'cron',
    age: 3 * 3_600_000,
    lastMessagePreview: 'Clear skies, two meetings, and the lab sensor is quiet.',
  });
  row('agent:main:cron:disk-check', {
    agentId: 'main',
    label: 'Automation: Check disk space',
    channel: 'cron',
    age: 2 * 3_600_000,
    lastMessagePreview: 'df: /Volumes/Backup: No such file or directory',
  });
  transcripts.get('agent:main:cron:morning-briefing').push(
    makeMessage('user', [textBlock('Write my morning briefing: weather, calendar and anything odd overnight.')]),
    makeMessage('assistant', [textBlock('Clear skies, two meetings, and the lab sensor is quiet.')]),
  );
  transcripts.get('agent:main:cron:disk-check').push(
    makeMessage('user', [textBlock('Check free space on every volume and warn me under 10%.')]),
    makeMessage('assistant', [textBlock('df: /Volumes/Backup: No such file or directory')]),
  );

  const dfCall = 'call_seed_df';
  transcripts.get('agent:main:main').push(
    makeMessage('user', [textBlock('Can you check disk usage and show me a quick status?')]),
    makeMessage('assistant', [
      thinkingBlock('I should inspect the disk usage and summarize the key mount points.'),
      toolCallBlock(dfCall, 'exec', { command: 'df -h' }),
    ]),
    makeMessage('toolResult', [textBlock('Filesystem      Size  Used Avail Use% Mounted on\n/dev/disk3s1   926G  411G  490G  46% /\n/dev/disk3s6   926G  7.0G  490G   2% /System/Volumes/VM')], {
      extra: { toolCallId: dfCall, toolName: 'exec', isError: false },
    }),
    makeMessage('assistant', [
      textBlock('## Disk status\n\n- Root volume has plenty of room.\n- VM volume is lightly used.\n\n```text\n/dev/disk3s1  46% used\n```\n\nHere is a synthetic usage chart.'),
      imageBlock('art-chart-1', 'Disk usage chart'),
    ]),
  );
  transcripts.get('agent:main:discord:channel:123').push(
    makeMessage('user', [textBlock('Discord says the lab sensor is noisy tonight.')], {
      extra: { provenance: { sourceChannel: 'discord' } },
    }),
    makeMessage('assistant', [textBlock('I will keep an eye on the home-lab channel and flag anomalies.')]),
  );
  // Long enough to need several older pages.
  for (let day = 1; day <= 150; day++) {
    transcripts.get('agent:main:dashboard:trip').push(
      makeMessage('user', [textBlock(`Idea for day ${day}?`)]),
      makeMessage('assistant', [textBlock(`Day ${day}: a slow morning, one museum, and **ramen** nearby.`)]),
    );
  }
  transcripts.get('agent:main:dashboard:trip').push(
    makeMessage('user', [textBlock('Plan a gentle first day in Tokyo.')]),
    makeMessage('assistant', [textBlock('Start with Meiji Shrine, a low-key lunch, and an early evening in Shinjuku.')]),
  );
  transcripts.get('agent:research:main').push(
    // Past the history cap, so clients have to recover it with `chat.message.get`.
    makeMessage('assistant', [textBlock(`## Long report\n\n${'Lorem ipsum dolor sit amet. '.repeat(400)}\n\nEND OF REPORT`)]),
    makeMessage('assistant', [textBlock('Scout is ready to investigate papers, repos, and docs.')]),
  );
  transcripts.get('agent:research:dashboard:papers').push(
    makeMessage('user', [textBlock('Summarize the latest diffusion papers.')]),
    makeMessage('assistant', [textBlock('I found themes around consistency models, efficient sampling, and video generation.')]),
  );
  transcripts.get('agent:research:subagent:abc').push(
    makeMessage('assistant', [textBlock('The paper primarily improves retrieval-augmented summarization evaluation.')]),
  );
  transcripts.get('agent:coder:main').push(
    makeMessage('assistant', [textBlock('Forge can edit code, run builds, and report concise status.')]),
  );

  return {
    agents,
    sessions,
    transcripts,
    artifacts,
    pairedDevices: new Map(),
    pendingPairing: new Map(),
    pendingApprovals: new Map(),
    // Resolved approvals keep their decision so identical retries stay idempotent, as on the Gateway.
    resolvedApprovals: new Map(),
    questions: new Map(),
    progressCards: new Map(),
    // Gateway-owned custom group catalog: names in display order, kept even when empty.
    groups: ['Home', 'Personal', 'Work'],
    idempotency: new Map(),
    activeRuns: new Map(),
    connections: new Set(),
    configState: createConfigState(),
    webPushState: createWebPushState(),
    cronState: createCronState(base),
    approvalHistoryState: createApprovalHistoryState(base),
    execApprovalsState: createExecApprovalsState(base),
  };
}

function sortedSessions(state, includeArchived = false) {
  return [...state.sessions.values()]
    .filter((s) => includeArchived || !s.archived)
    .sort((a, b) => {
      if (Boolean(a.pinned) !== Boolean(b.pinned)) return a.pinned ? -1 : 1;
      return (b.lastActivityAt ?? 0) - (a.lastActivityAt ?? 0);
    })
    .map(clone);
}

function sendJson(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

function sendRes(conn, id, payload) {
  sendJson(conn.ws, { type: 'res', id, ok: true, payload });
}

function sendErr(conn, id, code, message, details = undefined) {
  sendJson(conn.ws, { type: 'res', id, ok: false, error: { code, message, ...(details ? { details } : {}) } });
}

function sendEvent(conn, event, payload) {
  conn.seq += 1;
  sendJson(conn.ws, { type: 'event', event, payload, seq: conn.seq });
}

function broadcast(state, event, payload, predicate = () => true) {
  for (const conn of state.connections) {
    if (conn.authenticated && predicate(conn)) sendEvent(conn, event, payload);
  }
  handleWebPushEvent(state, event, payload);
}

function updateSessionRow(row, patch = {}) {
  Object.assign(row, patch, { updatedAt: nowMs() });
  return row;
}

function broadcastSessionChanged(state, sessionKey, reason, session) {
  broadcast(state, 'sessions.changed', { sessionKey, reason, session: clone(session) }, (conn) => conn.sessionSubscribed);
}

function groupCatalog(state) {
  return { groups: state.groups.map((name, position) => ({ name, position })), sectionOrder: [] };
}

// Like the real gateway, a category assigned through sessions.patch/create joins the catalog.
function registerGroup(state, name) {
  const trimmed = typeof name === 'string' ? name.trim() : '';
  if (trimmed && !state.groups.includes(trimmed)) state.groups.push(trimmed);
}

function moveGroupMembers(state, from, to) {
  let updated = 0;
  for (const row of state.sessions.values()) {
    if (row.category !== from) continue;
    row.category = to ?? undefined;
    updated += 1;
    broadcastSessionChanged(state, row.key, 'patch', row);
  }
  return updated;
}

function broadcastSessionMessage(state, sessionKey, message, messageSeq) {
  broadcast(
    state,
    'session.message',
    { sessionKey, message: clone(message), messageId: message.__openclaw.id, messageSeq, hasActiveRun: true },
    (conn) => conn.messageSubs.has(sessionKey),
  );
}

function verifyConnect(params, challenge, token) {
  if (!params || typeof params !== 'object') throw Object.assign(new Error('missing params'), { code: 'PROTOCOL' });
  if (params.minProtocol > 4 || params.maxProtocol < 4) {
    throw Object.assign(new Error('protocol mismatch'), { code: 'PROTOCOL_MISMATCH' });
  }
  if (params.role !== 'operator') throw Object.assign(new Error('role must be operator'), { code: 'PROTOCOL' });
  const device = params.device ?? {};
  if (device.signedAt !== challenge.ts || device.nonce !== challenge.nonce) {
    throw Object.assign(new Error('device auth invalid'), { code: 'DEVICE_AUTH_INVALID' });
  }
  const rawPublic = fromB64url(device.publicKey);
  if (rawPublic.length !== 32) throw Object.assign(new Error('invalid public key'), { code: 'DEVICE_AUTH_INVALID' });
  const expectedDeviceId = crypto.createHash('sha256').update(rawPublic).digest('hex');
  if (device.id !== expectedDeviceId) throw Object.assign(new Error('device id mismatch'), { code: 'DEVICE_AUTH_INVALID' });
  const scopes = Array.isArray(params.scopes) ? params.scopes.join(',') : '';
  const payload = `v2|${device.id}|${params.client?.id ?? ''}|${params.client?.mode ?? ''}|${params.role}|${scopes}|${device.signedAt}|${token}|${device.nonce}`;
  const pubKey = crypto.createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, rawPublic]), format: 'der', type: 'spki' });
  const ok = crypto.verify(null, Buffer.from(payload, 'utf8'), pubKey, fromB64url(device.signature));
  if (!ok) throw Object.assign(new Error('device auth invalid'), { code: 'DEVICE_AUTH_INVALID' });
  return { deviceId: device.id };
}

function deviceTokenFor(state, deviceId, scopes = []) {
  const existing = state.pairedDevices.get(deviceId);
  if (existing?.deviceToken) {
    for (const scope of scopes) existing.scopes.add(scope);
    return existing.deviceToken;
  }
  const deviceToken = `dt_${randHex(18)}`;
  state.pairedDevices.set(deviceId, { deviceToken, pairedAt: nowMs(), scopes: new Set(scopes) });
  return deviceToken;
}

// Like the Gateway: operator.admin covers every operator scope, operator.write covers read.
function scopeApproved(scope, approved) {
  return approved.has(scope) || approved.has('operator.admin') || (scope === 'operator.read' && approved.has('operator.write'));
}

function approvePairing(state, requestId) {
  const pending = state.pendingPairing.get(requestId);
  if (!pending) return false;
  deviceTokenFor(state, pending.deviceId, pending.scopes ?? []);
  state.pendingPairing.delete(requestId);
  console.log(`Pairing approved ${requestId}`);
  return true;
}

function setupManualPairing(state, enabled) {
  if (!enabled || setupManualPairing.didSetup) return;
  setupManualPairing.didSetup = true;
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    for (const token of chunk.trim().split(/\s+/).filter(Boolean)) approvePairing(state, token);
  });
  process.stdin.resume();
}

function advertisedMethods() {
  const hidden = [...(approvalHistoryDisabled() ? APPROVAL_HISTORY_METHODS : []), ...(execApprovalsDisabled() ? EXEC_APPROVALS_METHODS : [])];
  return METHODS.filter((m) => !hidden.includes(m));
}

function makeHelloPayload(state, params, connId, deviceId) {
  return {
    type: 'hello-ok',
    protocol: 4,
    server: { version: 'mock-2026.1', connId },
    features: { methods: advertisedMethods(), events: EVENTS },
    snapshot: {},
    auth: { role: 'operator', scopes: params.scopes ?? [], deviceToken: deviceTokenFor(state, deviceId) },
    policy: {
      maxPayload: 26214400,
      maxBufferedBytes: 52428800,
      tickIntervalMs: 15000,
      attachments: { maxBytes: 20000000, maxImageBytes: 5000000 },
    },
  };
}

const QUESTIONS_SCOPE = 'operator.questions';

function hasQuestionsScope(conn) {
  return conn.scopes?.includes(QUESTIONS_SCOPE) || conn.scopes?.includes('operator.admin');
}

function sendMissingQuestionsScope(conn, id) {
  sendErr(conn, id, 'FORBIDDEN', `missing scope: ${QUESTIONS_SCOPE}`, {
    code: 'MISSING_SCOPE',
    missingScope: QUESTIONS_SCOPE,
    requiredScopes: [QUESTIONS_SCOPE],
  });
}

function settleQuestion(state, record, status, answers = undefined) {
  if (record.status !== 'pending') return;
  record.status = status;
  if (answers) record.answers = answers;
  broadcast(state, 'question.resolved', { id: record.id, status, ...(answers ? { answers } : {}) }, hasQuestionsScope);
}

// Asks an ask_user question like OpenClaw does (question.requested), then blocks the run until it's settled.
async function simulateQuestion(state, run, sessionKey, row) {
  const toolCallId = shortId('call_');
  const options = [
    { label: 'Disconnect Discord from OpenClaw', description: 'Remove the Discord channel integration/config; the server itself stays intact' },
    { label: 'Delete one channel in the Discord server', description: 'e.g. #coworking or #gyms — tell me which' },
    { label: 'Stop watching Discord channels here', description: 'Only stop this chat from ambiently watching them' },
  ];
  const args = { questions: [{ id: 'discord_remove', header: 'Discord', question: 'What do you want removed?', options }] };
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'start', name: 'ask_user', toolCallId, args } });
  const record = {
    id: shortId('ask_'),
    questions: [{ questionId: 'discord_remove', header: 'Discord', question: 'What do you want removed?', options, isOther: true }],
    agentId: row.agentId,
    sessionKey,
    runId: run.runId,
    createdAtMs: nowMs(),
    expiresAtMs: nowMs() + 900_000,
    status: 'pending',
  };
  state.questions.set(record.id, record);
  broadcast(state, 'question.requested', clone(record), hasQuestionsScope);
  while (record.status === 'pending' && !run.aborted) {
    await runDelay(run, 100);
    if (nowMs() >= record.expiresAtMs) settleQuestion(state, record, 'expired');
  }
  if (run.aborted) {
    settleQuestion(state, record, 'cancelled');
    return null;
  }
  const picked = record.answers?.answers?.discord_remove ?? [];
  const output = record.status === 'answered' ? `User answered: ${picked.join(', ')}` : `User ${record.status === 'expired' ? "didn't answer in time" : 'skipped the question'}`;
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'result', name: 'ask_user', toolCallId, isError: false, result: output } });
  const transcript = state.transcripts.get(sessionKey);
  const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'ask_user', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  const toolResult = makeMessage('toolResult', [textBlock(output)], { openclaw: { runId: run.runId }, extra: { toolCallId, toolName: 'ask_user', isError: false } });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
  return record.status === 'answered' ? `You picked: ${picked.join(', ')}.` : 'Okay, skipping that.';
}

function runDelay(run, ms) {
  if (run.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      run.waiters.delete(resolve);
      run.timers.delete(timer);
      resolve();
    }, ms);
    run.timers.add(timer);
    run.waiters.add(resolve);
  });
}

function finishRunAbort(state, run) {
  if (run.finished) return;
  run.finished = true;
  for (const timer of run.timers) clearTimeout(timer);
  run.timers.clear();
  for (const resolve of run.waiters) resolve();
  run.waiters.clear();
  const row = state.sessions.get(run.sessionKey);
  if (row) {
    row.hasActiveRun = false;
    row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
    row.status = 'idle';
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionChanged(state, run.sessionKey, 'abort', row);
  }
  broadcast(state, 'chat', { runId: run.runId, sessionKey: run.sessionKey, seq: ++run.seq, state: 'aborted' });
  state.activeRuns.delete(run.runId);
}

function abortMatchingRuns(state, sessionKey, runId) {
  let count = 0;
  for (const run of state.activeRuns.values()) {
    if ((runId && run.runId === runId) || (!runId && run.sessionKey === sessionKey)) {
      run.aborted = true;
      finishRunAbort(state, run);
      count += 1;
    }
  }
  return count;
}

function putProgressCard(state, sessionKey, { markdown, steps }) {
  const previous = state.progressCards.get(sessionKey);
  const card = { sessionKey, revision: (previous?.revision ?? 0) + 1, updatedAt: nowMs(), markdown, steps };
  state.progressCards.set(sessionKey, card);
  broadcast(state, 'progressCard.changed', { sessionKey, revision: card.revision });
  return card;
}

/** Walks a three-step `progress_card` checklist, as an agent following a plan would. */
async function simulatePlan(state, run, sessionKey, row) {
  const markdown = '**Three-step task: mock plan**\n\nThe card updates between phases.';
  const labels = ['Inspect the workspace', 'Draft the change', 'Validate and summarize'];
  for (let current = 0; current <= labels.length; current += 1) {
    const steps = labels.map((step, index) => ({
      step,
      status: index < current ? 'completed' : index === current ? 'in_progress' : 'pending',
    }));
    const toolCallId = shortId('call_');
    const args = { markdown, plan: steps };
    broadcast(state, 'agent', {
      runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
      data: { phase: 'start', name: 'progress_card', toolCallId, args },
    });
    const card = putProgressCard(state, sessionKey, { markdown, steps });
    const done = steps.filter((step) => step.status === 'completed').length;
    const result = `Progress card updated (rev ${card.revision}, ${done}/${steps.length} done)`;
    broadcast(state, 'agent', {
      runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
      data: { phase: 'result', name: 'progress_card', toolCallId, isError: false, result },
    });
    const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'progress_card', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
    const toolResult = makeMessage('toolResult', [textBlock(result)], {
      openclaw: { runId: run.runId },
      extra: { toolCallId, toolName: 'progress_card', isError: false },
    });
    const transcript = state.transcripts.get(sessionKey);
    transcript.push(toolMsg, toolResult);
    broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
    broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    if (current < labels.length) {
      await runDelay(run, 1500);
      if (run.aborted) return;
    }
  }
}

// Summarizes a session's context: appends the compaction marker and shrinks `totalTokens`.
// Returns `{ tokensBefore, tokensAfter }`, or null when there's too little to compact.
function compactSession(state, sessionKey) {
  const row = state.sessions.get(sessionKey);
  const transcript = state.transcripts.get(sessionKey);
  const tokensBefore = row?.totalTokens ?? 0;
  if (!row || !transcript || tokensBefore < 4_000) return null;
  const tokensAfter = Math.round(tokensBefore * 0.18);
  const marker = makeMessage('system', [], { openclaw: { kind: 'compaction' } });
  transcript.push(marker);
  broadcastSessionMessage(state, sessionKey, marker, transcript.length);
  updateSessionRow(row, { totalTokens: tokensAfter, totalTokensFresh: true });
  return { tokensBefore, tokensAfter };
}

// `/compact [instructions]` sent as a chat message: compaction events, the marker, and a short reply.
async function simulateCompactCommand(state, run, sessionKey, row, instructions) {
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'compaction', data: { phase: 'start' } });
  await runDelay(run, 600);
  if (run.aborted) return;
  const result = compactSession(state, sessionKey);
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'compaction', data: { phase: 'end', completed: Boolean(result) } });
  const transcript = state.transcripts.get(sessionKey);
  const text = result
    ? `⚙️ Compacted (${result.tokensBefore} → ${result.tokensAfter} tokens)${instructions ? `, keeping: ${instructions}` : ''}.`
    : '⚙️ Nothing to compact yet.';
  const reply = makeMessage('assistant', [textBlock(text)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  transcript.push(reply);
  broadcastSessionMessage(state, sessionKey, reply, transcript.length);
  broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'final', message: clone(reply) });
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'end' } });
  row.hasActiveRun = false;
  row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
  row.status = 'idle';
  row.lastMessagePreview = text;
  updateSessionRow(row, { lastActivityAt: nowMs() });
  broadcastSessionChanged(state, sessionKey, 'compact', row);
  run.finished = true;
  state.activeRuns.delete(run.runId);
}

async function simulateRun(state, run, params) {
  const { sessionKey, message: text, attachments = [] } = params;
  const row = state.sessions.get(sessionKey);
  const transcript = state.transcripts.get(sessionKey);
  if (!row || !transcript) return;
  try {
    const content = [textBlock(String(text ?? ''))];
    for (const attachment of attachments) {
      if (attachment?.content && String(attachment.mimeType ?? '').startsWith('image/')) {
        const artifactId = `upload-${shortId()}`;
        state.artifacts.set(artifactId, {
          artifactId,
          mimeType: attachment.mimeType,
          data: Buffer.from(attachment.content, 'base64'),
        });
        content.push(imageBlock(artifactId, attachment.fileName ?? 'Uploaded image'));
      }
    }
    const userMsg = makeMessage('user', content, { openclaw: { runId: run.runId, idempotencyKey: params.idempotencyKey } });
    transcript.push(userMsg);
    row.hasActiveRun = true;
    row.activeRunIds = [...new Set([...row.activeRunIds, run.runId])];
    row.status = 'running';
    row.lastMessagePreview = String(text ?? '').slice(0, 120);
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionMessage(state, sessionKey, userMsg, transcript.length);
    broadcastSessionChanged(state, sessionKey, 'send', row);

    const compact = /^\/compact(?:\s+([\s\S]*))?$/i.exec(String(text ?? '').trim());
    if (compact) return await simulateCompactCommand(state, run, sessionKey, row, compact[1]?.trim() ?? '');

    if (/\bapprove\b/i.test(String(text ?? ''))) {
      // `approve once-only` leaves allow-always out of allowedDecisions; `approve short-lived` expires in 3 s.
      const onceOnly = /\bonce-only\b/i.test(String(text ?? ''));
      const ttlMs = /\bshort-lived\b/i.test(String(text ?? '')) ? 3_000 : 120_000;
      const approval = {
        id: shortId('approval_'),
        request: {
          command: 'rm -rf ./build',
          cwd: '/home/claw/project',
          sessionKey,
          agentId: row.agentId,
          allowedDecisions: onceOnly ? ['allow-once', 'deny'] : ['allow-once', 'allow-always', 'deny'],
        },
        createdAtMs: nowMs(),
        expiresAtMs: nowMs() + ttlMs,
      };
      state.pendingApprovals.set(approval.id, approval);
      setTimeout(() => {
        if (state.pendingApprovals.get(approval.id) === approval) state.pendingApprovals.delete(approval.id);
      }, ttlMs).unref?.();
      broadcast(state, 'exec.approval.requested', clone(approval));
    }

    broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'status', phase: 'thinking' });
    const thinkingParts = ['Thinking', ' through', ' the', ' mock', ' gateway', ' response...'];
    let thinking = '';
    for (const part of thinkingParts) {
      await runDelay(run, 160);
      if (run.aborted) return;
      thinking += part;
      broadcast(state, 'chat', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        state: 'delta',
        deltaText: '',
        message: makeMessage('assistant', [thinkingBlock(thinking)], { openclaw: { runId: run.runId }, model: rowModel(row) }),
      });
    }

    if (/\bplan\b/i.test(String(text ?? ''))) {
      await simulatePlan(state, run, sessionKey, row);
      if (run.aborted) return;
    }

    let answered = null;
    if (/\bask\b/i.test(String(text ?? ''))) {
      answered = await simulateQuestion(state, run, sessionKey, row);
      if (run.aborted) return;
    }

    const wantsTool = /tool|disk|image/i.test(String(text ?? ''));
    if (wantsTool) {
      const toolCallId = shortId('call_');
      broadcast(state, 'agent', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        stream: 'tool',
        data: { phase: 'start', name: 'exec', toolCallId, args: { command: 'uptime' } },
      });
      await runDelay(run, 800);
      if (run.aborted) return;
      broadcast(state, 'agent', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        stream: 'tool',
        data: { phase: 'result', name: 'exec', toolCallId, isError: false, result: ' 10:42  up 3 days, 4 users, load averages: 1.2 1.0 0.8' },
      });
      const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'exec', { command: 'uptime' })], { openclaw: { runId: run.runId }, model: rowModel(row) });
      const toolResult = makeMessage('toolResult', [textBlock(' 10:42  up 3 days, 4 users, load averages: 1.2 1.0 0.8')], {
        openclaw: { runId: run.runId },
        extra: { toolCallId, toolName: 'exec', isError: false },
      });
      transcript.push(toolMsg, toolResult);
      broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
      broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    }

    const reply = answered ?? `I heard: "${String(text ?? '')}".\n\n## Mock response\n\n- Streaming deltas are working.\n- Tool events are ${wantsTool ? 'included' : 'available when requested'}.\n- Markdown rendering can be tested here.\n\n\`\`\`text\nrunId=${run.runId}\n\`\`\``;
    const words = reply.split(/(\s+)/).filter((p) => p.length > 0);
    let out = '';
    for (const word of words) {
      await runDelay(run, 40);
      if (run.aborted) return;
      out += word;
      broadcast(state, 'chat', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        state: 'delta',
        deltaText: word,
        message: makeMessage('assistant', [thinkingBlock(thinking), textBlock(out)], { openclaw: { runId: run.runId }, model: rowModel(row) }),
      });
    }
    const finalContent = [thinkingBlock(thinking), textBlock(reply)];
    if (/image/i.test(String(text ?? ''))) finalContent.push(imageBlock('art-chart-1', 'Synthetic mock chart'));
    const finalMsg = makeMessage('assistant', finalContent, { openclaw: { runId: run.runId }, model: rowModel(row) });
    transcript.push(finalMsg);
    broadcastSessionMessage(state, sessionKey, finalMsg, transcript.length);
    broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'final', message: clone(finalMsg) });
    broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'end' } });

    row.hasActiveRun = false;
    row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
    row.status = 'idle';
    row.lastMessagePreview = reply.slice(0, 120);
    row.unread = true;
    // Each turn grows the context; the snapshot never passes the window.
    if (row.totalTokens !== undefined) {
      const limit = row.contextTokens ?? DEFAULT_CONTEXT_TOKENS;
      row.inputTokens = row.totalTokens;
      row.outputTokens = Math.ceil(reply.length / 4);
      row.totalTokens = Math.min(limit, row.totalTokens + 1_200 + row.outputTokens);
      row.totalTokensFresh = true;
    }
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionChanged(state, sessionKey, 'run-finished', row);
    run.finished = true;
    state.activeRuns.delete(run.runId);
  } catch (err) {
    if (!run.aborted) console.error('run simulation failed:', err);
    state.activeRuns.delete(run.runId);
  }
}

// Cron runs write into their automation's chat (`agent:<agent>:cron:<job>`), creating it on first use.
function postToSession(state, key, { agentId, label, userText, replyText }) {
  let row = state.sessions.get(key);
  if (!row) {
    row = makeSessionRow(key, { agentId, label, derivedTitle: label, channel: 'cron' });
    state.sessions.set(key, row);
    state.transcripts.set(key, []);
  }
  const transcript = state.transcripts.get(key);
  const userMsg = makeMessage('user', [textBlock(userText)]);
  const reply = makeMessage('assistant', [textBlock(replyText)]);
  transcript.push(userMsg, reply);
  broadcastSessionMessage(state, key, userMsg, transcript.length - 1);
  broadcastSessionMessage(state, key, reply, transcript.length);
  row.unread = true;
  row.lastMessagePreview = replyText;
  updateSessionRow(row, { lastActivityAt: nowMs() });
  broadcastSessionChanged(state, key, 'cron', row);
  return row;
}

function handleAuthedRequest(state, conn, msg) {
  const { id, method, params = {} } = msg;
  if (handleConfigRequest(state, conn, msg, { sendRes, sendErr, broadcast })) return;
  if (handleCronRequest(state, conn, msg, { sendRes, sendErr, broadcast, postToSession })) return;
  if (handleWebPushRequest(state, conn, msg, { sendRes, sendErr })) return;
  if (handleApprovalHistoryRequest(state, conn, msg, { sendRes, sendErr })) return;
  if (handleExecApprovalsRequest(state, conn, msg, { sendRes, sendErr })) return;
  switch (method) {
    case 'progressCard.get': {
      const key = params.sessionKey;
      if (!key) return sendErr(conn, id, 'INVALID_REQUEST', 'sessionKey is required.');
      sendRes(conn, id, { card: clone(state.progressCards.get(key) ?? null) });
      return;
    }
    case 'progressCard.put': {
      const key = params.sessionKey;
      if (!key) return sendErr(conn, id, 'INVALID_REQUEST', 'sessionKey is required.');
      const current = state.progressCards.get(key);
      if (params.markdown === undefined && params.plan === undefined) {
        // Conditional clear: only the revision the client saw is dismissed.
        if (current && params.expectedRevision !== undefined && current.revision !== params.expectedRevision) {
          sendRes(conn, id, { card: clone(current) });
          return;
        }
        state.progressCards.delete(key);
        if (params.expectedRevision === undefined) broadcast(state, 'progressCard.changed', { sessionKey: key, revision: null });
        sendRes(conn, id, { card: null });
        return;
      }
      sendRes(conn, id, { card: clone(putProgressCard(state, key, { markdown: params.markdown, steps: params.plan })) });
      return;
    }
    case 'agents.list': {
      sendRes(conn, id, {
        defaultId: 'main',
        mainKey: 'main',
        scope: 'per-sender',
        agents: [...state.agents.values()].map(clone),
      });
      break;
    }
    case 'sessions.subscribe': {
      conn.sessionSubscribed = true;
      sendRes(conn, id, {
        subscribed: true,
        list: { sessions: sortedSessions(state, params.archived === true || params.archived === 'all'), defaults: sessionDefaults(), nextOffset: null, hasMore: false },
      });
      break;
    }
    case 'sessions.list': {
      sendRes(conn, id, { sessions: sortedSessions(state, params.archived === true || params.archived === 'all'), defaults: sessionDefaults(), nextOffset: null, hasMore: false });
      break;
    }
    case 'sessions.groups.list': {
      sendRes(conn, id, groupCatalog(state));
      break;
    }
    case 'sessions.groups.put': {
      if (!Array.isArray(params.names)) return sendErr(conn, id, 'INVALID_REQUEST', 'names required');
      const names = [...new Set(params.names.map((n) => String(n).trim()).filter(Boolean))];
      const dropped = state.groups.filter((name) => !names.includes(name)
        && [...state.sessions.values()].some((row) => row.category === name));
      if (dropped.length) {
        return sendErr(conn, id, 'INVALID_REQUEST', `sessions.groups.put cannot drop groups that still have member sessions: ${dropped.join(', ')}`);
      }
      state.groups = names;
      sendRes(conn, id, { ok: true, ...groupCatalog(state) });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.groups.rename': {
      const from = String(params.name ?? '').trim();
      const to = String(params.to ?? '').trim();
      if (!from || !to) return sendErr(conn, id, 'INVALID_REQUEST', 'group rename requires non-empty names');
      if (!state.groups.includes(from)) return sendErr(conn, id, 'INVALID_REQUEST', `unknown session group: ${from}`);
      const updatedSessions = from === to ? 0 : moveGroupMembers(state, from, to);
      state.groups = state.groups.includes(to) && from !== to
        ? state.groups.filter((name) => name !== from)
        : state.groups.map((name) => (name === from ? to : name));
      sendRes(conn, id, { ok: true, ...groupCatalog(state), updatedSessions });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.groups.delete': {
      const name = String(params.name ?? '').trim();
      if (!name) return sendErr(conn, id, 'INVALID_REQUEST', 'group delete requires a non-empty name');
      const updatedSessions = moveGroupMembers(state, name, null);
      state.groups = state.groups.filter((group) => group !== name);
      sendRes(conn, id, { ok: true, ...groupCatalog(state), updatedSessions });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.messages.subscribe': {
      if (!state.sessions.has(params.key)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      conn.messageSubs.add(params.key);
      sendRes(conn, id, { subscribed: true, key: params.key });
      break;
    }
    case 'sessions.messages.unsubscribe': {
      conn.messageSubs.delete(params.key);
      sendRes(conn, id, { ok: true, key: params.key });
      break;
    }
    case 'chat.history': {
      const key = params.sessionKey;
      const row = state.sessions.get(key);
      const transcript = state.transcripts.get(key);
      if (!row || !transcript) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      const limit = Number.isFinite(params.limit) ? Math.max(0, params.limit) : transcript.length;
      // Like the Gateway: `offset` counts back from the newest message; `nextOffset` pages older.
      const offset = Number.isFinite(params.offset) ? Math.max(0, params.offset) : 0;
      const end = Math.max(0, transcript.length - offset);
      const start = Math.max(0, end - limit);
      const activeRun = row.activeRunIds[0] ? state.activeRuns.get(row.activeRunIds[0]) : undefined;
      sendRes(conn, id, {
        sessionKey: key,
        sessionId: row.sessionId,
        messages: transcript.slice(start, end).map((message) => projectForHistory(message)),
        totalMessages: transcript.length,
        hasMore: start > 0,
        ...(start > 0 ? { nextOffset: offset + (end - start) } : {}),
        thinkingLevel: 'medium',
        sessionInfo: { hasActiveRun: row.hasActiveRun, activeRunIds: [...row.activeRunIds] },
        ...(activeRun ? { inFlightRun: { runId: activeRun.runId, text: activeRun.text } } : {}),
      });
      break;
    }
    case 'chat.message.get': {
      const transcript = state.transcripts.get(params.sessionKey);
      if (!transcript) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      const message = transcript.find((entry) => entry.__openclaw?.id === params.messageId);
      if (!message) return sendRes(conn, id, { ok: false, unavailableReason: 'not_found' });
      const maxChars = Number.isFinite(params.maxChars) ? params.maxChars : 1_000_000;
      sendRes(conn, id, { ok: true, message: projectForHistory(message, maxChars) });
      break;
    }
    case 'chat.send': {
      const key = params.sessionKey;
      if (!params.idempotencyKey) return sendErr(conn, id, 'INVALID_REQUEST', 'idempotencyKey is required');
      if (!state.sessions.has(key)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      if (state.idempotency.has(params.idempotencyKey)) {
        return sendRes(conn, id, { runId: state.idempotency.get(params.idempotencyKey), status: 'started' });
      }
      const runId = shortId('run_');
      state.idempotency.set(params.idempotencyKey, runId);
      const run = {
        runId,
        sessionKey: key,
        text: params.message ?? '',
        seq: 0,
        aborted: false,
        finished: false,
        timers: new Set(),
        waiters: new Set(),
      };
      state.activeRuns.set(runId, run);
      sendRes(conn, id, { runId, status: 'started' });
      setImmediate(() => simulateRun(state, run, params));
      break;
    }
    case 'chat.abort': {
      abortMatchingRuns(state, params.sessionKey, params.runId);
      sendRes(conn, id, { aborted: true });
      break;
    }
    case 'sessions.patch': {
      const row = state.sessions.get(params.key);
      if (!row) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      if (params.expectedSessionId && params.expectedSessionId !== row.sessionId) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'expectedSessionId mismatch');
      }
      for (const field of ['unread', 'pinned', 'label', 'category', 'color', 'archived']) {
        if (Object.hasOwn(params, field)) row[field] = params[field];
      }
      if (Object.hasOwn(params, 'model')) {
        if (params.model === null) {
          Object.assign(row, { model: DEFAULT_MODEL.model, modelProvider: DEFAULT_MODEL.provider, modelOverrideSource: null });
        } else {
          const [provider, ...rest] = String(params.model).split('/');
          const choice = MODEL_CATALOG.find((m) => m.provider === provider && m.id === rest.join('/'));
          if (!choice) return sendErr(conn, id, 'INVALID_REQUEST', `model not allowed: ${params.model}`);
          if (!choice.available) return sendErr(conn, id, 'UNAVAILABLE', `model unavailable: ${params.model}`);
          Object.assign(row, { model: choice.id, modelProvider: choice.provider, modelOverrideSource: 'user' });
        }
      }
      if (Object.hasOwn(params, 'label')) row.derivedTitle = params.label ?? (row.isMain ? 'Main' : row.derivedTitle);
      if (Object.hasOwn(params, 'category')) registerGroup(state, params.category);
      updateSessionRow(row, { lastActivityAt: nowMs() });
      sendRes(conn, id, { ok: true, key: params.key, entry: clone(row) });
      broadcastSessionChanged(state, params.key, 'patch', row);
      break;
    }
    case 'sessions.compact': {
      if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
        return sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
      }
      const row = state.sessions.get(params.key);
      if (!row) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      if (row.hasActiveRun) return sendErr(conn, id, 'UNAVAILABLE', 'session has an active run');
      const result = compactSession(state, params.key);
      if (!result) return sendRes(conn, id, { ok: true, key: params.key, compacted: false, reason: 'Nothing to compact yet.' });
      sendRes(conn, id, { ok: true, key: params.key, compacted: true, result });
      broadcastSessionChanged(state, params.key, 'compact', row);
      break;
    }
    case 'models.list': {
      if (params.agentId && !state.agents.has(params.agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      sendRes(conn, id, { models: modelCatalog(params.includeDetails === true) });
      break;
    }
    case 'commands.list': {
      if (params.agentId && !state.agents.has(params.agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      if (params.sessionKey && !state.sessions.has(params.sessionKey)) return sendErr(conn, id, 'INVALID_REQUEST', 'Session not found.');
      const commands = COMMAND_CATALOG.filter((cmd) => !params.scope || cmd.scope === 'both' || cmd.scope === params.scope)
        .map(({ args, ...cmd }) => (params.includeArgs && args ? { ...cmd, args } : cmd));
      sendRes(conn, id, { commands: clone(commands) });
      break;
    }
    case 'sessions.create': {
      const agentId = params.agentId ?? 'main';
      if (!state.agents.has(agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      const key = `agent:${agentId}:dashboard:${shortId()}`;
      const row = {
        key,
        sessionId: crypto.randomUUID(),
        kind: 'direct',
        label: params.label ?? null,
        displayName: undefined,
        derivedTitle: params.label ?? 'New session',
        lastMessagePreview: params.message ? String(params.message).slice(0, 120) : 'New session created.',
        channel: 'webchat',
        agentId,
        isMain: false,
        category: params.category,
        color: undefined,
        pinned: false,
        unread: false,
        archived: false,
        updatedAt: nowMs(),
        lastActivityAt: nowMs(),
        status: 'idle',
        parentSessionKey: params.parentSessionKey,
        spawnedBy: params.parentSessionKey,
        hasActiveRun: false,
        activeRunIds: [],
      };
      state.sessions.set(key, row);
      registerGroup(state, params.category);
      state.transcripts.set(key, params.message ? [makeMessage('user', [textBlock(String(params.message))])] : []);
      sendRes(conn, id, { key, sessionId: row.sessionId, session: clone(row) });
      broadcastSessionChanged(state, key, 'create', row);
      break;
    }
    case 'artifacts.download': {
      const artifact = state.artifacts.get(params.artifactId);
      if (!artifact) return sendErr(conn, id, 'NOT_FOUND', 'artifact not found');
      sendRes(conn, id, {
        artifactId: params.artifactId,
        mimeType: artifact.mimeType,
        encoding: 'base64',
        data: artifact.data.toString('base64'),
      });
      break;
    }
    case 'users.prefs.get': {
      const prefs = state.userPrefs ?? (state.userPrefs = {});
      const keys = Array.isArray(params.keys) ? params.keys : Object.keys(prefs);
      const entries = Object.fromEntries(keys.filter((k) => k in prefs).map((k) => [k, clone(prefs[k])]));
      sendRes(conn, id, { status: 'ok', entries });
      break;
    }
    case 'users.prefs.set': {
      const prefs = state.userPrefs ?? (state.userPrefs = {});
      const entries = params.entries ?? {};
      if (process.env.MOCK_PREFS_NO_CAS && 'expectedEntries' in params) {
        return sendErr(conn, id, 'INVALID_REQUEST', "invalid users.prefs.set params: at root: unexpected property 'expectedEntries'");
      }
      for (const [key, expected] of Object.entries(params.expectedEntries ?? {})) {
        const current = key in prefs ? prefs[key] : null;
        if (canonicalJson(current) !== canonicalJson(expected)) {
          sendRes(conn, id, { status: 'conflict' });
          return;
        }
      }
      for (const [key, value] of Object.entries(entries)) {
        if (value === null) delete prefs[key];
        else prefs[key] = clone(value);
      }
      sendRes(conn, id, { status: 'ok' });
      broadcast(state, 'users.prefs.changed', { profileId: 'gateway-owner', keys: Object.keys(entries) });
      break;
    }
    case 'question.list': {
      if (!hasQuestionsScope(conn)) return sendMissingQuestionsScope(conn, id);
      sendRes(conn, id, { questions: [...state.questions.values()].filter((q) => q.status === 'pending').map(clone) });
      break;
    }
    case 'question.resolve': {
      if (!hasQuestionsScope(conn)) return sendMissingQuestionsScope(conn, id);
      const record = state.questions.get(params.id);
      if (!record) {
        return sendErr(conn, id, 'INVALID_REQUEST', `question '${params.id}' was not found`, { reason: 'QUESTION_NOT_FOUND' });
      }
      if (record.status !== 'pending') {
        return sendErr(conn, id, 'INVALID_REQUEST', 'question is already resolved', { reason: 'QUESTION_ALREADY_TERMINAL' });
      }
      if (params.cancel === true) {
        settleQuestion(state, record, 'cancelled');
        return sendRes(conn, id, { status: 'cancelled' });
      }
      const answers = params.answers?.answers;
      const complete = answers && record.questions.every((q) =>
        Array.isArray(answers[q.questionId]) && answers[q.questionId].length > 0 && answers[q.questionId].every((v) => typeof v === 'string'));
      if (!complete) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'every question needs an answer', { reason: 'QUESTION_INVALID_ANSWER' });
      }
      settleQuestion(state, record, 'answered', { answers });
      sendRes(conn, id, { status: 'answered', answers: { answers } });
      break;
    }
    case 'exec.approval.list': {
      const now = nowMs();
      sendRes(conn, id, { approvals: [...state.pendingApprovals.values()].filter((a) => a.expiresAtMs > now).map(clone) });
      break;
    }
    case 'exec.approval.resolve': {
      // Mirrors openclaw exec-approval.ts / approval-shared.ts / approval-errors.ts.
      if (!['allow-once', 'allow-always', 'deny'].includes(params.decision)) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid decision');
      }
      const resolvedDecision = state.resolvedApprovals.get(params.id);
      if (resolvedDecision !== undefined) {
        if (resolvedDecision === params.decision) return sendRes(conn, id, { ok: true });
        return sendErr(conn, id, 'INVALID_REQUEST', 'approval already resolved', { reason: 'APPROVAL_ALREADY_RESOLVED' });
      }
      const approval = state.pendingApprovals.get(params.id);
      if (!approval || approval.expiresAtMs <= nowMs()) {
        if (approval) state.pendingApprovals.delete(params.id);
        return sendErr(conn, id, 'INVALID_REQUEST', 'approval expired or not found', { reason: 'APPROVAL_NOT_FOUND' });
      }
      const allowed = approval.request?.allowedDecisions;
      if (Array.isArray(allowed) && !allowed.includes(params.decision)) {
        if (params.decision === 'allow-always') {
          return sendErr(conn, id, 'INVALID_REQUEST', 'allow-always is unavailable for this command', { reason: 'APPROVAL_ALLOW_ALWAYS_UNAVAILABLE' });
        }
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid decision');
      }
      recordExecResolution(state, approval, params.decision, conn.deviceId);
      if (params.decision === 'allow-always') recordAllowAlways(state, approval);
      state.pendingApprovals.delete(params.id);
      state.resolvedApprovals.set(params.id, params.decision);
      broadcast(state, 'exec.approval.resolved', { id: params.id, decision: params.decision });
      sendRes(conn, id, { ok: true, id: params.id, decision: params.decision });
      break;
    }
    default:
      sendErr(conn, id, 'UNKNOWN_METHOD', `unknown method: ${method}`);
  }
}

function handleConnect(state, conn, msg, options) {
  const { id, params = {} } = msg;
  const token = params.auth?.token ?? '';
  let deviceId;
  try {
    ({ deviceId } = verifyConnect(params, conn.challenge, token));
  } catch (err) {
    const code = err.code ?? 'DEVICE_AUTH_INVALID';
    sendErr(conn, id, code, err.message, { code });
    conn.ws.close(1008, code);
    return;
  }

  const issued = state.pairedDevices.get(deviceId)?.deviceToken;
  let authOk = false;
  if (token === options.mockToken) authOk = true;
  else if (issued && token === issued) authOk = true;

  if (!authOk) {
    const detailCode = String(token).startsWith('dt_') ? 'AUTH_DEVICE_TOKEN_MISMATCH' : 'AUTH_TOKEN_MISMATCH';
    sendErr(conn, id, 'UNAUTHORIZED', 'unauthorized', { code: detailCode });
    return;
  }

  const requestedScopes = Array.isArray(params.scopes) ? params.scopes : [];
  const paired = state.pairedDevices.get(deviceId);
  // A paired device asking for scopes it was never approved for needs a scope upgrade.
  const upgrade = paired && requestedScopes.some((scope) => !scopeApproved(scope, paired.scopes));
  if ((!paired || upgrade) && options.pairing !== 'off') {
    const reason = paired ? 'scope-upgrade' : 'not-paired';
    const requestId = shortId('pair_');
    // MOCK_LEGACY_PAIRING=1 approves first pairings without operator.questions, like a device
    // paired before Pincer asked for it, so the next connect needs a scope upgrade.
    const grantScopes = !paired && options.legacyPairing ? requestedScopes.filter((scope) => scope !== 'operator.questions') : requestedScopes;
    state.pendingPairing.set(requestId, { deviceId, scopes: grantScopes, displayName: params.client?.displayName ?? 'unknown', createdAt: nowMs() });
    console.log(`Pairing request ${requestId} (${reason}) from ${params.client?.displayName ?? 'unknown'} (${deviceId.slice(0, 8)})`);
    sendErr(conn, id, 'NOT_PAIRED', `pairing required (requestId: ${requestId})`, {
      code: 'PAIRING_REQUIRED',
      reason,
      requestId,
      deviceId,
      requestedScopes,
      ...(paired ? { approvedScopes: [...paired.scopes] } : {}),
    });
    if (options.pairing === 'auto') setTimeout(() => approvePairing(state, requestId), 3000);
    conn.ws.close(1008, 'PAIRING_REQUIRED');
    return;
  }
  if (options.pairing === 'off') deviceTokenFor(state, deviceId, requestedScopes);

  conn.authenticated = true;
  conn.connId = shortId('conn_');
  conn.deviceId = deviceId;
  conn.scopes = Array.isArray(params.scopes) ? params.scopes : [];
  sendRes(conn, id, makeHelloPayload(state, params, conn.connId, deviceId));
}

function simulateBackground(state) {
  const key = 'agent:main:discord:channel:123';
  const row = state.sessions.get(key);
  const transcript = state.transcripts.get(key);
  if (!row || !transcript) return;
  const userMsg = makeMessage('user', [textBlock(`Discord background ping at ${new Date().toISOString()}`)], {
    extra: { provenance: { sourceChannel: 'discord' } },
  });
  const assistantMsg = makeMessage('assistant', [textBlock('Mock background activity acknowledged.')]);
  transcript.push(userMsg, assistantMsg);
  row.unread = true;
  row.lastMessagePreview = 'Mock background activity acknowledged.';
  updateSessionRow(row, { lastActivityAt: nowMs() });
  broadcastSessionChanged(state, key, 'background', row);
  broadcast(state, 'chat', { runId: shortId('run_bg_'), sessionKey: key, seq: 1, state: 'final', message: clone(assistantMsg) });
}

export async function startServer(opts = {}) {
  const options = {
    host: opts.host ?? process.env.HOST ?? '127.0.0.1',
    port: Number(opts.port ?? process.env.PORT ?? 18789),
    mockToken: opts.mockToken ?? process.env.MOCK_TOKEN ?? 'dev-token',
    pairing: opts.pairing ?? process.env.MOCK_PAIRING ?? 'auto',
    background: opts.background ?? process.env.MOCK_BACKGROUND === '1',
    legacyPairing: opts.legacyPairing ?? process.env.MOCK_LEGACY_PAIRING === '1',
  };
  const state = createSeedState();
  setupManualPairing(state, options.pairing === 'manual');

  const wss = new WebSocketServer({ host: options.host, port: options.port });
  const ready = new Promise((resolve, reject) => {
    wss.once('listening', resolve);
    wss.once('error', reject);
  });

  wss.on('connection', (ws) => {
    const conn = {
      ws,
      seq: 0,
      authenticated: false,
      challenge: { nonce: b64url(crypto.randomBytes(24)), ts: nowMs() },
      sessionSubscribed: false,
      messageSubs: new Set(),
      tickTimer: undefined,
    };
    state.connections.add(conn);
    sendEvent(conn, 'connect.challenge', conn.challenge);
    conn.tickTimer = setInterval(() => {
      if (conn.authenticated) sendEvent(conn, 'tick', { ts: nowMs() });
    }, 15_000);

    ws.on('message', (data, isBinary) => {
      const bytes = Buffer.byteLength(data);
      if (!conn.authenticated && bytes > 64 * 1024) {
        ws.close(1009, 'pre-auth frame too large');
        return;
      }
      if (isBinary) {
        ws.close(1003, 'json text frames only');
        return;
      }
      let msg;
      try {
        msg = JSON.parse(data.toString('utf8'));
      } catch {
        sendErr(conn, undefined, 'PROTOCOL', 'invalid json');
        ws.close(1008, 'invalid json');
        return;
      }
      if (msg?.type !== 'req' || typeof msg.method !== 'string') {
        sendErr(conn, msg?.id, 'PROTOCOL', 'expected request frame');
        return;
      }
      console.log(`${conn.connId ?? 'preauth'} ${msg.method}`);
      if (!conn.authenticated) {
        if (msg.method !== 'connect') {
          sendErr(conn, msg.id, 'PROTOCOL', 'connect required');
          ws.close(1008, 'connect required');
          return;
        }
        handleConnect(state, conn, msg, options);
        return;
      }
      handleAuthedRequest(state, conn, msg);
    });

    ws.on('close', () => {
      if (conn.tickTimer) clearInterval(conn.tickTimer);
      state.connections.delete(conn);
    });
  });

  const backgroundTimer = options.background ? setInterval(() => simulateBackground(state), 45_000) : undefined;
  await ready;
  console.log(`mock OpenClaw Gateway listening on ws://${options.host}:${wss.address().port}`);

  return {
    wss,
    state,
    address: () => wss.address(),
    close: () =>
      new Promise((resolve) => {
        if (backgroundTimer) clearInterval(backgroundTimer);
        for (const timer of state.cronState.active.values()) clearTimeout(timer);
        for (const conn of state.connections) conn.ws.close(1001, 'server closing');
        wss.close(() => resolve());
      }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startServer().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
