import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { startServer } from '../server.mjs';
import { makeDevice, BASE_SCOPES, connectClient, rawConnect } from './helpers.mjs';

function assertAuthError(res, detailCode, authReason, nextStep, message) {
  assert.equal(res.connectRes.ok, false, JSON.stringify(res.connectRes));
  const { error } = res.connectRes;
  assert.equal(error.code, 'INVALID_REQUEST');
  assert.equal(error.details.code, detailCode);
  assert.equal(error.details.authReason, authReason);
  assert.equal(error.details.recommendedNextStep, nextStep);
  assert.equal(typeof error.details.canRetryWithDeviceToken, 'boolean');
  if (message) assert.equal(error.message, message);
  assert.equal(res.closeCode, 1008, 'auth failures close the socket');
}


// First-run modes: auth failures, password auth, pairing waits/rejections, non-Gateway servers.
export async function run() {
  const tokenServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${tokenServer.address().port}`;
    const device = makeDevice();
    assertAuthError(await rawConnect(url, device, { token: 'nope' }), 'AUTH_TOKEN_MISMATCH', 'token_mismatch', 'retry_with_device_token',
      'unauthorized: gateway token mismatch (provide gateway auth token)');
    assertAuthError(await rawConnect(url, device, {}), 'AUTH_TOKEN_MISSING', 'token_missing', 'update_auth_configuration',
      'unauthorized: gateway token missing (provide gateway auth token)');
    assertAuthError(await rawConnect(url, device, { password: 'nope' }), 'AUTH_TOKEN_MISMATCH', 'token_mismatch', 'update_auth_credentials');
    assertAuthError(await rawConnect(url, device, { token: 'dt_forged' }), 'AUTH_DEVICE_TOKEN_MISMATCH', 'device_token_mismatch', 'update_auth_credentials');
    const ok = await rawConnect(url, device, { token: 'dev-token' });
    assert.equal(ok.connectRes.ok, true);
    assert.equal(ok.connectRes.payload.server.version, 'mock-2026.1');
    assert.deepEqual(ok.connectRes.payload.auth.scopes, BASE_SCOPES);
    ok.ws.close();
    // The shared secret may ride in either wire field.
    const viaPassword = await rawConnect(url, makeDevice(), { password: 'dev-token' });
    assert.equal(viaPassword.connectRes.ok, true);
    viaPassword.ws.close();
  } finally {
    await tokenServer.close();
  }

  const passwordServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', auth: 'password', mockPassword: 'hunter2' });
  try {
    const url = `ws://127.0.0.1:${passwordServer.address().port}`;
    const device = makeDevice();
    assertAuthError(await rawConnect(url, device, { password: 'wrong' }), 'AUTH_PASSWORD_MISMATCH', 'password_mismatch', 'update_auth_credentials',
      'unauthorized: gateway password mismatch (provide gateway auth password)');
    assertAuthError(await rawConnect(url, device, {}), 'AUTH_PASSWORD_MISSING', 'password_missing', 'update_auth_configuration');
    assertAuthError(await rawConnect(url, device, { token: 'dev-token' }), 'AUTH_PASSWORD_MISMATCH', 'password_mismatch', 'update_auth_credentials');
    const ok = await rawConnect(url, device, { password: 'hunter2' });
    assert.equal(ok.connectRes.ok, true, JSON.stringify(ok.connectRes));
    const deviceToken = ok.connectRes.payload.auth.deviceToken;
    ok.ws.close();
    const reconnect = await rawConnect(url, device, { token: deviceToken, password: 'wrong' });
    assert.equal(reconnect.connectRes.ok, true, 'the issued device token wins');
    reconnect.ws.close();
  } finally {
    await passwordServer.close();
  }

  const noSecret = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: '' });
  try {
    const url = `ws://127.0.0.1:${noSecret.address().port}`;
    assertAuthError(await rawConnect(url, makeDevice(), { token: 'x' }), 'AUTH_TOKEN_NOT_CONFIGURED', 'token_missing_config', 'update_auth_configuration');
  } finally {
    await noSecret.close();
  }

  const openServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', auth: 'none' });
  try {
    const res = await rawConnect(`ws://127.0.0.1:${openServer.address().port}`, makeDevice(), {});
    assert.equal(res.connectRes.ok, true);
    res.ws.close();
  } finally {
    await openServer.close();
  }

  const limited = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', authRateLimit: 2 });
  try {
    const url = `ws://127.0.0.1:${limited.address().port}`;
    const device = makeDevice();
    await rawConnect(url, device, { token: 'a' });
    await rawConnect(url, device, { token: 'b' });
    const blocked = await rawConnect(url, device, { token: 'dev-token' });
    assertAuthError(blocked, 'AUTH_RATE_LIMITED', 'rate_limited', 'wait_then_retry',
      'unauthorized: too many failed authentication attempts (retry later)');
    assert.equal(blocked.connectRes.error.retryable, true);
    assert.ok(blocked.connectRes.error.retryAfterMs > 0);
  } finally {
    await limited.close();
  }

  const newer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', protocol: 5 });
  try {
    const res = await rawConnect(`ws://127.0.0.1:${newer.address().port}`, makeDevice(), { token: 'dev-token' });
    assert.equal(res.connectRes.error.code, 'INVALID_REQUEST');
    assert.equal(res.connectRes.error.message, 'protocol mismatch');
    assert.equal(res.connectRes.error.details.code, 'PROTOCOL_MISMATCH');
    assert.equal(res.connectRes.error.details.expectedProtocol, 5);
    assert.equal(res.closeCode, 1002);
  } finally {
    await newer.close();
  }

  const silent = await startServer({ host: '127.0.0.1', port: 0, challenge: 'off' });
  try {
    const res = await rawConnect(`ws://127.0.0.1:${silent.address().port}`, makeDevice(), { token: 'dev-token' }, BASE_SCOPES, { waitChallengeMs: 500 });
    assert.equal(res.challenge, undefined, 'MOCK_CHALLENGE=off never sends connect.challenge');
    assert.deepEqual(res.events, []);
  } finally {
    await silent.close();
  }

  // Manual pairing: the request id stays put across retries, and a paired operator approves it.
  const manual = await startServer({ host: '127.0.0.1', port: 0, pairing: 'manual', stdin: false });
  try {
    const url = `ws://127.0.0.1:${manual.address().port}`;
    const admin = makeDevice();
    manual.state.pairedDevices.set(admin.id, { deviceToken: 'dt_admin', pairedAt: Date.now(), scopes: new Set(['operator.admin']) });
    const approver = await connectClient(url, admin, 'dt_admin', true, ['operator.read', 'operator.admin']);
    const reader = await connectClient(url, admin, 'dt_admin', true, ['operator.read']);
    assert.ok(approver.hello.features.methods.includes('device.pair.approve'));
    assert.equal((await approver.send('device.pair.list')).pending.length, 2, 'seeded requests');
    assert.ok(approver.hello.features.events.includes('device.pair.resolved'));
    assert.equal((await reader.call('device.pair.list')).error.details.missingScope, 'operator.pairing');

    const device = makeDevice();
    const requested = approver.waitEvent('device.pair.requested');
    const first = await rawConnect(url, device, { token: 'dev-token' });
    const { error } = first.connectRes;
    assert.equal(error.code, 'NOT_PAIRED');
    assert.equal(error.details.code, 'PAIRING_REQUIRED');
    assert.equal(error.details.reason, 'not-paired');
    assert.equal(error.details.deviceId, device.id);
    assert.equal(error.details.remediationHint, 'Approve this device from the pending pairing requests.');
    assert.match(error.message, new RegExp(`requestId: ${error.details.requestId}`));
    assert.equal(first.closeCode, 1008);
    const requestId = error.details.requestId;
    assert.equal((await requested).requestId, requestId);
    const again = await rawConnect(url, device, { token: 'dev-token' });
    assert.equal(again.connectRes.error.details.requestId, requestId, 'a retry with the same scopes reuses the request');
    const listed = await approver.send('device.pair.list');
    const mine = listed.pending.filter((p) => p.deviceId === device.id);
    assert.deepEqual(mine.map((p) => p.requestId), [requestId]);
    assert.equal(mine[0].displayName, 'Pincer Selftest');
    const changed = await rawConnect(url, device, { token: 'dev-token' }, [...BASE_SCOPES, 'operator.admin']);
    const supersededId = changed.connectRes.error.details.requestId;
    assert.notEqual(supersededId, requestId, 'changed scopes supersede the request');
    assert.equal((await approver.call('device.pair.approve', { requestId })).error.message, 'unknown requestId');
    assert.equal((await approver.call('device.pair.approve', {})).error.code, 'INVALID_REQUEST');

    const resolved = approver.waitEvent('device.pair.resolved');
    const approved = await approver.send('device.pair.approve', { requestId: supersededId });
    assert.equal(approved.device.deviceId, device.id);
    const resolvedEvent = await resolved;
    assert.equal(resolvedEvent.requestId, supersededId);
    assert.equal(resolvedEvent.decision, 'approved');
    const connected = await rawConnect(url, device, { token: 'dev-token' }, [...BASE_SCOPES, 'operator.admin']);
    assert.equal(connected.connectRes.ok, true);
    assert.ok((await approver.send('device.pair.list')).paired.some((p) => p.deviceId === device.id && p.connected));
    connected.ws.close();

    const other = makeDevice();
    const pendingId = (await rawConnect(url, other, { token: 'dev-token' })).connectRes.error.details.requestId;
    const rejectedEvent = approver.waitEvent('device.pair.resolved', (p) => p.requestId === pendingId);
    assert.equal((await approver.send('device.pair.reject', { requestId: pendingId })).deviceId, other.id);
    assert.equal((await rejectedEvent).decision, 'rejected');
    const retry = await rawConnect(url, other, { token: 'dev-token' });
    assert.equal(retry.connectRes.error.details.code, 'PAIRING_REQUIRED', 'a rejected device just gets a new request');
    assert.notEqual(retry.connectRes.error.details.requestId, pendingId);
    approver.ws.close();
    reader.ws.close();
  } finally {
    await manual.close();
  }

  // MOCK_PAIRING=reject rejects every request; reject-once rejects the first then approves.
  const rejecting = await startServer({ host: '127.0.0.1', port: 0, pairing: 'reject', pairingDelayMs: 50 });
  try {
    const url = `ws://127.0.0.1:${rejecting.address().port}`;
    const device = makeDevice();
    const firstId = (await rawConnect(url, device, { token: 'dev-token' })).connectRes.error.details.requestId;
    await delay(150);
    const second = await rawConnect(url, device, { token: 'dev-token' });
    assert.notEqual(second.connectRes.error.details.requestId, firstId);
    await delay(150);
    assert.equal((await rawConnect(url, device, { token: 'dev-token' })).connectRes.error.details.code, 'PAIRING_REQUIRED');
  } finally {
    await rejecting.close();
  }
  const rejectOnce = await startServer({ host: '127.0.0.1', port: 0, pairing: 'reject-once', pairingDelayMs: 50 });
  try {
    const url = `ws://127.0.0.1:${rejectOnce.address().port}`;
    const device = makeDevice();
    const firstId = (await rawConnect(url, device, { token: 'dev-token' })).connectRes.error.details.requestId;
    await delay(150);
    const secondId = (await rawConnect(url, device, { token: 'dev-token' })).connectRes.error.details.requestId;
    assert.notEqual(secondId, firstId, 'the rejected request is replaced');
    await delay(150);
    const ok = await rawConnect(url, device, { token: 'dev-token' });
    assert.equal(ok.connectRes.ok, true, 'the second request is approved');
    ok.ws.close();
  } finally {
    await rejectOnce.close();
  }

  // The default auto mode approves after MOCK_PAIRING_DELAY_MS.
  const quick = await startServer({ host: '127.0.0.1', port: 0, pairingDelayMs: 50 });
  try {
    const url = `ws://127.0.0.1:${quick.address().port}`;
    const device = makeDevice();
    assert.equal((await rawConnect(url, device, { token: 'dev-token' })).connectRes.error.details.code, 'PAIRING_REQUIRED');
    await delay(150);
    const ok = await rawConnect(url, device, { token: 'dev-token' });
    assert.equal(ok.connectRes.ok, true);
    ok.ws.close();
  } finally {
    await quick.close();
  }

  await assert.rejects(startServer({ port: 0, auth: 'magic' }), /MOCK_AUTH must be/);
  await assert.rejects(startServer({ port: 0, pairing: 'sometimes' }), /unknown MOCK_PAIRING/);
}
