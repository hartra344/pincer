// Connect auth and pairing-required errors, shaped like the Gateway's
// (packages/gateway-protocol/src/connect-error-details.ts, src/gateway/server/ws-connection/
// auth-messages.ts, connect-auth.ts and handshake-auth-helpers.ts).
//
// Connect auth failures answer `INVALID_REQUEST` with a human message, `details.code`
// (AUTH_TOKEN_MISMATCH, ...), `details.authReason`, `canRetryWithDeviceToken` and
// `recommendedNextStep`, then close the socket with 1008. An unapproved device gets
// `NOT_PAIRED` / `PAIRING_REQUIRED` with the request id (devices.mjs keeps one open request per
// device). Rejecting a request just deletes it (upstream has no "rejected" connect error), so
// the next connect opens a new request id.
import { hasPairingScope } from './devices.mjs';

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

export function pairingRequiredError({ requestId, deviceId, reason, requestedScopes }, approvedScopes) {
  return {
    code: 'NOT_PAIRED',
    message: `pairing required (requestId: ${requestId})`,
    details: {
      code: 'PAIRING_REQUIRED',
      reason,
      requestId,
      remediationHint: reason === 'scope-upgrade' ? SCOPE_UPGRADE_HINT : NOT_PAIRED_HINT,
      deviceId,
      requestedRole: 'operator',
      requestedScopes,
      ...(approvedScopes ? { approvedScopes } : {}),
    },
  };
}

/// Deletes a pending request and tells pairing-scoped operators, like `device.pair.reject`.
export function rejectPendingDevice(state, requestId, broadcast) {
  const pending = state.pendingPairing.get(requestId);
  if (!pending) return undefined;
  state.pendingPairing.delete(requestId);
  console.log(`Pairing rejected ${requestId}`);
  broadcast(state, 'device.pair.resolved', { requestId, deviceId: pending.deviceId, decision: 'rejected', ts: Date.now() }, hasPairingScope);
  return pending;
}
