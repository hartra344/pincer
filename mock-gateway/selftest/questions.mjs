import assert from 'node:assert/strict';
import crypto from 'node:crypto';

export async function run(ctx) {
  const { client } = ctx;

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

  // Secure-form questions carry only field metadata and never echo the answers back.
  const secureRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'please help me login',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const securePrompt = await client.waitEvent('question.requested', (p) => p.runId === secureRun.runId);
  assert.equal(securePrompt.kind, 'secure_form');
  assert.equal(securePrompt.origin, 'mail.google.com');
  assert.equal(securePrompt.fields.length, 3);
  assert.deepEqual(securePrompt.fields.map((field) => field.role), ['username', 'password', 'otp']);
  const listed = await client.send('question.list');
  assert.ok(listed.questions.some((q) => q.id === securePrompt.id && q.kind === 'secure_form'));

  const invalid = await client.call('question.resolve', {
    id: securePrompt.id,
    answers: { requestId: securePrompt.requestId, answers: { identifier: 'user@example.com' } },
  });
  assert.equal(invalid.error.details.reason, 'QUESTION_INVALID_ANSWER');

  const canary = {
    identifier: 'user+canary@example.com',
    password: 'mock-password-canary',
    otp: '123456',
  };
  const resolvedEvent = client.waitEvent('question.resolved', (p) => p.id === securePrompt.id);
  const resolution = await client.send('question.resolve', {
    id: securePrompt.id,
    answers: { requestId: securePrompt.requestId, answers: canary },
  });
  assert.equal(resolution.status, 'answered');
  assert.deepEqual((await resolvedEvent).answers, { requestId: securePrompt.requestId, answers: canary });

  const secureFinal = await client.waitEvent('chat', (p) => p.runId === secureRun.runId && p.state === 'final', 10_000);
  const finalText = secureFinal.message.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  assert.match(finalText, /mail\.google\.com/);
  for (const secret of Object.values(canary)) assert.ok(!finalText.includes(secret), 'final reply must not echo secure-form values');
}
