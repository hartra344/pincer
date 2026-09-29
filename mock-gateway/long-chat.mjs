import { makeSessionRow } from './seed.mjs';
import { makeMessage, nowMs, textBlock } from './util.mjs';

export const LONG_CHAT_KEY = 'agent:main:dashboard:long-chat';

const SENTENCE = 'The quick brown fox jumps over the lazy dog while **bold** words, `inline code` and a [link](https://example.com) keep the parser busy. ';

/** Deterministic mixed-length text, so runs are comparable. */
export function longChatText(index) {
  if (index % 2 === 0) return `Question ${index / 2 + 1}: ${SENTENCE.slice(0, 40 + (index * 37) % 90)}?`;
  switch (index % 10) {
    case 1: return `Reply ${index}: ${SENTENCE}`;
    case 3: return `## Section ${index}\n\n${SENTENCE.repeat(2 + (index % 4))}\n\n- first point\n- second point\n- third point`;
    case 5: return `Reply ${index}:\n\n\`\`\`swift\nfunc f${index}(_ x: Int) -> Int {\n    x * ${index} + 1\n}\n\`\`\`\n\n${SENTENCE}`;
    case 7: return `Reply ${index}:\n\n${(SENTENCE + '\n\n').repeat(3 + (index % 5))}`;
    default: return `Reply ${index}: ${SENTENCE.repeat(1 + (index % 3))}`;
  }
}

/** MOCK_LONG_CHAT=<n>: one chat with n alternating user and assistant messages, oldest first. */
export function seedLongChat(state, count) {
  const now = nowMs();
  const row = makeSessionRow(LONG_CHAT_KEY, {
    agentId: 'main',
    label: `Long chat (${count})`,
    derivedTitle: `Long chat (${count})`,
    age: 60_000,
    lastMessagePreview: 'Reply: latest message of the long chat.',
  }, now);
  const transcript = [];
  for (let i = 0; i < count; i++) {
    const message = makeMessage(i % 2 === 0 ? 'user' : 'assistant', [textBlock(longChatText(i))]);
    message.timestamp = now - (count - i) * 30_000;
    transcript.push(message);
  }
  state.sessions.set(LONG_CHAT_KEY, row);
  state.transcripts.set(LONG_CHAT_KEY, transcript);
  return row;
}
