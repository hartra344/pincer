// Text-to-speech: tts.status, tts.providers, tts.personas, tts.enable, tts.disable, tts.setProvider,
// tts.setPersona, tts.convert and tts.speak. Shapes and error messages follow the Gateway's
// server-methods/tts.ts. tts.speak returns a short valid WAV (base64) so clients can play it.
// State (provider, persona, enabled) is mutable per mock server.
// MOCK_NO_TTS=1 makes the mock look like a Gateway without these methods.

export const TTS_METHODS = [
  'tts.status', 'tts.providers', 'tts.personas', 'tts.enable', 'tts.disable',
  'tts.setProvider', 'tts.setPersona', 'tts.convert', 'tts.speak',
];

export const TTS_MAX_TEXT_LENGTH = 4096;

export function ttsDisabled() {
  return process.env.MOCK_NO_TTS === '1';
}

const PROVIDERS = [
  { id: 'openai', name: 'OpenAI', configured: true, models: ['gpt-4o-mini-tts', 'tts-1'], voices: ['alloy', 'verse'] },
  { id: 'elevenlabs', name: 'ElevenLabs', configured: false, models: ['eleven_multilingual_v2'], voices: [] },
];

const PERSONAS = [
  { id: 'narrator', label: 'Narrator', description: 'Warm, measured storyteller', provider: 'openai', fallbackPolicy: 'preserve-persona', providers: ['openai'] },
  { id: 'concise', label: 'Concise', description: 'Brisk and to the point', provider: 'openai', fallbackPolicy: 'provider-defaults', providers: ['openai', 'elevenlabs'] },
];

function ttsState(state) {
  state.ttsState ??= { enabled: false, auto: 'off', provider: 'openai', persona: null };
  return state.ttsState;
}

// 0.3 s of 8 kHz mono 16-bit PCM: a quiet 440 Hz tone in a canonical 44-byte-header WAV.
export function tinyWavBase64() {
  const rate = 8000;
  const samples = Math.round(rate * 0.3);
  const buf = Buffer.alloc(44 + samples * 2);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + samples * 2, 4);
  buf.write('WAVEfmt ', 8, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) buf.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 3000), 44 + i * 2);
  return buf.toString('base64');
}

export function handleTtsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  if (!TTS_METHODS.includes(method) || ttsDisabled()) return false;
  const params = msg.params && typeof msg.params === 'object' && !Array.isArray(msg.params) ? msg.params : {};
  const tts = ttsState(state);
  const text = (value) => (typeof value === 'string' && value.trim() ? value.trim() : '');
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);

  switch (method) {
    case 'tts.status':
      sendRes(conn, id, {
        enabled: tts.enabled,
        auto: tts.auto,
        provider: tts.provider,
        persona: tts.persona,
        personas: PERSONAS.map(({ id: pid, label, description, provider }) => ({ id: pid, label, description, provider })),
        fallbackProvider: PROVIDERS.find((p) => p.id !== tts.provider && p.configured)?.id ?? null,
        fallbackProviders: PROVIDERS.filter((p) => p.id !== tts.provider && p.configured).map((p) => p.id),
        prefsPath: '/home/mock/.openclaw/settings/tts.json',
        providerStates: PROVIDERS.map((p) => ({ id: p.id, label: p.name, configured: p.configured })),
      });
      return true;
    case 'tts.providers':
      sendRes(conn, id, { providers: PROVIDERS.map((p) => ({ ...p })), active: tts.provider });
      return true;
    case 'tts.personas':
      sendRes(conn, id, { active: tts.persona, personas: PERSONAS.map((p) => ({ ...p })) });
      return true;
    case 'tts.enable':
    case 'tts.disable':
      tts.enabled = method === 'tts.enable';
      tts.auto = tts.enabled ? 'always' : 'off';
      sendRes(conn, id, { enabled: tts.enabled });
      return true;
    case 'tts.setProvider': {
      const provider = text(params.provider).toLowerCase();
      if (!provider || !PROVIDERS.some((p) => p.id === provider)) {
        invalid('Invalid provider. Use a registered TTS provider id.');
        return true;
      }
      tts.provider = provider;
      sendRes(conn, id, { provider });
      return true;
    }
    case 'tts.setPersona': {
      const raw = text(params.persona).toLowerCase();
      if (!raw || ['off', 'none', 'default'].includes(raw)) {
        tts.persona = null;
        sendRes(conn, id, { persona: null });
        return true;
      }
      if (!PERSONAS.some((p) => p.id === raw)) {
        invalid('Invalid persona. Use a configured TTS persona id.');
        return true;
      }
      tts.persona = raw;
      sendRes(conn, id, { persona: raw });
      return true;
    }
    case 'tts.convert':
      if (!text(params.text)) {
        invalid('tts.convert requires text');
        return true;
      }
      sendRes(conn, id, { audioPath: '/tmp/openclaw/tts/mock-voice.wav', provider: tts.provider, outputFormat: 'wav', voiceCompatible: false });
      return true;
    case 'tts.speak': {
      const spoken = text(params.text);
      if (!spoken) {
        invalid('tts.speak requires text');
        return true;
      }
      if (spoken.length > TTS_MAX_TEXT_LENGTH) {
        invalid(`tts.speak text too long (${spoken.length} chars, max ${TTS_MAX_TEXT_LENGTH})`);
        return true;
      }
      sendRes(conn, id, {
        audioBase64: tinyWavBase64(),
        provider: tts.provider,
        outputFormat: 'wav',
        mimeType: 'audio/wav',
        fileExtension: 'wav',
      });
      return true;
    }
  }
  return false;
}
