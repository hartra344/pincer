import { validWorkContext, withWorkContext, projectWorkContextForDisplay } from './work-context.mjs';
import { ADMIN_SCOPE } from './config.mjs';
import { noteApprovalForLogs, noteChatForLogs } from './logs.mjs';
import { markSubagentAborted, simulateSpawn } from './subagents.mjs';
import { liveFileEditCall } from './file-edits.mjs';
import { rowModel } from './catalog.mjs';
import { simulateQuestion, simulateSecretQuestion } from './questions.mjs';
import { makeSessionRow } from './seed.mjs';
import { broadcastSessionChanged, broadcastSessionMessage, markRunEnded, markRunStarted, updateSessionRow } from './session-list.mjs';
import { largeImageBlocks } from './large-media.mjs';
import { DEFAULT_CONTEXT_TOKENS, broadcast, clone, imageBlock, makeMessage, nowMs, sendErr, sendJson, sendRes, shortId, textBlock, thinkingBlock, toolCallBlock } from './util.mjs';

// Like the Gateway's history projection: text fields past the cap end in a sentinel and the
// message is flagged so clients can fetch the full copy with `chat.message.get`.
export const HISTORY_TEXT_MAX_CHARS = 8_000;

export function projectForHistory(message, maxChars = HISTORY_TEXT_MAX_CHARS) {
  const projected = clone(projectWorkContextForDisplay(message));
  // MOCK_HISTORY_NO_IDS=1: history without message ids, like a Gateway that doesn't stamp them.
  if (process.env.MOCK_HISTORY_NO_IDS === '1' && projected.__openclaw) delete projected.__openclaw.id;
  if (!Array.isArray(projected.content)) return projected;
  let truncated = false;
  for (const block of projected.content) {
    if (block?.type === 'text' && typeof block.text === 'string' && block.text.length > maxChars) {
      block.text = `${block.text.slice(0, maxChars)}\n...(truncated)...`;
      truncated = true;
    }
  }
  if (truncated) projected.__openclaw = { ...projected.__openclaw, truncated: true };
  return projected;
}

export function runDelay(run, ms) {
  if (run.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      run.waiters.delete(resolve);
      run.timers.delete(timer);
      resolve();
    }, ms);
    run.timers.add(timer);
    run.waiters.add(resolve);
  });
}

export function finishRunAbort(state, run) {
  if (run.finished) return;
  run.finished = true;
  for (const timer of run.timers) clearTimeout(timer);
  run.timers.clear();
  for (const resolve of run.waiters) resolve();
  run.waiters.clear();
  const row = state.sessions.get(run.sessionKey);
  if (row) {
    row.hasActiveRun = false;
    row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
    row.status = 'idle';
    markRunEnded(row);
    markSubagentAborted(state, row, run, broadcastSessionChanged);
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionChanged(state, run.sessionKey, 'abort', row);
  }
  // Like upstream chat-abort.ts: a terminal lifecycle end marked aborted, then the chat state.
  broadcast(state, 'agent', {
    runId: run.runId,
    sessionKey: run.sessionKey,
    ...(run.spawnedBy ? { spawnedBy: run.spawnedBy } : {}),
    seq: ++run.seq,
    stream: 'lifecycle',
    data: { phase: 'end', status: 'cancelled', aborted: true, stopReason: 'user', ...(run.startedAt ? { startedAt: run.startedAt } : {}), endedAt: nowMs() },
  });
  broadcast(state, 'chat', { runId: run.runId, sessionKey: run.sessionKey, seq: ++run.seq, state: 'aborted' });
  state.activeRuns.delete(run.runId);
}

export function abortMatchingRuns(state, sessionKey, runId) {
  let count = 0;
  for (const run of state.activeRuns.values()) {
    if ((runId && run.runId === runId) || (!runId && run.sessionKey === sessionKey)) {
      run.aborted = true;
      finishRunAbort(state, run);
      count += 1;
    }
  }
  return count;
}

export function putProgressCard(state, sessionKey, { markdown, steps }) {
  const previous = state.progressCards.get(sessionKey);
  const card = { sessionKey, revision: (previous?.revision ?? 0) + 1, updatedAt: nowMs(), markdown, steps };
  state.progressCards.set(sessionKey, card);
  broadcast(state, 'progressCard.changed', { sessionKey, revision: card.revision });
  return card;
}

/** Walks a three-step `progress_card` checklist, as an agent following a plan would. */

export async function simulatePlan(state, run, sessionKey, row) {
  const markdown = '**Three-step task: mock plan**\n\nThe card updates between phases.';
  const labels = ['Inspect the workspace', 'Draft the change', 'Validate and summarize'];
  for (let current = 0; current <= labels.length; current += 1) {
    const steps = labels.map((step, index) => ({
      step,
      status: index < current ? 'completed' : index === current ? 'in_progress' : 'pending',
    }));
    const toolCallId = shortId('call_');
    const args = { markdown, plan: steps };
    broadcast(state, 'agent', {
      runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
      data: { phase: 'start', name: 'progress_card', toolCallId, args },
    });
    const card = putProgressCard(state, sessionKey, { markdown, steps });
    const done = steps.filter((step) => step.status === 'completed').length;
    const result = `Progress card updated (rev ${card.revision}, ${done}/${steps.length} done)`;
    broadcast(state, 'agent', {
      runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
      data: { phase: 'result', name: 'progress_card', toolCallId, isError: false, result },
    });
    const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'progress_card', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
    const toolResult = makeMessage('toolResult', [textBlock(result)], {
      openclaw: { runId: run.runId },
      extra: { toolCallId, toolName: 'progress_card', isError: false },
    });
    const transcript = state.transcripts.get(sessionKey);
    transcript.push(toolMsg, toolResult);
    broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
    broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    if (current < labels.length) {
      await runDelay(run, 1500);
      if (run.aborted) return;
    }
  }
}

// Summarizes a session's context: appends the compaction marker and shrinks `totalTokens`.
// Returns `{ tokensBefore, tokensAfter }`, or null when there's too little to compact.
export function compactSession(state, sessionKey) {
  const row = state.sessions.get(sessionKey);
  const transcript = state.transcripts.get(sessionKey);
  const tokensBefore = row?.totalTokens ?? 0;
  if (!row || !transcript || tokensBefore < 4_000) return null;
  const tokensAfter = Math.round(tokensBefore * 0.18);
  const marker = makeMessage('system', [], { openclaw: { kind: 'compaction' } });
  transcript.push(marker);
  broadcastSessionMessage(state, sessionKey, marker, transcript.length);
  updateSessionRow(row, { totalTokens: tokensAfter, totalTokensFresh: true });
  return { tokensBefore, tokensAfter };
}

// `/compact [instructions]` sent as a chat message: compaction events, the marker, and a short reply.
export async function simulateCompactCommand(state, run, sessionKey, row, instructions) {
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'compaction', data: { phase: 'start' } });
  await runDelay(run, 600);
  if (run.aborted) return;
  const result = compactSession(state, sessionKey);
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'compaction', data: { phase: 'end', completed: Boolean(result) } });
  const transcript = state.transcripts.get(sessionKey);
  const text = result
    ? `⚙️ Compacted (${result.tokensBefore} → ${result.tokensAfter} tokens)${instructions ? `, keeping: ${instructions}` : ''}.`
    : '⚙️ Nothing to compact yet.';
  const reply = makeMessage('assistant', [textBlock(text)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  transcript.push(reply);
  broadcastSessionMessage(state, sessionKey, reply, transcript.length);
  broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'final', message: clone(reply) });
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'end' } });
  row.hasActiveRun = false;
  row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
  row.status = 'idle';
  markRunEnded(row);
  row.lastMessagePreview = text;
  updateSessionRow(row, { lastActivityAt: nowMs() });
  broadcastSessionChanged(state, sessionKey, 'compact', row);
  run.finished = true;
  state.activeRuns.delete(run.runId);
}

/// `__openclaw` reply metadata for a `chat.send` with `replyToId`, like upstream: the target's text
/// (up to 2000 characters) and who wrote it. Unknown ids send without it.
export function replyFacts(state, sessionKey, replyToId, conn) {
  if (typeof replyToId !== 'string' || !replyToId || replyToId.startsWith('pending:')) return {};
  const target = state.transcripts.get(sessionKey)?.find((entry) => entry.__openclaw?.id === replyToId);
  if (!target) return {};
  const text = (target.content ?? [])
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
    .join('\n')
    .trim()
    .slice(0, 2000);
  const agentId = state.sessions.get(sessionKey)?.agentId ?? 'main';
  const senderLabel = target.role === 'assistant'
    ? (state.agents.get(agentId)?.identity?.name ?? 'Assistant')
    : (conn.client?.displayName ?? 'User');
  return { replyToId, replyToPreview: { text, senderLabel } };
}

export async function simulateRun(state, run, params, replyMeta = {}) {
  const { sessionKey, message: text, attachments = [] } = params;
  const row = state.sessions.get(sessionKey);
  const transcript = state.transcripts.get(sessionKey);
  if (!row || !transcript) return;
  try {
    const prepared = withWorkContext(String(text ?? ''), params.workContext);
    const content = [textBlock(prepared.text)];
    for (const attachment of attachments) {
      if (attachment?.content && String(attachment.mimeType ?? '').startsWith('image/')) {
        const artifactId = `upload-${shortId()}`;
        state.artifacts.set(artifactId, {
          artifactId,
          mimeType: attachment.mimeType,
          data: Buffer.from(attachment.content, 'base64'),
        });
        content.push(imageBlock(artifactId, attachment.fileName ?? 'Uploaded image'));
      }
    }
    const userMsg = makeMessage('user', content, { openclaw: { runId: run.runId, idempotencyKey: `${params.idempotencyKey}:user`, ...replyMeta, ...prepared.facts } });
    transcript.push(userMsg);
    row.hasActiveRun = true;
    row.activeRunIds = [...new Set([...row.activeRunIds, run.runId])];
    row.status = 'running';
    markRunStarted(row);
    row.lastMessagePreview = String(text ?? '').slice(0, 120);
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionMessage(state, sessionKey, userMsg, transcript.length);
    broadcastSessionChanged(state, sessionKey, 'send', row);

    const compact = /^\/compact(?:\s+([\s\S]*))?$/i.exec(String(text ?? '').trim());
    if (compact) return await simulateCompactCommand(state, run, sessionKey, row, compact[1]?.trim() ?? '');

    if (/\bapprove\b/i.test(String(text ?? ''))) {
      // `approve once-only` leaves allow-always out of allowedDecisions; `approve short-lived` expires in 3 s.
      const onceOnly = /\bonce-only\b/i.test(String(text ?? ''));
      const ttlMs = /\bshort-lived\b/i.test(String(text ?? '')) ? 3_000 : 120_000;
      const approval = {
        id: shortId('approval_'),
        request: {
          command: 'rm -rf ./build',
          cwd: '/home/claw/project',
          sessionKey,
          agentId: row.agentId,
          allowedDecisions: onceOnly ? ['allow-once', 'deny'] : ['allow-once', 'allow-always', 'deny'],
        },
        createdAtMs: nowMs(),
        expiresAtMs: nowMs() + ttlMs,
      };
      state.pendingApprovals.set(approval.id, approval);
      setTimeout(() => {
        if (state.pendingApprovals.get(approval.id) === approval) state.pendingApprovals.delete(approval.id);
      }, ttlMs).unref?.();
      noteApprovalForLogs(state, approval);
      broadcast(state, 'exec.approval.requested', clone(approval));
    }

    run.startedAt = nowMs();
    broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'start', startedAt: run.startedAt } });
    broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'status', phase: 'thinking' });
    const thinkingParts = ['Thinking', ' through', ' the', ' mock', ' gateway', ' response...'];
    let thinking = '';
    for (const part of thinkingParts) {
      await runDelay(run, 160);
      if (run.aborted) return;
      thinking += part;
      broadcast(state, 'chat', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        state: 'delta',
        deltaText: '',
        message: makeMessage('assistant', [thinkingBlock(thinking)], { openclaw: { runId: run.runId }, model: rowModel(row) }),
      });
    }

    if (String(text ?? '').includes('[mock:fail-run]')) {
      // Like a provider timeout: the run ends with a chat `error` event and an `error` lifecycle phase.
      const errorMessage = 'LLM request timed out.';
      broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'error', errorMessage, errorKind: 'timeout' });
      broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'error', error: errorMessage } });
      row.hasActiveRun = false;
      row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
      row.status = 'idle';
      markRunEnded(row);
      updateSessionRow(row, { lastActivityAt: nowMs() });
      broadcastSessionChanged(state, sessionKey, 'run-finished', row);
      run.finished = true;
      state.activeRuns.delete(run.runId);
      return;
    }

    if (/\bplan\b/i.test(String(text ?? ''))) {
      await simulatePlan(state, run, sessionKey, row);
      if (run.aborted) return;
    }

    let answered = null;
    if (/\bsecret\b/i.test(String(text ?? ''))) {
      answered = await simulateSecretQuestion(state, run, sessionKey, row);
      if (run.aborted) return;
    } else if (/\bask\b/i.test(String(text ?? ''))) {
      answered = await simulateQuestion(state, run, sessionKey, row);
      if (run.aborted) return;
    }

    // `spawn` delegates to a subagent (`spawn fail` makes it fail), like `sessions_spawn`.
    let spawned = null;
    if (/\bspawn\b/i.test(String(text ?? ''))) {
      spawned = await simulateSpawn(state, run, sessionKey, {
        broadcast, broadcastSessionChanged, broadcastSessionMessage, makeSessionRow, makeMessage, textBlock, thinkingBlock,
        toolCallBlock, runDelay, shortId, rowModel,
      }, { fail: /\bspawn fail\b/i.test(String(text ?? '')) });
      if (run.aborted) return;
    }

    // `image huge` (one image over the 25 MiB cap) and `image many` (40 large ones) skip the tool call.
    const largeImages = /\bimage huge\b/i.test(String(text ?? '')) ? 'huge' : /\bimage many\b/i.test(String(text ?? '')) ? 'many' : null;
    const wantsTool = !largeImages && /tool|disk|image/i.test(String(text ?? ''));
    if (wantsTool) {
      const toolCallId = shortId('call_');
      broadcast(state, 'agent', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        stream: 'tool',
        data: { phase: 'start', name: 'exec', toolCallId, args: { command: 'uptime' } },
      });
      await runDelay(run, 800);
      if (run.aborted) return;
      broadcast(state, 'agent', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        stream: 'tool',
        data: { phase: 'result', name: 'exec', toolCallId, isError: false, result: ' 10:42  up 3 days, 4 users, load averages: 1.2 1.0 0.8' },
      });
      const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'exec', { command: 'uptime' })], { openclaw: { runId: run.runId }, model: rowModel(row) });
      const toolResult = makeMessage('toolResult', [textBlock(' 10:42  up 3 days, 4 users, load averages: 1.2 1.0 0.8')], {
        openclaw: { runId: run.runId },
        extra: { toolCallId, toolName: 'exec', isError: false },
      });
      transcript.push(toolMsg, toolResult);
      broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
      broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    }

    // "patch"/"diff" runs an upstream-shaped `edit` so clients can render its diff live.
    const wantsEdit = /\b(patch|diff)\b/i.test(String(text ?? ''));
    if (wantsEdit) {
      const call = liveFileEditCall();
      const toolCallId = shortId('call_');
      broadcast(state, 'agent', {
        runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
        data: { phase: 'start', name: call.name, toolCallId, args: call.args },
      });
      await runDelay(run, 400);
      if (run.aborted) return;
      broadcast(state, 'agent', {
        runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool',
        data: {
          phase: 'result', name: call.name, toolCallId, isError: false,
          result: { content: [textBlock(call.result)], details: call.details },
        },
      });
      const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, call.name, call.args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
      const toolResult = makeMessage('toolResult', [textBlock(call.result)], {
        openclaw: { runId: run.runId },
        extra: { toolCallId, toolName: call.name, details: call.details, isError: false },
      });
      transcript.push(toolMsg, toolResult);
      broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
      broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
    }

    const reply = spawned ? `Spawned a subagent: ${spawned.childSessionKey}. It will report back here.` : answered ?? `I heard: "${String(text ?? '')}".\n\n## Mock response\n\n- Streaming deltas are working.\n- Tool events are ${wantsTool ? 'included' : 'available when requested'}.\n- Markdown rendering can be tested here.\n\n\`\`\`text\nrunId=${run.runId}\n\`\`\``;
    const words = reply.split(/(\s+)/).filter((p) => p.length > 0);
    let out = '';
    for (const word of words) {
      await runDelay(run, 40);
      if (run.aborted) return;
      out += word;
      broadcast(state, 'chat', {
        runId: run.runId,
        sessionKey,
        seq: ++run.seq,
        state: 'delta',
        deltaText: word,
        message: makeMessage('assistant', [thinkingBlock(thinking), textBlock(out)], { openclaw: { runId: run.runId }, model: rowModel(row) }),
      });
    }
    const finalContent = [thinkingBlock(thinking), textBlock(reply)];
    if (largeImages) finalContent.push(...largeImageBlocks(state, largeImages));
    else if (/image/i.test(String(text ?? ''))) finalContent.push(imageBlock('art-chart-1', 'Synthetic mock chart'));
    const finalMsg = makeMessage('assistant', finalContent, { openclaw: { runId: run.runId }, model: rowModel(row) });
    transcript.push(finalMsg);
    broadcastSessionMessage(state, sessionKey, finalMsg, transcript.length);
    broadcast(state, 'chat', { runId: run.runId, sessionKey, seq: ++run.seq, state: 'final', message: clone(finalMsg) });
    broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'lifecycle', data: { phase: 'end' } });

    row.hasActiveRun = false;
    row.activeRunIds = row.activeRunIds.filter((id) => id !== run.runId);
    row.status = 'idle';
    markRunEnded(row);
    row.lastMessagePreview = reply.slice(0, 120);
    row.unread = true;
    // Each turn grows the context; the snapshot never passes the window.
    if (row.totalTokens !== undefined) {
      const limit = row.contextTokens ?? DEFAULT_CONTEXT_TOKENS;
      row.inputTokens = row.totalTokens;
      row.outputTokens = Math.ceil(reply.length / 4);
      row.totalTokens = Math.min(limit, row.totalTokens + 1_200 + row.outputTokens);
      row.totalTokensFresh = true;
    }
    updateSessionRow(row, { lastActivityAt: nowMs() });
    broadcastSessionChanged(state, sessionKey, 'run-finished', row);
    run.finished = true;
    state.activeRuns.delete(run.runId);
  } catch (err) {
    if (!run.aborted) console.error('run simulation failed:', err);
    state.activeRuns.delete(run.runId);
  }
}

// Cron runs write into their automation's chat (`agent:<agent>:cron:<job>`), creating it on first use.
export function postToSession(state, key, { agentId, label, userText, replyText }) {
  let row = state.sessions.get(key);
  if (!row) {
    row = makeSessionRow(key, { agentId, label, derivedTitle: label, channel: 'cron' });
    state.sessions.set(key, row);
    state.transcripts.set(key, []);
  }
  const transcript = state.transcripts.get(key);
  const userMsg = makeMessage('user', [textBlock(userText)]);
  const reply = makeMessage('assistant', [textBlock(replyText)]);
  transcript.push(userMsg, reply);
  broadcastSessionMessage(state, key, userMsg, transcript.length - 1);
  broadcastSessionMessage(state, key, reply, transcript.length);
  row.unread = true;
  row.lastMessagePreview = replyText;
  updateSessionRow(row, { lastActivityAt: nowMs() });
  broadcastSessionChanged(state, key, 'cron', row);
  return row;
}

export const CHAT_METHODS = new Set(['progressCard.get', 'progressCard.put', 'chat.history', 'chat.message.get', 'chat.send', 'message.action', 'chat.abort', 'sessions.compact']);

export function handleChatRequest(state, conn, msg) {
  if (!CHAT_METHODS.has(msg.method)) return false;
  dispatch(state, conn, msg);
  return true;
}

function dispatch(state, conn, msg) {
  const { id, method, params = {} } = msg;
  switch (method) {
    case 'progressCard.get': {
      const key = params.sessionKey;
      if (!key) return sendErr(conn, id, 'INVALID_REQUEST', 'sessionKey is required.');
      sendRes(conn, id, { card: clone(state.progressCards.get(key) ?? null) });
      return;
    }
    case 'progressCard.put': {
      const key = params.sessionKey;
      if (!key) return sendErr(conn, id, 'INVALID_REQUEST', 'sessionKey is required.');
      const current = state.progressCards.get(key);
      if (params.markdown === undefined && params.plan === undefined) {
        // Conditional clear: only the revision the client saw is dismissed.
        if (current && params.expectedRevision !== undefined && current.revision !== params.expectedRevision) {
          sendRes(conn, id, { card: clone(current) });
          return;
        }
        state.progressCards.delete(key);
        if (params.expectedRevision === undefined) broadcast(state, 'progressCard.changed', { sessionKey: key, revision: null });
        sendRes(conn, id, { card: null });
        return;
      }
      sendRes(conn, id, { card: clone(putProgressCard(state, key, { markdown: params.markdown, steps: params.plan })) });
      return;
    }
    case 'chat.history': {
      const key = params.sessionKey;
      const row = state.sessions.get(key);
      const transcript = state.transcripts.get(key);
      if (!row || !transcript) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      const limit = Number.isFinite(params.limit) ? Math.max(0, params.limit) : transcript.length;
      // Like the Gateway: `offset` counts back from the newest message; `nextOffset` pages older.
      const offset = Number.isFinite(params.offset) ? Math.max(0, params.offset) : 0;
      const end = Math.max(0, transcript.length - offset);
      const start = Math.max(0, end - limit);
      const activeRun = row.activeRunIds[0] ? state.activeRuns.get(row.activeRunIds[0]) : undefined;
      sendRes(conn, id, {
        sessionKey: key,
        sessionId: row.sessionId,
        messages: transcript.slice(start, end).map((message) => projectForHistory(message)),
        totalMessages: transcript.length,
        hasMore: start > 0,
        ...(start > 0 ? { nextOffset: offset + (end - start) } : {}),
        thinkingLevel: 'medium',
        sessionInfo: { hasActiveRun: row.hasActiveRun, activeRunIds: [...row.activeRunIds] },
        ...(activeRun ? { inFlightRun: { runId: activeRun.runId, text: activeRun.text } } : {}),
      });
      break;
    }
    case 'chat.message.get': {
      const transcript = state.transcripts.get(params.sessionKey);
      if (!transcript) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      const message = transcript.find((entry) => entry.__openclaw?.id === params.messageId);
      if (!message) return sendRes(conn, id, { ok: false, unavailableReason: 'not_found' });
      const maxChars = Number.isFinite(params.maxChars) ? params.maxChars : 1_000_000;
      sendRes(conn, id, { ok: true, message: projectForHistory(message, maxChars) });
      break;
    }
    case 'chat.send': {
      const key = params.sessionKey;
      // Gateways from before reply support reject the unknown property outright.
      if (process.env.MOCK_NO_REPLY_TO === '1' && Object.hasOwn(params, 'replyToId')) {
        return sendErr(conn, id, 'INVALID_REQUEST', "invalid chat.send params: at root: unexpected property 'replyToId'");
      }
      if (Object.hasOwn(params, 'workContext')) {
        if (process.env.MOCK_NO_WORK_CONTEXT === '1') {
          return sendErr(conn, id, 'INVALID_REQUEST', "invalid chat.send params: at root: unexpected property 'workContext'");
        }
        if (!validWorkContext(params.workContext)) return sendErr(conn, id, 'INVALID_REQUEST', 'invalid chat.send params: invalid workContext');
      }
      if (!params.idempotencyKey) return sendErr(conn, id, 'INVALID_REQUEST', 'idempotencyKey is required');
      if (!state.sessions.has(key)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      // Test hooks (see README): `[mock:fail-send]` / `[mock:reject-send]` always refuse; `[mock:drop]`
      // always drops this connection; the `-once` hooks only hit the first attempt for an idempotencyKey,
      // so a retry with the same key goes through.
      const message = String(params.message ?? '');
      const attempt = (state.sendAttempts.get(params.idempotencyKey) ?? 0) + 1;
      state.sendAttempts.set(params.idempotencyKey, attempt);
      if (message.includes('[mock:fail-send]')) return sendErr(conn, id, 'UNAVAILABLE', 'mock send failure');
      if (message.includes('[mock:reject-send]')) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid chat.send params: mock rejection');
      }
      if (message.includes('[mock:drop]')) return conn.ws.close(1012, 'mock drop');
      if (attempt === 1 && message.includes('[mock:unavailable-once]')) {
        return sendJson(conn.ws, {
          type: 'res', id, ok: false,
          error: { code: 'UNAVAILABLE', message: 'Previous run is still shutting down. Please try again in a moment.', retryable: true, retryAfterMs: 250 },
        });
      }
      if (attempt === 1 && message.includes('[mock:drop-once]')) return conn.ws.close(1012, 'mock drop');
      // Like upstream's dedupe cache: a repeated key starts nothing new and answers `in_flight` while the
      // run is going, then the cached terminal `ok`.
      if (state.idempotency.has(params.idempotencyKey)) {
        const runId = state.idempotency.get(params.idempotencyKey);
        return sendRes(conn, id, { runId, status: state.activeRuns.has(runId) ? 'in_flight' : 'ok' });
      }
      const runId = shortId('run_');
      state.idempotency.set(params.idempotencyKey, runId);
      // The ambiguous failure: the Gateway accepts the send, then the socket drops before the ack.
      const dropAfterAccept = attempt === 1 && message.includes('[mock:drop-after-accept]');
      noteChatForLogs(state, key, message, runId);
      const run = {
        runId,
        sessionKey: key,
        text: params.message ?? '',
        seq: 0,
        aborted: false,
        finished: false,
        timers: new Set(),
        waiters: new Set(),
      };
      state.activeRuns.set(runId, run);
      const reply = replyFacts(state, key, params.replyToId, conn);
      if (dropAfterAccept) conn.ws.close(1012, 'mock drop');
      else sendRes(conn, id, { runId, status: 'started' });
      setImmediate(() => simulateRun(state, run, params, reply));
      break;
    }
    case 'message.action': {
      for (const field of ['channel', 'action', 'idempotencyKey']) {
        if (typeof params[field] !== 'string' || !params[field]) return sendErr(conn, id, 'INVALID_REQUEST', `${field} is required`);
      }
      if (!params.params || typeof params.params !== 'object') return sendErr(conn, id, 'INVALID_REQUEST', 'params is required');
      if (state.messageActions.has(params.idempotencyKey)) return sendRes(conn, id, state.messageActions.get(params.idempotencyKey));
      const { emoji, messageId, remove } = params.params;
      if (params.action !== 'react') return sendErr(conn, id, 'INVALID_REQUEST', `unsupported action: ${params.action}`);
      if (params.channel !== 'discord') return sendErr(conn, id, 'INVALID_REQUEST', `reactions are not supported on ${params.channel}`);
      if (typeof emoji !== 'string' || !emoji || typeof messageId !== 'string' || !messageId) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'react needs params.emoji and params.messageId');
      }
      const result = remove === true ? { ok: true, removed: emoji } : { ok: true, added: emoji };
      state.messageActions.set(params.idempotencyKey, result);
      state.reactionLog.push({ channel: params.channel, sessionKey: params.sessionKey, ...params.params });
      sendRes(conn, id, result);
      break;
    }
    case 'chat.abort': {
      abortMatchingRuns(state, params.sessionKey, params.runId);
      sendRes(conn, id, { aborted: true });
      break;
    }
    case 'sessions.compact': {
      if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
        return sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
      }
      const row = state.sessions.get(params.key);
      if (!row) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      if (row.hasActiveRun) return sendErr(conn, id, 'UNAVAILABLE', 'session has an active run');
      const result = compactSession(state, params.key);
      if (!result) return sendRes(conn, id, { ok: true, key: params.key, compacted: false, reason: 'Nothing to compact yet.' });
      sendRes(conn, id, { ok: true, key: params.key, compacted: true, result });
      broadcastSessionChanged(state, params.key, 'compact', row);
      break;
    }
  }
}
