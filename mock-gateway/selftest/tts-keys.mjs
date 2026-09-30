import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { BASE_SCOPES, connectClient, makeDevice } from './helpers.mjs';

// ElevenLabs key names (speakerVoiceId over voiceId, `model` ignored for `modelId`), persona-sourced provider,
// null deletes in config.patch, secrets.store.delete and the tts.status auto modes.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    const patch = async (value) => {
      const snap = await admin.send('config.get');
      const res = await admin.call('config.patch', { raw: JSON.stringify(value), baseHash: snap.hash });
      assert.equal(res.ok, true, JSON.stringify(res));
    };
    const eleven = (fields) => patch({ tts: { providers: { elevenlabs: fields } } });
    const convert = (params = {}) => admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs', ...params });
    const stored = async (name) => (await admin.send('secrets.store.list', {})).entries.some((e) => e.name === name);
    const configured = async () => (await admin.send('tts.providers', {})).providers.find((p) => p.id === 'elevenlabs').configured;

    // speakerVoiceId wins over voiceId, whichever order they are written in.
    await eleven({ apiKey: 'sk_ok', speakerVoiceId: 'good_voice', voiceId: 'bogus_voice' });
    let res = await convert();
    assert.equal(res.payload.provider, 'elevenlabs', JSON.stringify(res));
    await eleven({ speakerVoiceId: 'bogus_voice', voiceId: 'good_voice' });
    res = await convert();
    assert.match(res.error.message, /voice_not_found: A voice with the voice_id bogus_voice/);
    res = await convert({ voiceId: 'good_voice' });
    assert.equal(res.payload.provider, 'elevenlabs', 'an explicit voiceId overrides the config');
    await eleven({ speakerVoiceId: null });
    assert.equal((await convert()).payload.provider, 'elevenlabs', 'voiceId applies once speakerVoiceId is deleted');

    // ElevenLabs reads modelId only: a `model` key is ignored, never a failure.
    await eleven({ model: 'eleven_bogus' });
    assert.equal((await convert()).payload.provider, 'elevenlabs', 'the ignored model key does not reach the provider');
    await eleven({ modelId: 'eleven_bogus' });
    assert.match((await convert()).error.message, /model_id_does_not_exist: Model with ID eleven_bogus/);
    await eleven({ modelId: 'eleven_v3', model: 'eleven_bogus' });
    assert.equal((await convert()).payload.provider, 'elevenlabs', 'modelId wins over model');
    assert.equal((await admin.send('config.get')).config.tts.providers.elevenlabs.model, 'eleven_bogus', 'the key stays in config');

    // Persona provider: prefs > persona > config provider > openai.
    assert.equal((await admin.send('tts.status', {})).provider, 'openai');
    await patch({ tts: { personas: { studio: { label: 'Studio', provider: 'elevenlabs', providers: { elevenlabs: {} } } } } });
    const personas = (await admin.send('tts.personas', {})).personas;
    assert.deepEqual(personas.find((p) => p.id === 'studio').providers, ['elevenlabs']);
    await admin.send('tts.setPersona', { persona: 'studio' });
    let status = await admin.send('tts.status', {});
    assert.equal(status.persona, 'studio');
    assert.equal(status.provider, 'elevenlabs', 'the persona supplies the provider');
    assert.equal((await admin.send('tts.providers', {})).active, 'elevenlabs');
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'elevenlabs');
    await admin.send('tts.setProvider', { provider: 'openai' });
    assert.equal((await admin.send('tts.status', {})).provider, 'openai', 'a prefs provider wins over the persona');
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'openai');
    await admin.send('tts.setPersona', { persona: 'off' });

    // Removing a key: config.patch null (JSON merge patch), plus secrets.store.delete and env.vars.
    const ref = { source: 'store', provider: 'default', id: 'ELEVENLABS_API_KEY' };
    await admin.send('secrets.store.set', { name: 'ELEVENLABS_API_KEY', value: 'sk_stored', kind: 'secret' });
    await eleven({ apiKey: ref });
    assert.equal(await configured(), true);
    await eleven({ apiKey: null });
    assert.equal(await configured(), false, 'deleting the apiKey un-configures the provider');
    assert.equal((await admin.send('config.get')).config.tts.providers.elevenlabs.apiKey, undefined);
    assert.equal((await admin.send('config.get')).config.tts.providers.elevenlabs.voiceId, 'good_voice', 'siblings stay');
    assert.equal(await stored('ELEVENLABS_API_KEY'), true);
    assert.deepEqual(await admin.send('secrets.store.delete', { name: 'ELEVENLABS_API_KEY' }), { ok: true, reloaded: true });
    assert.equal(await stored('ELEVENLABS_API_KEY'), false);
    await eleven({ apiKey: ref });
    assert.equal(await configured(), false, 'a ref to a deleted secret does not resolve');
    await eleven({ apiKey: { source: 'env', provider: 'default', id: 'ELEVENLABS_API_KEY' } });
    await patch({ env: { vars: { ELEVENLABS_API_KEY: 'sk_env' } } });
    assert.equal(await configured(), true);
    await patch({ tts: { providers: { elevenlabs: { apiKey: null } } }, env: { vars: { ELEVENLABS_API_KEY: null } } });
    assert.equal(await configured(), false);
    assert.equal((await admin.send('config.get')).config.env?.vars?.ELEVENLABS_API_KEY, undefined);
    await eleven({ apiKey: 'sk_inline' });
    assert.equal(await configured(), true);
    await eleven({ apiKey: null });
    assert.equal(await configured(), false, 'an inline key is removed the same way');

    // Auto mode: prefs win, else config `messages.tts.auto` (upstream) or `tts.auto`, else off.
    status = await admin.send('tts.status', {});
    assert.deepEqual([status.auto, status.enabled], ['off', false]);
    for (const mode of ['inbound', 'tagged']) {
      await patch({ messages: { tts: { auto: mode } } });
      status = await admin.send('tts.status', {});
      assert.deepEqual([status.auto, status.enabled], [mode, true], `config auto ${mode}`);
    }
    await admin.send('tts.enable', {});
    await patch({ messages: { tts: { auto: 'inbound' } } });
    assert.equal((await admin.send('tts.status', {})).auto, 'always', 'prefs written by tts.enable win over config');
    await admin.send('tts.disable', {});
    status = await admin.send('tts.status', {});
    assert.deepEqual([status.auto, status.enabled], ['off', false], 'tts.disable writes prefs off');
    await patch({ messages: { tts: { auto: null } } });
  } finally {
    await server.close();
  }

  // MOCK_TTS_AUTO seeds the config default.
  process.env.MOCK_TTS_AUTO = 'inbound';
  const seeded = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const c = await connectClient(`ws://127.0.0.1:${seeded.address().port}`, makeDevice(), 'dev-token');
    const status = await c.send('tts.status', {});
    assert.deepEqual([status.auto, status.enabled], ['inbound', true]);
    await c.send('tts.disable', {});
    assert.equal((await c.send('tts.status', {})).auto, 'off');
  } finally {
    delete process.env.MOCK_TTS_AUTO;
    await seeded.close();
  }
}
