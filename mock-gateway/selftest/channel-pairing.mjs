import assert from 'node:assert/strict';
import { PAIRING_TTL_MS, PENDING_PER_ACCOUNT, addChannelPairingRequest, createChannelPairingState } from '../pairing.mjs';
import { BASE_SCOPES, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server, url, device, deviceToken, dropped, closed, message, requested, admin, added } = ctx;
  // Channel pairing: operator.pairing (or operator.admin) for every method, upstream-shaped results.
  const unpaired = await connectClient(url, device, deviceToken, true);
  assert.ok(unpaired.hello.features.methods.includes('channels.pairing.list'));
  const pairingDenied = await unpaired.call('channels.pairing.list', {});
  assert.equal(pairingDenied.error.code, 'FORBIDDEN');
  assert.equal(pairingDenied.error.details.code, 'MISSING_SCOPE');
  assert.equal(pairingDenied.error.details.missingScope, 'operator.pairing');
  assert.deepEqual(pairingDenied.error.details.requiredScopes, ['operator.pairing']);
  assert.equal((await unpaired.call('channels.pairing.dismiss', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya' })).error.details.code,
    'MISSING_SCOPE');
  unpaired.ws.close();
  const pairer = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.pairing']);
  const pairingList = await pairer.send('channels.pairing.list', {});
  assert.deepEqual(pairingList.accounts.map((a) => `${a.channel}:${a.accountId}:${a.notifySupported}`),
    ['telegram:home:true', 'discord:family:false']);
  assert.deepEqual(pairingList.requests.map((r) => r.requestId), ['pr_maya', 'pr_discord', 'pr_soon']);
  assert.equal(pairingList.commandOwnerConfigured, true);
  assert.deepEqual(pairingList.limits, { pendingPerAccount: PENDING_PER_ACCOUNT, ttlMs: PAIRING_TTL_MS });
  // Closed objects: exactly the upstream keys, optional ones only when present.
  const sortedKeys = (o) => Object.keys(o).sort();
  assert.deepEqual(sortedKeys(pairingList), ['accounts', 'commandOwnerConfigured', 'limits', 'requests']);
  const ACCOUNT_KEYS = ['accountId', 'accountLabel', 'channel', 'channelLabel', 'notifySupported'];
  for (const a of pairingList.accounts) {
    assert.deepEqual(sortedKeys(a).filter((k) => k !== 'accountLabel'), ACCOUNT_KEYS.filter((k) => k !== 'accountLabel'));
    assert.ok(sortedKeys(a).every((k) => ACCOUNT_KEYS.includes(k)));
    assert.equal(typeof a.notifySupported, 'boolean');
  }
  const REQUEST_KEYS = ['accountId', 'accountLabel', 'channel', 'channelLabel', 'createdAt', 'expiresAt', 'lastSeenAt', 'metadata',
    'notifySupported', 'requestId', 'senderId', 'senderLabel'];
  const REQUIRED_REQUEST_KEYS = REQUEST_KEYS.filter((k) => k !== 'accountLabel' && k !== 'metadata');
  for (const r of pairingList.requests) {
    assert.ok(sortedKeys(r).every((k) => REQUEST_KEYS.includes(k)), `request keys ${sortedKeys(r)}`);
    assert.ok(REQUIRED_REQUEST_KEYS.every((k) => k in r), `required request keys ${sortedKeys(r)}`);
    assert.ok(Object.values(r.metadata ?? {}).every((v) => typeof v === 'string'));
    for (const k of ['createdAt', 'lastSeenAt', 'expiresAt']) assert.equal(new Date(r[k]).toISOString(), r[k]);
  }
  const maya = pairingList.requests[0];
  assert.equal(maya.metadata.name, 'Maya Chen');
  assert.equal(maya.senderLabel, 'Telegram user id');
  assert.ok(Date.parse(maya.expiresAt) - Date.parse(maya.createdAt) === PAIRING_TTL_MS && !Number.isNaN(Date.parse(maya.lastSeenAt)));
  assert.equal(pairingList.requests[1].metadata, undefined);
  assert.ok(Date.parse(pairingList.requests[2].expiresAt) - Date.now() < 11 * 60_000);
  assert.deepEqual((await pairer.send('channels.pairing.list', { channel: 'discord' })).requests.map((r) => r.requestId), ['pr_discord']);
  assert.match((await pairer.call('channels.pairing.list', { channel: 'signal' })).error.message, /^unknown pairing channel: signal$/);
  assert.equal((await pairer.call('channels.pairing.list', { limit: 5 })).error.code, 'INVALID_REQUEST');
  assert.equal((await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', code: 'x' })).error.code,
    'INVALID_REQUEST', 'approve params are closed');
  const ownerDenied = await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', bootstrapCommandOwner: true });
  assert.equal(ownerDenied.error.details.missingScope, 'operator.admin', 'bootstrapCommandOwner needs operator.admin');
  assert.deepEqual(await pairer.send('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', notify: true }),
    { requestId: 'pr_maya', senderId: '5550142', notification: 'sent', commandOwnerBootstrap: 'not-requested' });
  const staleApprove = await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya' });
  assert.equal(staleApprove.error.code, 'INVALID_REQUEST');
  assert.equal(staleApprove.error.message, 'pending DM access request no longer exists');
  assert.equal((await pairer.call('channels.pairing.dismiss', { channel: 'slack', accountId: 'work', requestId: 'pr_discord' })).error.message,
    'channel account does not use DM pairing: slack:work');
  assert.deepEqual(await pairer.send('channels.pairing.dismiss', { channel: 'discord', accountId: 'family', requestId: 'pr_discord' }),
    { requestId: 'pr_discord', senderId: '418820017734812160' });
  assert.equal((await pairer.call('channels.pairing.dismiss', { channel: 'discord', accountId: 'family', requestId: 'pr_discord' })).error.message,
    'pending DM access request no longer exists');
  assert.equal((await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_soon', notify: 'yes' })).error.code,
    'INVALID_REQUEST', 'notify must be a boolean');
  const newRequest = addChannelPairingRequest(server.state);
  const afterAdd = await pairer.send('channels.pairing.list', {});
  assert.deepEqual(afterAdd.requests.map((r) => r.requestId).sort(), ['pr_soon', newRequest.requestId].sort());
  assert.ok(afterAdd.requests.every((r) => sortedKeys(r).every((k) => REQUEST_KEYS.includes(k))), 'added requests keep the upstream shape');
  // Discord can't notify; notify omitted → not-requested.
  const discordAdded = addChannelPairingRequest(server.state);
  assert.equal(discordAdded.channel, 'discord');
  assert.deepEqual(await pairer.send('channels.pairing.approve',
    { channel: 'discord', accountId: 'family', requestId: discordAdded.requestId, notify: true }),
    { requestId: discordAdded.requestId, senderId: discordAdded.senderId, notification: 'unsupported', commandOwnerBootstrap: 'not-requested' });
  const quietAdded = addChannelPairingRequest(server.state);
  assert.deepEqual(sortedKeys(await pairer.send('channels.pairing.approve',
    { channel: quietAdded.channel, accountId: quietAdded.accountId, requestId: quietAdded.requestId })),
  ['commandOwnerBootstrap', 'notification', 'requestId', 'senderId']);
  assert.equal(server.state.channelPairingState.requests.some((r) => r.requestId === quietAdded.requestId), false);
  // Expired requests are dropped from the list and can't be approved.
  const expiredAdded = addChannelPairingRequest(server.state, Date.now() - PAIRING_TTL_MS - 1000);
  assert.ok(!(await pairer.send('channels.pairing.list', {})).requests.some((r) => r.requestId === expiredAdded.requestId));
  assert.equal((await pairer.call('channels.pairing.approve',
    { channel: expiredAdded.channel, accountId: expiredAdded.accountId, requestId: expiredAdded.requestId })).error.message,
  'pending DM access request no longer exists');
  // A full account drops its oldest request.
  const cap = createChannelPairingState();
  const capState = { channelPairingState: cap };
  for (let i = 0; i < 9; i += 1) addChannelPairingRequest(capState);
  for (const account of ['telegram:home', 'discord:family']) {
    assert.ok(cap.requests.filter((r) => `${r.channel}:${r.accountId}` === account).length <= PENDING_PER_ACCOUNT, `cap on ${account}`);
  }
  pairer.ws.close();
  const pairingAdmin = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.admin']);
  server.state.channelPairingState.commandOwnerConfigured = false;
  assert.deepEqual(await pairingAdmin.send('channels.pairing.approve',
    { channel: newRequest.channel, accountId: newRequest.accountId, requestId: newRequest.requestId, notify: true, bootstrapCommandOwner: true }),
    { requestId: newRequest.requestId, senderId: newRequest.senderId, notification: newRequest.notifySupported ? 'sent' : 'unsupported', commandOwnerBootstrap: 'configured' });
  assert.equal((await pairingAdmin.send('channels.pairing.list', {})).commandOwnerConfigured, true, 'admin covers operator.pairing');
  pairingAdmin.ws.close();
  process.env.MOCK_CHANNEL_PAIRING = 'off';
  try {
    const noPairing = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.admin']);
    for (const method of ['channels.pairing.list', 'channels.pairing.approve', 'channels.pairing.dismiss']) {
      assert.ok(!noPairing.hello.features.methods.includes(method));
      const unknown = await noPairing.call(method, {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    noPairing.ws.close();
  } finally {
    delete process.env.MOCK_CHANNEL_PAIRING;
  }

}
