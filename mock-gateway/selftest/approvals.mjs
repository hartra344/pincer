import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { SEEDED_HISTORY_COUNTS } from '../approvals.mjs';

export async function run(ctx) {
  const { device, first, client, history, final, pushSink, endpoint, message, requested } = ctx;
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

  Object.assign(ctx, { unknown, plugin, system, missing, always, asked });
}
