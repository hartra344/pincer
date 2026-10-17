// Node-role connections ("device mode"): a paired device that also connects as role `node`,
// declares caps/commands/permissions, and answers `node.invoke` requests from operators.
// Mirrors upstream src/gateway/server-methods/nodes.invoke.ts (node.invoke, node.invoke.result),
// nodes.pairing.ts (node.pair.list/approve/reject/remove), node-command-policy.ts
// (isNodeCommandAllowed), node-invoke-request.ts (the `node.invoke.request` event) and
// packages/gateway-protocol/src/schema/nodes.ts.
//
// Pairing: a node connect follows the same path as an operator connect. A device without the
// `node` role gets NOT_PAIRED / PAIRING_REQUIRED (reason `role-upgrade` when it is already paired
// as an operator, `not-paired` otherwise) and the mock's MOCK_PAIRING policy (auto after
// MOCK_PAIRING_DELAY_MS, manual, reject, ...) decides, so a node never skips approval. The first
// node connect after approval records the declared surface as approved; later connects that add
// commands keep the approved set and park a node pairing request (`node.pair.requested`) until
// `node.pair.approve`. Node sockets only receive node events, never operator broadcasts.
import { randHex, sendErr, sendEvent, sendRes } from './util.mjs';

export const NODE_INVOKE_METHODS = ['node.invoke', 'node.pair.list', 'node.pair.approve', 'node.pair.reject'];
export const NODE_ROLE_METHODS = ['node.invoke.result'];
export const NODE_EVENTS = ['node.invoke.request'];

// Upstream platform default allowlist for ios/macos (node-command-policy.ts); anything else a
// node declares never becomes invocable.
const PLATFORM_ALLOWLIST = new Set([
  'location.get', 'device.info', 'device.status', 'contacts.search', 'calendar.events', 'reminders.list',
  'photos.latest', 'motion.activity', 'motion.pedometer',
]);
const DEFAULT_INVOKE_TIMEOUT_MS = 30_000;

// devices.mjs imports this module, so the pairing-scope check lives here too.
function hasPairingScope(conn) {
  return hasScope(conn, 'operator.pairing');
}

export function pendingNodeRequestId(state, nodeId) {
  return [...pendingNodes(state).values()].find((p) => p.nodeId === nodeId)?.requestId;
}

export function isNodeConn(conn) {
  return conn.role === 'node';
}

export function filterDeclaredCommands(commands) {
  const list = Array.isArray(commands) ? commands : [];
  return [...new Set(list.filter((c) => typeof c === 'string' && PLATFORM_ALLOWLIST.has(c)))].sort();
}

function pendingNodes(state) {
  return (state.pendingNodePairing ??= new Map());
}

function invokes(state) {
  return (state.nodeInvokes ??= new Map());
}

export function nodeConnections(state, nodeId) {
  return [...state.connections].filter((c) => c.authenticated && isNodeConn(c) && c.deviceId === nodeId);
}

export function liveNodeConnection(state, nodeId) {
  return nodeConnections(state, nodeId).at(-1);
}

export function hasNodeRole(device) {
  return Boolean(device) && [device.role, ...(device.roles ?? [])].includes('node');
}

/// The node token: separate from the operator token, issued the first time a paired node connects.
export function nodeTokenFor(state, deviceId) {
  const device = state.pairedDevices.get(deviceId);
  device.nodeToken ??= `dt_${randHex(18)}`;
  return device.nodeToken;
}

function sameSet(a, b) {
  return a.length === b.length && a.every((v) => b.includes(v));
}

function pendingView(request) {
  return JSON.parse(JSON.stringify(request));
}

/// Registers an authenticated node connection (the caller already verified signature, auth and
/// role pairing). Records the declared surface and parks a request if it needs new approval.
export function attachNode(state, conn, params, broadcast) {
  const device = state.pairedDevices.get(conn.deviceId);
  const client = params.client ?? {};
  const declared = filterDeclaredCommands(params.commands);
  const caps = Array.isArray(params.caps) ? params.caps.filter((c) => typeof c === 'string') : [];
  const permissions = params.permissions && typeof params.permissions === 'object' && !Array.isArray(params.permissions) ? { ...params.permissions } : {};
  for (const other of nodeConnections(state, conn.deviceId)) other.ws.close(1008, 'node replaced');
  device.node ??= { commands: declared, caps, connected: false };
  const approved = device.node.commands ?? [];
  Object.assign(device.node, { version: client.version, modelIdentifier: client.modelIdentifier, permissions, connected: true, connectedAtMs: Date.now() });
  if (declared.some((c) => !approved.includes(c))) {
    const requestId = `nodepair_${randHex(6)}`;
    for (const [id, pending] of pendingNodes(state)) if (pending.nodeId === conn.deviceId) pendingNodes(state).delete(id);
    const request = {
      requestId, nodeId: conn.deviceId, displayName: client.displayName, platform: client.platform, version: client.version,
      caps, commands: declared, remoteIp: conn.ws._socket?.remoteAddress, ts: Date.now(),
    };
    pendingNodes(state).set(requestId, request);
    broadcast(state, 'node.pair.requested', pendingView(request), hasPairingScope);
  }
  conn.role = 'node';
  conn.nodeSurface = { caps, declared, permissions };
}

export function detachNode(state, conn) {
  if (!isNodeConn(conn) || !conn.deviceId) return;
  const device = state.pairedDevices.get(conn.deviceId);
  if (device?.node && nodeConnections(state, conn.deviceId).filter((c) => c !== conn).length === 0) device.node.connected = false;
  for (const [id, call] of invokes(state)) {
    if (call.conn === conn) {
      invokes(state).delete(id);
      clearTimeout(call.timer);
      call.fail('UNAVAILABLE', 'node disconnected', { code: 'NOT_CONNECTED', nodeCommandDispatched: true });
    }
  }
}

/// Commands the node may be invoked with right now: approved surface ∩ currently declared.
function effectiveCommands(state, nodeId, conn) {
  const approved = state.pairedDevices.get(nodeId)?.node?.commands ?? [];
  return conn.nodeSurface.declared.filter((c) => approved.includes(c));
}

/// Closes node sockets and drops pending node requests for a device (node.pair.remove, device removal).
export function dropNode(state, nodeId) {
  for (const [id, pending] of pendingNodes(state)) if (pending.nodeId === nodeId) pendingNodes(state).delete(id);
  for (const conn of nodeConnections(state, nodeId)) conn.ws.close(1008, 'node removed');
}

function objectError(method, params, required) {
  if (!params || typeof params !== 'object' || Array.isArray(params)) return `invalid ${method} params: at root: must be object`;
  const missing = required.find((key) => typeof params[key] !== 'string' || !params[key]);
  return missing ? `invalid ${method} params: at /${missing}: must NOT have fewer than 1 characters` : null;
}

/// Requests from a node-role socket. Only node.invoke.result is meaningful.
export function handleNodeRoleRequest(state, conn, msg) {
  const { id, method, params } = msg;
  if (method !== 'node.invoke.result') {
    sendErr(conn, id, 'INVALID_REQUEST', 'unauthorized role: node');
    return;
  }
  const error = objectError(method, params, ['id', 'nodeId']);
  if (error || typeof params.ok !== 'boolean') {
    sendErr(conn, id, 'INVALID_REQUEST', error ?? `invalid ${method} params: at /ok: must be boolean`);
    return;
  }
  const call = invokes(state).get(params.id);
  // Late or foreign results are ignored, like upstream.
  if (!call || call.conn !== conn || params.nodeId !== conn.deviceId) {
    sendRes(conn, id, { ok: true, ignored: true });
    return;
  }
  invokes(state).delete(params.id);
  clearTimeout(call.timer);
  if (params.ok) call.succeed(params.payloadJSON ?? null, params.payload);
  else call.fail('UNAVAILABLE', nodeErrorMessage(params.error), { nodeError: params.error ?? null, nodeCommandDispatched: true });
  sendRes(conn, id, { ok: true });
}

function nodeErrorMessage(error) {
  const message = error?.message || 'node invoke failed';
  return error?.code ? `${error.code}: ${message}` : message;
}

function parsePayload(payloadJSON) {
  if (!payloadJSON) return undefined;
  try { return JSON.parse(payloadJSON); } catch { return undefined; }
}

function hasScope(conn, scope) {
  const scopes = conn.scopes ?? [];
  return scopes.includes(scope) || scopes.includes('operator.admin');
}

/// Operator-side node methods; returns true when it handled `msg`.
export function handleNodeOperatorRequest(state, conn, msg, { broadcast }) {
  const { id, method, params = {} } = msg;
  if (!NODE_INVOKE_METHODS.includes(method)) return false;
  const required = method === 'node.invoke' ? 'operator.write' : 'operator.pairing';
  const allowed = method === 'node.invoke' ? hasScope(conn, 'operator.write') : hasScope(conn, 'operator.pairing');
  if (!allowed) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${required}`, { code: 'MISSING_SCOPE', missingScope: required, requiredScopes: [required] });
    return true;
  }
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  switch (method) {
    case 'node.invoke':
      invokeNode(state, conn, id, params, invalid);
      return true;
    case 'node.pair.list': {
      const paired = [...state.pairedDevices.values()].filter((d) => hasNodeRole(d) && d.node)
        .map((d) => ({ nodeId: d.deviceId, displayName: d.displayName, platform: d.platform, version: d.node.version, caps: d.node.caps ?? [], commands: d.node.commands ?? [] }));
      sendRes(conn, id, { pending: [...pendingNodes(state).values()].map(pendingView), paired });
      return true;
    }
    case 'node.pair.approve':
    case 'node.pair.reject': {
      const error = objectError(method, params, ['requestId']);
      if (error) return invalid(error), true;
      const requestId = params.requestId.trim();
      const pending = pendingNodes(state).get(requestId);
      if (!pending) return invalid('unknown requestId'), true;
      pendingNodes(state).delete(requestId);
      const approve = method === 'node.pair.approve';
      const resolved = { requestId, nodeId: pending.nodeId, decision: approve ? 'approved' : 'rejected', ts: Date.now() };
      const device = state.pairedDevices.get(pending.nodeId);
      if (approve && device?.node) {
        device.node.commands = pending.commands;
        device.node.caps = pending.caps;
        // The live session picks up the approved surface immediately; the node gets the event too.
        const live = liveNodeConnection(state, pending.nodeId);
        if (live) sendEvent(live, 'node.pair.resolved', resolved);
      }
      broadcast(state, 'node.pair.resolved', resolved, hasPairingScope);
      sendRes(conn, id, approve ? { requestId, node: { nodeId: pending.nodeId, displayName: pending.displayName, platform: pending.platform, caps: pending.caps, commands: pending.commands } } : { requestId, nodeId: pending.nodeId });
      return true;
    }
    default:
      return false;
  }
}

function invokeNode(state, conn, id, params, invalid) {
  const closed = ['nodeId', 'command', 'params', 'timeoutMs', 'idempotencyKey', 'sessionKey'];
  if (!params || typeof params !== 'object' || Array.isArray(params)) return invalid('invalid node.invoke params: at root: must be object');
  const extra = Object.keys(params).find((k) => !closed.includes(k));
  if (extra) return invalid(`invalid node.invoke params: at root: unexpected property '${extra}'`);
  for (const key of ['nodeId', 'command', 'idempotencyKey']) {
    if (typeof params[key] !== 'string' || !params[key]) return invalid(`invalid node.invoke params: at /${key}: must have required property '${key}'`);
  }
  if (params.timeoutMs !== undefined && (!Number.isInteger(params.timeoutMs) || params.timeoutMs < 0)) return invalid('invalid node.invoke params: at /timeoutMs: must be integer >= 0');
  const nodeId = params.nodeId.trim();
  const command = params.command.trim();
  const device = state.pairedDevices.get(nodeId);
  if (!hasNodeRole(device)) {
    return sendErr(conn, id, 'UNAVAILABLE', 'node pairing changed while invocation was active', { code: 'PAIRING_CHANGED', retryable: true });
  }
  const live = liveNodeConnection(state, nodeId);
  if (!live) {
    return sendErr(conn, id, 'UNAVAILABLE', 'node not connected', { code: 'NOT_CONNECTED', nodeError: { code: 'NOT_CONNECTED', message: 'node not connected' }, nodeCommandDispatched: false });
  }
  const commands = effectiveCommands(state, nodeId, live);
  // upstream isNodeCommandAllowed: allowlist first, then "declared"
  let reason;
  if (!command) reason = 'command required';
  else if (!PLATFORM_ALLOWLIST.has(command)) reason = 'command not allowlisted';
  else if (commands.length === 0) reason = 'node did not declare commands';
  else if (!commands.includes(command)) reason = 'command not declared by node';
  if (reason) return sendErr(conn, id, 'INVALID_REQUEST', reason, { reason, command });

  const invokeId = `invoke_${randHex(8)}`;
  const timeoutMs = params.timeoutMs && params.timeoutMs > 0 ? params.timeoutMs : DEFAULT_INVOKE_TIMEOUT_MS;
  const call = {
    conn: live,
    succeed: (payloadJSON, payload) => sendRes(conn, id, { ok: true, nodeId, command, payload: payloadJSON ? parsePayload(payloadJSON) : payload, payloadJSON: payloadJSON ?? null }),
    fail: (code, message, details) => sendErr(conn, id, code, message, details),
  };
  call.timer = setTimeout(() => {
    invokes(state).delete(invokeId);
    sendErr(conn, id, 'UNAVAILABLE', 'TIMEOUT: node invoke timed out', { nodeError: { code: 'TIMEOUT', message: 'node invoke timed out' }, nodeCommandDispatched: true });
  }, timeoutMs);
  invokes(state).set(invokeId, call);
  sendEvent(live, 'node.invoke.request', {
    id: invokeId, nodeId, command, paramsJSON: params.params === undefined ? null : JSON.stringify(params.params), timeoutMs, idempotencyKey: params.idempotencyKey,
  });
}
