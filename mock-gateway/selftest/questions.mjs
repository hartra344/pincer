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

  // Secret-store questions (upstream's `secrets` tool): the value goes to secrets.store, only "stored" goes on.
  const secretRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'save my stripe secret',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const secretPrompt = await client.waitEvent('question.requested', (p) => p.runId === secretRun.runId);
  assert.equal(secretPrompt.kind, undefined, 'upstream question records have no kind');
  assert.equal(secretPrompt.questions.length, 1);
  const [secretQuestion] = secretPrompt.questions;
  assert.equal(secretQuestion.questionId, 'secret_value');
  assert.equal(secretQuestion.isSecret, true);
  assert.deepEqual(secretQuestion.options, []);
  assert.equal(secretQuestion.secretStore.name, 'STRIPE_API_KEY');
  assert.equal(secretQuestion.secretStore.kind, 'secret');

  const twoValues = await client.call('question.resolve', { id: secretPrompt.id, answers: { answers: { secret_value: ['a', 'b'] } } });
  assert.equal(twoValues.error.details.reason, 'QUESTION_INVALID_ANSWER', 'a store-bound answer takes exactly one value');

  const canary = ' sk_test_mock-canary ';
  const resolvedEvent = client.waitEvent('question.resolved', (p) => p.id === secretPrompt.id);
  const resolution = await client.send('question.resolve', { id: secretPrompt.id, answers: { answers: { secret_value: [canary] } } });
  assert.deepEqual(resolution, { status: 'answered', answers: { answers: { secret_value: ['stored'] } } });
  assert.deepEqual((await resolvedEvent).answers, { answers: { secret_value: ['stored'] } });
  assert.equal(ctx.server.state.secretsStore.get('STRIPE_API_KEY').value, canary, 'the exact value lands in the secret store');
  assert.deepEqual(ctx.server.state.questions.get(secretPrompt.id).answers, { answers: { secret_value: ['stored'] } });

  const secretFinal = await client.waitEvent('chat', (p) => p.runId === secretRun.runId && p.state === 'final', 10_000);
  const history = await client.send('chat.history', { sessionKey: 'agent:main:main', limit: 50 });
  assert.ok(!JSON.stringify(history).includes('mock-canary'), 'the secret never reaches the transcript');
  assert.ok(!JSON.stringify(secretFinal).includes('mock-canary'), 'the secret never reaches the reply');
  assert.match(JSON.stringify(history), /Stored; value hidden/);
}
