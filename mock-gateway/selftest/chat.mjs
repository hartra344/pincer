import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { makeDevice, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server } = ctx;
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

  const scoutIdentity = await client.send('agent.identity.get', { agentId: 'research' });
  assert.deepEqual(scoutIdentity, { agentId: 'research', name: 'Scout', nameSource: 'agent', emoji: '🔭', avatar: '🔭' });
  const mainIdentity = await client.send('agent.identity.get', { sessionKey: 'agent:main:main' });
  assert.equal(mainIdentity.agentId, 'main');
  assert.equal(mainIdentity.name, 'Claw');

  const sessions = await client.send('sessions.subscribe', { limit: 20 });
  assert.ok(sessions.list.sessions.some((s) => s.key === 'agent:main:main'));

  const history = await client.send('chat.history', { sessionKey: 'agent:main:main', limit: 20 });
  const blocks = history.messages.flatMap((m) => m.content);
  assert.ok(blocks.some((b) => b.type === 'thinking'));
  assert.ok(blocks.some((b) => b.type === 'toolCall'));
  assert.ok(blocks.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));
  // Kiko's sessions_send messages and the morning briefing, projected as upstream's chat.history does.
  const forwarded = history.messages.filter((m) => m.senderSession);
  assert.deepEqual(forwarded.map((m) => [m.role, m.senderSession.agentId, m.provenance.kind, m.provenance.sourceTool]), [
    ['assistant', 'main', 'internal_system', 'cron'],
    ['assistant', 'kiko', 'inter_session', 'sessions_send'],
    ['assistant', 'kiko', 'inter_session', 'sessions_send'],
  ]);
  assert.equal(forwarded[0].senderSession.label, 'Morning briefing');
  assert.equal(forwarded[1].senderLabel, 'Forwarded from kiko');
  assert.ok(forwarded.every((m) => !m.content[0].text.startsWith('[') && m.model === undefined), 'prompt prefixes stripped, no model');
  const kikoRun = history.messages.filter((m) => m.__openclaw.runId === forwarded[1].__openclaw.runId);
  assert.deepEqual(kikoRun.map((m) => m.senderSession?.agentId ?? m.role), ['kiko', 'assistant'], "Claw's reply shares Kiko's run");

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

  Object.assign(ctx, { port, url, device, first, paired, deviceToken, client, agents, sessions, history, png, started, final });
}
