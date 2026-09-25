import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { CONFIG_METHODS, createConfigState, handleConfigRequest } from './config.mjs';

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const METHODS = [
  'agents.list',
  'sessions.subscribe',
  'sessions.list',
  'sessions.groups.list',
  'sessions.messages.subscribe',
  'sessions.messages.unsubscribe',
  'chat.history',
  'chat.send',
  'chat.abort',
  'sessions.patch',
  'sessions.create',
  'artifacts.download',
  'exec.approval.list',
  'exec.approval.resolve',
  'users.prefs.get',
  'users.prefs.set',
  ...CONFIG_METHODS,
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
  'users.prefs.changed',
  'plugins.changed',
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

function makeMessage(role, content, extras = {}) {
  return {
    role,
    content,
    timestamp: nowMs(),
    __openclaw: { id: crypto.randomUUID(), ...extras.openclaw },
    ...extras.extra,
  };
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
    const entry = {
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
    };
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
  });
  row('agent:research:main', {
    agentId: 'research',
    isMain: true,
    derivedTitle: 'Main',
    age: 90_000,
    lastMessagePreview: 'Research queue is clear.',
  });
  row('agent:research:dashboard:papers', {
    agentId: 'research',
    label: 'Paper digest',
    derivedTitle: 'Paper digest',
    category: 'Work',
    unread: true,
    age: 120_000,
    lastMessagePreview: 'Three papers summarized.',
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
  });

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
    idempotency: new Map(),
    activeRuns: new Map(),
    connections: new Set(),
    configState: createConfigState(),
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
}

function updateSessionRow(row, patch = {}) {
  Object.assign(row, patch, { updatedAt: nowMs() });
  return row;
}

function broadcastSessionChanged(state, sessionKey, reason, session) {
  broadcast(state, 'sessions.changed', { sessionKey, reason, session: clone(session) }, (conn) => conn.sessionSubscribed);
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

function deviceTokenFor(state, deviceId) {
  const existing = state.pairedDevices.get(deviceId);
  if (existing?.deviceToken) return existing.deviceToken;
  const deviceToken = `dt_${randHex(18)}`;
  state.pairedDevices.set(deviceId, { deviceToken, pairedAt: nowMs() });
  return deviceToken;
}

function approvePairing(state, requestId) {
  const pending = state.pendingPairing.get(requestId);
  if (!pending) return false;
  deviceTokenFor(state, pending.deviceId);
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

function makeHelloPayload(state, params, connId, deviceId) {
  return {
    type: 'hello-ok',
    protocol: 4,
    server: { version: 'mock-2026.1', connId },
    features: { methods: METHODS, events: EVENTS },
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

    if (/\bapprove\b/i.test(String(text ?? ''))) {
      const approval = {
        id: shortId('approval_'),
        request: { command: 'rm -rf ./build', cwd: '/home/claw/project', sessionKey, agentId: row.agentId },
        createdAtMs: nowMs(),
        expiresAtMs: nowMs() + 120_000,
      };
      state.pendingApprovals.set(approval.id, approval);
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
        message: makeMessage('assistant', [thinkingBlock(thinking)], { openclaw: { runId: run.runId } }),
      });
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
      const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'exec', { command: 'uptime' })], { openclaw: { runId: run.runId } });
      const toolResult = makeMessage('toolResult', [textBlock(' 10:42  up 3 days, 4 users, load averages: 1.2 1.0 0.8')], {
        openclaw: { runId: run.runId },
        extra: { toolCallId, toolName: 'exec', isError: false },
      });
      transcript.push(toolMsg, toolResult);
      broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
      broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    }

    const reply = `I heard: "${String(text ?? '')}".\n\n## Mock response\n\n- Streaming deltas are working.\n- Tool events are ${wantsTool ? 'included' : 'available when requested'}.\n- Markdown rendering can be tested here.\n\n\`\`\`text\nrunId=${run.runId}\n\`\`\``;
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
        message: makeMessage('assistant', [thinkingBlock(thinking), textBlock(out)], { openclaw: { runId: run.runId } }),
      });
    }
    const finalContent = [thinkingBlock(thinking), textBlock(reply)];
    if (/image/i.test(String(text ?? ''))) finalContent.push(imageBlock('art-chart-1', 'Synthetic mock chart'));
    const finalMsg = makeMessage('assistant', finalContent, { openclaw: { runId: run.runId } });
    transcript.push(finalMsg);
    broadcastSessionMessage(state, sessionKey, finalMsg, transcript.length);
    broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'final', message: clone(finalMsg) });
    broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'end' } });

    row.hasActiveRun = false;
    row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
    row.status = 'idle';
    row.lastMessagePreview = reply.slice(0, 120);
    row.unread = true;
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionChanged(state, sessionKey, 'run-finished', row);
    run.finished = true;
    state.activeRuns.delete(run.runId);
  } catch (err) {
    if (!run.aborted) console.error('run simulation failed:', err);
    state.activeRuns.delete(run.runId);
  }
}

function handleAuthedRequest(state, conn, msg) {
  const { id, method, params = {} } = msg;
  if (handleConfigRequest(state, conn, msg, { sendRes, sendErr, broadcast })) return;
  switch (method) {
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
        list: { sessions: sortedSessions(state, params.archived === true || params.archived === 'all'), nextOffset: null, hasMore: false },
      });
      break;
    }
    case 'sessions.list': {
      sendRes(conn, id, { sessions: sortedSessions(state, params.archived === true || params.archived === 'all'), nextOffset: null, hasMore: false });
      break;
    }
    case 'sessions.groups.list': {
      sendRes(conn, id, { groups: [{ name: 'Home' }, { name: 'Personal' }, { name: 'Work' }], sectionOrder: [] });
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
        messages: clone(transcript.slice(start, end)),
        totalMessages: transcript.length,
        hasMore: start > 0,
        ...(start > 0 ? { nextOffset: offset + (end - start) } : {}),
        thinkingLevel: 'medium',
        sessionInfo: { hasActiveRun: row.hasActiveRun, activeRunIds: [...row.activeRunIds] },
        ...(activeRun ? { inFlightRun: { runId: activeRun.runId, text: activeRun.text } } : {}),
      });
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
      if (Object.hasOwn(params, 'label')) row.derivedTitle = params.label ?? (row.isMain ? 'Main' : row.derivedTitle);
      updateSessionRow(row, { lastActivityAt: nowMs() });
      sendRes(conn, id, { ok: true, key: params.key, entry: clone(row) });
      broadcastSessionChanged(state, params.key, 'patch', row);
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
    case 'exec.approval.list': {
      sendRes(conn, id, { approvals: [...state.pendingApprovals.values()].map(clone) });
      break;
    }
    case 'exec.approval.resolve': {
      if (!['allow-once', 'allow-always', 'deny'].includes(params.decision)) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid decision');
      }
      state.pendingApprovals.delete(params.id);
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

  if (!state.pairedDevices.has(deviceId) && options.pairing !== 'off') {
    const requestId = shortId('pair_');
    state.pendingPairing.set(requestId, { deviceId, displayName: params.client?.displayName ?? 'unknown', createdAt: nowMs() });
    console.log(`Pairing request ${requestId} from ${params.client?.displayName ?? 'unknown'} (${deviceId.slice(0, 8)})`);
    sendErr(conn, id, 'NOT_PAIRED', `pairing required (requestId: ${requestId})`, {
      code: 'PAIRING_REQUIRED',
      requestId,
      deviceId,
    });
    if (options.pairing === 'auto') setTimeout(() => approvePairing(state, requestId), 3000);
    conn.ws.close(1008, 'PAIRING_REQUIRED');
    return;
  }
  if (options.pairing === 'off') deviceTokenFor(state, deviceId);

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
