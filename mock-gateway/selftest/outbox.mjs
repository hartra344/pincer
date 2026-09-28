import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { connectClient } from './helpers.mjs';

// Outbox hooks (#46): upstream-shaped send failures, drops, and idempotencyKey dedupe.
export async function run(ctx) {
  const { url, device, deviceToken } = ctx;
  const client = await connectClient(url, device, deviceToken, true);
  const { key } = await client.send('sessions.create', { agentId: 'main', label: 'Outbox selftest' });
  await client.send('sessions.messages.subscribe', { key });
  const userCopies = async (text) =>
    (await client.send('chat.history', { sessionKey: key })).messages
      .filter((m) => m.role === 'user' && m.content.some((b) => b.type === 'text' && b.text === text)).length;
  const finalFor = (runId) => client.waitEvent('chat', (p) => p.runId === runId && p.state === 'final', 10_000);

  // A plain duplicate starts nothing new: `in_flight` while the run goes, then the cached `ok`.
  const dupKey = `idem_${crypto.randomUUID()}`;
  const dupText = 'outbox dedupe check';
  const firstSend = await client.send('chat.send', { sessionKey: key, message: dupText, idempotencyKey: dupKey });
  assert.equal(firstSend.status, 'started');
  const inFlight = await client.send('chat.send', { sessionKey: key, message: dupText, idempotencyKey: dupKey });
  assert.deepEqual(inFlight, { runId: firstSend.runId, status: 'in_flight' });
  await finalFor(firstSend.runId);
  const afterFinal = await client.send('chat.send', { sessionKey: key, message: dupText, idempotencyKey: dupKey });
  assert.deepEqual(afterFinal, { runId: firstSend.runId, status: 'ok' });
  assert.equal(await userCopies(dupText), 1, 'a resent key lands once');

  // `[mock:reject-send]`: non-retryable INVALID_REQUEST every time; nothing lands.
  const rejectKey = `idem_${crypto.randomUUID()}`;
  for (let i = 0; i < 2; i += 1) {
    const rejected = await client.call('chat.send', { sessionKey: key, message: 'bad [mock:reject-send]', idempotencyKey: rejectKey });
    assert.equal(rejected.ok, false);
    assert.equal(rejected.error.code, 'INVALID_REQUEST');
    assert.equal(rejected.error.retryable, undefined);
  }

  // `[mock:unavailable-once]`: first attempt is upstream's retryable UNAVAILABLE; the same key then lands once.
  const busyKey = `idem_${crypto.randomUUID()}`;
  const busyText = 'busy then fine [mock:unavailable-once]';
  const busy = await client.call('chat.send', { sessionKey: key, message: busyText, idempotencyKey: busyKey });
  assert.equal(busy.ok, false);
  assert.deepEqual(busy.error, {
    code: 'UNAVAILABLE', message: 'Previous run is still shutting down. Please try again in a moment.', retryable: true, retryAfterMs: 250,
  });
  const busyRetry = await client.send('chat.send', { sessionKey: key, message: busyText, idempotencyKey: busyKey });
  assert.equal(busyRetry.status, 'started');
  await finalFor(busyRetry.runId);
  assert.equal(await userCopies(busyText), 1);
  // A fresh key with the same text fails again: the hook counts attempts per key, not per text.
  const busyAgain = await client.call('chat.send', { sessionKey: key, message: busyText, idempotencyKey: `idem_${crypto.randomUUID()}` });
  assert.equal(busyAgain.error?.retryable, true);

  // `[mock:drop-once]`: the socket closes before the Gateway accepts; the retry lands once.
  const dropKey = `idem_${crypto.randomUUID()}`;
  const dropText = 'dropped before accept [mock:drop-once]';
  const dropper = await connectClient(url, device, deviceToken, true);
  const dropClosed = new Promise((resolve) => dropper.ws.once('close', resolve));
  dropper.call('chat.send', { sessionKey: key, message: dropText, idempotencyKey: dropKey });
  assert.equal(await dropClosed, 1012);
  assert.equal(await userCopies(dropText), 0, 'nothing accepted before the drop');
  const dropRetry = await client.send('chat.send', { sessionKey: key, message: dropText, idempotencyKey: dropKey });
  assert.equal(dropRetry.status, 'started');
  await finalFor(dropRetry.runId);
  assert.equal(await userCopies(dropText), 1);

  // `[mock:drop-after-accept]`: accepted, then the socket drops before the ack (the ambiguous case).
  // Retrying with the same key gets the dedupe answer and no second copy.
  const ackKey = `idem_${crypto.randomUUID()}`;
  const ackText = 'accepted then dropped [mock:drop-after-accept]';
  const acker = await connectClient(url, device, deviceToken, true);
  const ackClosed = new Promise((resolve) => acker.ws.once('close', resolve));
  const acceptedFinal = client.waitEvent('chat', (p) => p.sessionKey === key && p.state === 'final', 10_000);
  let ackAnswered = false;
  acker.call('chat.send', { sessionKey: key, message: ackText, idempotencyKey: ackKey }).then(() => { ackAnswered = true; });
  assert.equal(await ackClosed, 1012);
  const retried = await client.send('chat.send', { sessionKey: key, message: ackText, idempotencyKey: ackKey });
  assert.ok(['in_flight', 'ok'].includes(retried.status), `dedupe status ${retried.status}`);
  const landed = await acceptedFinal;
  assert.equal(landed.runId, retried.runId);
  const settled = await client.send('chat.send', { sessionKey: key, message: ackText, idempotencyKey: ackKey });
  assert.deepEqual(settled, { runId: retried.runId, status: 'ok' });
  assert.equal(ackAnswered, false, 'the dropped send never got an ack');
  assert.equal(await userCopies(ackText), 1, 'the ambiguous send lands exactly once');
  client.ws.close();
}
