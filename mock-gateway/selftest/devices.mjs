import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { startServer } from '../server.mjs';
import { DEVICE_PAIRING_METHODS, NODE_METHODS, SEEDED_PENDING_REQUEST_IDS, deviceIdentityFor } from '../devices.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Device pairing + node inventory (devices.mjs), on a fresh server so revocations don't leak.
export async function run() {
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const pairingScopes = [...BASE_SCOPES, 'operator.pairing'];
  const sortedKeys = (o) => Object.keys(o).sort();
  const PENDING_KEYS = ['clientId', 'clientMode', 'deviceFamily', 'deviceId', 'displayName', 'isRepair', 'platform', 'publicKey',
    'remoteIp', 'requestId', 'role', 'roles', 'scopes', 'silent', 'ts'];
  const PAIRED_KEYS = ['approvedAtMs', 'approvedVia', 'clientId', 'clientMode', 'connected', 'createdAtMs', 'deviceFamily', 'deviceId',
    'displayName', 'lastSeenAtMs', 'operatorLabel', 'platform', 'publicKey', 'remoteIp', 'role', 'roles', 'scopes', 'tokens'];
  const devServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${devServer.address().port}`;
    const adminDevice = makeDevice();
    const firstTry = await connectClient(url, adminDevice, 'dev-token', false, adminScopes);
    assert.equal(firstTry.connectRes.error.details.code, 'PAIRING_REQUIRED');
    firstTry.ws.close();
    await delay(3500);
    const admin = await connectClient(url, adminDevice, 'dev-token', true, adminScopes);
    for (const m of [...DEVICE_PAIRING_METHODS, ...NODE_METHODS]) assert.ok(admin.hello.features.methods.includes(m), m);
    for (const e of ['device.pair.requested', 'device.pair.resolved', 'device.pair.changed']) assert.ok(admin.hello.features.events.includes(e), e);

    // Seeded list: two pending requests (a new iPad and a scope upgrade), Pincer itself plus three paired devices.
    const list = await admin.send('device.pair.list', {});
    assert.deepEqual(sortedKeys(list), ['paired', 'pending']);
    assert.deepEqual(list.pending.map((p) => p.requestId).sort(), [...SEEDED_PENDING_REQUEST_IDS].sort());
    for (const p of list.pending) {
      assert.ok(sortedKeys(p).every((k) => PENDING_KEYS.includes(k)), `pending keys ${sortedKeys(p)}`);
      assert.ok(p.requestId && p.deviceId && p.publicKey && Number.isInteger(p.ts), 'pending required fields');
      assert.equal(p.deviceId, crypto.createHash('sha256').update(Buffer.from(p.publicKey, 'base64url')).digest('hex'), 'deviceId is sha256(publicKey)');
    }
    const ipad = list.pending.find((p) => p.requestId === 'pair_ipad');
    assert.equal(ipad.displayName, "Alex's iPad");
    assert.equal(ipad.isRepair, false);
    assert.equal(ipad.deviceId, deviceIdentityFor('demo-ipad').deviceId);
    const upgradeReq = list.pending.find((p) => p.requestId === 'pair_studio_admin');
    assert.equal(upgradeReq.isRepair, true);
    assert.ok(upgradeReq.scopes.includes('operator.admin'));
    assert.deepEqual(list.paired.map((d) => d.displayName).sort(), ['Mac mini (home)', 'Pincer Selftest', 'Pixel 9', 'Studio MacBook Pro']);
    assert.ok(!JSON.stringify(list).includes('dt_'), 'no token material in device.pair.list');
    for (const d of list.paired) {
      assert.ok(sortedKeys(d).every((k) => PAIRED_KEYS.includes(k)), `paired keys ${sortedKeys(d)}`);
      assert.equal(typeof d.connected, 'boolean');
      assert.ok(Array.isArray(d.tokens) && d.tokens.every((t) => typeof t.role === 'string' && Array.isArray(t.scopes) && Number.isInteger(t.createdAtMs)));
      assert.ok(!('approvedScopes' in d) && !('deviceToken' in d));
    }
    const self = list.paired.find((d) => d.deviceId === adminDevice.id);
    assert.equal(self.connected, true);
    assert.equal(self.publicKey, adminDevice.publicKey);
    assert.equal(self.clientId, 'openclaw-macos');
    assert.equal(self.platform, 'macos');
    assert.ok(self.scopes.includes('operator.admin'));
    const studio = list.paired.find((d) => d.displayName === 'Studio MacBook Pro');
    assert.equal(studio.connected, false);
    assert.equal(studio.clientMode, 'cli');
    assert.ok(Date.now() - studio.lastSeenAtMs > 2 * 3_600_000);
    assert.deepEqual(list.paired.find((d) => d.displayName === 'Pixel 9').roles, ['node', 'operator']);

    // Closed params, like upstream's typebox schemas.
    assert.equal((await admin.call('device.pair.list', { limit: 5 })).error.message, "invalid device.pair.list params: at root: unexpected property 'limit'");
    assert.match((await admin.call('device.pair.approve', {})).error.message, /must have required property 'requestId'/);
    assert.equal((await admin.call('device.pair.reject', { requestId: '' })).error.code, 'INVALID_REQUEST');
    assert.match((await admin.call('device.pair.remove', { deviceId: 'x', force: true })).error.message, /unexpected property 'force'/);

    // A new device asks to pair: device.pair.requested reaches admins; retrying refreshes the same request.
    const newcomer = makeDevice();
    const requested = admin.waitEvent('device.pair.requested', (p) => p.deviceId === newcomer.id);
    const knock = await connectClient(url, newcomer, 'dev-token', false);
    knock.ws.close();
    const requestedEvent = await requested;
    assert.equal(requestedEvent.requestId, knock.connectRes.error.details.requestId);
    assert.equal(requestedEvent.publicKey, newcomer.publicKey);
    assert.equal(requestedEvent.displayName, 'Pincer Selftest');
    assert.deepEqual(requestedEvent.scopes, BASE_SCOPES);
    assert.ok(sortedKeys(requestedEvent).every((k) => PENDING_KEYS.includes(k)));
    const knockAgain = await connectClient(url, newcomer, 'dev-token', false);
    knockAgain.ws.close();
    assert.equal(knockAgain.connectRes.error.details.requestId, requestedEvent.requestId, 'same device refreshes its request');
    assert.equal((await admin.send('device.pair.list', {})).pending.filter((p) => p.deviceId === newcomer.id).length, 1);

    // Approve before the auto-approval: result + device.pair.resolved; a second approve is unknown.
    const resolvedApprove = admin.waitEvent('device.pair.resolved', (p) => p.requestId === requestedEvent.requestId);
    const approved = await admin.send('device.pair.approve', { requestId: requestedEvent.requestId });
    assert.deepEqual(sortedKeys(approved), ['device', 'requestId']);
    assert.equal(approved.device.deviceId, newcomer.id);
    assert.deepEqual(approved.device.scopes, BASE_SCOPES);
    assert.ok(!JSON.stringify(approved).includes('dt_'));
    const resolvedEvent = await resolvedApprove;
    assert.deepEqual(sortedKeys(resolvedEvent), ['decision', 'deviceId', 'requestId', 'ts']);
    assert.equal(resolvedEvent.decision, 'approved');
    assert.equal(resolvedEvent.deviceId, newcomer.id);
    const again = await admin.call('device.pair.approve', { requestId: requestedEvent.requestId });
    assert.equal(again.error.code, 'INVALID_REQUEST');
    assert.equal(again.error.message, 'unknown requestId');

    // Reject the iPad.
    const resolvedReject = admin.waitEvent('device.pair.resolved', (p) => p.requestId === 'pair_ipad');
    assert.deepEqual(await admin.send('device.pair.reject', { requestId: 'pair_ipad' }), { requestId: 'pair_ipad', deviceId: ipad.deviceId });
    assert.equal((await resolvedReject).decision, 'rejected');
    assert.equal((await admin.call('device.pair.reject', { requestId: 'pair_ipad' })).error.message, 'unknown requestId');
    assert.ok(!(await admin.send('device.pair.list', {})).pending.some((p) => p.requestId === 'pair_ipad'));

    // Without operator.pairing: FORBIDDEN for device.pair.* and node.rename, no pairing events; node.list only needs read.
    const reader = await connectClient(url, newcomer, 'dev-token', true);
    const denied = await reader.call('device.pair.list', {});
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', missingScope: 'operator.pairing', requiredScopes: ['operator.pairing'] });
    for (const [m, p] of [['device.pair.approve', { requestId: 'pair_studio_admin' }], ['device.pair.reject', { requestId: 'x' }],
      ['device.pair.remove', { deviceId: 'x' }], ['device.pair.rename', { deviceId: 'x', label: 'y' }], ['node.rename', { nodeId: 'x', displayName: 'y' }], ['node.pair.remove', { nodeId: 'x' }]]) {
      assert.equal((await reader.call(m, p)).error.details.missingScope, 'operator.pairing', m);
    }
    assert.equal((await reader.send('node.list', {})).nodes.length, 2);
    const readerEvents = [];
    reader.emitter.on('*', (event) => { if (event.startsWith('device.pair.')) readerEvents.push(event); });
    await admin.send('device.pair.rename', { deviceId: studio.deviceId, label: 'Studio' });
    await delay(200);
    assert.deepEqual(readerEvents, [], 'device.pair.* only reach operator.pairing clients');
    reader.ws.close();

    // operator.pairing without admin, on the device token: only its own device, and no cross-device changes.
    const newcomerToken = reader.hello.auth.deviceToken;
    const upgrade = await connectClient(url, newcomer, newcomerToken, false, pairingScopes);
    assert.equal(upgrade.connectRes.error.details.reason, 'scope-upgrade');
    upgrade.ws.close();
    const upgradeListed = (await admin.send('device.pair.list', {})).pending.find((p) => p.deviceId === newcomer.id);
    assert.equal(upgradeListed.isRepair, true);
    assert.ok(upgradeListed.scopes.includes('operator.pairing'));
    await admin.send('device.pair.approve', { requestId: upgradeListed.requestId });
    const pairer = await connectClient(url, newcomer, newcomerToken, true, pairingScopes);
    const ownList = await pairer.send('device.pair.list', {});
    assert.deepEqual(ownList.paired.map((d) => d.deviceId), [newcomer.id]);
    assert.deepEqual(ownList.pending, []);
    assert.equal((await pairer.call('device.pair.remove', { deviceId: studio.deviceId })).error.message, 'device pairing removal denied');
    assert.equal((await pairer.call('device.pair.rename', { deviceId: studio.deviceId, label: 'x' })).error.message, 'device pairing rename denied');
    assert.equal((await pairer.call('device.pair.approve', { requestId: 'pair_studio_admin' })).error.message, 'device pairing approval denied');
    assert.equal((await pairer.call('device.pair.reject', { requestId: 'pair_studio_admin' })).error.message, 'device pairing rejection denied');
    assert.equal((await pairer.call('node.rename', { nodeId: studio.deviceId, displayName: 'x' })).error.message, 'node rename denied');
    pairer.ws.close();
    // On the shared token it sees everything, but can't approve scopes it doesn't hold.
    const sharedPairer = await connectClient(url, newcomer, 'dev-token', true, pairingScopes);
    assert.ok((await sharedPairer.send('device.pair.list', {})).paired.length > 1);
    const tooMuch = await sharedPairer.call('device.pair.approve', { requestId: 'pair_studio_admin' });
    assert.equal(tooMuch.error.code, 'INVALID_REQUEST');
    assert.equal(tooMuch.error.message, 'missing scope: operator.admin');
    sharedPairer.ws.close();

    // Rename: device.pair.changed + operatorLabel.
    const changed = admin.waitEvent('device.pair.changed');
    assert.deepEqual(await admin.send('device.pair.rename', { deviceId: studio.deviceId, label: '  Studio Pro  ' }), { deviceId: studio.deviceId, label: 'Studio Pro' });
    assert.deepEqual(await changed, {});
    assert.equal((await admin.send('device.pair.list', {})).paired.find((d) => d.deviceId === studio.deviceId).operatorLabel, 'Studio Pro');
    assert.equal((await admin.call('device.pair.rename', { deviceId: studio.deviceId, label: '   ' })).error.message, 'label required');
    assert.match((await admin.call('device.pair.rename', { deviceId: studio.deviceId, label: 'x'.repeat(65) })).error.message, /more than 64/);
    assert.equal((await admin.call('device.pair.rename', { deviceId: 'nope', label: 'x' })).error.message, 'unknown deviceId');

    // Nodes: the Mac mini node host (connected) and the Pixel (offline).
    const nodes = await admin.send('node.list', {});
    assert.ok(Number.isInteger(nodes.ts));
    const mini = nodes.nodes.find((n) => n.displayName === 'Mac mini (home)');
    const pixelNode = nodes.nodes.find((n) => n.displayName === 'Pixel 9');
    assert.equal(mini.connected, true);
    assert.ok(mini.connectedAtMs < Date.now());
    assert.equal(pixelNode.connected, false);
    assert.ok(mini.caps.length > 0 && mini.commands.length > 0 && mini.version && mini.platform === 'darwin');
    assert.ok(nodes.nodes.every((n) => n.paired === true && n.approvalState === 'approved'));
    assert.ok(!nodes.nodes.some((n) => n.nodeId === adminDevice.id), 'operator-only devices are not nodes');
    const described = await admin.send('node.describe', { nodeId: mini.nodeId });
    assert.equal(described.nodeId, mini.nodeId);
    assert.ok(Number.isInteger(described.ts));
    assert.equal((await admin.call('node.describe', { nodeId: 'nope' })).error.message, 'unknown nodeId');
    assert.deepEqual(await admin.send('node.rename', { nodeId: mini.nodeId, displayName: 'Mac mini' }), { nodeId: mini.nodeId, displayName: 'Mac mini' });
    assert.equal((await admin.send('node.describe', { nodeId: mini.nodeId })).displayName, 'Mac mini');
    assert.equal((await admin.call('node.rename', { nodeId: 'nope', displayName: 'x' })).error.message, 'unknown nodeId');
    assert.equal((await admin.call('node.rename', { nodeId: mini.nodeId, displayName: ' ' })).error.message, 'displayName required');
    // node.pair.remove revokes the node role: the Pixel stays as an operator device, the node-only Mac mini goes.
    const nodeResolved = admin.waitEvent('node.pair.resolved', (p) => p.nodeId === pixelNode.nodeId);
    assert.deepEqual(await admin.send('node.pair.remove', { nodeId: pixelNode.nodeId }), { nodeId: pixelNode.nodeId });
    const nodeResolvedEvent = await nodeResolved;
    assert.equal(nodeResolvedEvent.decision, 'removed');
    assert.equal(nodeResolvedEvent.requestId, '');
    assert.equal((await admin.call('node.pair.remove', { nodeId: pixelNode.nodeId })).error.message, 'unknown nodeId');
    assert.deepEqual((await admin.send('device.pair.list', {})).paired.find((d) => d.deviceId === pixelNode.nodeId).roles, ['operator']);
    assert.deepEqual(await admin.send('node.pair.remove', { nodeId: mini.nodeId }), { nodeId: mini.nodeId });
    assert.deepEqual((await admin.send('node.list', {})).nodes, []);
    assert.ok(!(await admin.send('device.pair.list', {})).paired.some((d) => d.deviceId === mini.nodeId));

    // Remove: also drops that device's pending requests; removing yourself disconnects you.
    assert.deepEqual(await admin.send('device.pair.remove', { deviceId: studio.deviceId }), { deviceId: studio.deviceId });
    const afterRemove = await admin.send('device.pair.list', {});
    assert.ok(!afterRemove.paired.some((d) => d.deviceId === studio.deviceId));
    assert.ok(!afterRemove.pending.some((p) => p.requestId === 'pair_studio_admin'), 'removal drops pending repairs');
    assert.equal((await admin.call('device.pair.remove', { deviceId: studio.deviceId })).error.message, 'unknown deviceId');
    const closed = new Promise((resolve) => admin.ws.once('close', (code) => resolve(code)));
    assert.deepEqual(await admin.send('device.pair.remove', { deviceId: adminDevice.id }), { deviceId: adminDevice.id });
    assert.equal(await closed, 1008);
    const revoked = await connectClient(url, adminDevice, 'dev-token', false, adminScopes);
    assert.equal(revoked.connectRes.error.details.reason, 'not-paired');
    revoked.ws.close();
  } finally {
    await devServer.close();
  }

  // Older Gateways: no device.pair.* / node.* methods.
  process.env.MOCK_DEVICE_PAIRING = 'off';
  process.env.MOCK_NODES = 'off';
  const oldServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${oldServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    for (const m of [...DEVICE_PAIRING_METHODS, ...NODE_METHODS]) assert.ok(!client.hello.features.methods.includes(m), m);
    assert.ok(!client.hello.features.events.includes('device.pair.requested'));
    assert.equal((await client.call('device.pair.list', {})).error.code, 'UNKNOWN_METHOD');
    assert.equal((await client.call('node.list', {})).error.code, 'UNKNOWN_METHOD');
    client.ws.close();
  } finally {
    delete process.env.MOCK_DEVICE_PAIRING;
    delete process.env.MOCK_NODES;
    await oldServer.close();
  }
}
