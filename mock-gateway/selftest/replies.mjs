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

}
