import { rowModel } from './catalog.mjs';
import { runDelay } from './chat.mjs';
import { broadcastSessionMessage } from './session-list.mjs';
import { broadcast, clone, makeMessage, nowMs, sendErr, sendRes, shortId, textBlock, toolCallBlock } from './util.mjs';

export const QUESTIONS_SCOPE = 'operator.questions';

export function hasQuestionsScope(conn) {
  return conn.scopes?.includes(QUESTIONS_SCOPE) || conn.scopes?.includes('operator.admin');
}

export function sendMissingQuestionsScope(conn, id) {
  sendErr(conn, id, 'FORBIDDEN', `missing scope: ${QUESTIONS_SCOPE}`, {
    code: 'MISSING_SCOPE',
    missingScope: QUESTIONS_SCOPE,
    requiredScopes: [QUESTIONS_SCOPE],
  });
}

export function settleQuestion(state, record, status, answers = undefined) {
  if (record.status !== 'pending') return;
  record.status = status;
  if (answers) record.answers = answers;
  broadcast(state, 'question.resolved', { id: record.id, status, ...(answers ? { answers } : {}) }, hasQuestionsScope);
}

async function waitForQuestion(state, run, record) {
  while (record.status === 'pending' && !run.aborted) {
    await runDelay(run, 100);
    if (nowMs() >= record.expiresAtMs) settleQuestion(state, record, 'expired');
  }
}

function publishQuestion(state, record) {
  state.questions.set(record.id, record);
  broadcast(state, 'question.requested', clone(record), hasQuestionsScope);
}

// Asks an ask_user question like OpenClaw does (question.requested), then blocks the run until it's settled.
export async function simulateQuestion(state, run, sessionKey, row) {
  const toolCallId = shortId('call_');
  const options = [
    { label: 'Disconnect Discord from OpenClaw', description: 'Remove the Discord channel integration/config; the server itself stays intact' },
    { label: 'Delete one channel in the Discord server', description: 'e.g. #coworking or #gyms — tell me which' },
    { label: 'Stop watching Discord channels here', description: 'Only stop this chat from ambiently watching them' },
  ];
  const args = { questions: [{ id: 'discord_remove', header: 'Discord', question: 'What do you want removed?', options }] };
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'start', name: 'ask_user', toolCallId, args } });
  const record = {
    id: shortId('ask_'),
    questions: [{ questionId: 'discord_remove', header: 'Discord', question: 'What do you want removed?', options, isOther: true }],
    agentId: row.agentId,
    sessionKey,
    runId: run.runId,
    createdAtMs: nowMs(),
    expiresAtMs: nowMs() + 900_000,
    status: 'pending',
  };
  publishQuestion(state, record);
  await waitForQuestion(state, run, record);
  if (run.aborted) {
    settleQuestion(state, record, 'cancelled');
    return null;
  }
  const picked = record.answers?.answers?.discord_remove ?? [];
  const output = record.status === 'answered' ? `User answered: ${picked.join(', ')}` : `User ${record.status === 'expired' ? "didn't answer in time" : 'skipped the question'}`;
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'result', name: 'ask_user', toolCallId, isError: false, result: output } });
  const transcript = state.transcripts.get(sessionKey);
  const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'ask_user', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  const toolResult = makeMessage('toolResult', [textBlock(output)], { openclaw: { runId: run.runId }, extra: { toolCallId, toolName: 'ask_user', isError: false } });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
  return record.status === 'answered' ? `You picked: ${picked.join(', ')}.` : 'Okay, skipping that.';
}

// Asks for sensitive form fields the Gateway will fill itself, never echoing the answers back.
export async function simulateSecureFormQuestion(state, run, sessionKey, row) {
  const toolCallId = shortId('call_');
  const args = { fields: [{ role: 'username' }, { role: 'password' }, { role: 'otp' }] };
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'start', name: 'requestSecureInput', toolCallId, args } });
  const record = {
    id: shortId('ask_'),
    kind: 'secure_form',
    requestId: shortId('secure_'),
    origin: 'mail.google.com',
    fields: [
      { fieldId: 'identifier', role: 'username' },
      { fieldId: 'password', role: 'password' },
      { fieldId: 'otp', role: 'otp' },
    ],
    agentId: row.agentId,
    sessionKey,
    runId: run.runId,
    createdAtMs: nowMs(),
    expiresAtMs: nowMs() + 900_000,
    status: 'pending',
  };
  publishQuestion(state, record);
  await waitForQuestion(state, run, record);
  if (run.aborted) {
    settleQuestion(state, record, 'cancelled');
    return null;
  }
  const output = record.status === 'answered'
    ? `Secure form completed for ${record.origin}.`
    : `Secure form ${record.status === 'expired' ? 'expired before the operator answered' : 'was declined by the operator'}.`;
  broadcast(state, 'agent', {
    runId: run.runId,
    sessionKey,
    seq: ++run.seq,
    stream: 'tool',
    data: { phase: 'result', name: 'requestSecureInput', toolCallId, isError: false, result: output },
  });
  const transcript = state.transcripts.get(sessionKey);
  const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'requestSecureInput', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  const toolResult = makeMessage('toolResult', [textBlock(output)], {
    openclaw: { runId: run.runId },
    extra: { toolCallId, toolName: 'requestSecureInput', isError: false },
  });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
  if (record.status === 'answered') return `I filled the verified sign-in fields for ${record.origin}. Review the page and submit it there if everything looks right.`;
  if (record.status === 'expired') return `No problem — the secure sign-in request for ${record.origin} expired before anything was filled.`;
  return `Okay, I left the ${record.origin} sign-in form untouched.`;
}

export const QUESTION_METHODS = new Set(['question.list', 'question.resolve']);

export function handleQuestionRequest(state, conn, msg) {
  if (!QUESTION_METHODS.has(msg.method)) return false;
  dispatch(state, conn, msg);
  return true;
}

function resolveAskUserAnswer(record, params) {
  const answers = params.answers?.answers;
  const complete = answers && record.questions.every((q) =>
    Array.isArray(answers[q.questionId]) && answers[q.questionId].length > 0 && answers[q.questionId].every((v) => typeof v === 'string'));
  if (!complete) return null;
  return { answers };
}

function resolveSecureFormAnswer(record, params) {
  const payload = params.answers;
  const answers = payload?.answers;
  const complete = payload?.requestId === record.requestId
    && answers
    && record.fields.every((field) => typeof answers[field.fieldId] === 'string' && answers[field.fieldId].length > 0);
  if (!complete) return null;
  const picked = Object.fromEntries(record.fields.map((field) => [field.fieldId, answers[field.fieldId]]));
  return { requestId: record.requestId, answers: picked };
}

function dispatch(state, conn, msg) {
  const { id, method, params = {} } = msg;
  switch (method) {
    case 'question.list': {
      if (!hasQuestionsScope(conn)) return sendMissingQuestionsScope(conn, id);
      sendRes(conn, id, { questions: [...state.questions.values()].filter((q) => q.status === 'pending').map(clone) });
      break;
    }
    case 'question.resolve': {
      if (!hasQuestionsScope(conn)) return sendMissingQuestionsScope(conn, id);
      const record = state.questions.get(params.id);
      if (!record) {
        return sendErr(conn, id, 'INVALID_REQUEST', `question '${params.id}' was not found`, { reason: 'QUESTION_NOT_FOUND' });
      }
      if (record.status !== 'pending') {
        return sendErr(conn, id, 'INVALID_REQUEST', 'question is already resolved', { reason: 'QUESTION_ALREADY_TERMINAL' });
      }
      if (params.cancel === true) {
        settleQuestion(state, record, 'cancelled');
        return sendRes(conn, id, { status: 'cancelled' });
      }
      const answers = record.kind === 'secure_form'
        ? resolveSecureFormAnswer(record, params)
        : resolveAskUserAnswer(record, params);
      if (!answers) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'every question needs an answer', { reason: 'QUESTION_INVALID_ANSWER' });
      }
      settleQuestion(state, record, 'answered', answers);
      sendRes(conn, id, { status: 'answered', answers });
      break;
    }
  }
}
