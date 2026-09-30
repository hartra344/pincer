import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { createApprovalHistoryState } from './approvals.mjs';
import { createAgentWorkspaces } from './agents.mjs';
import { createConfigState } from './config.mjs';
import { createCronState } from './cron.mjs';
import { createLogsState } from './logs.mjs';
import { createExecApprovalsState } from './exec-approvals.mjs';
import { createChannelPairingState } from './pairing.mjs';
import { createHealthState } from './health.mjs';
import { createSetupState } from './setup.mjs';
import { seedSessionManager } from './sessions.mjs';
import { createChannelsState } from './channels.mjs';
import { createWebPushState } from './webpush.mjs';
import { seedRunningSubagentRun, seedSubagents } from './subagents.mjs';
import { createDevicePairingState } from './devices.mjs';
import { seededFileEditCalls } from './file-edits.mjs';
import { seededToolCards, TOOL_CARDS_KEY, TOOL_CARDS_PREVIEW, TOOL_CARDS_TITLE } from './tool-cards.mjs';
import { seedForwardedMessages } from './forwarded.mjs';
import { DEFAULT_MODEL, imageBlock, makeMessage, nowMs, textBlock, thinkingBlock, toolCallBlock } from './util.mjs';

export const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function pngChunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])));
  return Buffer.concat([len, typeBuf, data, crc]);
}

export function makePng() {
  const width = 320;
  const height = 200;
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 4 + 1);
    raw[row] = 0;
    for (let x = 0; x < width; x++) {
      const i = row + 1 + x * 4;
      const bar = Math.floor(x / 40) % 2;
      raw[i] = Math.min(255, 40 + x);
      raw[i + 1] = Math.min(255, 60 + y);
      raw[i + 2] = bar ? 220 : 120;
      raw[i + 3] = 255;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

export function makeSessionRow(key, props, base = nowMs()) {
  return {
    key,
    sessionId: crypto.randomUUID(),
    kind: 'direct',
    label: props.label ?? null,
    displayName: props.displayName,
    derivedTitle: props.derivedTitle ?? props.label ?? 'Untitled',
    lastMessagePreview: props.lastMessagePreview ?? 'Ready when you are.',
    channel: props.channel ?? 'webchat',
    agentId: props.agentId,
    isMain: Boolean(props.isMain),
    category: props.category,
    color: props.color,
    pinned: Boolean(props.pinned),
    unread: Boolean(props.unread),
    archived: false,
    updatedAt: base - (props.age ?? 0),
    lastActivityAt: base - (props.age ?? 0),
    status: props.status ?? 'idle',
    parentSessionKey: props.parentSessionKey,
    spawnedBy: props.spawnedBy,
    hasActiveRun: false,
    activeRunIds: [],
    model: DEFAULT_MODEL.model,
    modelProvider: DEFAULT_MODEL.provider,
    modelOverrideSource: null,
    // Context snapshot and the latest run's usage, as the Gateway's session rows carry them.
    ...(props.totalTokens !== undefined
      ? { totalTokens: props.totalTokens, totalTokensFresh: true, inputTokens: props.totalTokens, outputTokens: 800 }
      : {}),
    ...(props.contextTokens !== undefined ? { contextTokens: props.contextTokens } : {}),
  };
}

export function createSeedState() {
  const base = nowMs();
  const agents = new Map([
    ['main', { id: 'main', name: 'Claw', identity: { name: 'Claw', emoji: '🦞' } }],
    ['research', { id: 'research', name: 'Scout', identity: { name: 'Scout', emoji: '🔭' } }],
    ['coder', { id: 'coder', name: 'Forge', identity: { name: 'Forge', emoji: '🛠️' }, model: 'anthropic/claude-sonnet-5' }],
    ['kiko', { id: 'kiko', name: 'Kiko', identity: { name: 'Kiko', emoji: '🌕' } }],
  ]);
  const agentWorkspaces = createAgentWorkspaces(agents, base);
  const sessions = new Map();
  const transcripts = new Map();
  const artifacts = new Map([
    ['art-chart-1', { artifactId: 'art-chart-1', mimeType: 'image/png', data: makePng() }],
  ]);

  function row(key, props) {
    const entry = makeSessionRow(key, props, base);
    sessions.set(key, entry);
    transcripts.set(key, []);
    return entry;
  }

  row('agent:main:main', {
    agentId: 'main',
    isMain: true,
    derivedTitle: 'Main',
    channel: 'webchat',
    age: 10_000,
    lastMessagePreview: 'Disk looks healthy.',
    totalTokens: 172_000,
    contextTokens: 200_000,
  });
  row('agent:main:discord:channel:123', {
    agentId: 'main',
    label: 'home-lab',
    derivedTitle: 'home-lab',
    category: 'Home',
    channel: 'discord',
    pinned: true,
    unread: true,
    age: 20_000,
    lastMessagePreview: 'Discord bridge is online.',
  });
  row('agent:main:telegram:home:direct:5550142', {
    agentId: 'main',
    label: 'Maya',
    derivedTitle: 'Maya',
    category: 'Home',
    channel: 'telegram',
    lastChannel: 'telegram',
    lastAccountId: 'home',
    age: 45_000,
    lastMessagePreview: 'Friday pickup is at 3:15.',
  });
  row('agent:main:dashboard:trip', {
    agentId: 'main',
    label: 'Japan trip',
    derivedTitle: 'Japan trip',
    category: 'Personal',
    color: 'pink',
    age: 60_000,
    lastMessagePreview: 'Kyoto day plan drafted.',
    totalTokens: 48_000,
    contextTokens: 200_000,
  });
  row('agent:research:main', {
    agentId: 'research',
    isMain: true,
    derivedTitle: 'Main',
    age: 90_000,
    lastMessagePreview: 'Research queue is clear.',
    // No contextTokens: clients fall back to models.list, then sessions.list defaults.
    totalTokens: 12_000,
  });
  row('agent:research:dashboard:papers', {
    agentId: 'research',
    label: 'Paper digest',
    derivedTitle: 'Paper digest',
    category: 'Work',
    unread: true,
    age: 120_000,
    lastMessagePreview: 'Three papers summarized.',
    totalTokens: 96_000,
    contextTokens: 200_000,
  });
  row('agent:research:subagent:abc', {
    agentId: 'research',
    label: 'Summarize arXiv 2401.x',
    derivedTitle: 'Summarize arXiv 2401.x',
    parentSessionKey: 'agent:research:dashboard:papers',
    spawnedBy: 'agent:research:dashboard:papers',
    age: 180_000,
    lastMessagePreview: 'Subagent found the main contribution.',
  });
  row('agent:coder:main', {
    agentId: 'coder',
    isMain: true,
    derivedTitle: 'Main',
    age: 240_000,
    lastMessagePreview: 'No active coding run.',
    totalTokens: 190_000,
    contextTokens: 200_000,
  });
  row('agent:kiko:main', {
    agentId: 'kiko',
    isMain: true,
    derivedTitle: 'Main',
    age: 300_000,
    lastMessagePreview: 'Claw sent the list of home-lab bills.',
  });
  // Upstream-shaped `edit`, `write` and `apply_patch` calls (see file-edits.mjs).
  row('agent:coder:dashboard:retry-fix', {
    agentId: 'coder',
    label: 'Fix retry backoff',
    derivedTitle: 'Fix retry backoff',
    age: 6 * 3_600_000,
    lastMessagePreview: 'Retries now stop after 4 attempts and skip 4xx errors.',
  });
  // Upstream-shaped `exec`, MCP, `web_fetch` and `read` calls (see tool-cards.mjs).
  row(TOOL_CARDS_KEY, {
    agentId: 'main',
    label: TOOL_CARDS_TITLE,
    derivedTitle: TOOL_CARDS_TITLE,
    age: 3 * 60_000,
    lastMessagePreview: TOOL_CARDS_PREVIEW,
  });

  // Chats of the seeded automations (see cron.mjs); their runs append here.
  row('agent:main:cron:morning-briefing', {
    agentId: 'main',
    label: 'Automation: Morning briefing',
    channel: 'cron',
    age: 3 * 3_600_000,
    lastMessagePreview: 'Clear skies, two meetings, and the lab sensor is quiet.',
  });
  row('agent:main:cron:disk-check', {
    agentId: 'main',
    label: 'Automation: Check disk space',
    channel: 'cron',
    age: 2 * 3_600_000,
    lastMessagePreview: 'df: /Volumes/Backup: No such file or directory',
  });
  transcripts.get('agent:main:cron:morning-briefing').push(
    makeMessage('user', [textBlock('Write my morning briefing: weather, calendar and anything odd overnight.')]),
    makeMessage('assistant', [textBlock('Clear skies, two meetings, and the lab sensor is quiet.')]),
  );
  transcripts.get('agent:main:cron:disk-check').push(
    makeMessage('user', [textBlock('Check free space on every volume and warn me under 10%.')]),
    makeMessage('assistant', [textBlock('df: /Volumes/Backup: No such file or directory')]),
  );
  // Native Discord slash commands run in their own session (`agent:<agent>:discord:slash:<userId>`).
  row('agent:main:discord:slash:418235907214753792', {
    agentId: 'main',
    channel: 'discord',
    age: 4 * 3_600_000,
    lastMessagePreview: 'Status: online, 3 agents.',
  });
  transcripts.get('agent:main:discord:slash:418235907214753792').push(
    makeMessage('user', [textBlock('/status')]),
    makeMessage('assistant', [textBlock('Status: online, 3 agents.')]),
  );

  seedForwardedMessages({ transcripts, makeMessage, textBlock, toolCallBlock });
  const dfCall = 'call_seed_df';
  transcripts.get('agent:main:main').push(
    makeMessage('user', [textBlock('Can you check disk usage and show me a quick status?')]),
    makeMessage('assistant', [
      thinkingBlock('I should inspect the disk usage and summarize the key mount points.'),
      toolCallBlock(dfCall, 'exec', { command: 'df -h' }),
    ]),
    makeMessage('toolResult', [textBlock('Filesystem      Size  Used Avail Use% Mounted on\n/dev/disk3s1   926G  411G  490G  46% /\n/dev/disk3s6   926G  7.0G  490G   2% /System/Volumes/VM')], {
      extra: { toolCallId: dfCall, toolName: 'exec', isError: false },
    }),
    makeMessage('assistant', [
      textBlock('## Disk status\n\n- Root volume has plenty of room.\n- VM volume is lightly used.\n\n```text\n/dev/disk3s1  46% used\n```\n\nHere is a synthetic usage chart.'),
      imageBlock('art-chart-1', 'Disk usage chart'),
    ]),
  );
  // Bridged messages carry their channel message id, and the agent reacted 👀 to this one with its
  // `message` tool (as upstream's ack reactions do).
  const labAck = 'call_seed_lab_ack';
  transcripts.get('agent:main:discord:channel:123').push(
    makeMessage('user', [textBlock('Discord says the lab sensor is noisy tonight.')], {
      openclaw: { transport: { channel: 'discord', messageId: '1300000000000000001', conversationRef: 'channel:123' } },
      extra: { provenance: { sourceChannel: 'discord' } },
    }),
    makeMessage('assistant', [toolCallBlock(labAck, 'message', { action: 'react', emoji: '👀', messageId: '1300000000000000001' })]),
    makeMessage('toolResult', [textBlock('{"ok":true,"added":"👀"}')], {
      extra: { toolCallId: labAck, toolName: 'message', isError: false },
    }),
    makeMessage('assistant', [textBlock('I will keep an eye on the home-lab channel and flag anomalies.')]),
  );
  // A bridged Telegram chat whose agent replies carry `openclawDelivery` reply targets: the first answers an
  // earlier message (quote card), the second answers the latest one (`replyToCurrent`, no quote), and the
  // last leaks a `[[reply_to_current]]` directive into its text.
  const tgUser = (id, messageId, text) => makeMessage('user', [textBlock(text)], {
    openclaw: { id, transport: { channel: 'telegram', messageId, conversationRef: '5550142' }, senderId: '5550142', senderName: 'Maya' },
    extra: { provenance: { sourceChannel: 'telegram' }, senderLabel: 'Maya' },
  });
  const tgReply = (text, openclawDelivery) => makeMessage('assistant', [textBlock(text)], { extra: { openclawDelivery } });
  transcripts.get('agent:main:telegram:home:direct:5550142').push(
    tgUser('mock-tg-clinic', '9101', "Can you find the pediatrician's opening hours?"),
    tgUser('mock-tg-dentist', '9102', 'Also, when is my dentist appointment?'),
    tgReply("Dr. Alvarez's office is open Monday to Friday, 8:00 to 17:00, and Saturday 9:00 to 12:00.", { replyToId: 'mock-tg-clinic' }),
    tgReply('Your dentist appointment is Thursday at 10:30 with Dr. Kim.', { replyToCurrent: true }),
    tgUser('mock-tg-pharmacy', '9104', 'Did the pharmacy call back about the refill?'),
    tgUser('mock-tg-bus', '9105', 'Is the 7:40 bus running today?'),
    // Named by Telegram's own message id rather than a transcript id.
    tgReply('The pharmacy called at 9:05: the refill is ready for pickup until 6 pm.', { replyToId: '9104' }),
    tgUser('mock-tg-pickup', '9103', 'And what time is school pickup on Friday?'),
    tgReply('[[reply_to_current]] Friday pickup is at 3:15, half an hour earlier than usual.', { replyToCurrent: true }),
  );
  // Long enough to need several older pages.
  for (let day = 1; day <= 150; day++) {
    transcripts.get('agent:main:dashboard:trip').push(
      makeMessage('user', [textBlock(`Idea for day ${day}?`)]),
      makeMessage('assistant', [textBlock(`Day ${day}: a slow morning, one museum, and **ramen** nearby.`)]),
    );
  }
  transcripts.get('agent:main:dashboard:trip').push(
    makeMessage('user', [textBlock('Plan a gentle first day in Tokyo.')]),
    makeMessage('assistant', [textBlock('Start with Meiji Shrine, a low-key lunch, and an early evening in Shinjuku.')]),
  );
  transcripts.get('agent:research:main').push(
    // Past the history cap, so clients have to recover it with `chat.message.get`.
    makeMessage('assistant', [textBlock(`## Long report\n\n${'Lorem ipsum dolor sit amet. '.repeat(400)}\n\nEND OF REPORT`)]),
    makeMessage('assistant', [textBlock('Scout is ready to investigate papers, repos, and docs.')]),
  );
  transcripts.get('agent:research:dashboard:papers').push(
    makeMessage('user', [textBlock('Summarize the latest diffusion papers.')]),
    makeMessage('assistant', [textBlock('I found themes around consistency models, efficient sampling, and video generation.')]),
  );
  transcripts.get('agent:research:subagent:abc').push(
    makeMessage('assistant', [textBlock('The paper primarily improves retrieval-augmented summarization evaluation.')]),
  );
  transcripts.get('agent:coder:main').push(
    makeMessage('assistant', [textBlock('Forge can edit code, run builds, and report concise status.')]),
  );
  seedSubagents({ row, sessions, transcripts, makeMessage, textBlock, thinkingBlock, toolCallBlock, base });
  transcripts.get(TOOL_CARDS_KEY).push(...seededToolCards({ makeMessage, textBlock, toolCallBlock }));
  const [editCall, writeCall, patchCall] = seededFileEditCalls();
  const fileEditResult = (call) => makeMessage('toolResult', [textBlock(call.result)], {
    extra: { toolCallId: call.id, toolName: call.name, details: call.details, isError: false },
  });
  transcripts.get('agent:coder:dashboard:retry-fix').push(
    makeMessage('user', [textBlock('The API client hammers the server on 429s and never gives up. Fix the retry loop and add a test.')]),
    makeMessage('assistant', [
      thinkingBlock('withRetry loops forever and never checks the status; cap attempts and only retry 429/5xx.'),
      toolCallBlock(editCall.id, editCall.name, editCall.args),
    ]),
    fileEditResult(editCall),
    makeMessage('assistant', [toolCallBlock(writeCall.id, writeCall.name, writeCall.args)]),
    fileEditResult(writeCall),
    makeMessage('assistant', [
      textBlock('Now switching the client over and removing the old helper.'),
      toolCallBlock(patchCall.id, patchCall.name, patchCall.args),
    ]),
    fileEditResult(patchCall),
    makeMessage('assistant', [textBlock('Retries now stop after 4 attempts and skip 4xx errors. `retry.test.ts` covers both cases, and `legacy-retry.ts` is gone.')]),
  );
  const sessionManager = seedSessionManager({ row, transcripts, makeMessage, textBlock, base });

  const state = {
    agents,
    agentWorkspaces,
    sessions,
    transcripts,
    artifacts,
    // Connect-time pairing and device.pair.*: seeded with a few devices and two pending requests.
    ...createDevicePairingState(),
    pendingApprovals: new Map(),
    // Resolved approvals keep their decision so identical retries stay idempotent, as on the Gateway.
    resolvedApprovals: new Map(),
    questions: new Map(),
    progressCards: new Map(),
    // Gateway-owned custom group catalog: names in display order, kept even when empty.
    groups: ['Home', 'Personal', 'Work'],
    idempotency: new Map(),
    // chat.send attempts per idempotencyKey, for the `-once` failure hooks.
    sendAttempts: new Map(),
    messageActions: new Map(),
    reactionLog: [],
    activeRuns: new Map(sessionManager.stubRuns.map((run) => [run.runId, run])),
    // Inactive transcript branch tips per session (see sessions.mjs).
    sessionBranches: sessionManager.branches,
    connections: new Set(),
    configState: createConfigState(),
    webPushState: createWebPushState(),
    cronState: createCronState(base),
    approvalHistoryState: createApprovalHistoryState(base),
    logsState: createLogsState(base),
    execApprovalsState: createExecApprovalsState(base),
    channelPairingState: createChannelPairingState(base),
    healthState: createHealthState(base),
    setupState: createSetupState(),
    channelsState: createChannelsState(),
  };
  seedRunningSubagentRun(state);
  return state;
}
