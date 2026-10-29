import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

// sessions.patch thinkingLevel (#1086): set, reject unknown levels, clear with null, broadcast.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${server.address().port}`, makeDevice(), 'dev-token');
    await client.send('sessions.subscribe', {});
    const key = 'agent:main:main';
    const rowOf = async (k) => (await client.send('sessions.list', {})).sessions.find((row) => row.key === k);

    let row = await rowOf(key);
    assert.equal(row.thinkingLevel, undefined, 'main follows its default');
    assert.equal(row.thinkingDefault, 'medium');
    assert.deepEqual(row.thinkingLevels.map((level) => level.id),
      ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'adaptive', 'max', 'ultra']);
    assert.equal((await rowOf('agent:research:dashboard:papers')).thinkingLevel, 'ultra', 'seeded on Ultra');
    assert.equal((await client.send('chat.history', { sessionKey: key, limit: 1 })).thinkingLevel, 'medium');

    const changed = client.waitEvent('sessions.changed', (p) => p.sessionKey === key && p.reason === 'patch');
    const patched = await client.send('sessions.patch', { key, thinkingLevel: 'high' });
    assert.equal(patched.entry.thinkingLevel, 'high');
    assert.equal((await changed).session.thinkingLevel, 'high', 'the change is broadcast');
    row = await rowOf(key);
    assert.equal(row.thinkingLevel, 'high');
    assert.equal((await client.send('chat.history', { sessionKey: key, limit: 1 })).thinkingLevel, 'high');

    const rejected = await client.call('sessions.patch', { key, thinkingLevel: 'galaxy-brain' });
    assert.equal(rejected.ok, false);
    assert.equal(rejected.error.code, 'INVALID_REQUEST');
    assert.equal((await rowOf(key)).thinkingLevel, 'high', 'a rejected level leaves the row alone');

    const cleared = await client.send('sessions.patch', { key, thinkingLevel: null });
    assert.equal(cleared.entry.thinkingLevel, undefined, 'null clears the override');
    assert.equal(cleared.entry.thinkingDefault, 'medium');
    assert.equal((await rowOf(key)).thinkingLevel, undefined);
  } finally {
    await server.close();
  }
}
