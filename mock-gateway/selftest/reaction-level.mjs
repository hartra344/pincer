import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// reactionLevel config (#107), on a fresh server so the patches don't leak.
export async function run() {
  const cfgServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${cfgServer.address().port}`, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    // Config round-trip and schema.
    const schema = (await client.send('config.schema', {})).schema.properties.channels.properties;
    for (const channel of ['telegram', 'whatsapp']) {
      assert.deepEqual(schema[channel].properties.reactionLevel.enum, ['off', 'ack', 'minimal', 'extensive']);
      assert.deepEqual(schema[channel].properties.accounts.additionalProperties.properties.reactionLevel.enum, ['off', 'ack', 'minimal', 'extensive']);
    }
    assert.equal(schema.discord.properties.reactionLevel, undefined, 'Discord has no reactionLevel');
    let snap = await client.send('config.get', {});
    assert.equal(snap.config.channels.telegram.reactionLevel, 'minimal');
    assert.equal(snap.config.channels.telegram.accounts.home.reactionLevel, 'extensive');
    assert.equal(snap.config.channels.whatsapp.reactionLevel, undefined);
    await client.send('config.patch', {
      raw: JSON.stringify({ channels: { whatsapp: { reactionLevel: 'ack' }, telegram: { accounts: { home: { reactionLevel: null } } } } }),
      baseHash: snap.hash,
    });
    snap = await client.send('config.get', {});
    assert.equal(snap.config.channels.whatsapp.reactionLevel, 'ack');
    assert.equal(snap.config.channels.telegram.accounts.home.reactionLevel, undefined, 'null clears the override');
    assert.equal(snap.config.channels.telegram.reactionLevel, 'minimal');
    await client.send('config.patch', {
      raw: JSON.stringify({ channels: { whatsapp: { reactionLevel: null }, telegram: { accounts: { home: { reactionLevel: 'extensive' } } } } }),
      baseHash: snap.hash,
    });
    const status = await client.send('channels.status', {});
    assert.deepEqual(status.channelAccounts.telegram.map((a) => a.accountId), ['default', 'home']);

  } finally {
    await cfgServer.close();
  }
}
