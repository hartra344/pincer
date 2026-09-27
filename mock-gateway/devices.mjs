// Device pairing and the paired-node inventory, mirroring upstream
// src/gateway/server-methods/devices.ts, nodes.read.ts and nodes.pairing.ts.
// device.pair.list/approve/reject/remove/rename, node.rename and node.pair.remove need operator.pairing, node.list and
// node.describe need operator.read (operator.admin covers everything, operator.write covers read).
// Callers that connected with their device token and lack operator.admin only see and manage their
// own device, like the Gateway. device.pair.requested/resolved/changed only reach operator.pairing
// clients. MOCK_DEVICE_PAIRING=off (or MOCK_NODES=off) makes the mock look like a Gateway without them.
import crypto from 'node:crypto';

export const DEVICE_PAIRING_METHODS = ['device.pair.list', 'device.pair.approve', 'device.pair.reject', 'device.pair.remove', 'device.pair.rename'];
export const NODE_METHODS = ['node.list', 'node.describe', 'node.rename', 'node.pair.remove'];
export const DEVICE_PAIRING_EVENTS = ['device.pair.requested', 'device.pair.resolved', 'device.pair.changed', 'node.pair.requested', 'node.pair.resolved'];
export const PAIRING_SCOPE = 'operator.pairing';
const ADMIN_SCOPE = 'operator.admin';
const READ_SCOPE = 'operator.read';
const OPERATOR_ROLE = 'operator';

export function devicePairingDisabled() {
  return process.env.MOCK_DEVICE_PAIRING === 'off';
}

export function nodesDisabled() {
  return process.env.MOCK_NODES === 'off';
}

function hasScope(scopes, scope) {
  const list = scopes ?? [];
  return list.includes(scope) || list.includes(ADMIN_SCOPE) || (scope === READ_SCOPE && list.includes('operator.write'));
}

export function hasPairingScope(conn) {
  return hasScope(conn.scopes, PAIRING_SCOPE);
}

// Seeded devices never connect, so a stable made-up key is enough; the id is its sha256 like upstream.
function seededIdentity(name) {
  const raw = crypto.createHash('sha256').update(`mock-device:${name}`).digest();
  return { publicKey: raw.toString('base64url'), deviceId: crypto.createHash('sha256').update(raw).digest('hex') };
}

export function deviceIdentityFor(name) {
  return seededIdentity(name);
}

function roleList(record) {
  const roles = new Set([record.role, ...(record.roles ?? [])].filter(Boolean));
  return [...roles];
}

function makePaired(name, fields, base) {
  const { deviceId, publicKey } = seededIdentity(name);
  const approvedAtMs = base - fields.approvedAgoMs;
  return {
    deviceId,
    publicKey,
    displayName: fields.displayName,
    platform: fields.platform,
    deviceFamily: fields.deviceFamily,
    clientId: fields.clientId,
    clientMode: fields.clientMode,
    role: fields.role,
    roles: fields.roles,
    scopes: new Set(fields.scopes),
    remoteIp: fields.remoteIp,
    createdAtMs: approvedAtMs,
    approvedAtMs,
    lastSeenAtMs: base - fields.lastSeenAgoMs,
    approvedVia: 'manual',
    deviceToken: `dt_${crypto.randomBytes(18).toString('hex')}`,
    pairedAt: approvedAtMs,
    tokenCreatedAtMs: approvedAtMs,
    ...(fields.node ? { node: fields.node } : {}),
  };
}

// Same devices as the in-app demo, minus Pincer itself (it shows up once it pairs): a CLI on
// another Mac that's asking for operator.admin, an Android phone that is also a node, a Mac mini
// node host, and a brand-new iPad waiting for approval.
export function createDevicePairingState(base = Date.now()) {
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const studio = makePaired('studio-macbook-pro', {
    displayName: 'Studio MacBook Pro', platform: 'darwin', deviceFamily: 'desktop', clientId: 'cli', clientMode: 'cli',
    role: OPERATOR_ROLE, roles: [OPERATOR_ROLE], scopes: ['operator.read', 'operator.write', 'operator.approvals', 'operator.pairing'],
    remoteIp: '192.168.1.24', approvedAgoMs: 40 * DAY, lastSeenAgoMs: 3 * HOUR,
  }, base);
  const pixel = makePaired('pixel-9', {
    displayName: 'Pixel 9', platform: 'android', deviceFamily: 'phone', clientId: 'openclaw-android', clientMode: 'node',
    role: 'node', roles: ['node', OPERATOR_ROLE], scopes: ['operator.read', 'operator.write'],
    remoteIp: '100.84.12.7', approvedAgoMs: 12 * DAY, lastSeenAgoMs: 2 * DAY,
    node: { version: '2026.9.1', modelIdentifier: 'Pixel 9', caps: ['camera', 'location', 'notifications'], commands: ['camera.snap', 'location.get'], connected: false },
  }, base);
  const macMini = makePaired('mac-mini-home', {
    displayName: 'Mac mini (home)', platform: 'darwin', deviceFamily: 'desktop', clientId: 'node-host', clientMode: 'node',
    role: 'node', roles: ['node'], scopes: [],
    remoteIp: '192.168.1.10', approvedAgoMs: 90 * DAY, lastSeenAgoMs: 60_000,
    node: {
      version: '2026.9.2', modelIdentifier: 'Macmini9,1', caps: ['browser', 'canvas', 'screen', 'system'],
      commands: ['system.run', 'system.which', 'browser.proxy', 'screen.record', 'canvas.present'], connected: true, connectedAgoMs: 5 * HOUR,
    },
  }, base);
  const pairedDevices = new Map([studio, pixel, macMini].map((d) => [d.deviceId, d]));
  const ipad = seededIdentity('travis-ipad');
  const pendingPairing = new Map([
    ['pair_ipad', {
      requestId: 'pair_ipad', deviceId: ipad.deviceId, publicKey: ipad.publicKey, displayName: "Travis's iPad", platform: 'ipados',
      deviceFamily: 'tablet', clientId: 'openclaw-ios', clientMode: 'ui', role: OPERATOR_ROLE, roles: [OPERATOR_ROLE],
      scopes: ['operator.read', 'operator.write', 'operator.approvals', 'operator.questions'], remoteIp: '192.168.1.31',
      silent: false, isRepair: false, ts: base - 2 * 60_000,
    }],
    ['pair_studio_admin', {
      requestId: 'pair_studio_admin', deviceId: studio.deviceId, publicKey: studio.publicKey, displayName: studio.displayName,
      platform: studio.platform, deviceFamily: studio.deviceFamily, clientId: studio.clientId, clientMode: studio.clientMode,
      role: OPERATOR_ROLE, roles: [OPERATOR_ROLE], scopes: [...studio.scopes, ADMIN_SCOPE], remoteIp: studio.remoteIp,
      silent: false, isRepair: true, ts: base - 15 * 60_000,
    }],
  ]);
  return { pairedDevices, pendingPairing };
}

export const SEEDED_PENDING_REQUEST_IDS = ['pair_ipad', 'pair_studio_admin'];

function isConnected(state, deviceId) {
  for (const conn of state.connections) {
    if (conn.authenticated && conn.deviceId === deviceId) return true;
  }
  return false;
}

function pendingView(pending) {
  const { requestId, deviceId, publicKey, displayName, platform, deviceFamily, clientId, clientMode, role, roles, scopes, remoteIp, silent, isRepair, ts } = pending;
  return JSON.parse(JSON.stringify({
    requestId, deviceId, publicKey, displayName, platform, deviceFamily, clientId, clientMode, role, roles, scopes, remoteIp, silent, isRepair, ts,
  }));
}

// Like upstream redactPairedDevice: token lifecycle summaries, never token material or approvedScopes.
function pairedView(state, device, { withConnected = true } = {}) {
  const scopes = [...device.scopes];
  const view = {
    deviceId: device.deviceId,
    publicKey: device.publicKey,
    displayName: device.displayName,
    platform: device.platform,
    deviceFamily: device.deviceFamily,
    clientId: device.clientId,
    clientMode: device.clientMode,
    role: device.role,
    roles: device.roles,
    scopes,
    remoteIp: device.remoteIp,
    operatorLabel: device.operatorLabel,
    tokens: roleList(device).map((role) => ({
      role,
      scopes: role === OPERATOR_ROLE ? scopes : [],
      createdAtMs: device.tokenCreatedAtMs ?? device.pairedAt,
      ...(device.lastSeenAtMs ? { lastUsedAtMs: device.lastSeenAtMs } : {}),
    })),
    approvedVia: device.approvedVia,
    ...(withConnected ? { connected: isConnected(state, device.deviceId) } : {}),
    createdAtMs: device.createdAtMs ?? device.pairedAt,
    approvedAtMs: device.approvedAtMs ?? device.pairedAt,
    lastSeenAtMs: device.lastSeenAtMs,
  };
  return JSON.parse(JSON.stringify(view));
}

// Fills in who a device is the first time it connects, and when it was last seen.
export function noteDeviceConnected(state, deviceId, params, remoteIp) {
  const device = state.pairedDevices.get(deviceId);
  if (!device) return;
  const client = params.client ?? {};
  device.publicKey ??= params.device?.publicKey;
  device.displayName ??= client.displayName;
  device.platform ??= client.platform;
  device.deviceFamily ??= client.deviceFamily;
  device.clientId ??= client.id;
  device.clientMode ??= client.mode;
  device.role ??= params.role ?? OPERATOR_ROLE;
  device.roles ??= [device.role];
  device.remoteIp ??= remoteIp;
  device.approvedVia ??= 'manual';
  device.lastSeenAtMs = Date.now();
}

// A device that needs pairing (or more scopes) opens a request, or refreshes its open one.
export function openPairingRequest(state, { deviceId, params, scopes, remoteIp, isRepair }, broadcast) {
  const client = params.client ?? {};
  // Like `openclaw devices`: a retry with changed role, scopes or key supersedes the open request
  // with a new requestId; an identical retry refreshes it.
  let existing = [...state.pendingPairing.values()].find((p) => p.deviceId === deviceId);
  const sameAsk = existing && existing.role === (params.role ?? OPERATOR_ROLE) && existing.publicKey === params.device?.publicKey
    && [...existing.scopes].sort().join(',') === [...scopes].sort().join(',');
  if (existing && !sameAsk) {
    state.pendingPairing.delete(existing.requestId);
    existing = undefined;
  }
  const requestId = existing?.requestId ?? `pair_${crypto.randomBytes(6).toString('hex')}`;
  const request = {
    requestId,
    deviceId,
    publicKey: params.device?.publicKey,
    displayName: client.displayName ?? 'unknown',
    platform: client.platform,
    deviceFamily: client.deviceFamily,
    clientId: client.id,
    clientMode: client.mode,
    role: params.role ?? OPERATOR_ROLE,
    roles: [params.role ?? OPERATOR_ROLE],
    scopes: [...scopes],
    remoteIp,
    silent: false,
    isRepair,
    ts: Date.now(),
  };
  state.pendingPairing.set(requestId, request);
  broadcast(state, 'device.pair.requested', pendingView(request), hasPairingScope);
  return request;
}

// Approves a pending request: pairs the device (or widens its scopes) and tells pairing clients.
export function approvePendingDevice(state, requestId, broadcast) {
  const pending = state.pendingPairing.get(requestId);
  if (!pending) return null;
  const now = Date.now();
  let device = state.pairedDevices.get(pending.deviceId);
  if (!device) {
    device = {
      deviceId: pending.deviceId,
      deviceToken: `dt_${crypto.randomBytes(18).toString('hex')}`,
      pairedAt: now,
      createdAtMs: now,
      tokenCreatedAtMs: now,
      scopes: new Set(),
    };
    state.pairedDevices.set(pending.deviceId, device);
  }
  for (const scope of pending.scopes ?? []) device.scopes.add(scope);
  for (const key of ['publicKey', 'displayName', 'platform', 'deviceFamily', 'clientId', 'clientMode', 'role', 'remoteIp']) {
    if (pending[key] !== undefined) device[key] = pending[key];
  }
  device.roles = [...new Set([...(device.roles ?? []), ...(pending.roles ?? [])])];
  device.approvedAtMs = now;
  device.approvedVia = 'manual';
  state.pendingPairing.delete(requestId);
  broadcast(state, 'device.pair.resolved', { requestId, deviceId: pending.deviceId, decision: 'approved', ts: now }, hasPairingScope);
  return { requestId, device };
}

function isObject(params) {
  return params && typeof params === 'object' && !Array.isArray(params);
}

// Closed-object validation with upstream's message shape.
function paramsError(method, params, required, optional = []) {
  if (!isObject(params)) return `invalid ${method} params: at root: must be object`;
  const allowed = new Set([...required, ...optional]);
  const extra = Object.keys(params).find((key) => !allowed.has(key));
  if (extra) return `invalid ${method} params: at root: unexpected property '${extra}'`;
  const missing = required.find((key) => !(key in params));
  if (missing) return `invalid ${method} params: at root: must have required property '${missing}'`;
  const bad = required.find((key) => typeof params[key] !== 'string' || !params[key]);
  if (bad) return `invalid ${method} params: at /${bad}: must NOT have fewer than 1 characters`;
  return null;
}

function callerAuthz(conn) {
  return {
    callerDeviceId: conn.isDeviceTokenAuth ? conn.deviceId : null,
    isAdminCaller: (conn.scopes ?? []).includes(ADMIN_SCOPE),
  };
}

function hasNonOperatorRole(record) {
  return roleList(record).some((role) => role !== OPERATOR_ROLE);
}

function nodeRecords(state) {
  return [...state.pairedDevices.values()].filter((d) => roleList(d).includes('node'));
}

function nodeView(device) {
  const node = device.node ?? {};
  const connected = node.connected === true;
  return JSON.parse(JSON.stringify({
    nodeId: device.deviceId,
    displayName: device.displayName,
    platform: device.platform,
    version: node.version,
    clientId: device.clientId,
    clientMode: device.clientMode,
    remoteIp: device.remoteIp,
    deviceFamily: device.deviceFamily,
    modelIdentifier: node.modelIdentifier,
    caps: node.caps ?? [],
    commands: node.commands ?? [],
    approvalState: 'approved',
    paired: true,
    connected,
    ...(connected && node.connectedAgoMs ? { connectedAtMs: Date.now() - node.connectedAgoMs } : {}),
    lastSeenAtMs: device.lastSeenAtMs,
  }));
}

export function handleDevicesRequest(state, conn, msg, { sendRes, sendErr, broadcast }) {
  const { id, method, params = {} } = msg;
  const isDevice = DEVICE_PAIRING_METHODS.includes(method) && !devicePairingDisabled();
  const isNode = NODE_METHODS.includes(method) && !nodesDisabled();
  if (!isDevice && !isNode) return false;
  const requiredScope = method === 'node.list' || method === 'node.describe' ? READ_SCOPE : PAIRING_SCOPE;
  if (!hasScope(conn.scopes, requiredScope)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${requiredScope}`, { code: 'MISSING_SCOPE', missingScope: requiredScope, requiredScopes: [requiredScope] });
    return true;
  }
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  const authz = callerAuthz(conn);
  const limitedToSelf = authz.callerDeviceId && !authz.isAdminCaller;

  switch (method) {
    case 'device.pair.list': {
      const error = paramsError(method, params, []);
      if (error) return invalid(error), true;
      const pending = [...state.pendingPairing.values()].filter((p) => !limitedToSelf || p.deviceId === authz.callerDeviceId);
      const paired = [...state.pairedDevices.values()].filter((d) => !limitedToSelf || d.deviceId === authz.callerDeviceId);
      sendRes(conn, id, { pending: pending.map(pendingView), paired: paired.map((d) => pairedView(state, d)) });
      return true;
    }
    case 'device.pair.approve': {
      const error = paramsError(method, params, ['requestId']);
      if (error) return invalid(error), true;
      const requestId = params.requestId.trim();
      const pending = state.pendingPairing.get(requestId);
      if (!authz.isAdminCaller) {
        if (!pending) return invalid('device pairing approval denied'), true;
        if (authz.callerDeviceId && pending.deviceId !== authz.callerDeviceId) return invalid('device pairing approval denied'), true;
        if (hasNonOperatorRole(pending)) return invalid('device pairing approval denied'), true;
      }
      if (!pending) return invalid('unknown requestId'), true;
      const missing = (pending.scopes ?? []).find((scope) => scope.startsWith('operator.') && !hasScope(conn.scopes, scope));
      if (missing) return invalid(`missing scope: ${missing}`), true;
      const approved = approvePendingDevice(state, requestId, broadcast);
      sendRes(conn, id, { requestId, device: pairedView(state, approved.device, { withConnected: false }) });
      return true;
    }
    case 'device.pair.reject': {
      const error = paramsError(method, params, ['requestId']);
      if (error) return invalid(error), true;
      const requestId = params.requestId.trim();
      const pending = state.pendingPairing.get(requestId);
      if (limitedToSelf && (!pending || pending.deviceId !== authz.callerDeviceId)) return invalid('device pairing rejection denied'), true;
      if (!pending) return invalid('unknown requestId'), true;
      state.pendingPairing.delete(requestId);
      broadcast(state, 'device.pair.resolved', { requestId, deviceId: pending.deviceId, decision: 'rejected', ts: Date.now() }, hasPairingScope);
      sendRes(conn, id, { requestId, deviceId: pending.deviceId });
      return true;
    }
    case 'device.pair.remove':
    case 'device.pair.rename': {
      const remove = method === 'device.pair.remove';
      const error = paramsError(method, params, remove ? ['deviceId'] : ['deviceId', 'label']);
      if (error) return invalid(error), true;
      if (!remove && params.label.length > 64) return invalid(`invalid ${method} params: at /label: must NOT have more than 64 characters`), true;
      const deviceId = params.deviceId.trim();
      const denied = `device pairing ${remove ? 'removal' : 'rename'} denied`;
      if (limitedToSelf && deviceId !== authz.callerDeviceId) return invalid(denied), true;
      const device = state.pairedDevices.get(deviceId);
      if (authz.callerDeviceId && !authz.isAdminCaller && device && hasNonOperatorRole(device)) return invalid(denied), true;
      if (!remove) {
        const label = params.label.trim();
        if (!label) return invalid('label required'), true;
        if (!device) return invalid('unknown deviceId'), true;
        device.operatorLabel = label;
        broadcast(state, 'device.pair.changed', {}, hasPairingScope);
        sendRes(conn, id, { deviceId, label });
        return true;
      }
      if (!device) return invalid('unknown deviceId'), true;
      state.pairedDevices.delete(deviceId);
      for (const [requestId, pending] of state.pendingPairing) {
        if (pending.deviceId === deviceId) state.pendingPairing.delete(requestId);
      }
      sendRes(conn, id, { deviceId });
      // Like the Gateway, the removed device's connections (maybe this one) go right after the reply.
      queueMicrotask(() => {
        for (const other of state.connections) {
          if (other.deviceId === deviceId) other.ws.close(1008, 'device removed');
        }
      });
      return true;
    }
    case 'node.list': {
      const error = paramsError(method, params, []);
      if (error) return invalid(error), true;
      const nodes = nodeRecords(state).map(nodeView);
      sendRes(conn, id, { ts: Date.now(), nodes });
      return true;
    }
    case 'node.describe': {
      const error = paramsError(method, params, ['nodeId']);
      if (error) return invalid(error), true;
      const device = nodeRecords(state).find((d) => d.deviceId === params.nodeId.trim());
      if (!device) return invalid('unknown nodeId'), true;
      sendRes(conn, id, { ts: Date.now(), ...nodeView(device) });
      return true;
    }
    case 'node.rename': {
      const error = paramsError(method, params, ['nodeId', 'displayName']);
      if (error) return invalid(error), true;
      const nodeId = params.nodeId.trim();
      if (limitedToSelf && nodeId !== authz.callerDeviceId) return invalid('node rename denied'), true;
      const displayName = params.displayName.trim();
      if (!displayName) return invalid('displayName required'), true;
      const device = nodeRecords(state).find((d) => d.deviceId === nodeId);
      if (!device) return invalid('unknown nodeId'), true;
      device.displayName = displayName;
      sendRes(conn, id, { nodeId, displayName });
      return true;
    }
    case 'node.pair.remove': {
      const error = paramsError(method, params, ['nodeId']);
      if (error) return invalid(error), true;
      const nodeId = params.nodeId.trim();
      const device = nodeRecords(state).find((d) => d.deviceId === nodeId);
      if (!device) return invalid('unknown nodeId'), true;
      if (limitedToSelf && (nodeId !== authz.callerDeviceId || hasNonOperatorRole(device))) return invalid('node pairing removal denied'), true;
      // Revokes the node role; a device left with no role is gone.
      device.roles = roleList(device).filter((role) => role !== 'node');
      device.role = device.roles[0];
      delete device.node;
      if (device.roles.length === 0) state.pairedDevices.delete(nodeId);
      broadcast(state, 'node.pair.resolved', { requestId: '', nodeId, decision: 'removed', ts: Date.now() }, hasPairingScope);
      sendRes(conn, id, { nodeId });
      return true;
    }
    default:
      return false;
  }
}
