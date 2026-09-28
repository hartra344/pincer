import assert from 'node:assert/strict';
import crypto from 'node:crypto';

export async function run(ctx) {
  const { client, final, message, requested } = ctx;
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

}
