import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { startServer } from '../server.mjs';
import { FAILED_DELIVERY_QUEUE, addFailedDelivery, createHealthState, healthSummary } from '../health.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server, port, url, device, deviceToken, agents, sessions, failed, delivery, message, system, snapshot, adminScopes, restart, again, nothing, status, one } = ctx;
  // Health, presence and a safe restart.
  const watcher = await connectClient(url, device, deviceToken, true);
  for (const method of ['health', 'status', 'last-heartbeat', 'system-presence', 'gateway.restart.request']) {
    assert.ok(watcher.hello.features.methods.includes(method), method);
  }
  for (const event of ['health', 'heartbeat', 'presence', 'shutdown']) assert.ok(watcher.hello.features.events.includes(event), event);
  const helloSnap = watcher.hello.snapshot;
  assert.ok(Array.isArray(helloSnap.presence) && helloSnap.presence.some((p) => p.deviceId === device.id));
  assert.ok(helloSnap.presence.some((p) => p.mode === 'gateway' && p.reason === 'self' && p.host), 'the gateway reports its own host');
  assert.equal(helloSnap.health.ok, true);
  assert.ok(helloSnap.uptimeMs > 86_400_000, 'mock has been up for a day');
  const healthNow = await watcher.send('health');
  assert.equal(healthNow.channels.discord.connected, true);
  assert.equal(healthNow.heartbeatSeconds, 1800);
  // One failed delivery that stays failed, so Pincer shows a dismissable issue.
  assert.equal(healthNow.deliveryQueues.failed.length, 1);
  assert.equal(healthNow.deliveryQueues.failed[0].queueName, FAILED_DELIVERY_QUEUE);
  assert.equal(healthNow.deliveryQueues.failed[0].count, 1);
  assert.ok(healthNow.deliveryQueues.failed[0].oldestFailedAt > 0);
  assert.deepEqual(helloSnap.health.deliveryQueues.failed, healthNow.deliveryQueues.failed);
  assert.equal(healthNow.deliveryQueues.ingressFailed[0].count, 2);
  assert.equal(healthNow.deliveryQueues.ingressFailed[0].channelId, 'telegram');
  assert.equal(healthNow.deliveryQueues.ingressFailed[0].accountId, 'default');
  assert.deepEqual(helloSnap.health.deliveryQueues.ingressFailed, healthNow.deliveryQueues.ingressFailed);
  assert.deepEqual(helloSnap.health.deliveryQueues.ingressPressure, healthNow.deliveryQueues.ingressPressure);
  assert.equal(healthNow.deliveryQueues.ingressPressure[0].pendingCount, 3);
  assert.equal(healthNow.deliveryQueues.ingressPressure[0].claimedCount, 1);
  assert.equal(healthNow.deliveryQueues.ingressPressure[0].blockedCount, 1);
  assert.ok(healthNow.deliveryQueues.ingressPressure[0].oldestReceivedAt > 0);
  assert.equal((await watcher.send('last-heartbeat')).status, 'ok-token');
  assert.ok((await watcher.send('system-presence')).some((p) => p.mode === 'node'));
  assert.ok((await watcher.send('status')).uptimeMs > 0);
  const restartDenied = await watcher.call('gateway.restart.request', { reason: 'nope' });
  assert.equal(restartDenied.error.details.code, 'MISSING_SCOPE');

  const restarter = await connectClient(url, device, deviceToken, true, adminScopes);
  // A live run defers the restart; skipDeferral escalates it (coalesced into the pending one).
  const liveRun = await watcher.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'keep going for a while',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.ok(server.state.activeRuns.size > 0);
  const deferredRestart = await restarter.send('gateway.restart.request', { reason: 'selftest' });
  assert.equal(deferredRestart.status, 'deferred');
  assert.equal(deferredRestart.preflight.safe, false);
  assert.ok(deferredRestart.preflight.blockers[0].message.includes('active agent run'));
  const shutdownSeen = restarter.waitEvent('shutdown');
  const restarterClosed = new Promise((resolve) => restarter.ws.once('close', (code) => resolve(code)));
  const coalescedRestart = await restarter.send('gateway.restart.request', { reason: 'selftest', skipDeferral: true });
  assert.equal(coalescedRestart.status, 'coalesced');
  const shutdownPayload = await shutdownSeen;
  assert.equal(shutdownPayload.restartExpectedMs, 1500);
  assert.equal(await restarterClosed, 1012);
  void liveRun;
  const refusedSocket = new WebSocket(url);
  const refusedCode = await new Promise((resolve) => refusedSocket.once('close', (code) => resolve(code)));
  assert.equal(refusedCode, 1013, 'refuses connections while restarting');
  await delay(1700);
  const back = await connectClient(url, device, deviceToken, true, adminScopes);
  assert.ok(back.hello.snapshot.uptimeMs < 60_000, 'fresh uptime after restart');
  // Nothing running: scheduled right away.
  const backClosed = new Promise((resolve) => back.ws.once('close', (code) => resolve(code)));
  const scheduled = await back.send('gateway.restart.request', { reason: 'selftest again' });
  assert.equal(scheduled.status, 'scheduled');
  assert.equal(scheduled.preflight.safe, true);
  assert.equal(await backClosed, 1012);
  await delay(1700);

  // MOCK_NO_HEALTH=1 is an older Gateway without any of it.
  process.env.MOCK_NO_HEALTH = '1';
  try {
    const old = await connectClient(url, device, deviceToken, true, adminScopes);
    assert.ok(!old.hello.features.methods.includes('health'));
    assert.ok(!old.hello.features.methods.includes('gateway.restart.request'));
    assert.deepEqual(old.hello.snapshot, {});
    assert.equal((await old.call('health')).error.code, 'UNKNOWN_METHOD');
    assert.equal((await old.call('gateway.restart.request', {})).error.code, 'UNKNOWN_METHOD');
    old.ws.close();
  } finally {
    delete process.env.MOCK_NO_HEALTH;
  }

  // The failed delivery survived the restarts; MOCK_FAILED_DELIVERY_EVERY adds more, MOCK_FAILED_DELIVERY=off drops it.
  const afterRestart = await connectClient(url, device, deviceToken, true);
  assert.equal((await afterRestart.send('health')).deliveryQueues.failed[0].count, 1);
  afterRestart.ws.close();
  const fakeState = { agents: new Map(), sessions: new Map(), healthState: createHealthState() };
  const sent = [];
  addFailedDelivery(fakeState, (_state, event, payload) => sent.push({ event, payload }));
  assert.equal(fakeState.healthState.failedDelivery.count, 2);
  assert.equal(sent[0].event, 'health');
  assert.equal(sent[0].payload.deliveryQueues.failed[0].count, 2);
  process.env.MOCK_FAILED_DELIVERY = 'off';
  try {
    const quiet = { agents: new Map(), sessions: new Map(), healthState: createHealthState() };
    assert.deepEqual(healthSummary(quiet).deliveryQueues.failed, []);
    addFailedDelivery(quiet, () => assert.fail('nothing to add'));
  } finally {
    delete process.env.MOCK_FAILED_DELIVERY;
  }
  // Through the env vars on a real server: the timer broadcasts `health` with a higher count;
  // MOCK_FAILED_DELIVERY=off reports no failed queue in `health` or the hello snapshot.
  process.env.MOCK_FAILED_DELIVERY_EVERY = '0.2';
  const everyServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  delete process.env.MOCK_FAILED_DELIVERY_EVERY;
  try {
    const client = await connectClient(`ws://127.0.0.1:${everyServer.address().port}`, makeDevice(), 'dev-token');
    const grown = await client.waitEvent('health', (p) => p.deliveryQueues?.failed?.[0]?.count >= 2, 3000);
    assert.equal(grown.deliveryQueues.failed[0].queueName, FAILED_DELIVERY_QUEUE);
    assert.ok((await client.send('health')).deliveryQueues.failed[0].count >= 2);
    client.ws.close();
  } finally {
    await everyServer.close();
  }
  process.env.MOCK_FAILED_DELIVERY = 'off';
  const offServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token', failedDeliveryEvery: 0.1 });
  delete process.env.MOCK_FAILED_DELIVERY;
  try {
    const client = await connectClient(`ws://127.0.0.1:${offServer.address().port}`, makeDevice(), 'dev-token');
    assert.deepEqual(client.hello.snapshot.health.deliveryQueues.failed, []);
    await delay(300);
    assert.deepEqual((await client.send('health')).deliveryQueues.failed, []);
    client.ws.close();
  } finally {
    await offServer.close();
  }
}
