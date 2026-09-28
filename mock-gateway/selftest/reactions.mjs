import assert from 'node:assert/strict';
import crypto from 'node:crypto';

export async function run(ctx) {
  const { server, client, history, final } = ctx;
  // Reactions: the seeded Discord message has its channel id, the agent reacted 👀 with `message`,
  // and message.action reacts on Discord only.
  assert.ok(client.hello.features.methods.includes('message.action'));
  const lab = (await client.send('chat.history', { sessionKey: 'agent:main:discord:channel:123' })).messages;
  const sensor = lab.find((m) => m.__openclaw?.transport?.messageId === '1300000000000000001');
  assert.equal(sensor.__openclaw.transport.channel, 'discord');
  assert.equal(sensor.__openclaw.transport.conversationRef, 'channel:123');
  const ackCall = lab.flatMap((m) => m.content).find((b) => b.type === 'toolCall' && b.name === 'message');
  assert.deepEqual(ackCall.arguments, { action: 'react', emoji: '👀', messageId: '1300000000000000001' });
  const reactKey = `idem_${crypto.randomUUID()}`;
  const reactParams = {
    channel: 'discord', action: 'react', sessionKey: 'agent:main:discord:channel:123',
    params: { messageId: '1300000000000000001', emoji: '👍', to: 'channel:123' }, idempotencyKey: reactKey,
  };
  assert.deepEqual(await client.send('message.action', reactParams), { ok: true, added: '👍' });
  assert.deepEqual(await client.send('message.action', reactParams), { ok: true, added: '👍' }, 'idempotent');
  assert.equal(server.state.reactionLog.length, 1);
  assert.deepEqual(await client.send('message.action', {
    ...reactParams, params: { ...reactParams.params, remove: true }, idempotencyKey: `idem_${crypto.randomUUID()}`,
  }), { ok: true, removed: '👍' });
  assert.equal((await client.call('message.action', { ...reactParams, channel: 'webchat', idempotencyKey: `idem_${crypto.randomUUID()}` }))
    .error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('message.action', { ...reactParams, action: 'pin', idempotencyKey: `idem_${crypto.randomUUID()}` }))
    .error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('message.action', { channel: 'discord', action: 'react', params: {} })).error.code, 'INVALID_REQUEST');
  for (const params of [{ messageId: '1300000000000000001' }, { emoji: '👍' }, { messageId: '', emoji: '👍' }]) {
    const missing = await client.call('message.action', { ...reactParams, params, idempotencyKey: `idem_${crypto.randomUUID()}` });
    assert.equal(missing.error.code, 'INVALID_REQUEST', `react without ${JSON.stringify(params)} is rejected`);
  }
  assert.equal((await client.call('message.action', { ...reactParams, idempotencyKey: undefined })).error.code, 'INVALID_REQUEST',
    'idempotencyKey is required');
  assert.equal(server.state.reactionLog.length, 2, 'only accepted reactions are logged');
  assert.deepEqual(server.state.reactionLog.map((entry) => [entry.emoji, entry.remove ?? false]), [['👍', false], ['👍', true]]);

  // Reply previews are cut to 2000 characters, like upstream.
  const report = (await client.send('chat.history', { sessionKey: 'agent:research:main' })).messages
    .find((m) => m.role === 'assistant' && JSON.stringify(m.content).includes('Long report'));
  const reportRun = await client.send('chat.send', {
    sessionKey: 'agent:research:main', message: 'about the report', replyToId: report.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === reportRun.runId && p.state === 'final', 10_000);
  const reportReply = (await client.send('chat.history', { sessionKey: 'agent:research:main' })).messages
    .find((m) => m.__openclaw?.runId === reportRun.runId && m.role === 'user');
  assert.equal(reportReply.__openclaw.replyToPreview.text.length, 2000);
  assert.ok(reportReply.__openclaw.replyToPreview.text.startsWith('## Long report'));
  assert.equal(reportReply.__openclaw.replyToPreview.senderLabel, 'Scout');

}
