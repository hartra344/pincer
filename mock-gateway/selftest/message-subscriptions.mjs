import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

// sessions.messages.subscribe observers are keyed by subscriptionId.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${server.address().port}`, makeDevice(), 'dev-token');
    const key = 'agent:main:main';
    const observers = () => [...server.state.connections].flatMap((c) => [...(c.messageSubs.get(key) ?? [])]).sort();
    await client.send('sessions.messages.subscribe', { key, subscriptionId: 'a' });
    await client.send('sessions.messages.subscribe', { key, subscriptionId: 'b' });
    await client.send('sessions.messages.subscribe', { key });
    assert.deepEqual(observers(), ['', 'a', 'b']);
    await client.send('sessions.messages.unsubscribe', { key, subscriptionId: 'a' });
    assert.deepEqual(observers(), ['', 'b']);
    await client.send('sessions.messages.unsubscribe', { key });
    await client.send('sessions.messages.unsubscribe', { key, subscriptionId: 'b' });
    assert.deepEqual(observers(), []);

    process.env.MOCK_NO_SUBSCRIPTION_ID = '1';
    try {
      const rejected = await client.call('sessions.messages.subscribe', { key, subscriptionId: 'a' });
      assert.equal(rejected.error.code, 'INVALID_REQUEST');
      assert.match(rejected.error.message, /sessions\.messages\.subscribe params/);
      await client.send('sessions.messages.subscribe', { key });
      assert.deepEqual(observers(), ['']);
    } finally {
      delete process.env.MOCK_NO_SUBSCRIPTION_ID;
    }
    client.ws.close();
  } finally {
    await server.close();
  }
}
