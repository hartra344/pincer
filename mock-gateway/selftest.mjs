import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import http from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { startServer } from './server.mjs';
import { SEEDED_HISTORY_COUNTS } from './approvals.mjs';
import { decryptWebPush, sessionPath } from './webpush.mjs';

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

const BASE_SCOPES = ['operator.read', 'operator.write', 'operator.approvals', 'operator.questions'];

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

  // Test hooks for failed sends: one refused, one that drops the connection.
  const refused = await client.call('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'nope [mock:fail-send]',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.equal(refused.ok, false);
  assert.equal(refused.error.code, 'UNAVAILABLE');
  const dropped = await connectClient(url, device, deviceToken, true);
  const closed = new Promise((resolve) => dropped.ws.once('close', resolve));
  dropped.call('chat.send', { sessionKey: 'agent:main:main', message: 'bye [mock:drop]', idempotencyKey: `idem_${crypto.randomUUID()}` });
  assert.equal(await closed, 1012);
  const afterHooks = await client.send('chat.history', { sessionKey: 'agent:main:main' });
  assert.ok(!afterHooks.messages.some((m) => JSON.stringify(m.content).includes('[mock:')), 'hooked sends leave no messages');

  // Web Push: finished replies and approvals are encrypted to the subscription's keys.
  const pushed = [];
  const pushSink = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      pushed.push({ path: req.url, headers: req.headers, body: Buffer.concat(chunks) });
      res.writeHead(201).end();
    });
  });
  await new Promise((resolve) => pushSink.listen(0, '127.0.0.1', resolve));
  const receiver = crypto.createECDH('prime256v1');
  receiver.generateKeys();
  const pushKeys = { p256dh: b64url(receiver.getPublicKey()), auth: b64url(crypto.randomBytes(16)) };
  const endpoint = `http://127.0.0.1:${pushSink.address().port}/v1/push/abc/gw`;
  assert.equal((await client.call('push.web.subscribe', { endpoint: 'http://example.com/x', keys: pushKeys })).ok, false);
  assert.equal((await client.call('push.web.subscribe', { endpoint, keys: { p256dh: 'short', auth: 'x' } })).ok, false);
  const subscribed = await client.send('push.web.subscribe', { endpoint, keys: pushKeys });
  assert.ok(subscribed.subscriptionId);
  assert.equal((await client.send('push.web.subscribe', { endpoint, keys: pushKeys })).subscriptionId, subscribed.subscriptionId,
    'subscribe upserts by endpoint');
  const pushedRun = await client.send('chat.send', {
    sessionKey: 'agent:main:discord:channel:123',
    message: 'hello push',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === pushedRun.runId && p.state === 'final', 10_000);
  await waitUntil(() => pushed.length >= 1, 3000, 'web push delivery');
  const [delivery] = pushed;
  assert.equal(delivery.path, '/v1/push/abc/gw');
  assert.equal(delivery.headers['content-encoding'], 'aes128gcm');
  assert.equal(delivery.headers.ttl, '300');
  assert.match(delivery.headers.topic, /^[\w-]{32}$/);
  assert.match(delivery.headers.authorization, /^vapid t=/);
  const message = JSON.parse(decryptWebPush(delivery.body, { privateKey: receiver.getPrivateKey(), auth: pushKeys.auth }).toString('utf8'));
  assert.equal(message.title, 'OpenClaw agent finished');
  assert.equal(message.url, 'chat/main/discord/channel/123');
  assert.equal(message.tag, `openclaw-agent-finished-${pushedRun.runId}`);
  assert.ok(!JSON.stringify(message).includes('hello push'), 'push carries no message content');
  assert.equal(sessionPath('agent:main:main'), 'chat/main');
  assert.equal(sessionPath('agent:research:dashboard'), 'chat/research/~key/dashboard');
  const requestedP = client.waitEvent('exec.approval.requested');
  const approvalRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'please approve this',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const requested = await requestedP;
  await client.waitEvent('chat', (p) => p.runId === approvalRun.runId && p.state === 'final', 10_000);
  await waitUntil(() => pushed.length >= 3, 3000, 'approval web push');
  const approvalPushes = pushed.slice(1).map((p) => JSON.parse(decryptWebPush(p.body, { privateKey: receiver.getPrivateKey(), auth: pushKeys.auth })));
  const approvalPush = approvalPushes.find((p) => p.tag === `openclaw-approval-${requested.id}`);
  assert.equal(approvalPush.url, `approve/${requested.id}`);
  assert.equal(approvalPush.title, 'OpenClaw approval requested');
  assert.equal(pushed.find((p) => p.headers.urgency === 'high')?.headers.ttl, '120');
  const pendingLookup = await client.send('approval.get', { id: requested.id });
  assert.equal(pendingLookup.approval.status, 'pending');
  assert.equal(pendingLookup.approval.presentation.commandText, 'rm -rf ./build');
  assert.ok(!JSON.stringify(pendingLookup).includes('/home/claw'), 'approval snapshots never carry cwd');
  await client.send('exec.approval.resolve', { id: requested.id, decision: 'deny' });
  assert.deepEqual(requested.request.allowedDecisions, ['allow-once', 'allow-always', 'deny']);
  // Identical retry is idempotent; a conflicting one is already resolved (openclaw approval-shared.ts).
  assert.equal((await client.send('exec.approval.resolve', { id: requested.id, decision: 'deny' })).ok, true);
  const conflicting = await client.call('exec.approval.resolve', { id: requested.id, decision: 'allow-once' });
  assert.equal(conflicting.ok, false);
  assert.equal(conflicting.error.code, 'INVALID_REQUEST');
  assert.equal(conflicting.error.message, 'approval already resolved');
  assert.equal(conflicting.error.details.reason, 'APPROVAL_ALREADY_RESOLVED');
  assert.ok(!(await client.send('exec.approval.list')).approvals.some((a) => a.id === requested.id));
  const unknown = await client.call('exec.approval.resolve', { id: 'approval_missing', decision: 'allow-once' });
  assert.equal(unknown.ok, false);
  assert.equal(unknown.error.code, 'INVALID_REQUEST');
  assert.equal(unknown.error.message, 'approval expired or not found');
  assert.equal(unknown.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal((await client.call('exec.approval.resolve', { id: 'approval_missing', decision: 'maybe' })).error.message, 'invalid decision');

  // Approval history: newest-first terminal ledger with opaque cursors and a kind filter.
  const seededTotal = Object.values(SEEDED_HISTORY_COUNTS).reduce((a, b) => a + b, 0);
  assert.ok(client.hello.features.methods.includes('approval.history'));
  assert.ok(client.hello.features.methods.includes('approval.get'));
  const page1 = await client.send('approval.history', {});
  assert.equal(page1.items.length, 50, 'default limit is 50');
  assert.ok(page1.nextCursor);
  const page2 = await client.send('approval.history', { cursor: page1.nextCursor });
  assert.equal(page2.nextCursor, undefined);
  const allItems = [...page1.items, ...page2.items];
  assert.equal(allItems.length, seededTotal + 1, 'seeded history plus the approval just resolved');
  assert.equal(new Set(allItems.map((r) => r.id)).size, allItems.length, 'no duplicates across pages');
  assert.ok(allItems.every((r, i) => i === 0 || allItems[i - 1].resolvedAtMs >= r.resolvedAtMs), 'newest first');
  assert.ok(allItems.every((r) => r.status !== 'pending' && !('cwd' in r.presentation)));
  assert.deepEqual(new Set(allItems.map((r) => r.status)), new Set(['allowed', 'denied', 'expired', 'cancelled']));
  assert.deepEqual(new Set(allItems.map((r) => r.resolver?.kind ?? 'none')), new Set(['device', 'channel', 'runtime', 'system', 'none']));
  const [top] = page1.items;
  assert.equal(top.id, requested.id, 'resolved approval is at the top');
  assert.equal(top.status, 'denied');
  assert.equal(top.decision, 'deny');
  assert.equal(top.reason, 'user');
  assert.deepEqual(top.resolver, { kind: 'device', id: device.id });
  assert.deepEqual(top.source, { agentId: 'main', sessionKey: 'agent:main:main' });
  const resolvedLookup = await client.send('approval.get', { id: requested.id });
  assert.equal(resolvedLookup.approval.status, 'denied');
  assert.equal((await client.send('approval.history', { limit: 100 })).items.length, seededTotal + 1);
  assert.equal((await client.call('approval.history', { limit: 101 })).error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('approval.history', { limit: 0 })).error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('approval.history', { kind: 'bogus' })).error.code, 'INVALID_REQUEST');
  for (const kind of ['exec', 'plugin', 'system-agent']) {
    const expected = SEEDED_HISTORY_COUNTS[kind] + (kind === 'exec' ? 1 : 0);
    const small1 = await client.send('approval.history', { kind, limit: 7 });
    assert.ok(small1.items.every((r) => r.presentation.kind === kind), `${kind} filter`);
    const filtered = [...small1.items];
    let cursor = small1.nextCursor;
    while (cursor) {
      const next = await client.send('approval.history', { kind, limit: 7, cursor });
      assert.ok(next.items.every((r) => r.presentation.kind === kind));
      filtered.push(...next.items);
      cursor = next.nextCursor;
    }
    assert.equal(filtered.length, expected, `${kind} total`);
    assert.equal(new Set(filtered.map((r) => r.id)).size, expected);
  }
  const execCursor = (await client.send('approval.history', { kind: 'exec', limit: 5 })).nextCursor;
  const kindMismatch = await client.call('approval.history', { kind: 'plugin', cursor: execCursor });
  assert.equal(kindMismatch.error.code, 'INVALID_REQUEST', 'cursor is bound to its filter');
  for (const cursor of ['not-a-cursor', Buffer.from('{"v":1,"after":"nope"}').toString('base64url')]) {
    const badCursor = await client.call('approval.history', { cursor });
    assert.equal(badCursor.ok, false);
    assert.equal(badCursor.error.code, 'INVALID_REQUEST');
    assert.equal(badCursor.error.message, 'invalid approval.history cursor');
  }
  const plugin = allItems.find((r) => r.presentation.kind === 'plugin');
  assert.deepEqual((await client.send('approval.get', { id: plugin.id })).approval, plugin, 'approval.get round-trips a history row');
  const system = allItems.find((r) => r.presentation.kind === 'system-agent');
  assert.deepEqual((await client.send('approval.get', { id: system.id })).approval, system);
  const missing = await client.call('approval.get', { id: 'approval_missing' });
  assert.equal(missing.error.code, 'INVALID_REQUEST');
  assert.equal(missing.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal((await client.send('push.web.unsubscribe', { endpoint })).removed, true);
  pushSink.close();

  // `approve once-only` leaves allow-always out; asking for it anyway keeps the approval pending.
  const onceOnlyP = client.waitEvent('exec.approval.requested');
  const onceOnlyRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'approve once-only',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const onceOnly = await onceOnlyP;
  assert.deepEqual(onceOnly.request.allowedDecisions, ['allow-once', 'deny']);
  const always = await client.call('exec.approval.resolve', { id: onceOnly.id, decision: 'allow-always' });
  assert.equal(always.ok, false);
  assert.equal(always.error.code, 'INVALID_REQUEST');
  assert.equal(always.error.message, 'allow-always is unavailable for this command');
  assert.equal(always.error.details.reason, 'APPROVAL_ALLOW_ALWAYS_UNAVAILABLE');
  assert.ok((await client.send('exec.approval.list')).approvals.some((a) => a.id === onceOnly.id), 'still pending');
  const onceResolvedEvent = client.waitEvent('exec.approval.resolved', (p) => p.id === onceOnly.id);
  assert.equal((await client.send('exec.approval.resolve', { id: onceOnly.id, decision: 'allow-once' })).ok, true);
  assert.equal((await onceResolvedEvent).decision, 'allow-once');
  await client.waitEvent('chat', (p) => p.runId === onceOnlyRun.runId && p.state === 'final', 10_000);

  // `approve short-lived` expires after 3 s and then reads as not found.
  const shortP = client.waitEvent('exec.approval.requested');
  const shortRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'approve short-lived',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const shortLived = await shortP;
  assert.ok(shortLived.expiresAtMs - shortLived.createdAtMs <= 3_000);
  await client.waitEvent('chat', (p) => p.runId === shortRun.runId && p.state === 'final', 10_000);
  await delay(Math.max(0, shortLived.expiresAtMs - Date.now()) + 50);
  assert.ok(!(await client.send('exec.approval.list')).approvals.some((a) => a.id === shortLived.id), 'expired approval is not listed');
  const expired = await client.call('exec.approval.resolve', { id: shortLived.id, decision: 'deny' });
  assert.equal(expired.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal(expired.error.message, 'approval expired or not found');

  const asked = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'ask me something',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const askedPrompt = await client.waitEvent('question.requested', (p) => p.runId === asked.runId);
  assert.equal(askedPrompt.status, 'pending');
  assert.equal(askedPrompt.sessionKey, 'agent:main:main');
  assert.equal(askedPrompt.questions[0].questionId, 'discord_remove');
  assert.equal(askedPrompt.questions[0].options.length, 3);
  assert.equal(askedPrompt.questions[0].isOther, true);
  const listed = await client.send('question.list');
  assert.ok(listed.questions.some((q) => q.id === askedPrompt.id));
  const incomplete = await client.call('question.resolve', { id: askedPrompt.id, answers: { answers: {} } });
  assert.equal(incomplete.error.details.reason, 'QUESTION_INVALID_ANSWER');
  const resolvedEvent = client.waitEvent('question.resolved', (p) => p.id === askedPrompt.id);
  const resolution = await client.send('question.resolve', {
    id: askedPrompt.id,
    answers: { answers: { discord_remove: ['Stop watching Discord channels here'] } },
  });
  assert.equal(resolution.status, 'answered');
  assert.deepEqual((await resolvedEvent).answers.answers.discord_remove, ['Stop watching Discord channels here']);
  const askedFinal = await client.waitEvent('chat', (p) => p.runId === asked.runId && p.state === 'final', 10_000);
  assert.ok(askedFinal.message.content.some((b) => b.type === 'text' && b.text.includes('Stop watching Discord channels here')));
  const resolvedAgain = await client.call('question.resolve', { id: askedPrompt.id, cancel: true });
  assert.equal(resolvedAgain.error.details.reason, 'QUESTION_ALREADY_TERMINAL');
  assert.equal((await client.call('question.resolve', { id: 'ask_missing', cancel: true })).error.details.reason, 'QUESTION_NOT_FOUND');

  // Skipping cancels the prompt and the run carries on.
  const skippedRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'ask again',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const skippedPrompt = await client.waitEvent('question.requested', (p) => p.runId === skippedRun.runId);
  assert.equal((await client.send('question.resolve', { id: skippedPrompt.id, cancel: true })).status, 'cancelled');
  const skippedFinal = await client.waitEvent('chat', (p) => p.runId === skippedRun.runId && p.state === 'final', 10_000);
  assert.ok(skippedFinal.message.content.some((b) => b.type === 'text' && b.text.includes('skipping')));

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

  // Command policy (exec.approvals.get/set): operator.admin only, token redacted, base-hash CAS.
  assert.ok(admin.hello.features.methods.includes('exec.approvals.get'));
  assert.ok(admin.hello.features.methods.includes('exec.approvals.set'));
  const policyReader = await connectClient(url, device, deviceToken, true);
  for (const method of ['exec.approvals.get', 'exec.approvals.set']) {
    const gated = await policyReader.call(method, {});
    assert.equal(gated.error.code, 'FORBIDDEN', 'operator.approvals alone is not enough');
    assert.equal(gated.error.message, 'missing scope: operator.admin');
    assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
  }
  policyReader.ws.close();
  const policy = await admin.send('exec.approvals.get', {});
  assert.equal(policy.path, '~/.openclaw/exec-approvals.json');
  assert.equal(policy.exists, true);
  assert.match(policy.hash, /^[0-9a-f]{64}$/);
  assert.deepEqual(policy.file.socket, { path: '~/.openclaw/exec-approvals.sock' }, 'socket token redacted');
  assert.ok(!JSON.stringify(policy).includes('mock-secret'));
  assert.deepEqual(policy.file.defaults, { security: 'allowlist', ask: 'on-miss' });
  assert.deepEqual(policy.resolvedDefaults, { security: 'allowlist', ask: 'on-miss', askFallback: 'deny', autoAllowSkills: false });
  assert.equal(policy.file.agents.main.allowlist.length, 2);
  assert.equal(policy.file.agents.main.allowlist.filter((e) => e.source === 'allow-always').length, 1);
  assert.equal(policy.file.agents.main.mcpTools.length, 1);
  assert.equal(policy.file.agents.research.ask, 'always');
  assert.ok(!agents.agents.some((a) => a.id === 'ghost') && policy.file.agents.ghost.allowlist.length === 1);
  const badGet = await admin.call('exec.approvals.get', { extra: true });
  assert.equal(badGet.error.code, 'INVALID_REQUEST');
  assert.match(badGet.error.message, /^invalid exec\.approvals\.get params: /);

  const schemaErrors = [
    { file: { ...policy.file, extra: 1 }, baseHash: policy.hash },
    { file: { ...policy.file, version: 2 }, baseHash: policy.hash },
    { file: { version: 1, agents: { main: { allowlist: [{ source: 'allow-always' }] } } }, baseHash: policy.hash },
    { file: { version: 1, agents: { main: { mcpTools: [{ server: 'github', tool: 'x', source: 'allow-always' }] } } }, baseHash: policy.hash },
    { file: { version: 1, defaults: { autoAllowSkills: 'yes' } }, baseHash: policy.hash },
    { file: policy.file, baseHash: policy.hash, extra: 1 },
  ];
  for (const params of schemaErrors) {
    const res = await admin.call('exec.approvals.set', params);
    assert.equal(res.error.code, 'INVALID_REQUEST', JSON.stringify(params));
    assert.match(res.error.message, /^invalid exec\.approvals\.set params: /);
  }
  // Schema errors come before hash checks, like upstream.
  assert.match((await admin.call('exec.approvals.set', { file: { version: 2 } })).error.message, /^invalid exec\.approvals\.set params/);
  const noBase = await admin.call('exec.approvals.set', { file: policy.file });
  assert.equal(noBase.error.code, 'INVALID_REQUEST');
  assert.equal(noBase.error.message, 'exec approvals base hash required; re-run exec.approvals.get and retry');
  const staleSet = await admin.call('exec.approvals.set', { file: policy.file, baseHash: 'deadbeef' });
  assert.equal(staleSet.error.message, 'exec approvals changed since last load; re-run exec.approvals.get and retry');
  assert.equal((await admin.call('exec.approvals.set', { baseHash: policy.hash })).error.message, 'exec approvals file is required');

  // Round trip without the token: unknown enum values survive, the stored token is kept.
  const edited = structuredClone(policy.file);
  edited.defaults.ask = 'off';
  edited.agents.research.security = 'future-mode';
  edited.agents.main.allowlist = edited.agents.main.allowlist.slice(0, 1);
  const saved = await admin.send('exec.approvals.set', { file: edited, baseHash: policy.hash });
  assert.notEqual(saved.hash, policy.hash);
  assert.deepEqual(saved.file, edited);
  assert.equal(server.state.execApprovalsState.file.socket.token, 'mock-secret', 'socket token preserved');
  assert.deepEqual(await admin.send('exec.approvals.get', {}), saved);
  const lostUpdate = await admin.call('exec.approvals.set', { file: policy.file, baseHash: policy.hash });
  assert.match(lostUpdate.error.message, /changed since last load/);
  const noSocket = structuredClone(saved.file);
  delete noSocket.socket;
  const savedAgain = await admin.send('exec.approvals.set', { file: noSocket, baseHash: saved.hash });
  assert.deepEqual(savedAgain.file.socket, { path: '~/.openclaw/exec-approvals.sock' });
  assert.equal(server.state.execApprovalsState.file.socket.token, 'mock-secret');

  // Always allow in chat adds the command to that agent's allowlist and changes the hash.
  const coderChat = await admin.send('sessions.create', { agentId: 'coder', label: 'Policy selftest' });
  const alwaysRequested = admin.waitEvent('exec.approval.requested', (p) => p.request.sessionKey === coderChat.key);
  const alwaysRun = await admin.send('chat.send', { sessionKey: coderChat.key, message: 'approve this', idempotencyKey: `idem_${crypto.randomUUID()}` });
  const alwaysApproval = await alwaysRequested;
  await admin.send('exec.approval.resolve', { id: alwaysApproval.id, decision: 'allow-always' });
  await admin.waitEvent('chat', (p) => p.runId === alwaysRun.runId && p.state === 'final', 10_000);
  const afterAlways = await admin.send('exec.approvals.get', {});
  assert.notEqual(afterAlways.hash, savedAgain.hash);
  assert.ok(!savedAgain.file.agents.coder, 'coder had no policy entry before');
  const coderEntry = afterAlways.file.agents.coder.allowlist.at(-1);
  assert.equal(coderEntry.source, 'allow-always');
  assert.equal(coderEntry.pattern, 'rm -rf ./build');
  assert.equal(coderEntry.commandText, 'rm -rf ./build');
  assert.ok(coderEntry.id && coderEntry.lastUsedAt > Date.now() - 60_000);
  assert.match((await admin.call('exec.approvals.set', { file: afterAlways.file, baseHash: savedAgain.hash })).error.message, /changed since last load/);

  // Context usage and compaction.
  const reader = await connectClient(url, device, deviceToken, true);
  const rows = (await reader.send('sessions.list', { limit: 50 })).sessions;
  const papersRow = rows.find((s) => s.key === 'agent:research:dashboard:papers');
  assert.equal(papersRow.totalTokens, 96_000);
  assert.equal(papersRow.contextTokens, 200_000);
  assert.equal((await reader.send('sessions.list', {})).defaults.contextTokens, 128_000);
  const plainModels = await reader.send('models.list', { agentId: 'main' });
  assert.equal(plainModels.models[0].contextTokens, undefined, 'contextTokens only with includeDetails');
  assert.equal(plainModels.models[0].contextWindow, 1_000_000);
  const detailed = await reader.send('models.list', { agentId: 'main', includeDetails: true });
  assert.equal(detailed.models[0].contextTokens, 200_000);
  const compactDenied = await reader.call('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(compactDenied.error.details.code, 'MISSING_SCOPE');
  const compacted = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(compacted.compacted, true);
  assert.deepEqual(compacted.result, { tokensBefore: 96_000, tokensAfter: 17_280 });
  const papersHistory = await reader.send('chat.history', { sessionKey: 'agent:research:dashboard:papers' });
  assert.equal(papersHistory.messages.at(-1).__openclaw.kind, 'compaction');
  const again = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(again.compacted, true, 'still above the minimum');
  const nothing = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(nothing.compacted, false);
  assert.match(nothing.reason, /Nothing to compact/);

  await reader.send('sessions.messages.subscribe', { key: 'agent:coder:main' });
  const compactRun = await reader.send('chat.send', {
    sessionKey: 'agent:coder:main',
    message: '/compact keep the build notes',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const compactEnd = reader.waitEvent('agent', (p) => p.runId === compactRun.runId && p.stream === 'compaction' && p.data.phase === 'end');
  const compactFinal = await reader.waitEvent('chat', (p) => p.runId === compactRun.runId && p.state === 'final', 10_000);
  await compactEnd;
  assert.match(compactFinal.message.content[0].text, /190000 → 34200 tokens\), keeping: keep the build notes/);
  const coderRow = (await reader.send('sessions.list', {})).sessions.find((s) => s.key === 'agent:coder:main');
  assert.equal(coderRow.totalTokens, 34_200);
  reader.ws.close();
  admin.ws.close();

  // Approval history needs operator.approvals; MOCK_NO_APPROVAL_HISTORY=1 hides it entirely.
  const noApprovals = await connectClient(url, device, 'dev-token', true, ['operator.read']);
  const noScope = await noApprovals.call('approval.history', {});
  assert.equal(noScope.error.details.code, 'MISSING_SCOPE');
  noApprovals.ws.close();
  process.env.MOCK_NO_APPROVAL_HISTORY = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true);
    assert.ok(!legacy.hello.features.methods.includes('approval.history'));
    assert.ok(!legacy.hello.features.methods.includes('approval.get'));
    assert.ok(legacy.hello.features.methods.includes('exec.approval.resolve'));
    for (const method of ['approval.history', 'approval.get']) {
      const unknown = await legacy.call(method, { id: 'x' });
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_APPROVAL_HISTORY;
  }

  // MOCK_NO_EXEC_APPROVALS=1 hides the command policy methods, like an older Gateway.
  process.env.MOCK_NO_EXEC_APPROVALS = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true, adminScopes);
    assert.ok(!legacy.hello.features.methods.some((m) => m.startsWith('exec.approvals.')));
    assert.ok(legacy.hello.features.methods.includes('exec.approval.resolve'));
    for (const method of ['exec.approvals.get', 'exec.approvals.set']) {
      const unknown = await legacy.call(method, {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_EXEC_APPROVALS;
  }

  // MOCK_EXEC_APPROVALS_MISSING=1 starts without a policy file; saving creates it.
  process.env.MOCK_EXEC_APPROVALS_MISSING = '1';
  const missingServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  delete process.env.MOCK_EXEC_APPROVALS_MISSING;
  try {
    const fresh = await connectClient(`ws://127.0.0.1:${missingServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    const empty = await fresh.send('exec.approvals.get', {});
    assert.equal(empty.exists, false);
    assert.deepEqual(empty.file, { version: 1 });
    assert.match(empty.hash, /^[0-9a-f]{64}$/);
    assert.deepEqual(empty.resolvedDefaults, { security: 'full', ask: 'off', askFallback: 'deny', autoAllowSkills: false });
    const wrongBase = await fresh.call('exec.approvals.set', { file: { version: 1 }, baseHash: 'deadbeef' });
    assert.equal(wrongBase.error.message, 'exec approvals changed since last load; re-run exec.approvals.get and retry');
    const created = await fresh.send('exec.approvals.set', { file: { version: 1, defaults: { security: 'deny' } }, baseHash: empty.hash });
    assert.equal(created.exists, true);
    assert.notEqual(created.hash, empty.hash);
    assert.deepEqual(created.file, { version: 1, defaults: { security: 'deny' } });
    assert.deepEqual(created.resolvedDefaults, { security: 'deny', ask: 'off', askFallback: 'deny', autoAllowSkills: false }, 'unset fields use built-in values');
    const requiredNow = await fresh.call('exec.approvals.set', { file: created.file });
    assert.match(requiredNow.error.message, /base hash required/);
    fresh.ws.close();
  } finally {
    await missingServer.close();
  }
  console.log('PASS');
} finally {
  await server.close();
}
