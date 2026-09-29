import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { parseDelays } from '../control.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

// mock.control: RPC counters, delayed responses, emit, patchSession and drop.
export async function run() {
  assert.deepEqual([...parseDelays('sessions.subscribe=800, chat.history=300,bad,x=0')], [['sessions.subscribe', 800], ['chat.history', 300]]);
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const control = await connectClient(url, makeDevice(), 'dev-token');
    const app = await connectClient(url, makeDevice(), 'dev-token');
    await control.send('mock.control', { action: 'resetStats' });

    await app.send('users.prefs.get', {});
    await app.send('users.prefs.get', {});
    await app.send('sessions.list', {});
    const stats = await control.send('mock.control', { action: 'stats' });
    assert.equal(stats.total['users.prefs.get'], 2);
    assert.equal(stats.total['sessions.list'], 1);
    assert.equal(stats.total['mock.control'], undefined, 'control calls are not counted');
    assert.equal(stats.connections.length, 1);
    assert.deepEqual(stats.connections[0].log, ['users.prefs.get', 'users.prefs.get', 'sessions.list']);

    // Delayed subscribe: the snapshot is taken at request time, events sent meanwhile arrive first.
    await control.send('mock.control', { action: 'setDelay', delays: { 'sessions.subscribe': 300 } });
    const started = Date.now();
    const events = [];
    app.emitter.on('sessions.changed', (payload) => events.push(payload));
    const pending = app.send('sessions.subscribe', {});
    await new Promise((resolve) => setTimeout(resolve, 50));
    await control.send('mock.control', { action: 'patchSession', key: 'agent:main:main', patch: { label: 'Changed mid-subscribe' } });
    await control.send('mock.control', { action: 'emit', event: 'sessions.changed', payload: { reason: 'groups' } });
    const subscribed = await pending;
    assert.ok(Date.now() - started >= 280, 'subscribe response was delayed');
    assert.equal(events.length, 2, 'events arrived during the delay');
    assert.equal(events[0].session.label, 'Changed mid-subscribe');
    assert.notEqual(subscribed.list.sessions.find((row) => row.key === 'agent:main:main').label, 'Changed mid-subscribe');
    await control.send('mock.control', { action: 'setDelay', delays: {} });

    // Drop closes the other connections and leaves the control one.
    const closed = new Promise((resolve) => app.ws.once('close', resolve));
    const dropped = await control.send('mock.control', { action: 'drop' });
    assert.equal(dropped.dropped, 1);
    await closed;
    assert.equal((await control.send('mock.control', { action: 'stats' })).total['sessions.list'], 1);
    control.ws.close();
  } finally {
    await server.close();
  }
}
