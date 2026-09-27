// Operator device pairing and connect auth, shaped like the Gateway's
// (packages/gateway-protocol/src/connect-error-details.ts, src/gateway/server/ws-connection/
// auth-messages.ts + connect-auth.ts, src/gateway/server-methods/devices.ts).
//
// Connect auth failures answer `INVALID_REQUEST` with a human message, `details.code`
// (AUTH_TOKEN_MISMATCH, ...), `details.authReason`, `canRetryWithDeviceToken` and
// `recommendedNextStep`, then close the socket with 1008. An unapproved device gets
// `NOT_PAIRED` / `PAIRING_REQUIRED` with the request id; retrying with the same scopes reuses
// the pending request, changed scopes replace it. Rejecting a request just deletes it (there is
// no "rejected" connect error upstream), so the next connect opens a new request id.
//
// device.pair.list / device.pair.approve / device.pair.reject need operator.pairing
// (operator.admin covers it) and broadcast device.pair.requested / device.pair.resolved, so a
// check can approve or reject from a second, already-paired connection. Simplified: no
// per-device self-scoping for non-admin callers and no paired-device redaction details.
export const DEVICE_PAIRING_METHODS = ['device.pair.list', 'device.pair.approve', 'device.pair.reject'];
export const DEVICE_PAIRING_EVENTS = ['device.pair.requested', 'device.pair.resolved'];
const PAIRING_SCOPE = 'operator.pairing';
const ADMIN_SCOPE = 'operator.admin';

const NOT_PAIRED_HINT = 'Approve this device from the pending pairing requests.';
const SCOPE_UPGRADE_HINT = 'Review the requested scopes, then approve the pending upgrade.';

// Upstream `resolveAuthConnectErrorDetailCode` + `formatGatewayAuthFailureMessage` for a
// non-CLI, non-Control-UI client, and `resolveUnauthorizedHandshakeContext` for the hints.
const AUTH_FAILURES = {
  token_missing: { code: 'AUTH_TOKEN_MISSING', message: 'unauthorized: gateway token missing (provide gateway auth token)', next: 'update_auth_configuration' },
  token_mismatch: { code: 'AUTH_TOKEN_MISMATCH', message: 'unauthorized: gateway token mismatch (provide gateway auth token)', next: 'update_auth_credentials' },
  token_missing_config: { code: 'AUTH_TOKEN_NOT_CONFIGURED', message: 'unauthorized: gateway token not configured on gateway (set gateway.auth.token)', next: 'update_auth_configuration' },
  password_missing: { code: 'AUTH_PASSWORD_MISSING', message: 'unauthorized: gateway password missing (provide gateway auth password)', next: 'update_auth_configuration' },
  password_mismatch: { code: 'AUTH_PASSWORD_MISMATCH', message: 'unauthorized: gateway password mismatch (provide gateway auth password)', next: 'update_auth_credentials' },
  password_missing_config: { code: 'AUTH_PASSWORD_NOT_CONFIGURED', message: 'unauthorized: gateway password not configured on gateway (set gateway.auth.password)', next: 'update_auth_configuration' },
  device_token_mismatch: { code: 'AUTH_DEVICE_TOKEN_MISMATCH', message: 'unauthorized: device token mismatch (rotate/reissue device token)', next: 'update_auth_credentials' },
  rate_limited: { code: 'AUTH_RATE_LIMITED', message: 'unauthorized: too many failed authentication attempts (retry later)', next: 'wait_then_retry' },
};
export const AUTH_FAILURE_CODES = Object.fromEntries(Object.entries(AUTH_FAILURES).map(([reason, f]) => [reason, f.code]));
export const RATE_LIMIT_RETRY_AFTER_MS = 60_000;

/// Which failure (if any) a connect's `auth` gets. `mode` is the mock's gateway.auth.mode:
/// token, password or none. Either wire field may carry the configured shared secret, and an
/// issued device token always works.
export function checkConnectAuth(auth = {}, { mode, token, password, issuedDeviceToken }) {
  const sentToken = typeof auth.token === 'string' ? auth.token : '';
  const sentPassword = typeof auth.password === 'string' ? auth.password : '';
  if (issuedDeviceToken && sentToken === issuedDeviceToken) return undefined;
  if (mode === 'none') return undefined;
  const secret = mode === 'password' ? password : token;
  const kind = mode === 'password' ? 'password' : 'token';
  if (!secret) return `${kind}_missing_config`;
  if ((sentToken && sentToken === secret) || (sentPassword && sentPassword === secret)) return undefined;
  if (sentToken.startsWith('dt_') && !sentPassword) return 'device_token_mismatch';
  const provided = mode === 'password' ? sentPassword || sentToken : sentToken || sentPassword;
  return provided ? `${kind}_mismatch` : `${kind}_missing`;
}

/// Sends the upstream-shaped auth rejection and closes the socket like the Gateway does.
export function rejectConnectAuth(conn, id, reason, { sendJson, auth = {}, hasDeviceIdentity = true }) {
  const failure = AUTH_FAILURES[reason];
  const canRetryWithDeviceToken = reason === 'token_mismatch' && hasDeviceIdentity && Boolean(auth.token) && !auth.deviceToken;
  const error = {
    code: 'INVALID_REQUEST',
    message: failure.message,
    ...(reason === 'rate_limited' ? { retryable: true, retryAfterMs: RATE_LIMIT_RETRY_AFTER_MS } : {}),
    details: {
      code: failure.code,
      authReason: reason,
      canRetryWithDeviceToken,
      recommendedNextStep: canRetryWithDeviceToken ? 'retry_with_device_token' : failure.next,
    },
  };
  sendJson(conn.ws, { type: 'res', id, ok: false, error });
  conn.ws.close(1008, failure.message.slice(0, 120));
}

function sameScopes(a = [], b = []) {
  return a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',');
}

/// Parks (or reuses) a pending pairing request for this device and returns it.
export function openPairingRequest(state, { deviceId, scopes, grantScopes, displayName, reason, makeId, now = Date.now() }) {
  for (const [requestId, pending] of state.pendingPairing) {
    if (pending.deviceId !== deviceId) continue;
    if (pending.reason === reason && sameScopes(pending.requestedScopes, scopes)) return { request: pending, created: false };
    // Changed scopes supersede the old request, like `openclaw devices list` shows.
    state.pendingPairing.delete(requestId);
  }
  const request = { requestId: makeId(), deviceId, reason, requestedScopes: [...scopes], scopes: grantScopes, displayName, createdAt: now };
  state.pendingPairing.set(request.requestId, request);
  return { request, created: true };
}

export function pairingRequiredError(request, approvedScopes) {
  return {
    code: 'NOT_PAIRED',
    message: `pairing required (requestId: ${request.requestId})`,
    details: {
      code: 'PAIRING_REQUIRED',
      reason: request.reason,
      requestId: request.requestId,
      remediationHint: request.reason === 'scope-upgrade' ? SCOPE_UPGRADE_HINT : NOT_PAIRED_HINT,
      deviceId: request.deviceId,
      requestedRole: 'operator',
      requestedScopes: request.requestedScopes,
      ...(approvedScopes ? { approvedScopes } : {}),
    },
  };
}

function pendingRow(request) {
  return {
    requestId: request.requestId,
    deviceId: request.deviceId,
    displayName: request.displayName,
    role: 'operator',
    scopes: [...request.requestedScopes],
    reason: request.reason,
    ts: request.createdAt,
  };
}

function hasPairingScope(conn) {
  const scopes = conn.scopes ?? [];
  return scopes.includes(PAIRING_SCOPE) || scopes.includes(ADMIN_SCOPE);
}

/// Deletes a pending request and tells pairing-scoped operators. Returns the request or undefined.
export function rejectPairing(state, requestId, broadcast) {
  const pending = state.pendingPairing.get(requestId);
  if (!pending) return undefined;
  state.pendingPairing.delete(requestId);
  console.log(`Pairing rejected ${requestId}`);
  broadcast(state, 'device.pair.resolved', { requestId, deviceId: pending.deviceId, decision: 'rejected', ts: Date.now() }, hasPairingScope);
  return pending;
}

export function announcePairingRequest(state, request, broadcast) {
  broadcast(state, 'device.pair.requested', pendingRow(request), hasPairingScope);
}

export function handleDevicePairingRequest(state, conn, msg, { sendRes, sendErr, broadcast, approvePairing }) {
  const { id, method, params = {} } = msg;
  if (!DEVICE_PAIRING_METHODS.includes(method)) return false;
  if (!hasPairingScope(conn)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${PAIRING_SCOPE}`, { code: 'MISSING_SCOPE', missingScope: PAIRING_SCOPE, requiredScopes: [PAIRING_SCOPE] });
    return true;
  }
  if (method === 'device.pair.list') {
    const paired = [...state.pairedDevices].map(([deviceId, d]) => ({
      deviceId,
      role: 'operator',
      scopes: [...d.scopes],
      approvedAtMs: d.pairedAt,
      connected: [...state.connections].some((c) => c.authenticated && c.deviceId === deviceId),
    }));
    sendRes(conn, id, { pending: [...state.pendingPairing.values()].map(pendingRow), paired });
    return true;
  }
  const requestId = typeof params.requestId === 'string' ? params.requestId.trim() : '';
  if (!requestId) {
    sendErr(conn, id, 'INVALID_REQUEST', `invalid ${method} params: requestId required`);
    return true;
  }
  const pending = state.pendingPairing.get(requestId);
  if (!pending) {
    sendErr(conn, id, 'INVALID_REQUEST', 'unknown requestId');
    return true;
  }
  if (method === 'device.pair.reject') {
    rejectPairing(state, requestId, broadcast);
    sendRes(conn, id, pendingRow(pending));
    return true;
  }
  approvePairing(state, requestId);
  const device = state.pairedDevices.get(pending.deviceId);
  sendRes(conn, id, { requestId, device: { deviceId: pending.deviceId, role: 'operator', scopes: [...(device?.scopes ?? [])] } });
  return true;
}
