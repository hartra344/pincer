import assert from 'node:assert/strict';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { url, device, deviceToken } = ctx;
  const c = await connectClient(url, device, deviceToken, true);
  for (const m of ['tts.status', 'tts.providers', 'tts.personas', 'tts.enable', 'tts.disable', 'tts.setProvider', 'tts.setPersona', 'tts.convert', 'tts.speak', 'secrets.store.set']) {
    assert.ok(c.hello.features.methods.includes(m), m);
  }
  const status = await c.send('tts.status', {});
  assert.equal(status.enabled, false);
  assert.equal(status.auto, 'off');
  assert.equal(status.provider, 'openai');
  assert.equal(status.persona, null);
  assert.ok(status.personas.length === 2 && status.providerStates.some((p) => p.configured) && status.providerStates.some((p) => !p.configured));
  assert.equal(typeof status.prefsPath, 'string');
  const providers = await c.send('tts.providers', {});
  assert.equal(providers.active, 'openai');
  assert.deepEqual(providers.providers.find((p) => p.id === 'openai').voices, ['alloy', 'verse']);
  const personas = await c.send('tts.personas', {});
  assert.equal(personas.active, null);
  assert.ok(personas.personas.every((p) => Array.isArray(p.providers)));

  assert.deepEqual(await c.send('tts.enable', {}), { enabled: true });
  assert.equal((await c.send('tts.status', {})).auto, 'always');
  assert.deepEqual(await c.send('tts.disable', {}), { enabled: false });
  assert.equal((await c.send('tts.status', {})).enabled, false);

  assert.deepEqual(await c.send('tts.setProvider', { provider: 'elevenlabs' }), { provider: 'elevenlabs' });
  assert.equal((await c.send('tts.providers', {})).active, 'elevenlabs');
  const badProvider = await c.call('tts.setProvider', { provider: 'nope' });
  assert.equal(badProvider.error.code, 'INVALID_REQUEST');
  assert.equal(badProvider.error.message, 'Invalid provider. Use a registered TTS provider id.');
  await c.send('tts.setProvider', { provider: 'openai' });

  assert.deepEqual(await c.send('tts.setPersona', { persona: 'Narrator' }), { persona: 'narrator' });
  assert.equal((await c.send('tts.personas', {})).active, 'narrator');
  assert.equal((await c.send('tts.status', {})).persona, 'narrator');
  const badPersona = await c.call('tts.setPersona', { persona: 'nope' });
  assert.equal(badPersona.error.message, 'Invalid persona. Use a configured TTS persona id.');
  for (const clear of ['off', 'none', 'default', '']) {
    await c.send('tts.setPersona', { persona: 'concise' });
    assert.deepEqual(await c.send('tts.setPersona', { persona: clear }), { persona: null }, clear);
  }

  const clip = await c.send('tts.speak', { text: 'Hello there.' });
  assert.equal(clip.provider, 'openai');
  assert.equal(clip.mimeType, 'audio/wav');
  assert.equal(clip.fileExtension, 'wav');
  assert.equal(clip.outputFormat, 'wav');
  const wav = Buffer.from(clip.audioBase64, 'base64');
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  assert.equal(wav.readUInt32LE(4) + 8, wav.length);
  const noText = await c.call('tts.speak', { text: '  ' });
  assert.equal(noText.error.code, 'INVALID_REQUEST');
  assert.equal(noText.error.message, 'tts.speak requires text');
  const tooLong = await c.call('tts.speak', { text: 'a'.repeat(5000) });
  assert.match(tooLong.error.message, /^tts\.speak text too long \(5000 chars, max 4096\)$/);

  const conv = await c.send('tts.convert', { text: 'Hi' });
  assert.equal(typeof conv.audioPath, 'string');
  assert.equal(conv.voiceCompatible, false);
  assert.equal((await c.call('tts.convert', {})).error.message, 'tts.convert requires text');
  c.ws.close();
}
