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

  // Gateway-level reactions: users.self, session.reactions.list/set and the session.reaction event.
  assert.ok(client.hello.features.methods.includes('session.reactions.set') && client.hello.features.methods.includes('session.reactions.list'));
  assert.ok(client.hello.features.events.includes('session.reaction'));
  assert.equal((await client.send('users.self')).profile.id, 'demo-owner');
  const mainKey = 'agent:main:main';
  const mainHistory = (await client.send('chat.history', { sessionKey: mainKey })).messages;
  const diskReply = mainHistory.find((m) => m.role === 'assistant' && JSON.stringify(m.content).includes('Disk status'));
  const listed = await client.send('session.reactions.list', { sessionKey: mainKey });
  assert.ok(listed.sessionId);
  const seeded = listed.reactions[diskReply.__openclaw.id];
  assert.deepEqual(seeded.find((r) => r.emoji === '👍').identities.map((i) => i.id).sort(), ['demo-owner', 'sam']);
  assert.equal(seeded.find((r) => r.emoji === '🎉').count, 2);
  assert.deepEqual((await client.send('session.reactions.list', { sessionKey: 'agent:coder:main' })).reactions, {});
  const setParams = { sessionKey: mainKey, messageId: diskReply.__openclaw.id, emoji: '❤️' };
  const eventP = client.waitEvent('session.reaction', (p) => p.messageId === setParams.messageId && p.emoji === '❤️', 5000);
  const added = await client.send('session.reactions.set', setParams);
  assert.deepEqual(added.reactions.find((r) => r.emoji === '❤️'), { emoji: '❤️', count: 1, identities: [{ id: 'demo-owner', label: 'You' }] });
  assert.equal(added.mirror.status, 'skipped');
  const event = await eventP;
  assert.equal(event.action, 'added');
  assert.equal(event.actor.id, 'demo-owner');
  assert.deepEqual(event.reactions, added.reactions);
  const again = await client.send('session.reactions.set', setParams);
  assert.equal(again.mirror.reason, 'reaction already in that state');
  const removed = await client.send('session.reactions.set', { ...setParams, remove: true });
  assert.ok(!removed.reactions.some((r) => r.emoji === '❤️'));
  const bridged = lab.find((m) => m.__openclaw?.transport?.messageId);
  assert.equal((await client.send('session.reactions.set', { sessionKey: 'agent:main:discord:channel:123', messageId: bridged.__openclaw.id, emoji: '🔥' })).mirror.status, 'delivered');
  const bad = (params) => client.call('session.reactions.set', { ...setParams, ...params }).then((r) => r.error);
  assert.equal((await bad({ messageId: 'nope' })).message, 'unknown message');
  assert.equal((await bad({ emoji: 'ab' })).message, 'one emoji grapheme is required');
  assert.equal((await bad({ emoji: '👍👍' })).code, 'INVALID_REQUEST');
  assert.equal((await client.call('session.reactions.list', { sessionKey: 'agent:nope:main' })).error.code, 'INVALID_REQUEST');
  process.env.MOCK_NO_PROFILE = '1';
  try {
    assert.equal((await client.call('users.self')).error.code, 'FORBIDDEN');
    assert.equal((await bad({})).message, 'identified reaction author required');
  } finally {
    delete process.env.MOCK_NO_PROFILE;
  }
  process.env.MOCK_NO_REACTIONS = '1';
  try {
    const old = await client.call('session.reactions.list', { sessionKey: mainKey });
    assert.equal(old.error.message, 'unknown method: session.reactions.list');
  } finally {
    delete process.env.MOCK_NO_REACTIONS;
  }

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
