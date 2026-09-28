import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { url, device, deviceToken, client, history } = ctx;
  // Test hooks for failed sends: one refused, one that drops the connection.
  const refused = await client.call('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'nope [mock:fail-send]',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.equal(refused.ok, false);
  assert.equal(refused.error.code, 'UNAVAILABLE');
  const dropped = await connectClient(url, device, deviceToken, true);
  const closed = new Promise((resolve) => dropped.ws.once('close', resolve));
  dropped.call('chat.send', { sessionKey: 'agent:main:main', message: 'bye [mock:drop]', idempotencyKey: `idem_${crypto.randomUUID()}` });
  assert.equal(await closed, 1012);
  const afterHooks = await client.send('chat.history', { sessionKey: 'agent:main:main' });
  assert.ok(!afterHooks.messages.some((m) => JSON.stringify(m.content).includes('[mock:')), 'hooked sends leave no messages');

  // `[mock:fail-run]` ends the run with a chat `error` and an `error` lifecycle phase, like a provider timeout.
  const failedChat = client.waitEvent('chat', (p) => p.sessionKey === 'agent:research:main' && p.state === 'error', 10_000);
  const failedLifecycle = client.waitEvent('agent', (p) => p.sessionKey === 'agent:research:main' && p.stream === 'lifecycle' && p.data?.phase === 'error', 10_000);
  const failing = await client.send('chat.send', {
    sessionKey: 'agent:research:main',
    message: 'this one breaks [mock:fail-run]',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const failed = await failedChat;
  assert.equal(failed.runId, failing.runId);
  assert.equal(failed.errorKind, 'timeout');
  assert.ok(failed.errorMessage);
  assert.equal((await failedLifecycle).runId, failing.runId);

  Object.assign(ctx, { dropped, closed, afterHooks, failed });
}
