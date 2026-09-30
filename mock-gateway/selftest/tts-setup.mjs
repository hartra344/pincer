import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { BASE_SCOPES, connectClient, makeDevice } from './helpers.mjs';

const REDACTED = '__OPENCLAW_REDACTED__';

export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    for (const m of ['secrets.store.set', 'secrets.store.list', 'secrets.store.delete']) assert.ok(admin.hello.features.methods.includes(m), m);

    // ElevenLabs starts without a key: "Needs key", its built-in models listed, speak falls back to openai.
    const providers = async () => (await admin.send('tts.providers', {})).providers.find((p) => p.id === 'elevenlabs');
    let eleven = await providers();
    assert.equal(eleven.configured, false);
    assert.deepEqual(eleven.models.slice(0, 3), ['eleven_v3', 'eleven_multilingual_v2', 'eleven_flash_v2_5']);
    assert.equal((await admin.send('tts.status', {})).providerStates.find((p) => p.id === 'elevenlabs').configured, false);
    await admin.send('tts.setProvider', { provider: 'elevenlabs' });
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'openai');
    const explicit = await admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs' });
    assert.equal(explicit.error.code, 'UNAVAILABLE');
    assert.equal(explicit.error.message, 'TTS conversion failed: elevenlabs: not configured');

    // secrets.store needs operator.admin.
    const denied = await reader.call('secrets.store.list', {});
    assert.equal(denied.error.details.scope, 'operator.admin');
    assert.deepEqual((await admin.send('secrets.store.list', {})).entries, []);
    const badName = await admin.call('secrets.store.set', { name: 'elevenlabs_api_key', value: 'x', kind: 'secret' });
    assert.equal(badName.error.code, 'INVALID_REQUEST');
    assert.match(badName.error.message, /^Secret store name must match /);
    assert.match((await admin.call('secrets.store.set', { name: 'ELEVENLABS_API_KEY', value: '', kind: 'secret' })).error.message, /^Secret store value is empty/);
    assert.match((await admin.call('secrets.store.set', { name: 'ELEVENLABS_API_KEY', value: REDACTED, kind: 'secret' })).error.message, /redaction placeholder/);

    // Save a key: secrets.store.set, then a SecretRef in the config.
    assert.deepEqual(await admin.send('secrets.store.set', { name: 'ELEVENLABS_API_KEY', value: 'sk_live_abc123', kind: 'secret' }), { ok: true, reloaded: true });
    const listed = (await admin.send('secrets.store.list', {})).entries;
    assert.equal(listed.length, 1);
    assert.equal(listed[0].name, 'ELEVENLABS_API_KEY');
    assert.equal(listed[0].kind, 'secret');
    assert.equal('value' in listed[0], false, 'secret values are never disclosed');
    assert.equal((await providers()).configured, false, 'a stored secret alone is not enough until the config references it');
    const ref = { source: 'store', provider: 'default', id: 'ELEVENLABS_API_KEY' };
    const patch = async (value) => {
      const snap = await admin.send('config.get');
      return admin.call('config.patch', { raw: JSON.stringify(value), baseHash: snap.hash });
    };
    let res = await patch({ tts: { providers: { elevenlabs: { apiKey: ref, modelId: 'eleven_v3', speakerVoiceId: 'pMsXgVXv3BLzUgSXRplE' } } } });
    assert.equal(res.ok, true, JSON.stringify(res));
    const tts = (await admin.send('config.get')).config.tts.providers;
    assert.deepEqual(tts.elevenlabs.apiKey, { ...ref, id: REDACTED }, 'a SecretRef keeps source and provider; the id is redacted');
    assert.equal(tts.elevenlabs.modelId, 'eleven_v3');
    assert.equal(tts.openai.model, 'gpt-4o-mini-tts', 'the patch merged');
    assert.equal((await providers()).configured, true);
    assert.equal((await admin.send('tts.status', {})).providerStates.find((p) => p.id === 'elevenlabs').configured, true);
    let clip = await admin.send('tts.speak', { text: 'Hi' });
    assert.equal(clip.provider, 'elevenlabs');
    assert.equal(clip.mimeType, 'audio/wav');

    // A rejected model or key makes tts.speak fall back through the chain to openai (upstream executeTtsProviderAttempts);
    // tts.convert with an explicit provider/modelId/voiceId never falls back and reports the provider's error.
    const modelError = (id) => `TTS conversion failed: elevenlabs: ElevenLabs API error (400): model_id_does_not_exist: Model with ID ${id} does not exist`;
    res = await patch({ tts: { providers: { elevenlabs: { modelId: 'eleven_bogus' } } } });
    assert.equal(res.ok, true);
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'openai');
    assert.equal((await admin.send('tts.convert', { text: 'Hi' })).provider, 'openai');
    let failed = await admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs' });
    assert.equal(failed.error.code, 'UNAVAILABLE');
    assert.equal(failed.error.message, modelError('eleven_bogus'));
    await patch({ tts: { providers: { elevenlabs: { modelId: 'gpt-4o' } } } });
    assert.equal((await admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs' })).error.message, modelError('gpt-4o'));
    await patch({ tts: { providers: { elevenlabs: { modelId: 'eleven_v4_turbo' } } } });
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'elevenlabs');
    assert.equal((await admin.send('tts.convert', { text: 'Hi', provider: 'elevenlabs', modelId: 'eleven_v3' })).provider, 'elevenlabs');
    failed = await admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs', modelId: 'eleven_bogus' });
    assert.equal(failed.error.message, modelError('eleven_bogus'));
    failed = await admin.call('tts.convert', { text: 'Hi', modelId: 'eleven_bogus' });
    assert.equal(failed.error.message, modelError('eleven_bogus'), 'an explicit modelId disables fallback');

    // A bad key resolves (Ready), tts.speak falls back to openai, and an explicit convert reports the 401.
    for (const bad of ['bad-key', 'sk_invalid']) {
      await admin.send('secrets.store.set', { name: 'ELEVENLABS_API_KEY', value: bad, kind: 'secret' });
      assert.equal((await providers()).configured, true);
      assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'openai');
      failed = await admin.call('tts.convert', { text: 'Hi', provider: 'elevenlabs' });
      assert.equal(failed.error.code, 'UNAVAILABLE');
      assert.equal(failed.error.message, 'TTS conversion failed: elevenlabs: ElevenLabs API error (401): invalid_api_key: Invalid API key');
    }

    // A literal key is redacted by config.get and still configures the provider; the redacted echo keeps it.
    await patch({ tts: { providers: { elevenlabs: { apiKey: 'sk_literal_key' } } } });
    const shown = (await admin.send('config.get')).config.tts.providers.elevenlabs.apiKey;
    assert.equal(shown, REDACTED);
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'elevenlabs');
    res = await patch({ tts: { providers: { elevenlabs: { apiKey: REDACTED } } } });
    assert.equal(res.ok, true);

    // Deleting the stored key un-configures a store-backed provider again.
    await patch({ tts: { providers: { elevenlabs: { apiKey: ref } } } });
    assert.equal((await providers()).configured, true);
    assert.deepEqual(await admin.send('secrets.store.delete', { name: 'ELEVENLABS_API_KEY' }), { ok: true, reloaded: true });
    assert.deepEqual((await admin.send('secrets.store.list', {})).entries, []);
    assert.equal((await providers()).configured, false);
    assert.equal((await admin.send('tts.speak', { text: 'Hi' })).provider, 'openai');

    // Env fallback: env.vars holds the key (redacted), an env SecretRef resolves it.
    await patch({ env: { vars: { ELEVENLABS_API_KEY: 'sk_env_key' } }, tts: { providers: { elevenlabs: { apiKey: { source: 'env', provider: 'default', id: 'ELEVENLABS_API_KEY' } } } } });
    assert.equal((await providers()).configured, true);
    assert.equal((await admin.send('config.get')).config.env.vars.ELEVENLABS_API_KEY, REDACTED);

    // env-kind entries list their value.
    await admin.send('secrets.store.set', { name: 'XI_API_KEY', value: 'plain', kind: 'env' });
    assert.equal((await admin.send('secrets.store.list', {})).entries[0].value, 'plain');
    admin.ws.close();
    reader.ws.close();
  } finally {
    await server.close();
  }
}
