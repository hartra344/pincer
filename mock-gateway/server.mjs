import crypto from 'node:crypto';
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { seedLongChat } from './long-chat.mjs';
import { APPROVAL_HISTORY_METHODS, approvalHistoryDisabled, handleApprovalHistoryRequest } from './approvals.mjs';
import { AGENT_MANAGEMENT_METHODS, agentManagementDisabled, handleAgentsRequest } from './agents.mjs';
import { SKILLS_METHODS, TOOLS_METHODS, handleSkillsRequest, skillsDisabled, toolsDisabled } from './skills.mjs';
import { MCP_EVENTS, MCP_METHODS, handleMcpHttp, handleMcpRequest, mcpDisabled } from './mcp.mjs';
import { CONFIG_METHODS, handleConfigRequest } from './config.mjs';
import { CRON_METHODS, handleCronRequest } from './cron.mjs';
import { LOGS_METHODS, handleLogsRequest, logsDisabled, stopLogs } from './logs.mjs';
import { EXEC_APPROVALS_METHODS, execApprovalsDisabled, handleExecApprovalsRequest } from './exec-approvals.mjs';
import { handleUsageRequest, USAGE_METHODS, usageDisabled } from './usage.mjs';
import { CHANNEL_PAIRING_METHODS, addChannelPairingRequest, channelPairingDisabled, handleChannelPairingRequest } from './pairing.mjs';
import { RATE_LIMIT_RETRY_AFTER_MS, checkConnectAuth, pairingRequiredError, rejectConnectAuth, rejectPendingDevice } from './connect-auth.mjs';
import { HEALTH_EVENTS, HEALTH_METHODS, addFailedDelivery, broadcastPresence, cancelPendingRestart, handleHealthRequest, healthDisabled, helloSnapshot, isRestarting, healthSummary } from './health.mjs';
import { SETUP_METHODS, handleSetupRequest } from './setup.mjs';
import { SESSION_MANAGER_METHODS, handleSessionManagerRequest, hiddenSessionManagerMethods } from './sessions.mjs';
import { CHANNEL_LIFECYCLE_METHODS, handleChannelsRequest } from './channels.mjs';
import { handleWebPushRequest } from './webpush.mjs';
import { DEVICE_PAIRING_EVENTS, DEVICE_PAIRING_METHODS, NODE_METHODS, approvePendingDevice, devicePairingDisabled, handleDevicesRequest, noteDeviceConnected, nodesDisabled, openPairingRequest } from './devices.mjs';
import { handleCatalogRequest } from './catalog.mjs';
import { abortMatchingRuns, finishRunAbort, handleChatRequest, postToSession } from './chat.mjs';
import { handleMiscRequest } from './misc.mjs';
import { handleQuestionRequest } from './questions.mjs';
import { createSeedState } from './seed.mjs';
import { broadcastSessionChanged, handleSessionListRequest, registerGroup, updateSessionRow } from './session-list.mjs';
import { CONTROL_METHOD, handleControlRequest, initControl, noteRequest } from './control.mjs';
import { broadcast, clone, makeMessage, nowMs, randHex, sendErr, sendEvent, sendJson, sendRes, shortId, textBlock } from './util.mjs';

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

const METHODS = [
  'agents.list',
  ...AGENT_MANAGEMENT_METHODS,
  ...SKILLS_METHODS,
  ...TOOLS_METHODS,
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
  'message.action',
  'sessions.patch',
  'sessions.compact',
  ...SESSION_MANAGER_METHODS,
  'models.list',
  'sessions.create',
  'artifacts.download',
  'exec.approval.list',
  'exec.approval.resolve',
  ...APPROVAL_HISTORY_METHODS,
  ...EXEC_APPROVALS_METHODS,
  ...USAGE_METHODS,
  'question.list',
  'question.resolve',
  'users.prefs.get',
  'users.prefs.set',
  'commands.list',
  'progressCard.get',
  'progressCard.put',
  ...CONFIG_METHODS,
  ...MCP_METHODS,
  ...CRON_METHODS,
  ...LOGS_METHODS,
  ...CHANNEL_PAIRING_METHODS,
  ...DEVICE_PAIRING_METHODS,
  ...NODE_METHODS,
  ...HEALTH_METHODS,
  ...SETUP_METHODS,
  ...CHANNEL_LIFECYCLE_METHODS,
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
  ...MCP_EVENTS,
  'progressCard.changed',
  'cron',
  ...DEVICE_PAIRING_EVENTS,
  ...HEALTH_EVENTS,
];

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function fromB64url(value) {
  return Buffer.from(String(value ?? ''), 'base64url');
}

function verifyConnect(params, challenge, token, protocol = 4) {
  if (!params || typeof params !== 'object') throw Object.assign(new Error('missing params'), { code: 'PROTOCOL' });
  if (params.minProtocol > protocol || params.maxProtocol < protocol) {
    // Upstream connect-admission.ts: INVALID_REQUEST + details.code, closed with 1002.
    throw Object.assign(new Error('protocol mismatch'), {
      code: 'INVALID_REQUEST',
      closeCode: 1002,
      details: { code: 'PROTOCOL_MISMATCH', clientMinProtocol: params.minProtocol, clientMaxProtocol: params.maxProtocol, expectedProtocol: protocol },
    });
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
  const now = nowMs();
  state.pairedDevices.set(deviceId, { deviceId, deviceToken, pairedAt: now, createdAtMs: now, approvedAtMs: now, tokenCreatedAtMs: now, scopes: new Set(scopes) });
  return deviceToken;
}

// Like the Gateway: operator.admin covers every operator scope, operator.write covers read.
function scopeApproved(scope, approved) {
  return approved.has(scope) || approved.has('operator.admin') || (scope === 'operator.read' && approved.has('operator.write'));
}

function approvePairing(state, requestId) {
  if (!approvePendingDevice(state, requestId, broadcast)) return false;
  console.log(`Pairing approved ${requestId}`);
  return true;
}

function setupManualPairing(state, enabled) {
  if (!enabled || setupManualPairing.didSetup) return;
  setupManualPairing.didSetup = true;
  process.stdin.setEncoding('utf8');
  // `<requestId>` approves; `reject <requestId>` rejects.
  process.stdin.on('data', (chunk) => {
    for (const line of chunk.split(/\r?\n/)) {
      const words = line.trim().split(/\s+/).filter(Boolean);
      if (words[0] === 'reject') words.slice(1).forEach((requestId) => rejectPendingDevice(state, requestId, broadcast));
      else words.forEach((requestId) => approvePairing(state, requestId));
    }
  });
  process.stdin.resume();
}

function advertisedMethods() {
  const hidden = [
    ...(approvalHistoryDisabled() ? APPROVAL_HISTORY_METHODS : []),
    ...(execApprovalsDisabled() ? EXEC_APPROVALS_METHODS : []),
    ...(agentManagementDisabled() ? AGENT_MANAGEMENT_METHODS : []),
    ...(skillsDisabled() ? SKILLS_METHODS : []),
    ...(toolsDisabled() ? TOOLS_METHODS : []),
    ...(channelPairingDisabled() ? CHANNEL_PAIRING_METHODS : []),
    ...(healthDisabled() ? HEALTH_METHODS : []),
    ...(devicePairingDisabled() ? DEVICE_PAIRING_METHODS : []),
    ...(nodesDisabled() ? NODE_METHODS : []),
    ...(usageDisabled() ? USAGE_METHODS : []),
    ...(logsDisabled() ? LOGS_METHODS : []),
    ...(mcpDisabled() ? MCP_METHODS : []),
    ...hiddenSessionManagerMethods(),
  ];
  return METHODS.filter((m) => !hidden.includes(m));
}

function makeHelloPayload(state, params, connId, deviceId) {
  return {
    type: 'hello-ok',
    protocol: state.protocol ?? 4,
    server: { version: 'mock-2026.1', connId },
    features: { methods: advertisedMethods(), events: devicePairingDisabled() ? EVENTS.filter((e) => !DEVICE_PAIRING_EVENTS.includes(e)) : EVENTS },
    snapshot: healthDisabled() ? {} : helloSnapshot(state),
    auth: { role: 'operator', scopes: params.scopes ?? [], deviceToken: deviceTokenFor(state, deviceId) },
    policy: {
      maxPayload: 26214400,
      maxBufferedBytes: 52428800,
      tickIntervalMs: 15000,
      attachments: { maxBytes: 20000000, maxImageBytes: 5000000 },
    },
  };
}

const REQUEST_HANDLERS = [
  (state, conn, msg) => handleConfigRequest(state, conn, msg, { sendRes, sendErr, broadcast }),
  (state, conn, msg) => handleMcpRequest(state, conn, msg, { sendRes, sendErr, broadcast }),
  (state, conn, msg) => handleCronRequest(state, conn, msg, { sendRes, sendErr, broadcast, postToSession }),
  (state, conn, msg) => handleWebPushRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleApprovalHistoryRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleLogsRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleExecApprovalsRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleAgentsRequest(state, conn, msg, { sendRes, sendErr, broadcast }),
  (state, conn, msg) => handleSkillsRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleUsageRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleChannelPairingRequest(state, conn, msg, { sendRes, sendErr }),
  (state, conn, msg) => handleSetupRequest(state, conn, msg, { sendRes, sendErr, broadcast, healthSummary }),
  (state, conn, msg) => handleChannelsRequest(state, conn, msg, { sendRes, sendErr, broadcast, healthSummary }),
  (state, conn, msg) => handleDevicesRequest(state, conn, msg, { sendRes, sendErr, broadcast }),
  (state, conn, msg) => handleHealthRequest(state, conn, msg, { sendRes, sendErr, broadcast, abortRun: finishRunAbort }),
  (state, conn, msg) => handleSessionManagerRequest(state, conn, msg, {
    sendRes, sendErr, broadcast, broadcastSessionChanged, abortMatchingRuns, makeMessage, textBlock, clone,
    registerGroup: (name) => registerGroup(state, name),
    registerSession: (key, row, transcript) => {
      state.sessions.set(key, row);
      state.transcripts.set(key, transcript);
    },
  }),
  handleChatRequest,
  handleSessionListRequest,
  handleCatalogRequest,
  handleMiscRequest,
  handleQuestionRequest,
];

function handleAuthedRequest(state, conn, msg) {
  if (msg.method === CONTROL_METHOD) {
    handleControlRequest(state, conn, msg);
    return;
  }
  noteRequest(state, conn, msg);
  for (const handle of REQUEST_HANDLERS) {
    if (handle(state, conn, msg)) return;
  }
  sendErr(conn, msg.id, 'UNKNOWN_METHOD', `unknown method: ${msg.method}`);
}

function handleConnect(state, conn, msg, options) {
  const { id, params = {} } = msg;
  const token = params.auth?.token ?? '';
  let deviceId;
  try {
    ({ deviceId } = verifyConnect(params, conn.challenge, token, options.protocol));
  } catch (err) {
    const code = err.code ?? 'DEVICE_AUTH_INVALID';
    sendErr(conn, id, code, err.message, err.details ?? { code });
    conn.ws.close(err.closeCode ?? 1008, err.message);
    return;
  }

  const issued = state.pairedDevices.get(deviceId)?.deviceToken;
  // MOCK_AUTH_RATE_LIMIT=<n>: n failed attempts lock shared-secret auth for a minute.
  if (state.authLockedUntil && nowMs() >= state.authLockedUntil) Object.assign(state, { authLockedUntil: 0, authFailures: 0 });
  const failure = state.authLockedUntil
    ? 'rate_limited'
    : checkConnectAuth(params.auth, { mode: options.auth, token: options.mockToken, password: options.mockPassword, issuedDeviceToken: issued });
  if (failure) {
    if (failure !== 'rate_limited' && options.authRateLimit > 0 && ++state.authFailures >= options.authRateLimit) {
      state.authLockedUntil = nowMs() + RATE_LIMIT_RETRY_AFTER_MS;
    }
    rejectConnectAuth(conn, id, failure, { sendJson, auth: params.auth ?? {} });
    return;
  }
  state.authFailures = 0;
  const isDeviceTokenAuth = Boolean(issued) && params.auth?.token === issued;

  const requestedScopes = Array.isArray(params.scopes) ? params.scopes : [];
  const paired = state.pairedDevices.get(deviceId);
  // A paired device asking for scopes it was never approved for needs a scope upgrade.
  const upgrade = paired && requestedScopes.some((scope) => !scopeApproved(scope, paired.scopes));
  if ((!paired || upgrade) && options.pairing !== 'off') {
    const reason = paired ? 'scope-upgrade' : 'not-paired';
    // MOCK_LEGACY_PAIRING=1 approves first pairings without operator.questions, like a device
    // paired before Pincer asked for it, so the next connect needs a scope upgrade.
    const grantScopes = !paired && options.legacyPairing ? requestedScopes.filter((scope) => scope !== 'operator.questions') : requestedScopes;
    const displayName = params.client?.displayName ?? 'unknown';
    const before = [...state.pendingPairing.values()].find((p) => p.deviceId === deviceId)?.requestId;
    const remoteIp = conn.ws._socket?.remoteAddress;
    const request = openPairingRequest(state, { deviceId, params, scopes: grantScopes, remoteIp, isRepair: Boolean(paired) }, broadcast);
    const { requestId } = request;
    const existing = before === requestId;
    console.log(`Pairing request ${requestId} (${reason}${existing ? ', pending' : ''}) from ${displayName} (${deviceId.slice(0, 8)})`);
    const error = pairingRequiredError({ requestId, deviceId, reason, requestedScopes }, paired ? [...paired.scopes] : undefined);
    sendErr(conn, id, error.code, error.message, error.details);
    if (!existing) schedulePairingDecision(state, request, options);
    conn.ws.close(1008, 'PAIRING_REQUIRED');
    return;
  }
  if (options.pairing === 'off') deviceTokenFor(state, deviceId, requestedScopes);

  conn.authenticated = true;
  conn.connId = shortId('conn_');
  conn.deviceId = deviceId;
  conn.isDeviceTokenAuth = isDeviceTokenAuth;
  noteDeviceConnected(state, deviceId, params, conn.ws._socket?.remoteAddress);
  conn.scopes = Array.isArray(params.scopes) ? params.scopes : [];
  conn.client = params.client ?? {};
  conn.connectedAt = nowMs();
  sendRes(conn, id, makeHelloPayload(state, params, conn.connId, deviceId));
  broadcastPresence(state, broadcast);
}

// MOCK_PAIRING=auto approves, reject rejects, reject-once rejects a device's first request and
// approves the next; each after MOCK_PAIRING_DELAY_MS (default 3000). manual waits for stdin or
// device.pair.approve / device.pair.reject.
function schedulePairingDecision(state, request, options) {
  let decision;
  if (options.pairing === 'auto') decision = 'approve';
  else if (options.pairing === 'reject') decision = 'reject';
  else if (options.pairing === 'reject-once') {
    state.rejectedOnce ??= new Set();
    decision = state.rejectedOnce.has(request.deviceId) ? 'approve' : 'reject';
    state.rejectedOnce.add(request.deviceId);
  }
  if (!decision) return;
  setTimeout(() => {
    if (decision === 'approve') approvePairing(state, request.requestId);
    else rejectPendingDevice(state, request.requestId, broadcast);
  }, options.pairingDelayMs);
}

function simulateBackground(state) {
  const key = 'agent:main:discord:channel:123';
  const row = state.sessions.get(key);
  const transcript = state.transcripts.get(key);
  if (!row || !transcript) return;
  const userMsg = makeMessage('user', [textBlock(`Discord background ping at ${new Date().toISOString()}`)], {
    openclaw: { transport: { channel: 'discord', messageId: String(1300000000000000000n + BigInt(nowMs())), conversationRef: 'channel:123' } },
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
    pairingDelayMs: Number(opts.pairingDelayMs ?? process.env.MOCK_PAIRING_DELAY_MS ?? 3000),
    auth: opts.auth ?? process.env.MOCK_AUTH ?? 'token',
    mockPassword: opts.mockPassword ?? process.env.MOCK_PASSWORD ?? 'dev-password',
    authRateLimit: Number(opts.authRateLimit ?? process.env.MOCK_AUTH_RATE_LIMIT ?? 0),
    protocol: Number(opts.protocol ?? process.env.MOCK_PROTOCOL ?? 4),
    challenge: opts.challenge ?? process.env.MOCK_CHALLENGE ?? 'on',
    background: opts.background ?? process.env.MOCK_BACKGROUND === '1',
    legacyPairing: opts.legacyPairing ?? process.env.MOCK_LEGACY_PAIRING === '1',
    channelPairingEvery: Number(opts.channelPairingEvery ?? process.env.MOCK_CHANNEL_PAIRING_EVERY ?? 0),
    failedDeliveryEvery: Number(opts.failedDeliveryEvery ?? process.env.MOCK_FAILED_DELIVERY_EVERY ?? 0),
    longChat: Number(opts.longChat ?? process.env.MOCK_LONG_CHAT ?? 0),
  };
  if (!['token', 'password', 'none'].includes(options.auth)) throw new Error(`MOCK_AUTH must be token, password or none, not ${options.auth}`);
  if (!['auto', 'manual', 'off', 'reject', 'reject-once'].includes(options.pairing)) throw new Error(`unknown MOCK_PAIRING: ${options.pairing}`);
  const state = createSeedState();
  if (options.longChat > 0) seedLongChat(state, Math.floor(options.longChat));
  state.protocol = options.protocol;
  initControl(state);
  state.authFailures = 0;
  state.authLockedUntil = 0;
  setupManualPairing(state, options.pairing === 'manual' && opts.stdin !== false);

  // The same port also serves the mock MCP OAuth consent pages.
  const httpServer = http.createServer((req, res) => {
    if (mcpDisabled() || !handleMcpHttp(state, req, res, broadcast)) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
    }
  });
  const wss = new WebSocketServer({ server: httpServer });
  const ready = new Promise((resolve, reject) => {
    httpServer.once('listening', resolve);
    httpServer.once('error', reject);
  });
  httpServer.listen(options.port, options.host);

  wss.on('connection', (ws, req) => {
    // A simulated restart is under way: the Gateway isn't accepting connections yet.
    if (isRestarting(state)) {
      ws.close(1013, 'gateway restarting');
      return;
    }
    const conn = {
      ws,
      seq: 0,
      authenticated: false,
      challenge: { nonce: b64url(crypto.randomBytes(24)), ts: nowMs() },
      sessionSubscribed: false,
      messageSubs: new Set(),
      tickTimer: undefined,
      baseUrl: req.headers.host ? `http://${req.headers.host}` : undefined,
    };
    state.connections.add(conn);
    // MOCK_CHALLENGE=off: a WebSocket server that isn't a Gateway (never sends the challenge).
    if (options.challenge !== 'off') sendEvent(conn, 'connect.challenge', conn.challenge);
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
      conn.lastActivityAt = nowMs();
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
      if (conn.authenticated && !isRestarting(state)) broadcastPresence(state, broadcast);
    });
  });

  const backgroundTimer = options.background ? setInterval(() => simulateBackground(state), 45_000) : undefined;
  const pairingTimer = options.channelPairingEvery > 0
    ? setInterval(() => addChannelPairingRequest(state), options.channelPairingEvery * 1000)
    : undefined;
  const failedDeliveryTimer = options.failedDeliveryEvery > 0
    ? setInterval(() => addFailedDelivery(state, broadcast), options.failedDeliveryEvery * 1000)
    : undefined;
  await ready;
  state.httpBaseUrl = `http://${['0.0.0.0', '::'].includes(options.host) ? '127.0.0.1' : options.host}:${httpServer.address().port}`;
  console.log(`mock OpenClaw Gateway listening on ws://${options.host}:${httpServer.address().port}`);

  return {
    wss,
    state,
    address: () => httpServer.address(),
    close: () =>
      new Promise((resolve) => {
        if (backgroundTimer) clearInterval(backgroundTimer);
        if (pairingTimer) clearInterval(pairingTimer);
        if (failedDeliveryTimer) clearInterval(failedDeliveryTimer);
        for (const timer of state.cronState.active.values()) clearTimeout(timer);
        stopLogs(state.logsState);
        cancelPendingRestart(state);
        for (const conn of state.connections) conn.ws.close(1001, 'server closing');
        wss.close(() => httpServer.close(() => resolve()));
        httpServer.closeAllConnections?.();
      }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  startServer().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
