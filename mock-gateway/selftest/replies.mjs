import assert from 'node:assert/strict';
import crypto from 'node:crypto';

export async function run(ctx) {
  const { client, history, final, afterHooks } = ctx;
  // Replies: replyToId persists the quoted target's id and a preview, like upstream.
  const quotedTarget = afterHooks.messages.find((m) => m.role === 'assistant' && m.content.some((b) => b.type === 'text'));
  const replyRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'replying to that',
    replyToId: quotedTarget.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === replyRun.runId && p.state === 'final', 10_000);
  const afterReply = await client.send('chat.history', { sessionKey: 'agent:main:main' });
  const replyEntry = afterReply.messages.find((m) => m.__openclaw?.runId === replyRun.runId && m.role === 'user');
  assert.equal(replyEntry.__openclaw.replyToId, quotedTarget.__openclaw.id);
  assert.equal(replyEntry.__openclaw.replyToPreview.senderLabel, 'Claw');
  assert.ok(replyEntry.__openclaw.replyToPreview.text.length > 0);
  assert.ok(replyEntry.__openclaw.replyToPreview.text.length <= 2000);
  const ownTarget = afterReply.messages.find((m) => m.role === 'user' && m.__openclaw?.id);
  const ownRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main', message: 'about my own message', replyToId: ownTarget.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === ownRun.runId && p.state === 'final', 10_000);
  const unknownRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main', message: 'unknown target', replyToId: 'pending:nope',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === unknownRun.runId && p.state === 'final', 10_000);
  const afterOwn = (await client.send('chat.history', { sessionKey: 'agent:main:main' })).messages;
  assert.equal(afterOwn.find((m) => m.__openclaw?.runId === ownRun.runId && m.role === 'user').__openclaw.replyToPreview.senderLabel,
    'Pincer Selftest');
  assert.equal(afterOwn.find((m) => m.__openclaw?.runId === unknownRun.runId && m.role === 'user').__openclaw.replyToId, undefined,
    'unknown targets send without reply metadata');
  // MOCK_NO_REPLY_TO=1 is a Gateway from before replies.
  process.env.MOCK_NO_REPLY_TO = '1';
  try {
    const noReply = await client.call('chat.send', {
      sessionKey: 'agent:main:main', message: 'x', replyToId: quotedTarget.__openclaw.id, idempotencyKey: `idem_${crypto.randomUUID()}`,
    });
    assert.equal(noReply.error.code, 'INVALID_REQUEST');
    assert.equal(noReply.error.message, "invalid chat.send params: at root: unexpected property 'replyToId'");
  } finally {
    delete process.env.MOCK_NO_REPLY_TO;
  }

  // Agent reply targets: `openclawDelivery` on assistant messages of the seeded Telegram chat.
  const tg = (await client.send('chat.history', { sessionKey: 'agent:main:telegram:home:direct:5550142' })).messages;
  const tgUsers = tg.filter((m) => m.role === 'user');
  assert.equal(tgUsers[0].__openclaw.id, 'mock-tg-clinic');
  assert.equal(tgUsers[0].__openclaw.transport.messageId, '9101');
  const tgAssistants = tg.filter((m) => m.role === 'assistant');
  assert.equal(tgAssistants[0].openclawDelivery.replyToId, 'mock-tg-clinic', 'answers an earlier message');
  assert.ok(tg.some((m) => m.__openclaw?.id === tgAssistants[0].openclawDelivery.replyToId));
  assert.equal(tgUsers[0].__openclaw.senderName, 'Maya');
  assert.equal(tgUsers[0].senderLabel, 'Maya');
  const byChannelId = tgAssistants.find((m) => m.openclawDelivery?.replyToId === '9104');
  assert.ok(tgUsers.some((m) => m.__openclaw.transport.messageId === '9104'), 'a channel-native id names a user message');
  assert.ok(byChannelId);
  assert.equal(tgAssistants.find((m) => m.openclawDelivery?.replyToCurrent === true).openclawDelivery.replyToCurrent, true);
  assert.match(tgAssistants[tgAssistants.length - 1].content[0].text, /^\[\[reply_to_current\]\] /, 'a leaked directive stays in the text');

}
