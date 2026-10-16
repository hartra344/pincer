// Talk: talk.catalog (upstream gateway-protocol schema/channels.ts shape) and the hidden-record trigger.
// Only talk.catalog is implemented; talk.session.create is advertised (clients gate on both) but answers
// UNAVAILABLE until the call itself lands.
// MOCK_TALK=unconfigured: realtime providers are listed but not configured (ready: false).
// MOCK_NO_TALK=1 makes the mock look like a Gateway without these methods.
// Sending the chat message "/mock hidden-consult" makes the mock emit one hidden user record
// (`display: false`, internal_system provenance, like a Talk consult prompt) before its normal visible reply.
import { broadcastSessionMessage } from './session-list.mjs';
import { makeMessage, textBlock } from './util.mjs';

export const TALK_METHODS = ['talk.catalog', 'talk.session.create'];
export const HIDDEN_CONSULT_TRIGGER = '/mock hidden-consult';

export function talkDisabled() {
  return process.env.MOCK_NO_TALK === '1';
}

const FORMAT = { encoding: 'pcm16', sampleRateHz: 24000, channels: 1 };

export function talkCatalog() {
  const configured = process.env.MOCK_TALK !== 'unconfigured';
  return {
    modes: ['realtime', 'stt-tts', 'transcription'],
    transports: ['gateway-relay', 'webrtc'],
    brains: ['agent-consult', 'direct-tools', 'none'],
    speech: { activeProvider: 'openai', providers: [{ id: 'openai', label: 'OpenAI', configured: true }] },
    transcription: { activeProvider: 'openai', providers: [{ id: 'openai', label: 'OpenAI', configured: true }] },
    realtime: {
      ready: configured,
      activeProvider: 'openai',
      providers: [{
        id: 'openai',
        label: 'OpenAI Realtime',
        configured,
        defaultModel: 'gpt-realtime',
        voices: ['alloy', 'marin'],
        modes: ['realtime'],
        transports: ['gateway-relay', 'webrtc'],
        brains: ['agent-consult'],
        inputAudioFormats: [FORMAT],
        outputAudioFormats: [FORMAT],
        supportsBargeIn: true,
        supportsToolCalls: true,
      }],
    },
    config: {},
  };
}

export function handleTalkRequest(state, conn, msg, { sendRes, sendErr }) {
  if (!TALK_METHODS.includes(msg.method) || talkDisabled()) return false;
  if (msg.method === 'talk.catalog') sendRes(conn, msg.id, talkCatalog());
  else sendErr(conn, msg.id, 'UNAVAILABLE', 'talk.session.create is not implemented in the mock yet');
  return true;
}

export function isHiddenConsultTrigger(text) {
  return String(text ?? '').trim() === HIDDEN_CONSULT_TRIGGER;
}

export function emitHiddenConsult(state, run, sessionKey, transcript) {
  const hidden = makeMessage('user', [textBlock('[talk consult] What is on my calendar today?')], {
    openclaw: { runId: run.runId },
    extra: { display: false, provenance: { kind: 'internal_system' } },
  });
  transcript.push(hidden);
  broadcastSessionMessage(state, sessionKey, hidden, transcript.length);
}
