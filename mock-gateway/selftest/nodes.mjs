import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { startServer } from '../server.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Device mode: the same device connects as operator and as role `node`, on a fresh server.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', pairingDelayMs: 50, mockToken: 'dev-token' });
  const sockets = [];
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const scopes = [...BASE_SCOPES, 'operator.pairing', 'operator.admin'];
    const device = makeDevice();
    const track = (client) => (sockets.push(client.ws), client);
    const surface = (commands) => ({ caps: ['location'], commands, permissions: { location: true } });
    const connectOperator = async () => {
      const first = await connectClient(url, device, 'dev-token', false, scopes);
      if (first.connectRes.error.details.code === 'PAIRING_REQUIRED') {
        first.ws.close();
        await delay(250);
      }
      return track(await connectClient(url, device, 'dev-token', true, scopes));
    };
    const operator = await connectOperator();
    const invokeParams = (command, extra = {}) => ({ nodeId: device.id, command, params: { desiredAccuracy: 'coarse' }, timeoutMs: 2000, idempotencyKey: `k-${Math.random()}`, ...extra });

    // First node connect: role upgrade needs approval (auto-approved after the delay), then a separate node token.
    const declared = ['location.get', 'device.info', 'system.run', 'camera.snap'];
    const denied = await connectClient(url, device, 'dev-token', false, [], surface(declared));
    assert.equal(denied.connectRes.error.details.code, 'PAIRING_REQUIRED');
    assert.equal(denied.connectRes.error.details.reason, 'role-upgrade');
    assert.equal(denied.connectRes.error.details.requestedRole, 'node');
    assert.ok(denied.connectRes.error.details.requestId);
    denied.ws.close();
    await delay(250);
    let node = track(await connectClient(url, device, 'dev-token', true, [], surface(declared)));
    assert.equal(node.hello.auth.role, 'node');
    assert.deepEqual(node.hello.auth.scopes, []);
    const nodeToken = node.hello.auth.deviceToken;
    assert.match(nodeToken, /^dt_/);
    assert.notEqual(nodeToken, operator.hello.auth.deviceToken, 'node token is separate from the operator token');
    const nodeEvents = [];
    node.emitter.on('*', (event) => nodeEvents.push(event));

    // node.list: declared commands filtered through the platform allowlist, never system.run or camera.snap.
    let listed = (await operator.send('node.list', {})).nodes.find((n) => n.nodeId === device.id);
    assert.ok(listed, 'node listed');
    assert.deepEqual(listed.commands, ['device.info', 'location.get']);
    assert.deepEqual(listed.caps, ['location']);
    assert.deepEqual(listed.permissions, { location: true });
    assert.equal(listed.connected, true);
    assert.equal(listed.platform, 'macos');
    assert.equal(listed.displayName, 'Pincer Selftest');
    assert.equal(listed.approvalState, 'approved');

    // Round trip: node.invoke -> node.invoke.request event -> node.invoke.result -> response.
    const invoke = operator.call('node.invoke', invokeParams('location.get'));
    const request = await node.waitEvent('node.invoke.request');
    assert.equal(request.nodeId, device.id);
    assert.equal(request.command, 'location.get');
    assert.equal(JSON.parse(request.paramsJSON).desiredAccuracy, 'coarse');
    assert.equal(request.timeoutMs, 2000);
    assert.ok(request.id && request.idempotencyKey);
    const payload = { lat: 1.5, lon: 2.5, accuracyMeters: 10, timestamp: '2026-01-01T00:00:00Z', isPrecise: false };
    const ack = await node.call('node.invoke.result', { id: request.id, nodeId: device.id, ok: true, payloadJSON: JSON.stringify(payload) });
    assert.equal(ack.ok, true);
    const result = await invoke;
    assert.equal(result.ok, true, JSON.stringify(result));
    assert.deepEqual(result.payload, { ok: true, nodeId: device.id, command: 'location.get', payload, payloadJSON: JSON.stringify(payload) });

    // A node-reported failure becomes UNAVAILABLE with the node's code.
    const failing = operator.call('node.invoke', invokeParams('device.info'));
    const failReq = await node.waitEvent('node.invoke.request');
    await node.call('node.invoke.result', { id: failReq.id, nodeId: device.id, ok: false, error: { code: 'UNAVAILABLE', message: 'LOCATION_DISABLED: turn on Location' } });
    const failed = await failing;
    assert.equal(failed.error.code, 'UNAVAILABLE');
    assert.match(failed.error.message, /LOCATION_DISABLED/);

    // Timeouts, and result frames only count from the node role.
    const timedOut = await operator.call('node.invoke', invokeParams('location.get', { timeoutMs: 80 }));
    assert.equal(timedOut.error.code, 'UNAVAILABLE');
    assert.match(timedOut.error.message, /timed out/);
    assert.equal((await operator.call('node.invoke.result', { id: 'x', nodeId: device.id, ok: true })).ok, false);
    assert.equal((await node.call('chat.history', {})).error.message, 'unauthorized role: node');

    // Not allowlisted vs. allowlisted but not declared.
    const notAllowed = await operator.call('node.invoke', invokeParams('system.run'));
    assert.equal(notAllowed.error.code, 'INVALID_REQUEST');
    assert.equal(notAllowed.error.message, 'command not allowlisted');
    const undeclared = await operator.call('node.invoke', invokeParams('calendar.events'));
    assert.equal(undeclared.error.code, 'INVALID_REQUEST');
    assert.equal(undeclared.error.message, 'command not declared by node');
    assert.equal((await operator.call('node.invoke', { nodeId: device.id, command: 'location.get' })).ok, false, 'idempotencyKey required');

    // Surface change: a new command keeps the old effective set until approved.
    const requested = operator.waitEvent('node.pair.requested');
    node.ws.close();
    await delay(50);
    node = track(await connectClient(url, device, nodeToken, true, [], surface(['location.get', 'device.info', 'calendar.events'])));
    node.emitter.on('*', (event) => nodeEvents.push(event));
    const pending = await requested;
    assert.equal(pending.nodeId, device.id);
    assert.deepEqual(pending.commands, ['calendar.events', 'device.info', 'location.get']);
    listed = (await operator.send('node.list', {})).nodes.find((n) => n.nodeId === device.id);
    assert.deepEqual(listed.commands, ['device.info', 'location.get'], 'effective commands unchanged until approval');
    assert.equal(listed.connected, true);
    const stillBlocked = await operator.call('node.invoke', invokeParams('calendar.events'));
    assert.equal(stillBlocked.error.message, 'command not declared by node');
    assert.equal((await operator.send('node.pair.list', {})).pending.length, 1);
    const approvedEvent = operator.waitEvent('node.pair.resolved', (e) => e.decision === 'approved');
    const nodeNotified = node.waitEvent('node.pair.resolved');
    await operator.send('node.pair.approve', { requestId: pending.requestId });
    assert.equal((await approvedEvent).requestId, pending.requestId);
    assert.equal((await nodeNotified).decision, 'approved');
    listed = (await operator.send('node.list', {})).nodes.find((n) => n.nodeId === device.id);
    assert.deepEqual(listed.commands, ['calendar.events', 'device.info', 'location.get']);
    const calendar = operator.call('node.invoke', invokeParams('calendar.events'));
    const calReq = await node.waitEvent('node.invoke.request');
    await node.call('node.invoke.result', { id: calReq.id, nodeId: device.id, ok: true, payloadJSON: '{"events":[]}' });
    assert.deepEqual((await calendar).payload.payload, { events: [] });

    // health.summary and the Pincer-only pincer.health.query (#1084) are opt-in via
    // gateway.nodes.commands.allow (seeded); deny overrides allow.
    {
      const fullSurface = surface(['location.get', 'device.info', 'calendar.events', 'health.summary', 'pincer.health.query']);
      // Without the allow entry, a freshly connected node's declared surface drops pincer.health.query.
      let cfg = await operator.send('config.get', {});
      const unallowed = await operator.call('config.patch', { raw: JSON.stringify({ gateway: { nodes: { commands: { allow: ['health.summary'] } } } }), baseHash: cfg.hash });
      assert.equal(unallowed.ok, true, JSON.stringify(unallowed));
      const summaryOnly = operator.waitEvent('node.pair.requested');
      node.ws.close();
      await delay(50);
      node = track(await connectClient(url, device, nodeToken, true, [], fullSurface));
      node.emitter.on('*', (event) => nodeEvents.push(event));
      const summaryReq = await summaryOnly;
      assert.ok(summaryReq.commands.includes('health.summary'));
      assert.ok(!summaryReq.commands.includes('pincer.health.query'), 'pincer.health.query needs the allow entry');
      assert.equal((await operator.call('node.invoke', invokeParams('pincer.health.query', { params: {} }))).error.message, 'command not allowlisted');
      await operator.send('node.pair.reject', { requestId: summaryReq.requestId });
      cfg = await operator.send('config.get', {});
      const reallowed = await operator.call('config.patch', { raw: JSON.stringify({ gateway: { nodes: { commands: { allow: ['health.summary', 'pincer.health.query'] } } } }), baseHash: cfg.hash });
      assert.equal(reallowed.ok, true, JSON.stringify(reallowed));

      const healthPending = operator.waitEvent('node.pair.requested');
      node.ws.close();
      await delay(50);
      node = track(await connectClient(url, device, nodeToken, true, [], fullSurface));
      node.emitter.on('*', (event) => nodeEvents.push(event));
      const healthReq = await healthPending;
      assert.ok(healthReq.commands.includes('health.summary'), 'seeded allow lets health.summary be declared');
      assert.ok(healthReq.commands.includes('pincer.health.query'), 'seeded allow lets pincer.health.query be declared');
      await operator.send('node.pair.approve', { requestId: healthReq.requestId });
      listed = (await operator.send('node.list', {})).nodes.find((n) => n.nodeId === device.id);
      assert.ok(listed.commands.includes('health.summary'));
      assert.ok(listed.commands.includes('pincer.health.query'));
      const health = operator.call('node.invoke', invokeParams('health.summary', { params: { period: 'today' } }));
      const healthInvoke = await node.waitEvent('node.invoke.request');
      assert.equal(healthInvoke.command, 'health.summary');
      assert.equal(healthInvoke.paramsJSON, '{"period":"today"}');
      const summary = { period: 'today', startISO: '2026-10-27T04:00:00Z', endISO: '2026-10-27T19:30:00Z', timeZoneIdentifier: 'America/New_York', stepCount: 8432, sleepDurationMinutes: 412, restingHeartRateBpm: 58.4, workoutCount: 1, workoutDurationMinutes: 42 };
      await node.call('node.invoke.result', { id: healthInvoke.id, nodeId: device.id, ok: true, payloadJSON: JSON.stringify(summary) });
      assert.deepEqual((await health).payload.payload, summary);

      // pincer.health.query round-trips params and payload (the HRV statistics fixture, HealthQuery.Fixture).
      const queryParams = { mode: 'statistics', type: 'heartRateVariabilitySDNN', interval: 'day' };
      const query = operator.call('node.invoke', invokeParams('pincer.health.query', { params: queryParams }));
      const queryInvoke = await node.waitEvent('node.invoke.request');
      assert.equal(queryInvoke.command, 'pincer.health.query');
      assert.deepEqual(JSON.parse(queryInvoke.paramsJSON), queryParams);
      const hrv = {
        mode: 'statistics', type: 'heartRateVariabilitySDNN', identifier: 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', kind: 'quantity',
        unit: 'ms', interval: 'day', aggregation: 'discrete', startISO: '2026-10-21T00:00:00-04:00', endISO: '2026-10-28T12:00:00-04:00',
        timeZoneIdentifier: 'America/New_York',
        buckets: [42.3, 45.1, 39.8, 51.2, 48.6, 35.9, 44.1].map((average, day) => ({
          startISO: `2026-10-${21 + day}T00:00:00-04:00`, endISO: `2026-10-${22 + day}T00:00:00-04:00`, average, minimum: average - 9, maximum: average + 14,
        })),
      };
      await node.call('node.invoke.result', { id: queryInvoke.id, nodeId: device.id, ok: true, payloadJSON: JSON.stringify(hrv) });
      assert.deepEqual((await query).payload.payload, hrv);

      // deny overrides allow, both for invoke and for what a node may declare.
      cfg = await operator.send('config.get', {});
      const patched = await operator.call('config.patch', { raw: JSON.stringify({ gateway: { nodes: { commands: { deny: ['health.summary', 'pincer.health.query'] } } } }), baseHash: cfg.hash });
      assert.equal(patched.ok, true, JSON.stringify(patched));
      for (const command of ['health.summary', 'pincer.health.query']) {
        const blocked = await operator.call('node.invoke', invokeParams(command, { params: {} }));
        assert.equal(blocked.error.code, 'INVALID_REQUEST');
        assert.equal(blocked.error.message, 'command not allowlisted', command);
      }
    }

    // node.pair.remove drops the node role, closes node sockets and keeps the operator session.
    const nodeClosed = new Promise((resolve) => node.ws.once('close', resolve));
    const removed = operator.waitEvent('node.pair.resolved', (e) => e.decision === 'removed');
    await operator.send('node.pair.remove', { nodeId: device.id });
    assert.equal((await removed).nodeId, device.id);
    await nodeClosed;
    assert.equal((await operator.send('node.list', {})).nodes.some((n) => n.nodeId === device.id), false);
    assert.equal((await operator.call('node.invoke', invokeParams('location.get'))).ok, false);
    assert.ok((await operator.send('health', {})), 'operator connection survives');
    assert.deepEqual([...new Set(nodeEvents)].filter((e) => !['connect.challenge', 'tick', 'node.pair.resolved', 'node.invoke.request'].includes(e)), [], 'node sockets only get node events');
  } finally {
    for (const ws of sockets) ws.close();
    await server.close();
  }
}
