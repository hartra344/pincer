import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { startServer } from './server.mjs';

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function makeDevice() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const spki = publicKey.export({ format: 'der', type: 'spki' });
  const rawPublic = Buffer.from(spki).subarray(-32);
  const id = crypto.createHash('sha256').update(rawPublic).digest('hex');
  return { id, publicKey: b64url(rawPublic), privateKey };
}

const BASE_SCOPES = ['operator.read', 'operator.write', 'operator.approvals'];

function signConnect(device, challenge, token, scopes = BASE_SCOPES) {
  const client = {
    id: 'openclaw-macos',
    displayName: 'Pincer Selftest',
    version: '0.0.0',
    platform: 'macos',
    mode: 'ui',
    deviceFamily: 'desktop',
    instanceId: 'selftest',
  };
  const payload = `v2|${device.id}|${client.id}|${client.mode}|operator|${scopes.join(',')}|${challenge.ts}|${token}|${challenge.nonce}`;
  return {
    minProtocol: 4,
    maxProtocol: 4,
    client,
    role: 'operator',
    scopes,
    caps: ['tool-events'],
    auth: { token },
    device: {
      id: device.id,
      publicKey: device.publicKey,
      signature: b64url(crypto.sign(null, Buffer.from(payload, 'utf8'), device.privateKey)),
      signedAt: challenge.ts,
      nonce: challenge.nonce,
    },
  };
}

async function connectClient(url, device, token, expectOk = true, scopes = BASE_SCOPES) {
  const ws = new WebSocket(url);
  const emitter = new EventEmitter();
  const pending = new Map();
  let nextId = 1;
  let challenge;
  let hello;

  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    if (msg.type === 'event') {
      if (msg.event === 'connect.challenge') challenge = msg.payload;
      emitter.emit(msg.event, msg.payload);
      emitter.emit('*', msg.event, msg.payload);
    } else if (msg.type === 'res') {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        p(msg);
      }
    }
  });

  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  await waitUntil(() => challenge, 1000, 'challenge');
  const id = `req_${nextId++}`;
  const connectResP = new Promise((resolve) => pending.set(id, resolve));
  ws.send(JSON.stringify({ type: 'req', id, method: 'connect', params: signConnect(device, challenge, token, scopes) }));
  const connectRes = await connectResP;
  if (expectOk) {
    assert.equal(connectRes.ok, true, JSON.stringify(connectRes));
    hello = connectRes.payload;
    assert.equal(hello.type, 'hello-ok');
  } else {
    assert.equal(connectRes.ok, false, JSON.stringify(connectRes));
    return { ws, connectRes };
  }

  function call(method, params = {}) {
    const reqId = `req_${nextId++}`;
    const p = new Promise((resolve) => pending.set(reqId, resolve));
    ws.send(JSON.stringify({ type: 'req', id: reqId, method, params }));
    return p;
  }

  function send(method, params = {}) {
    return call(method, params).then((res) => {
      assert.equal(res.ok, true, `${method} failed: ${JSON.stringify(res)}`);
      return res.payload;
    });
  }

  function waitEvent(name, predicate = () => true, timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`timed out waiting for ${name}`));
      }, timeoutMs);
      function handler(payload) {
        try {
          if (predicate(payload)) {
            cleanup();
            resolve(payload);
          }
        } catch (err) {
          cleanup();
          reject(err);
        }
      }
      function cleanup() {
        clearTimeout(timer);
        emitter.off(name, handler);
      }
      emitter.on(name, handler);
    });
  }

  return { ws, hello, send, call, waitEvent, emitter };
}

async function waitUntil(fn, timeoutMs, label) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = fn();
    if (value) return value;
    await delay(20);
  }
  throw new Error(`timed out waiting for ${label}`);
}

const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', mockToken: 'dev-token' });
try {
  const port = server.address().port;
  const url = `ws://127.0.0.1:${port}`;
  const device = makeDevice();

  const first = await connectClient(url, device, 'dev-token', false);
  assert.equal(first.connectRes.error.code, 'NOT_PAIRED');
  assert.equal(first.connectRes.error.details.code, 'PAIRING_REQUIRED');
  first.ws.close();

  await delay(3500);

  const paired = await connectClient(url, device, 'dev-token', true);
  const deviceToken = paired.hello.auth.deviceToken;
  assert.match(deviceToken, /^dt_/);
  paired.ws.close();

  const client = await connectClient(url, device, deviceToken, true);
  assert.equal(client.hello.auth.deviceToken, deviceToken);

  const agents = await client.send('agents.list');
  assert.equal(agents.defaultId, 'main');
  assert.ok(agents.agents.some((a) => a.id === 'research'));

  const sessions = await client.send('sessions.subscribe', { limit: 20 });
  assert.ok(sessions.list.sessions.some((s) => s.key === 'agent:main:main'));

  const history = await client.send('chat.history', { sessionKey: 'agent:main:main', limit: 20 });
  const blocks = history.messages.flatMap((m) => m.content);
  assert.ok(blocks.some((b) => b.type === 'thinking'));
  assert.ok(blocks.some((b) => b.type === 'toolCall'));
  assert.ok(blocks.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));

  const artifact = await client.send('artifacts.download', { sessionKey: 'agent:main:main', artifactId: 'art-chart-1' });
  const png = Buffer.from(artifact.data, 'base64');
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');

  await client.send('sessions.messages.subscribe', { key: 'agent:main:main' });
  let deltaCount = 0;
  let sawTool = false;
  client.emitter.on('chat', (payload) => {
    if (payload.state === 'delta' && payload.deltaText !== undefined) deltaCount += 1;
  });
  client.emitter.on('agent', (payload) => {
    if (payload.stream === 'tool' && payload.data?.phase === 'result') sawTool = true;
  });

  const started = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'show me a tool and an image',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.match(started.runId, /^run_/);
  const final = await client.waitEvent('chat', (p) => p.runId === started.runId && p.state === 'final', 10_000);
  assert.ok(final.message.content.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));
  assert.ok(deltaCount > 0, 'expected chat deltas');
  assert.equal(sawTool, true, 'expected tool result event');

  // Config and plugins: reads need operator.read, writes operator.admin.
  const snapshot = await client.send('config.get');
  assert.equal(snapshot.valid, true, JSON.stringify(snapshot.issues));
  assert.equal(snapshot.config.gateway.auth.token, '__OPENCLAW_REDACTED__');
  const schema = await client.send('config.schema');
  assert.equal(schema.uiHints['gateway.auth.token'].sensitive, true);
  // Cron: reads with operator.read, writes need operator.admin.
  const cronStatus = await client.send('cron.status');
  assert.equal(cronStatus.enabled, true);
  assert.equal(cronStatus.jobs, 3);
  const cronList = await client.send('cron.list', { includeDisabled: true, limit: 2, sortBy: 'nextRunAtMs', sortDir: 'asc' });
  assert.equal(cronList.total, 3);
  assert.equal(cronList.hasMore, true);
  const cronRest = await client.send('cron.list', { includeDisabled: true, limit: 2, offset: cronList.nextOffset });
  assert.equal(cronList.jobs.length + cronRest.jobs.length, 3);
  const enabledOnly = await client.send('cron.list', {});
  assert.ok(enabledOnly.jobs.every((job) => job.enabled), 'disabled jobs hidden by default');
  const diskRuns = await client.send('cron.runs', { scope: 'job', id: 'disk-check', limit: 50, sortDir: 'desc' });
  assert.equal(diskRuns.entries[0].status, 'error');
  assert.equal(diskRuns.entries[0].sessionKey, 'agent:main:cron:disk-check');
  assert.equal((await client.call('cron.run', { id: 'disk-check' })).error.details.code, 'MISSING_SCOPE');
  const denied = await client.call('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}}}', baseHash: snapshot.hash });
  assert.equal(denied.ok, false);
  assert.match(denied.error.message, /operator\.admin/);
  client.ws.close();

  const admin = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.admin']);
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
  admin.ws.close();
  console.log('PASS');
} finally {
  await server.close();
}
