import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server, port, url, device, paired, deviceToken, client, agents, history, started, delivery, message, plugin, asked, snapshot } = ctx;
  // A device paired before Pincer asked for operator.questions: the Gateway refuses the new
  // scope with approvedScopes, so the client can drop it and connect with what it had.
  const legacyScopes = BASE_SCOPES.filter((s) => s !== 'operator.questions');
  const legacyDevice = makeDevice();
  const legacyFirst = await connectClient(url, legacyDevice, 'dev-token', false, legacyScopes);
  assert.equal(legacyFirst.connectRes.error.details.reason, 'not-paired');
  legacyFirst.ws.close();
  await delay(3500);
  const legacyPaired = await connectClient(url, legacyDevice, 'dev-token', true, legacyScopes);
  const legacyToken = legacyPaired.hello.auth.deviceToken;
  legacyPaired.ws.close();
  const legacyUpgrade = await connectClient(url, legacyDevice, legacyToken, false, BASE_SCOPES);
  assert.equal(legacyUpgrade.connectRes.error.details.reason, 'scope-upgrade');
  assert.deepEqual([...legacyUpgrade.connectRes.error.details.approvedScopes].sort(), [...legacyScopes].sort());
  assert.match(legacyUpgrade.connectRes.error.details.requestId, /^pair_/);
  legacyUpgrade.ws.close();
  const legacyFallback = await connectClient(url, legacyDevice, legacyToken, true, legacyScopes);
  assert.deepEqual(legacyFallback.hello.auth.scopes, legacyScopes);
  legacyFallback.ws.close();

  const noQuestions = await connectClient(url, device, deviceToken, true, BASE_SCOPES.filter((s) => s !== 'operator.questions'));
  const unscoped = await noQuestions.call('question.list');
  assert.equal(unscoped.error.details.code, 'MISSING_SCOPE');
  assert.equal(unscoped.error.details.missingScope, 'operator.questions');
  noQuestions.ws.close();

  // Asking for more than was approved at pairing parks a scope upgrade, like the Gateway.
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const upgrade = await connectClient(url, device, deviceToken, false, adminScopes);
  assert.equal(upgrade.connectRes.error.details.code, 'PAIRING_REQUIRED');
  assert.equal(upgrade.connectRes.error.details.reason, 'scope-upgrade');
  assert.ok(upgrade.connectRes.error.details.approvedScopes.includes('operator.questions'));
  assert.ok(!upgrade.connectRes.error.details.approvedScopes.includes('operator.admin'));
  upgrade.ws.close();
  await delay(3500);

  const admin = await connectClient(url, device, deviceToken, true, adminScopes);
  const stale = await admin.call('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}}}', baseHash: 'nope' });
  assert.match(stale.error.message, /config changed since last load/);
  const invalid = await admin.call('config.patch', { raw: '{"gateway":{"port":70000}}', baseHash: snapshot.hash });
  assert.equal(invalid.ok, false);
  assert.equal(invalid.error.details.issues[0].path, 'gateway.port');
  const hot = await admin.send('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}},"gateway":{"auth":{"token":"__OPENCLAW_REDACTED__"}}}', baseHash: snapshot.hash });
  assert.deepEqual(hot.changedPaths, ['agents.defaults.timeoutSeconds']);
  assert.equal(hot.restart, undefined);
  assert.equal(server.state.configState.config.gateway.auth.token, 'dev-token', 'redacted secret restored');
  const restart = await admin.send('config.patch', { raw: '{"gateway":{"port":18790}}', baseHash: hot.hash });
  assert.equal(restart.restart.delayMs, 2000);

  const added = await admin.send('cron.add', {
    name: 'Selftest job',
    agentId: 'main',
    schedule: { kind: 'every', everyMs: 3_600_000 },
    sessionTarget: 'isolated',
    wakeMode: 'now',
    payload: { kind: 'agentTurn', message: 'Say hi' },
    delivery: { mode: 'none' },
  });
  assert.ok(added.id && added.state.nextRunAtMs > Date.now());
  const mismatched = await admin.call('cron.add', { name: 'Bad', schedule: { kind: 'every', everyMs: 1000 }, sessionTarget: 'main', wakeMode: 'now', payload: { kind: 'agentTurn', message: 'x' } });
  assert.match(mismatched.error.message, /systemEvent/);
  const paused = await admin.send('cron.update', { id: added.id, expectedConfigRevision: added.configRevision, patch: { enabled: false } });
  assert.equal(paused.enabled, false);
  assert.equal(paused.state.nextRunAtMs, undefined);
  const staleCron = await admin.call('cron.update', { id: added.id, expectedConfigRevision: added.configRevision, patch: { name: 'x' } });
  assert.match(staleCron.error.message, /revision/);
  const cronStarted = admin.waitEvent('cron', (p) => p.jobId === added.id && p.action === 'started');
  const cronFinished = admin.waitEvent('cron', (p) => p.jobId === added.id && p.action === 'finished');
  const ran = await admin.send('cron.run', { id: added.id, mode: 'force' });
  assert.equal(ran.enqueued, true);
  await cronStarted;
  await cronFinished;
  const addedRuns = await admin.send('cron.runs', { scope: 'job', id: added.id });
  assert.equal(addedRuns.entries[0].runId, ran.runId);
  assert.equal(addedRuns.entries[0].status, 'ok');
  const runChat = await admin.send('chat.history', { sessionKey: addedRuns.entries[0].sessionKey });
  assert.ok(runChat.messages.some((m) => m.content.some((b) => b.text === 'Say hi')), 'run linked to its chat');
  await admin.send('cron.remove', { id: added.id });
  assert.equal((await admin.call('cron.get', { id: added.id })).ok, false);

  const plugins = await admin.send('plugins.list');
  assert.equal(plugins.plugins.find((p) => p.id === 'weather').state, 'needs-setup');
  const consent = await admin.call('plugins.setEnabled', { pluginId: 'browser', enabled: true });
  assert.equal(consent.error.details.capabilityConsentCode, 'PLUGIN_CAPABILITY_CONSENT_REQUIRED');
  const changed = admin.waitEvent('plugins.changed');
  const enabled = await admin.send('plugins.setEnabled', { pluginId: 'browser', enabled: true, acknowledgeCapabilities: { reviewToken: consent.error.details.reviewToken } });
  assert.equal(enabled.plugin.enabled, true);
  await changed;
  const installed = await admin.send('plugins.install', { source: 'npm', spec: 'openclaw-plugin-todo@1.0.0' });
  assert.equal(installed.plugin.id, 'todo');
  const removed = await admin.send('plugins.uninstall', { pluginId: 'todo' });
  assert.equal(removed.pluginId, 'todo');
  const bundled = await admin.call('plugins.uninstall', { pluginId: 'browser' });
  assert.equal(bundled.ok, false);

  Object.assign(ctx, { adminScopes, admin, invalid, restart, added, changed, enabled, bundled });
}
