// Subagent runs (`sessions_spawn`) for the mock Gateway: a seeded parent chat with spawned child
// sessions, and live spawns streamed as upstream `agent` events.
//
// Shapes follow openclaw/openclaw:
// - Session rows (packages/gateway-protocol/src/schema/sessions-row.ts): `spawnedBy`,
//   `parentSessionKey`, `childSessions`, `spawnDepth`, `subagentRole`, `subagentControlScope`,
//   `createdVia: "spawn"`, `status` (queued | running | done | failed | killed | timeout),
//   `startedAt`, `endedAt`, `runtimeMs`, `lastRunError`, `lastRunId`, `abortedLastRun`,
//   `subagentRunState` (active | interrupted | historical), `hasActiveSubagentRun`.
// - Agent events (src/infra/agent-events.ts): `{ runId, seq, stream, ts, sessionKey, spawnedBy?, data }`
//   with streams `lifecycle` (start {startedAt} / end {endedAt, aborted?, stopReason?} /
//   error {error, endedAt}), `thinking` and `assistant` ({ text, delta }), and `tool`
//   (start {name, toolCallId, args} / update {partialResult} / result {isError, result}).
// - The `sessions_spawn` tool result: `{ status: "accepted", childSessionKey, runId }`.
// - `sessions.list` takes `spawnedBy` to list one session's children.

import crypto from 'node:crypto';

export const SUBAGENT_PARENT_KEY = 'agent:coder:dashboard:release';
export const SEEDED_SUBAGENTS = {
  done: 'agent:coder:subagent:5b0f2c1e-8d4a-4f6e-9a51-2c7d3e1f0a01',
  failed: 'agent:coder:subagent:9e3d7a60-1b2c-4d8e-b7f4-6a5c4d3b2e02',
  running: 'agent:research:subagent:c41a8f93-7e6d-4a2b-8c1f-0d9e8b7a6f03',
  // Spawned by the running orchestrator, then stopped.
  killed: 'agent:research:subagent:e2b19d74-3f5a-4c6b-9d8e-7f1a2b3c4d04',
};
export const SEEDED_RUNNING_RUN_ID = 'run_seed_docs_audit';

const MINUTE = 60_000;

/// Adds the release chat and its subagents. `h` carries server.mjs helpers.
export function seedSubagents(h) {
  const { row, transcripts, makeMessage, textBlock, thinkingBlock, toolCallBlock, base } = h;
  const at = (ago) => base - ago;
  const said = (message, ago) => ({ ...message, timestamp: at(ago) });
  const kids = SEEDED_SUBAGENTS;

  row(SUBAGENT_PARENT_KEY, {
    agentId: 'coder',
    label: 'Release prep',
    derivedTitle: 'Release prep',
    category: 'Work',
    age: 30 * MINUTE,
    lastMessagePreview: 'Spawned three helpers for the 2.4 release.',
  });
  Object.assign(h.sessions.get(SUBAGENT_PARENT_KEY), {
    childSessions: [kids.done, kids.failed, kids.running],
    hasActiveSubagentRun: true,
  });

  const child = (key, props, extra) => {
    const entry = row(key, { ...props, parentSessionKey: props.parent, spawnedBy: props.parent });
    Object.assign(entry, { createdVia: 'spawn', subagentRole: 'leaf', spawnDepth: 1 }, extra);
    return entry;
  };
  child(kids.done, {
    agentId: 'coder', label: 'Write the changelog', derivedTitle: 'Write the changelog', parent: SUBAGENT_PARENT_KEY,
    age: 26 * MINUTE, status: 'done', lastMessagePreview: 'CHANGELOG.md updated with 14 entries.',
  }, {
    startedAt: at(29 * MINUTE), endedAt: at(26 * MINUTE), runtimeMs: 3 * MINUTE,
    lastRunId: 'run_seed_changelog', subagentRunState: 'historical',
  });
  child(kids.failed, {
    agentId: 'coder', label: 'Run the test suite', derivedTitle: 'Run the test suite', parent: SUBAGENT_PARENT_KEY,
    age: 22 * MINUTE, status: 'failed', lastMessagePreview: '2 tests failed in LoginTests.',
  }, {
    startedAt: at(29 * MINUTE), endedAt: at(22 * MINUTE), runtimeMs: 7 * MINUTE,
    lastRunId: 'run_seed_tests', lastRunError: 'swift test exited with code 1: 2 failures in LoginTests',
    subagentRunState: 'historical',
  });
  child(kids.running, {
    agentId: 'research', label: 'Audit the docs', derivedTitle: 'Audit the docs', parent: SUBAGENT_PARENT_KEY,
    age: 1 * MINUTE, status: 'running', lastMessagePreview: 'Checking links in docs/setup.md…',
  }, {
    startedAt: at(4 * MINUTE), lastRunId: SEEDED_RUNNING_RUN_ID, hasActiveRun: true, activeRunIds: [SEEDED_RUNNING_RUN_ID],
    subagentRunState: 'active', subagentRole: 'orchestrator', subagentControlScope: 'children',
    childSessions: [kids.killed],
  });
  const killed = row(kids.killed, {
    agentId: 'research', label: 'Check external links', derivedTitle: 'Check external links',
    parentSessionKey: kids.running, spawnedBy: kids.running, age: 2 * MINUTE, status: 'killed',
    lastMessagePreview: 'Stopped.',
  });
  Object.assign(killed, {
    createdVia: 'spawn', subagentRole: 'leaf', spawnDepth: 2, startedAt: at(3 * MINUTE), endedAt: at(2 * MINUTE),
    runtimeMs: MINUTE, abortedLastRun: true, lastRunId: 'run_seed_links', subagentRunState: 'historical',
  });

  const spawnCall = (id, label, task, agentId) => toolCallBlock(id, 'sessions_spawn', { task, label, agentId });
  const spawnResult = (id, key, runId) => makeMessage('toolResult', [textBlock(JSON.stringify({ status: 'accepted', childSessionKey: key, runId }))], {
    extra: { toolCallId: id, toolName: 'sessions_spawn', isError: false },
  });
  transcripts.get(SUBAGENT_PARENT_KEY).push(
    said(makeMessage('user', [textBlock('Get the 2.4 release ready: changelog, tests and a docs pass.')]), 30 * MINUTE),
    said(makeMessage('assistant', [
      thinkingBlock('Three independent jobs, so I will run them in parallel as subagents.'),
      spawnCall('call_spawn_changelog', 'Write the changelog', 'Summarize merged PRs since 2.3 into CHANGELOG.md.', 'coder'),
      spawnCall('call_spawn_tests', 'Run the test suite', 'Run swift test and report failures.', 'coder'),
      spawnCall('call_spawn_docs', 'Audit the docs', 'Check docs/ for stale steps and broken links.', 'research'),
    ]), 29.5 * MINUTE),
    said(spawnResult('call_spawn_changelog', kids.done, 'run_seed_changelog'), 29.4 * MINUTE),
    said(spawnResult('call_spawn_tests', kids.failed, 'run_seed_tests'), 29.4 * MINUTE),
    said(spawnResult('call_spawn_docs', kids.running, SEEDED_RUNNING_RUN_ID), 29.4 * MINUTE),
    said(makeMessage('assistant', [textBlock('Spawned three helpers for the 2.4 release.')]), 29 * MINUTE),
  );
  transcripts.get(kids.done).push(
    said(makeMessage('user', [textBlock('Summarize merged PRs since 2.3 into CHANGELOG.md.')]), 29 * MINUTE),
    said(makeMessage('assistant', [thinkingBlock('List merged PRs first.'), toolCallBlock('call_cl_log', 'exec', { command: 'git log --merges v2.3..HEAD --oneline' })]), 28.8 * MINUTE),
    said(makeMessage('toolResult', [textBlock('14 merge commits')], { extra: { toolCallId: 'call_cl_log', toolName: 'exec', isError: false } }), 28.5 * MINUTE),
    said(makeMessage('assistant', [toolCallBlock('call_cl_edit', 'edit', { path: 'CHANGELOG.md' })]), 27 * MINUTE),
    said(makeMessage('toolResult', [textBlock('ok')], { extra: { toolCallId: 'call_cl_edit', toolName: 'edit', isError: false } }), 26.5 * MINUTE),
    said(makeMessage('assistant', [textBlock('CHANGELOG.md updated with 14 entries.')]), 26 * MINUTE),
  );
  transcripts.get(kids.failed).push(
    said(makeMessage('user', [textBlock('Run swift test and report failures.')]), 29 * MINUTE),
    said(makeMessage('assistant', [thinkingBlock('Build first, then run the tests.'), toolCallBlock('call_t_build', 'exec', { command: 'swift build' })]), 28.8 * MINUTE),
    said(makeMessage('toolResult', [textBlock('Build complete! (41.2s)')], { extra: { toolCallId: 'call_t_build', toolName: 'exec', isError: false } }), 28 * MINUTE),
    said(makeMessage('assistant', [toolCallBlock('call_t_test', 'exec', { command: 'swift test' })]), 27.9 * MINUTE),
    said(makeMessage('toolResult', [textBlock('LoginTests.testTimeout failed\nLoginTests.testRefresh failed\nexit code 1')], { extra: { toolCallId: 'call_t_test', toolName: 'exec', isError: true } }), 22.5 * MINUTE),
    said(makeMessage('assistant', [textBlock('2 tests failed in LoginTests.')], { extra: { stopReason: 'error', errorMessage: 'swift test exited with code 1: 2 failures in LoginTests' } }), 22 * MINUTE),
  );
  transcripts.get(kids.running).push(
    said(makeMessage('user', [textBlock('Check docs/ for stale steps and broken links.')]), 4 * MINUTE),
    said(makeMessage('assistant', [thinkingBlock('Split the link check out to a helper.'), toolCallBlock('call_d_spawn', 'sessions_spawn', { task: 'Check external links in docs/.', label: 'Check external links' })]), 3.5 * MINUTE),
    said(makeMessage('toolResult', [textBlock(JSON.stringify({ status: 'accepted', childSessionKey: kids.killed, runId: 'run_seed_links' }))], { extra: { toolCallId: 'call_d_spawn', toolName: 'sessions_spawn', isError: false } }), 3.4 * MINUTE),
    said(makeMessage('assistant', [toolCallBlock('call_d_read', 'read', { path: 'docs/setup.md' })]), 1 * MINUTE),
  );
  transcripts.get(kids.killed).push(
    said(makeMessage('user', [textBlock('Check external links in docs/.')]), 3 * MINUTE),
    said(makeMessage('assistant', [toolCallBlock('call_l_fetch', 'web_fetch', { url: 'https://example.com/guide' })]), 2.5 * MINUTE),
  );
}

/// Recomputes `hasActiveSubagentRun` on `parentKey` from its children's rows.
function refreshParent(state, parentKey, broadcastSessionChanged) {
  const parent = state.sessions.get(parentKey);
  if (!parent) return;
  const kids = parent.childSessions ?? [];
  parent.hasActiveSubagentRun = kids.some((key) => state.sessions.get(key)?.status === 'running');
  broadcastSessionChanged(state, parentKey, 'subagent', parent);
}

/// Direct children of `parentKey`, for `sessions.list { spawnedBy }`.
export function isSpawnedBy(row, parentKey) {
  return row.spawnedBy === parentKey || row.parentSessionKey === parentKey;
}

/// The seeded running subagent owns a real (idle) run so `chat.abort` can stop it.
export function seedRunningSubagentRun(state) {
  const run = {
    runId: SEEDED_RUNNING_RUN_ID,
    sessionKey: SEEDED_SUBAGENTS.running,
    text: '',
    seq: 7,
    aborted: false,
    finished: false,
    timers: new Set(),
    waiters: new Set(),
    startedAt: state.sessions.get(SEEDED_SUBAGENTS.running)?.startedAt,
    spawnedBy: SUBAGENT_PARENT_KEY,
  };
  state.activeRuns.set(run.runId, run);
}

/// A stopped subagent is `killed`, like upstream's subagent registry records it.
export function markSubagentAborted(state, row, run, broadcastSessionChanged) {
  if (!row?.key?.includes(':subagent:')) return;
  const endedAt = Date.now();
  Object.assign(row, {
    status: 'killed',
    abortedLastRun: true,
    endedAt,
    subagentRunState: 'historical',
    ...(row.startedAt ? { runtimeMs: Math.max(0, endedAt - row.startedAt) } : {}),
  });
  const parentKey = row.spawnedBy ?? row.parentSessionKey;
  if (parentKey) refreshParent(state, parentKey, broadcastSessionChanged);
}

/// `sessions_spawn` inside a parent run: tool start, a new child row, the accepted result, then the
/// child's own run streamed in the background. `fail` makes the child's tool and run error.
export async function simulateSpawn(state, run, parentKey, h, { fail = false } = {}) {
  const { broadcast, broadcastSessionChanged, broadcastSessionMessage, makeSessionRow, makeMessage, textBlock,
    toolCallBlock, runDelay, shortId, rowModel } = h;
  const parent = state.sessions.get(parentKey);
  const agentId = parent.agentId;
  const label = fail ? 'Run the flaky test' : 'Summarize the logs';
  const task = fail ? 'Run LoginTests until it fails.' : 'Summarize the last hour of gateway logs.';
  const toolCallId = shortId('call_');
  const args = { task, label, agentId };
  broadcast(state, 'agent', { runId: run.runId, sessionKey: parentKey, seq: ++run.seq, stream: 'tool', data: { phase: 'start', name: 'sessions_spawn', toolCallId, args } });
  await runDelay(run, 120);
  if (run.aborted) return null;

  const childKey = `agent:${agentId}:subagent:${crypto.randomUUID()}`;
  const childRunId = shortId('run_');
  const startedAt = Date.now();
  const childRow = makeSessionRow(childKey, {
    agentId, label, derivedTitle: label, parentSessionKey: parentKey, spawnedBy: parentKey, status: 'running',
    lastMessagePreview: task,
  }, startedAt);
  Object.assign(childRow, {
    createdVia: 'spawn', subagentRole: 'leaf', spawnDepth: (parent.spawnDepth ?? 0) + 1, startedAt,
    hasActiveRun: true, activeRunIds: [childRunId], lastRunId: childRunId, subagentRunState: 'active',
  });
  state.sessions.set(childKey, childRow);
  state.transcripts.set(childKey, [makeMessage('user', [textBlock(task)], { openclaw: { runId: childRunId } })]);
  parent.childSessions = [...(parent.childSessions ?? []), childKey];
  broadcastSessionChanged(state, childKey, 'create', childRow);
  refreshParent(state, parentKey, broadcastSessionChanged);

  const result = { status: 'accepted', childSessionKey: childKey, runId: childRunId };
  broadcast(state, 'agent', { runId: run.runId, sessionKey: parentKey, seq: ++run.seq, stream: 'tool', data: { phase: 'result', name: 'sessions_spawn', toolCallId, isError: false, result } });
  const transcript = state.transcripts.get(parentKey);
  const toolMsg = makeMessage('assistant', [toolCallBlock(toolCallId, 'sessions_spawn', args)], { openclaw: { runId: run.runId }, model: rowModel(parent) });
  const toolResult = makeMessage('toolResult', [textBlock(JSON.stringify(result))], {
    openclaw: { runId: run.runId }, extra: { toolCallId, toolName: 'sessions_spawn', isError: false },
  });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, parentKey, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, parentKey, toolResult, transcript.length);

  const child = {
    runId: childRunId, sessionKey: childKey, text: task, seq: 0, aborted: false, finished: false,
    timers: new Set(), waiters: new Set(), startedAt, spawnedBy: parentKey,
  };
  state.activeRuns.set(childRunId, child);
  setImmediate(() => simulateChildRun(state, child, childRow, h, fail).catch((err) => {
    if (!child.aborted) console.error('subagent simulation failed:', err);
  }));
  return result;
}

async function simulateChildRun(state, run, row, h, fail) {
  const { broadcast, broadcastSessionChanged, broadcastSessionMessage, makeMessage, textBlock, thinkingBlock,
    toolCallBlock, runDelay, rowModel, shortId } = h;
  const key = run.sessionKey;
  const emit = (stream, data) => broadcast(state, 'agent', { runId: run.runId, sessionKey: key, spawnedBy: run.spawnedBy, seq: ++run.seq, stream, data });
  emit('lifecycle', { phase: 'start', startedAt: run.startedAt });
  let thinking = '';
  for (const part of ['Reading', ' the', ' task']) {
    await runDelay(run, 60);
    if (run.aborted) return;
    thinking += part;
    emit('thinking', { text: thinking, delta: part });
  }
  const toolCallId = shortId('call_');
  const command = fail ? 'swift test --filter LoginTests' : 'tail -n 200 gateway.log';
  emit('tool', { phase: 'start', name: 'exec', toolCallId, args: { command } });
  await runDelay(run, 120);
  if (run.aborted) return;
  emit('tool', { phase: 'update', name: 'exec', toolCallId, partialResult: fail ? 'Building…' : '200 lines read' });
  await runDelay(run, 120);
  if (run.aborted) return;
  const output = fail ? 'LoginTests.testTimeout failed\nexit code 1' : '3 warnings, no errors in the last hour.';
  emit('tool', { phase: 'result', name: 'exec', toolCallId, isError: fail, result: output });
  const transcript = state.transcripts.get(key);
  const toolMsg = makeMessage('assistant', [thinkingBlock(thinking), toolCallBlock(toolCallId, 'exec', { command })], { openclaw: { runId: run.runId }, model: rowModel(row) });
  const toolResult = makeMessage('toolResult', [textBlock(output)], { openclaw: { runId: run.runId }, extra: { toolCallId, toolName: 'exec', isError: fail } });
  transcript.push(toolMsg, toolResult);
  broadcastSessionMessage(state, key, toolMsg, transcript.length - 1);
  broadcastSessionMessage(state, key, toolResult, transcript.length);

  const endedAt = () => Date.now();
  if (fail) {
    const error = 'swift test exited with code 1: LoginTests.testTimeout failed';
    const at = endedAt();
    emit('lifecycle', { phase: 'error', error, endedAt: at });
    broadcast(state, 'chat', { runId: run.runId, sessionKey: key, seq: ++run.seq, state: 'error', errorMessage: error });
    Object.assign(row, { status: 'failed', lastRunError: error, endedAt: at, runtimeMs: at - run.startedAt, lastMessagePreview: error });
  } else {
    const reply = 'Gateway logs: 3 warnings, no errors in the last hour.';
    let out = '';
    for (const word of reply.split(/(\s+)/).filter(Boolean)) {
      await runDelay(run, 20);
      if (run.aborted) return;
      out += word;
      emit('assistant', { text: out, delta: word });
    }
    const finalMsg = makeMessage('assistant', [thinkingBlock(thinking), textBlock(reply)], { openclaw: { runId: run.runId }, model: rowModel(row) });
    transcript.push(finalMsg);
    broadcastSessionMessage(state, key, finalMsg, transcript.length);
    broadcast(state, 'chat', { runId: run.runId, sessionKey: key, seq: ++run.seq, state: 'final', message: finalMsg });
    const at = endedAt();
    emit('lifecycle', { phase: 'end', stopReason: 'stop', aborted: false, endedAt: at });
    Object.assign(row, { status: 'done', endedAt: at, runtimeMs: at - run.startedAt, lastMessagePreview: reply });
  }
  run.finished = true;
  state.activeRuns.delete(run.runId);
  Object.assign(row, { hasActiveRun: false, activeRunIds: [], subagentRunState: 'historical', updatedAt: Date.now(), lastActivityAt: Date.now() });
  broadcastSessionChanged(state, key, 'run-finished', row);
  refreshParent(state, run.spawnedBy, broadcastSessionChanged);
}
