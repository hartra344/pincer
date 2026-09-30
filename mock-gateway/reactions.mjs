import { broadcast, nowMs, sendErr, sendRes } from './util.mjs';

// Mirrors openclaw's session.reactions.set/list (+ session.reaction event) and users.self.
export const REACTION_METHODS = ['session.reactions.set', 'session.reactions.list'];
export const REACTION_EVENTS = ['session.reaction'];
const OWNER = { id: 'demo-owner', label: 'You' };
const PER_IDENTITY_LIMIT = 20;

// MOCK_NO_REACTIONS=1 behaves like an older gateway; MOCK_NO_PROFILE=1 like a client without a user profile.
export function reactionsDisabled() {
  return process.env.MOCK_NO_REACTIONS === '1';
}
function noProfile() {
  return process.env.MOCK_NO_PROFILE === '1';
}

const store = (state) => state.sessionReactions ?? (state.sessionReactions = new Map());
const messageKey = (sessionKey, messageId) => `${sessionKey}\n${messageId}`;

function summaries(state, sessionKey, messageId) {
  const byEmoji = store(state).get(messageKey(sessionKey, messageId));
  if (!byEmoji) return [];
  return [...byEmoji]
    .filter(([, who]) => who.size > 0)
    .map(([emoji, who]) => ({ emoji, count: who.size, identities: [...who].map(([id, label]) => ({ id, label })) }));
}

function addReaction(state, sessionKey, messageId, emoji, identity, remove = false) {
  const key = messageKey(sessionKey, messageId);
  const byEmoji = store(state).get(key) ?? new Map();
  const who = byEmoji.get(emoji) ?? new Map();
  const had = who.has(identity.id);
  if (remove) who.delete(identity.id);
  else who.set(identity.id, identity.label);
  if (who.size > 0) byEmoji.set(emoji, who);
  else byEmoji.delete(emoji);
  if (byEmoji.size > 0) store(state).set(key, byEmoji);
  else store(state).delete(key);
  return remove ? had : !had;
}

// Emoji grapheme check: one grapheme, at most 32 characters, containing a pictographic character or keycap/flag.
function isReactionEmoji(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 32) return false;
  const graphemes = [...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment(value)];
  if (graphemes.length !== 1) return false;
  return /\p{Extended_Pictographic}|\p{Regional_Indicator}|\u20e3/u.test(value);
}

function findMessage(state, sessionKey, messageId) {
  return (state.transcripts.get(sessionKey) ?? []).find((m) => m.__openclaw?.id === messageId);
}

export function seedReactions(state) {
  const sam = { id: 'sam', label: 'Sam' };
  const riley = { id: 'riley', label: 'Riley' };
  const main = state.transcripts.get('agent:main:main');
  const assistant = main.find((m) => m.role === 'assistant' && JSON.stringify(m.content).includes('Disk status'));
  const question = main.find((m) => m.role === 'user' && JSON.stringify(m.content).includes('disk usage'));
  const lab = state.transcripts.get('agent:main:discord:channel:123').find((m) => m.__openclaw?.transport?.messageId);
  const seed = (key, msg, emoji, who) => who.forEach((identity) => addReaction(state, key, msg.__openclaw.id, emoji, identity));
  seed('agent:main:main', assistant, '👍', [OWNER, sam]);
  seed('agent:main:main', assistant, '🎉', [sam, riley]);
  seed('agent:main:main', question, '🙏', [sam]);
  seed('agent:main:discord:channel:123', lab, '👀', [riley]);
}

export function handleReactionsRequest(state, conn, msg) {
  const { id, method, params = {} } = msg;
  if (method === 'users.self') {
    if (noProfile()) sendErr(conn, id, 'FORBIDDEN', 'users.self requires an authenticated user');
    else sendRes(conn, id, { profile: { id: OWNER.id, displayName: OWNER.label, emails: [], updatedAt: nowMs() } });
    return true;
  }
  if (!REACTION_METHODS.includes(method)) return false;
  if (reactionsDisabled()) {
    sendErr(conn, id, 'INVALID_REQUEST', `unknown method: ${method}`);
    return true;
  }
  const { sessionKey } = params;
  const row = typeof sessionKey === 'string' ? state.sessions.get(sessionKey) : undefined;
  if (!row) {
    sendErr(conn, id, 'INVALID_REQUEST', `Session "${sessionKey}" was not found.`);
    return true;
  }
  if (method === 'session.reactions.list') {
    const reactions = {};
    for (const key of store(state).keys()) {
      const [session, messageId] = key.split('\n');
      if (session === sessionKey) reactions[messageId] = summaries(state, sessionKey, messageId);
    }
    sendRes(conn, id, { sessionId: row.sessionId, reactions });
    return true;
  }
  if (noProfile()) {
    sendErr(conn, id, 'INVALID_REQUEST', 'identified reaction author required');
    return true;
  }
  if (typeof params.messageId !== 'string' || !params.messageId) {
    sendErr(conn, id, 'INVALID_REQUEST', 'invalid session.reactions.set params: messageId is required');
    return true;
  }
  if (!isReactionEmoji(params.emoji)) {
    sendErr(conn, id, 'INVALID_REQUEST', 'one emoji grapheme is required');
    return true;
  }
  const message = findMessage(state, sessionKey, params.messageId);
  if (!message || !['user', 'assistant'].includes(message.role)) {
    sendErr(conn, id, 'INVALID_REQUEST', 'unknown message');
    return true;
  }
  const remove = params.remove === true;
  if (!remove) {
    const mine = [...store(state)].filter(([key]) => key === messageKey(sessionKey, params.messageId))
      .flatMap(([, byEmoji]) => [...byEmoji].filter(([e, who]) => e !== params.emoji && who.has(OWNER.id)));
    if (mine.length >= PER_IDENTITY_LIMIT) {
      sendErr(conn, id, 'INVALID_REQUEST', 'reaction limit reached');
      return true;
    }
  }
  const changed = addReaction(state, sessionKey, params.messageId, params.emoji, OWNER, remove);
  const reactions = summaries(state, sessionKey, params.messageId);
  const transport = message.__openclaw?.transport;
  const mirror = !changed
    ? { status: 'skipped', reason: 'reaction already in that state' }
    : message.role === 'user' && transport
      ? { status: 'delivered' }
      : { status: 'skipped', reason: 'message has no source channel transport' };
  sendRes(conn, id, { messageId: params.messageId, reactions, mirror });
  if (changed) {
    broadcast(state, 'session.reaction', {
      sessionKey, agentId: row.agentId ?? 'main', sessionId: row.sessionId, messageId: params.messageId,
      emoji: params.emoji, action: remove ? 'removed' : 'added',
      actor: { type: 'human', id: OWNER.id, label: OWNER.label }, reactions,
    });
  }
  return true;
}
