// Messages from another agent or an automation, as `chat.history` projects them (#207). Mirrors
// openclaw src/gateway/chat-display-projection.history.ts `projectForwardedMessages`: a user turn
// with provenance `{ kind: 'inter_session', sourceTool: 'sessions_send' }` (another agent) or
// `{ kind: 'internal_system', sourceTool: 'cron', jobId, runId, sourceSessionKey }` (an automation)
// becomes an assistant message with `senderSession` and `senderLabel`, keeps its provenance and loses
// the model-facing prompt prefix (src/sessions/input-provenance.ts). The receiving agent's reply
// follows in the same run.

export const KIKO_KEY = 'agent:kiko:main';
export const KIKO_INTRO_RUN_ID = 'seed-run-kiko-intro';
export const KIKO_THANKS_RUN_ID = 'seed-run-kiko-thanks';
export const BRIEFING_RUN_ID = 'seed-run-briefing';

export const KIKO_INTRO = "Hi Claw! I'm Kiko, Travis's new finance assistant. I'm putting together his monthly budget. Which home-lab services renew on a schedule, and roughly what do they cost?";
export const CLAW_REPLY = 'Hi Kiko, welcome aboard! Three things renew on a schedule: Backblaze B2 storage (about $6 a month), Tailscale (free) and the clawhouse.dev domain ($12 a year, due in March).';
export const KIKO_THANKS = "Thanks Claw, that's everything I need. I've added all three to the budget. Talk soon!";
export const CLAW_NOTE = 'Kiko is tracking the home-lab bills now, so renewals will show up in her monthly summary.';

function fromKiko(makeMessage, textBlock, text, id, runId) {
  const message = makeMessage('assistant', [textBlock(text)], {
    openclaw: { id, runId },
    extra: {
      provenance: { kind: 'inter_session', sourceSessionKey: KIKO_KEY, sourceChannel: 'internal', sourceTool: 'sessions_send' },
      senderSession: { sessionKey: KIKO_KEY, agentId: 'kiko' },
      senderLabel: 'Forwarded from kiko',
    },
  });
  // The forwarded prompt was a user turn: no model of this chat wrote it.
  delete message.provider;
  delete message.model;
  return message;
}

export function seedForwardedMessages({ transcripts, makeMessage, textBlock, toolCallBlock }) {
  const briefingSession = `agent:main:cron:morning-briefing:run:${BRIEFING_RUN_ID}`;
  const briefing = makeMessage('assistant', [textBlock('Write my morning briefing: weather, calendar and anything odd overnight.')], {
    openclaw: { id: 'seed-briefing-prompt', runId: BRIEFING_RUN_ID },
    extra: {
      provenance: {
        kind: 'internal_system',
        sourceTool: 'cron',
        jobId: 'morning-briefing',
        runId: BRIEFING_RUN_ID,
        sourceSessionKey: briefingSession,
        sourcePromptPrefix: '[cron:morning-briefing Morning briefing]',
      },
      senderSession: { sessionKey: briefingSession, agentId: 'main', label: 'Morning briefing' },
      senderLabel: 'Forwarded from Morning briefing',
    },
  });
  delete briefing.provider;
  delete briefing.model;

  // Claw's main chat: the briefing, then Kiko introducing herself. Kiko, Claw, Kiko, Claw, then you.
  transcripts.get('agent:main:main').push(
    briefing,
    makeMessage('assistant', [textBlock('Clear skies, two meetings, and the lab sensor is quiet.')], { openclaw: { runId: BRIEFING_RUN_ID } }),
    fromKiko(makeMessage, textBlock, KIKO_INTRO, 'seed-kiko-intro', KIKO_INTRO_RUN_ID),
    makeMessage('assistant', [textBlock(CLAW_REPLY)], { openclaw: { id: 'seed-claw-to-kiko', runId: KIKO_INTRO_RUN_ID } }),
    fromKiko(makeMessage, textBlock, KIKO_THANKS, 'seed-kiko-thanks', KIKO_THANKS_RUN_ID),
    makeMessage('assistant', [textBlock(CLAW_NOTE)], { openclaw: { id: 'seed-claw-kiko-note', runId: KIKO_THANKS_RUN_ID } }),
    makeMessage('user', [textBlock('Nice, thanks both 🙌')], { openclaw: { id: 'seed-thanks-both' } }),
  );

  // Kiko's own chat, where she was asked to reach out.
  const send = (id, message, runId, reply) => [
    makeMessage('assistant', [toolCallBlock(id, 'sessions_send', { sessionKey: 'agent:main:main', message })]),
    makeMessage('toolResult', [textBlock(JSON.stringify({ runId, sessionKey: 'agent:main:main', status: 'ok', reply }))], {
      extra: { toolCallId: id, toolName: 'sessions_send', isError: false },
    }),
  ];
  transcripts.get(KIKO_KEY).push(
    makeMessage('user', [textBlock('Introduce yourself to Claw and find out what the home lab costs each month.')]),
    ...send('call_seed_kiko_intro', KIKO_INTRO, KIKO_INTRO_RUN_ID, CLAW_REPLY),
    ...send('call_seed_kiko_thanks', KIKO_THANKS, KIKO_THANKS_RUN_ID, CLAW_NOTE),
    makeMessage('assistant', [textBlock("Claw sent the list: Backblaze B2 at about $6 a month, Tailscale for free and the domain at $12 a year. I've added them to your budget.")]),
  );
}
