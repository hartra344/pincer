import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// talk.catalog shape (#973) plus the hidden-consult trigger; the unconfigured variant runs on a fresh server.
export async function run(ctx) {
  const { client } = ctx;
  assert.ok(client.hello.features.methods.includes('talk.catalog'), 'hello advertises talk.catalog');

  const catalog = await client.send('talk.catalog', {});
  assert.deepEqual(catalog.modes, ['realtime', 'stt-tts', 'transcription']);
  assert.deepEqual(catalog.transports, ['gateway-relay', 'webrtc']);
  assert.deepEqual(catalog.brains, ['agent-consult', 'direct-tools', 'none']);
  for (const group of ['speech', 'transcription', 'realtime']) {
    assert.ok(Array.isArray(catalog[group].providers), `${group}.providers`);
  }
  assert.equal(catalog.realtime.ready, true);
  assert.equal(catalog.realtime.activeProvider, 'openai');
  const openai = catalog.realtime.providers.find((p) => p.id === 'openai');
  assert.equal(openai.configured, true);
  assert.ok(openai.label.length > 0);
  assert.ok(openai.transports.includes('gateway-relay'));
  assert.ok(openai.brains.includes('agent-consult'));
  assert.equal(openai.supportsBargeIn, true);
  assert.deepEqual(openai.inputAudioFormats[0], { encoding: 'pcm16', sampleRateHz: 24000, channels: 1 });

  await client.send('sessions.messages.subscribe', { key: 'agent:main:main' });
  const hiddenKey = `hidden_${crypto.randomUUID()}`;
  const seen = [];
  const collect = (event) => seen.push(event);
  client.emitter.on('session.message', collect);
  try {
    const run = await client.send('chat.send', { sessionKey: 'agent:main:main', message: '/mock hidden-consult', idempotencyKey: hiddenKey });
    await client.waitEvent('chat', (p) => p.runId === run.runId && p.state === 'final', 10_000);
  } finally {
    client.emitter.off('session.message', collect);
  }
  const hidden = seen.filter((e) => e.message?.display === false);
  assert.ok(hidden.length >= 1, 'trigger emits a display:false session.message');
  assert.equal(hidden[0].message.provenance?.kind, 'internal_system');
  assert.ok(seen.some((e) => e.message?.role === 'assistant' && e.message?.display !== false), 'a visible assistant reply follows');

  const previous = process.env.MOCK_TALK;
  process.env.MOCK_TALK = 'unconfigured';
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const other = await connectClient(`ws://127.0.0.1:${server.address().port}`, makeDevice(), 'dev-token', true, [...BASE_SCOPES]);
    const result = await other.send('talk.catalog', {});
    assert.equal(result.realtime.ready, false);
    assert.ok(result.realtime.providers.length > 0);
    assert.ok(result.realtime.providers.every((p) => p.configured === false));
    other.ws.close();
  } finally {
    if (previous === undefined) delete process.env.MOCK_TALK;
    else process.env.MOCK_TALK = previous;
    await server.close();
  }
}
