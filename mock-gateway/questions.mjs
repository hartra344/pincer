import { rowModel } from './catalog.mjs';
import { runDelay } from './chat.mjs';
import { writeSecret } from './secrets.mjs';
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

// Requests an API key like upstream's `secrets` tool: one isSecret question bound to the secret store.
// Answering writes the value to secrets.store; only the "stored" marker reaches the record, events and transcript.
export async function simulateSecretQuestion(state, run, sessionKey, row) {
  const toolCallId = shortId('call_');
  const name = 'STRIPE_API_KEY';
  const reason = "Needed to reconcile this month's Stripe payouts.";
  const args = { action: 'request', name, allowedHosts: ['api.stripe.com'], reason };
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'start', name: 'secrets', toolCallId, args } });
  const record = {
    id: shortId('ask_'),
    questions: [{
      questionId: 'secret_value',
      header: 'API key',
      question: `Provide the secret for ${name}.`,
      options: [],
      isSecret: true,
      secretStore: { name, kind: 'secret', allowedHosts: ['api.stripe.com'], reason },
    }],
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
  const stored = record.status === 'answered';
  const output = stored
    ? `Stored; value hidden. Use the returned ref for config SecretRefs.\n\n${JSON.stringify({ status: 'stored', name, kind: 'secret', ref: { source: 'store', provider: 'default', id: name } })}`
    : `No credential arrived; proceed with best judgment.\n\n${JSON.stringify({ status: 'no_answer' })}`;
  broadcast(state, 'agent', { runId: run.runId, sessionKey, seq: ++run.seq, stream: 'tool', data: { phase: 'result', name: 'secrets', toolCallId, isError: false, result: output } });
  const transcript = state.transcripts.get(sessionKey);
  const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'secrets', args)], { openclaw: { runId: run.runId }, model: rowModel(row) });
  const toolResult = makeMessage('toolResult', [textBlock(output)], { openclaw: { runId: run.runId }, extra: { toolCallId, toolName: 'secrets', isError: false } });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, sessionKey, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, sessionKey, toolResult, transcript.length);
  return stored
    ? `Thanks — ${name} is in the Gateway's secret store. I'll reference it by name and never see the value.`
    : "No problem, I'll skip the Stripe reconciliation for now.";
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

// Upstream writes a store-bound answer to the secret store and fans out only { [questionId]: ["stored"] }.
function resolveSecretStoreAnswer(state, record, params) {
  const question = record.questions[0];
  const values = params.answers?.answers?.[question.questionId];
  if (!Array.isArray(values) || values.length !== 1 || typeof values[0] !== 'string' || !values[0]) return null;
  const { name, kind = 'secret', allowedHosts = [] } = question.secretStore;
  writeSecret(state, name, { kind, value: values[0], allowedHosts });
  return { answers: { [question.questionId]: ['stored'] } };
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
      const answers = record.questions[0]?.secretStore
        ? resolveSecretStoreAnswer(state, record, params)
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
