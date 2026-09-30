// Text-to-speech: tts.status, tts.providers, tts.personas, tts.enable, tts.disable, tts.setProvider,
// tts.setPersona, tts.convert and tts.speak. Shapes and error messages follow the Gateway's
// server-methods/tts.ts. tts.speak returns a short valid WAV (base64) so clients can play it.
// State (provider, persona, enabled) is mutable per mock server.
// MOCK_NO_TTS=1 makes the mock look like a Gateway without these methods.
//
// ElevenLabs setup: its API key lives in the config at <TTS_CONFIG_ROOT>.providers.elevenlabs.apiKey, either a
// literal (config.get redacts it) or a SecretRef ({source:"store", provider:"default", id:"ELEVENLABS_API_KEY"})
// that resolves through secrets.mjs. The provider is "configured" once the key resolves. A key starting with
// "bad" or equal to "sk_invalid" resolves but tts.speak fails with ElevenLabs' 401; a modelId that is not an
// `eleven_*` id (or is eleven_bogus) fails with a 400. tts.speak walks the provider chain like upstream (see
// synthesize); tts.convert with an explicit provider/modelId/voiceId never falls back.
import { resolveSecretRef } from './secrets.mjs';

export const TTS_METHODS = [
  'tts.status', 'tts.providers', 'tts.personas', 'tts.enable', 'tts.disable',
  'tts.setProvider', 'tts.setPersona', 'tts.convert', 'tts.speak',
];

export const TTS_MAX_TEXT_LENGTH = 4096;
// Where the TTS section lives in the config. Single source of truth for the mock.
export const TTS_CONFIG_ROOT = ['tts'];
export const ELEVENLABS_INVALID_KEY_MESSAGE = 'ElevenLabs API error (401): invalid_api_key: Invalid API key';

// Personas live in config like upstream (`<root>.personas.<id>`); `providers` is a map, listed by its keys.
const SEED_PERSONAS = {
  narrator: { label: 'Narrator', description: 'Warm, measured storyteller', provider: 'openai', fallbackPolicy: 'preserve-persona', providers: { openai: {} } },
  concise: { label: 'Concise', description: 'Brisk and to the point', provider: 'openai', fallbackPolicy: 'provider-defaults', providers: { openai: {}, elevenlabs: {} } },
};

export const TTS_AUTO_MODES = ['off', 'always', 'inbound', 'tagged'];
const normalizeAuto = (value) => (typeof value === 'string' && TTS_AUTO_MODES.includes(value.trim().toLowerCase()) ? value.trim().toLowerCase() : undefined);

export function seedTtsConfig() {
  const tts = TTS_CONFIG_ROOT.reduceRight((inner, key) => ({ [key]: inner }), {
    providers: { openai: { model: 'gpt-4o-mini-tts', voice: 'alloy' } },
    personas: structuredClone(SEED_PERSONAS),
  });
  // MOCK_TTS_AUTO=off|always|inbound|tagged seeds upstream's config default (`messages.tts.auto`); tts.enable /
  // tts.disable write prefs, which win over it, and no RPC can set inbound/tagged.
  const auto = normalizeAuto(process.env.MOCK_TTS_AUTO);
  return auto ? { ...tts, messages: { tts: { auto } } } : tts;
}

// Schema node for the config root property that holds the TTS section.
export function ttsSchemaProperties() {
  const section = {
    type: 'object',
    properties: {
      providers: { type: 'object', additionalProperties: { type: 'object' } },
      personas: { type: 'object', additionalProperties: { type: 'object' } },
      provider: { type: 'string' },
      auto: { type: 'string', enum: TTS_AUTO_MODES },
    },
  };
  const [head, ...rest] = TTS_CONFIG_ROOT;
  return {
    [head]: rest.reduceRight((inner, key) => ({ type: 'object', properties: { [key]: inner } }), section),
    messages: { type: 'object', properties: { tts: section } },
    env: { type: 'object', properties: { vars: { type: 'object', additionalProperties: { type: 'string' } } } },
  };
}

// Paths config.get redacts: an inline apiKey, a SecretRef's id and env.vars.*_API_KEY.
export function isTtsApiKeyPath(path) {
  if (path.length === 3 && path[0] === 'env' && path[1] === 'vars' && path[2].endsWith('_API_KEY')) return true;
  const n = TTS_CONFIG_ROOT.length;
  if (path.length < n + 3 || !TTS_CONFIG_ROOT.every((k, i) => path[i] === k) || path[n] !== 'providers') return false;
  const rest = path.slice(n + 2).join('.');
  return rest === 'apiKey' || rest === 'apiKey.id';
}

function providerConfig(state, providerId) {
  let node = state.configState?.config;
  for (const key of [...TTS_CONFIG_ROOT, 'providers', providerId]) node = node?.[key];
  return node ?? {};
}

const isBadElevenLabsKey = (key) => key.startsWith('bad') || key === 'sk_invalid';
const str = (value) => (typeof value === 'string' && value.trim() ? value.trim() : undefined);

// Upstream defaults and normalisation (extensions/elevenlabs/speech-provider-factory.ts).
export const ELEVENLABS_DEFAULT_VOICE_ID = 'pMsXgVXv3BLzUgSXRplE';
export const ELEVENLABS_DEFAULT_MODEL_ID = 'eleven_multilingual_v2';
const normalizeElevenLabsModelId = (value) => ({ eleven_turbo_v2_5: 'eleven_flash_v2_5', eleven_turbo_v2: 'eleven_flash_v2' })[value] ?? value;

// What the ElevenLabs provider effectively uses for a provider config node. The voice is `speakerVoiceId`, else
// `voiceId` (src/tts/speaker.ts withSpeakerSelectionCompat), else the default; the model is `modelId` only: a
// `model` key is never read, so it is reported as `ignoredModel`.
export function resolveElevenLabsConfig(node) {
  const raw = node && typeof node === 'object' ? node : {};
  return {
    voiceId: str(raw.speakerVoiceId) ?? str(raw.voiceId) ?? ELEVENLABS_DEFAULT_VOICE_ID,
    modelId: normalizeElevenLabsModelId(str(raw.modelId)) ?? ELEVENLABS_DEFAULT_MODEL_ID,
    ignoredModel: str(raw.modelId) ? undefined : str(raw.model),
  };
}
const isConfigured = (state, providerId) => providerId === 'openai' || resolveSecretRef(state, providerConfig(state, providerId).apiKey) !== undefined;


export function ttsDisabled() {
  return process.env.MOCK_NO_TTS === '1';
}

const PROVIDERS = [
  { id: 'openai', name: 'OpenAI', configured: true, models: ['gpt-4o-mini-tts', 'tts-1'], voices: ['alloy', 'verse'] },
  { id: 'elevenlabs', name: 'ElevenLabs', configured: false, models: ['eleven_v3', 'eleven_multilingual_v2', 'eleven_flash_v2_5', 'eleven_flash_v2', 'eleven_turbo_v2_5', 'eleven_monolingual_v1'], voices: ['pMsXgVXv3BLzUgSXRplE'] },
];

// The TTS section of the live config, falling back to upstream's `messages.tts`.
function ttsSection(state, ...path) {
  const config = state.configState?.config;
  const read = (root) => root.reduce((node, key) => node?.[key], config);
  const primary = path.reduce((node, key) => node?.[key], read(TTS_CONFIG_ROOT));
  return primary ?? path.reduce((node, key) => node?.[key], read(['messages', 'tts']));
}

function personas(state) {
  const map = ttsSection(state, 'personas');
  if (!map || typeof map !== 'object') return [];
  return Object.entries(map)
    .filter(([, p]) => p && typeof p === 'object')
    .map(([id, p]) => ({ id: id.toLowerCase(), label: p.label, description: p.description, provider: str(p.provider)?.toLowerCase(), fallbackPolicy: p.fallbackPolicy, providers: Object.keys(p.providers ?? {}) }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

// prefs (tts.setProvider / tts.setPersona / tts.enable / tts.disable) live in ttsState; config supplies defaults.
function ttsState(state) {
  state.ttsState ??= { provider: null, persona: null, auto: undefined };
  return state.ttsState;
}

const activePersona = (state) => personas(state).find((p) => p.id === ttsState(state).persona);

// Mirrors resolveTtsSettingsSnapshot: prefs provider, else the persona's, else the config's, else openai.
export function effectiveProvider(state) {
  const prefs = ttsState(state).provider;
  if (prefs) return { provider: prefs, source: 'prefs' };
  const persona = activePersona(state)?.provider;
  if (persona) return { provider: persona, source: 'persona' };
  const configured = str(ttsSection(state, 'provider'))?.toLowerCase();
  if (configured) return { provider: configured, source: 'config' };
  return { provider: 'openai', source: 'default' };
}

// prefs auto, else config `auto`, else off (resolveTtsAutoModeFromPrefs(prefs) ?? config.auto).
function autoMode(state) {
  return ttsState(state).auto ?? normalizeAuto(ttsSection(state, 'auto')) ?? 'off';
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

// One provider's attempt: null on success, else the failure wording (a provider error or "not configured").
function attempt(state, provider, overrides = {}) {
  if (!isConfigured(state, provider)) return 'not configured';
  if (provider !== 'elevenlabs') return null;
  const node = providerConfig(state, provider);
  const key = resolveSecretRef(state, node.apiKey);
  if (isBadElevenLabsKey(key)) return ELEVENLABS_INVALID_KEY_MESSAGE;
  const config = resolveElevenLabsConfig(node);
  // Explicit overrides win over config (overrides.voiceId ?? config.voiceId).
  const model = normalizeElevenLabsModelId(overrides.modelId) ?? config.modelId;
  const voice = overrides.voiceId ?? config.voiceId;
  if (!/^eleven_/.test(model) || model === 'eleven_bogus') {
    return `ElevenLabs API error (400): model_id_does_not_exist: Model with ID ${model} does not exist`;
  }
  if (voice.startsWith('bogus')) {
    return `ElevenLabs API error (404): voice_not_found: A voice with the voice_id ${voice} was not found.`;
  }
  return null;
}

// Mirrors upstream executeTtsProviderAttempts: the primary provider first, then every other provider unless
// `fallback` is false (explicit provider/modelId/voiceId). Returns the provider that spoke; when none does the
// errors are joined as `TTS conversion failed: elevenlabs: <msg>; openai: <msg>`.
function synthesize(state, primary, { modelId, voiceId, fallback }) {
  const order = fallback ? [primary, ...PROVIDERS.map((p) => p.id).filter((p) => p !== primary)] : [primary];
  const errors = [];
  for (const provider of order) {
    const failure = attempt(state, provider, provider === primary ? { modelId, voiceId } : {});
    if (failure === null) return provider;
    errors.push(`${provider}: ${failure}`);
  }
  throw new Error(`TTS conversion failed: ${errors.join('; ')}`);
}

export function handleTtsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  if (!TTS_METHODS.includes(method) || ttsDisabled()) return false;
  const params = msg.params && typeof msg.params === 'object' && !Array.isArray(msg.params) ? msg.params : {};
  const tts = ttsState(state);
  const active = effectiveProvider(state).provider;
  const persona = activePersona(state);
  const auto = autoMode(state);
  const personaList = personas(state);
  const providers = PROVIDERS.map((p) => ({ ...p, configured: isConfigured(state, p.id) }));
  const unavailable = (message) => sendErr(conn, id, 'UNAVAILABLE', message);
  const text = (value) => (typeof value === 'string' && value.trim() ? value.trim() : '');
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);

  switch (method) {
    case 'tts.status':
      sendRes(conn, id, {
        enabled: auto !== 'off',
        auto,
        provider: active,
        persona: persona?.id ?? null,
        personas: personaList.map(({ id: pid, label, description, provider }) => ({ id: pid, label, description, provider })),
        fallbackProvider: providers.find((p) => p.id !== active && p.configured)?.id ?? null,
        fallbackProviders: providers.filter((p) => p.id !== active && p.configured).map((p) => p.id),
        prefsPath: '/home/mock/.openclaw/settings/tts.json',
        providerStates: providers.map((p) => ({ id: p.id, label: p.name, configured: p.configured })),
      });
      return true;
    case 'tts.providers':
      sendRes(conn, id, { providers: providers.map((p) => ({ ...p })), active });
      return true;
    case 'tts.personas':
      sendRes(conn, id, { active: persona?.id ?? null, personas: personaList });
      return true;
    case 'tts.enable':
    case 'tts.disable':
      tts.auto = method === 'tts.enable' ? 'always' : 'off';
      sendRes(conn, id, { enabled: tts.auto !== 'off' });
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
      if (!personaList.some((p) => p.id === raw)) {
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
      try {
        const explicit = text(params.provider).toLowerCase();
        const provider = synthesize(state, explicit || active, { modelId: text(params.modelId) || undefined, voiceId: text(params.voiceId) || undefined, fallback: !explicit && !text(params.modelId) && !text(params.voiceId) });
        sendRes(conn, id, { audioPath: '/tmp/openclaw/tts/mock-voice.wav', provider, outputFormat: 'wav', voiceCompatible: false });
      } catch (err) {
        unavailable(err.message);
      }
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
      let provider;
      try {
        provider = synthesize(state, active, { fallback: true });
      } catch (err) {
        unavailable(err.message);
        return true;
      }
      sendRes(conn, id, {
        audioBase64: tinyWavBase64(),
        provider,
        outputFormat: 'wav',
        mimeType: 'audio/wav',
        fileExtension: 'wav',
      });
      return true;
    }
  }
  return false;
}
