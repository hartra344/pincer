import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { SEEDED_RUNNING_RUN_ID, SEEDED_SUBAGENTS, SUBAGENT_PARENT_KEY } from '../subagents.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

// Subagent tree + run timeline (#35), on a fresh server so spawned rows don't leak.
export async function run() {
  const subServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${subServer.address().port}`, makeDevice(), 'dev-token');
    await client.send('sessions.subscribe', {});
    const rows = (await client.send('sessions.list', {})).sessions;
    const byKey = new Map(rows.map((r) => [r.key, r]));
    const parent = byKey.get(SUBAGENT_PARENT_KEY);
    assert.ok(parent, 'seeded parent chat');
    assert.deepEqual(parent.childSessions, [SEEDED_SUBAGENTS.done, SEEDED_SUBAGENTS.failed, SEEDED_SUBAGENTS.running]);
    assert.equal(parent.hasActiveSubagentRun, true);
    const statuses = Object.fromEntries(Object.entries(SEEDED_SUBAGENTS).map(([name, key]) => [name, byKey.get(key)?.status]));
    assert.deepEqual(statuses, { done: 'done', failed: 'failed', running: 'running', killed: 'killed' });
    for (const [name, key] of Object.entries(SEEDED_SUBAGENTS)) {
      const r = byKey.get(key);
      assert.match(key, /^agent:[a-z]+:subagent:[0-9a-f-]{36}$/, `${name} key shape`);
      assert.equal(r.spawnedBy, r.parentSessionKey, `${name} spawnedBy = parentSessionKey`);
      assert.equal(r.createdVia, 'spawn');
      assert.equal(typeof r.startedAt, 'number');
      assert.equal(r.spawnDepth, name === 'killed' ? 2 : 1);
      if (name !== 'running') assert.equal(r.runtimeMs, r.endedAt - r.startedAt, `${name} runtimeMs`);
    }
    const running = byKey.get(SEEDED_SUBAGENTS.running);
    assert.equal(running.endedAt, undefined);
    assert.deepEqual(running.activeRunIds, [SEEDED_RUNNING_RUN_ID]);
    assert.equal(running.hasActiveRun, true);
    assert.equal(running.subagentRole, 'orchestrator');
    assert.equal(byKey.get(SEEDED_SUBAGENTS.killed).spawnedBy, SEEDED_SUBAGENTS.running, 'nested under the orchestrator');
    assert.equal(byKey.get(SEEDED_SUBAGENTS.killed).abortedLastRun, true);
    assert.match(byKey.get(SEEDED_SUBAGENTS.failed).lastRunError, /2 failures in LoginTests/);

    // `sessions.list { spawnedBy }` lists direct children only.
    const kids = (await client.send('sessions.list', { spawnedBy: SUBAGENT_PARENT_KEY })).sessions.map((r) => r.key).sort();
    assert.deepEqual(kids, [SEEDED_SUBAGENTS.done, SEEDED_SUBAGENTS.failed, SEEDED_SUBAGENTS.running].sort());
    assert.deepEqual((await client.send('sessions.list', { spawnedBy: SEEDED_SUBAGENTS.running })).sessions.map((r) => r.key), [SEEDED_SUBAGENTS.killed]);
    assert.deepEqual((await client.send('sessions.list', { spawnedBy: 'agent:main:nope' })).sessions, []);

    // Seeded transcripts carry the spawn receipts and the failed tool.
    const parentHistory = await client.send('chat.history', { sessionKey: SUBAGENT_PARENT_KEY, limit: 50 });
    const receipts = parentHistory.messages.filter((m) => m.toolName === 'sessions_spawn').map((m) => JSON.parse(m.content[0].text));
    assert.deepEqual(receipts.map((r) => r.status), ['accepted', 'accepted', 'accepted']);
    assert.ok(receipts.some((r) => r.childSessionKey === SEEDED_SUBAGENTS.running && r.runId === SEEDED_RUNNING_RUN_ID));
    const failedHistory = await client.send('chat.history', { sessionKey: SEEDED_SUBAGENTS.failed, limit: 50 });
    assert.ok(failedHistory.messages.some((m) => m.role === 'toolResult' && m.isError === true));
    const stamps = failedHistory.messages.map((m) => m.timestamp);
    assert.deepEqual(stamps, [...stamps].sort((a, b) => a - b), 'seeded child transcript in time order');

    // A live spawn: the parent's sessions_spawn tool, a new child row, then the child's own run.
    const agentEvents = [];
    client.emitter.on('agent', (p) => agentEvents.push(p));
    const created = client.waitEvent('sessions.changed', (p) => p.reason === 'create' && p.session?.spawnedBy === SUBAGENT_PARENT_KEY);
    const { runId: parentRun } = await client.send('chat.send', { sessionKey: SUBAGENT_PARENT_KEY, message: 'Please spawn a helper', idempotencyKey: crypto.randomUUID() });
    const childRow = (await created).session;
    assert.equal(childRow.status, 'running');
    assert.equal(childRow.spawnDepth, 1);
    assert.equal(childRow.hasActiveRun, true);
    const childRun = childRow.activeRunIds[0];
    const childEnd = await client.waitEvent('agent', (p) => p.runId === childRun && p.stream === 'lifecycle' && p.data.phase !== 'start', 10_000);
    assert.equal(childEnd.data.phase, 'end');
    assert.equal(childEnd.data.aborted, false);
    await client.waitEvent('chat', (p) => p.runId === parentRun && p.state === 'final', 10_000).catch(() => {});
    const parentTool = agentEvents.filter((e) => e.runId === parentRun && e.stream === 'tool');
    assert.deepEqual(parentTool.map((e) => e.data.phase), ['start', 'result']);
    assert.equal(parentTool[0].data.name, 'sessions_spawn');
    assert.deepEqual(parentTool[1].data.result, { status: 'accepted', childSessionKey: childRow.key, runId: childRun });
    const parentLifecycle = agentEvents.filter((e) => e.runId === parentRun && e.stream === 'lifecycle').map((e) => e.data.phase);
    assert.equal(parentLifecycle[0], 'start', 'runs open with lifecycle start');
    const child = agentEvents.filter((e) => e.runId === childRun);
    assert.ok(child.every((e) => e.sessionKey === childRow.key && e.spawnedBy === SUBAGENT_PARENT_KEY && typeof e.ts === 'number'));
    const seqs = child.map((e) => e.seq);
    assert.equal(seqs[0], 1, 'child runs have their own seq');
    assert.ok(seqs.every((seq, i) => i === 0 || seq > seqs[i - 1]), 'child seq increases');
    const kinds = child.map((e) => (e.stream === 'tool' ? `tool:${e.data.phase}` : e.stream === 'lifecycle' ? `lifecycle:${e.data.phase}` : e.stream));
    assert.deepEqual([...new Set(kinds)], ['lifecycle:start', 'thinking', 'tool:start', 'tool:update', 'tool:result', 'assistant', 'lifecycle:end']);
    assert.equal(typeof child[0].data.startedAt, 'number');
    assert.ok(child.at(-1).data.endedAt >= child[0].data.startedAt);
    const thinking = child.filter((e) => e.stream === 'thinking');
    assert.equal(thinking.at(-1).data.text, thinking.map((e) => e.data.delta).join(''), 'thinking text accumulates its deltas');
    const done = (await client.send('sessions.list', {})).sessions.find((r) => r.key === childRow.key);
    assert.equal(done.status, 'done');
    assert.equal(done.runtimeMs, done.endedAt - done.startedAt);
    assert.equal(done.hasActiveRun, false);
    assert.ok((await client.send('sessions.list', {})).sessions.find((r) => r.key === SUBAGENT_PARENT_KEY).childSessions.includes(childRow.key));

    // `spawn fail`: the child's tool errors and its run ends with lifecycle error.
    const failCreated = client.waitEvent('sessions.changed', (p) => p.reason === 'create' && p.session?.spawnedBy === SUBAGENT_PARENT_KEY);
    await client.send('chat.send', { sessionKey: SUBAGENT_PARENT_KEY, message: 'spawn fail please', idempotencyKey: crypto.randomUUID() });
    const failRow = (await failCreated).session;
    const failEnd = await client.waitEvent('agent', (p) => p.runId === failRow.activeRunIds[0] && p.stream === 'lifecycle' && p.data.phase !== 'start', 10_000);
    assert.equal(failEnd.data.phase, 'error');
    assert.match(failEnd.data.error, /exited with code 1/);
    assert.ok(agentEvents.some((e) => e.runId === failRow.activeRunIds[0] && e.stream === 'tool' && e.data.phase === 'result' && e.data.isError === true));
    const failed = (await client.send('sessions.list', {})).sessions.find((r) => r.key === failRow.key);
    assert.equal(failed.status, 'failed');
    assert.match(failed.lastRunError, /LoginTests/);

    // Stopping the seeded running subagent: lifecycle end marked aborted, row `killed`.
    const aborted = client.waitEvent('agent', (p) => p.runId === SEEDED_RUNNING_RUN_ID && p.stream === 'lifecycle');
    const abortedChat = client.waitEvent('chat', (p) => p.runId === SEEDED_RUNNING_RUN_ID && p.state === 'aborted');
    await client.send('chat.abort', { sessionKey: SEEDED_SUBAGENTS.running });
    const abortEvent = await aborted;
    assert.deepEqual([abortEvent.data.phase, abortEvent.data.aborted, abortEvent.data.status], ['end', true, 'cancelled']);
    assert.equal(abortEvent.spawnedBy, SUBAGENT_PARENT_KEY);
    assert.ok(abortEvent.seq > 7, 'abort continues the seeded run seq');
    await abortedChat;
    const after = new Map((await client.send('sessions.list', {})).sessions.map((r) => [r.key, r]));
    const killed = after.get(SEEDED_SUBAGENTS.running);
    assert.deepEqual([killed.status, killed.abortedLastRun, killed.hasActiveRun], ['killed', true, false]);
    assert.equal(killed.runtimeMs, killed.endedAt - killed.startedAt);
    assert.equal(after.get(SUBAGENT_PARENT_KEY).hasActiveSubagentRun, false, 'no child still running');

    // A plain chat abort still ends with an aborted lifecycle and leaves non-subagent rows alone.
    const plainStart = client.waitEvent('agent', (p) => p.sessionKey === 'agent:main:main' && p.stream === 'lifecycle' && p.data.phase === 'start');
    const { runId: plainRun } = await client.send('chat.send', { sessionKey: 'agent:main:main', message: 'hello', idempotencyKey: crypto.randomUUID() });
    assert.equal((await plainStart).runId, plainRun);
    assert.equal(typeof (await plainStart).data.startedAt, 'number');
    const plainEnd = client.waitEvent('agent', (p) => p.runId === plainRun && p.stream === 'lifecycle' && p.data.phase === 'end');
    await client.send('chat.abort', { sessionKey: 'agent:main:main', runId: plainRun });
    assert.equal((await plainEnd).data.aborted, true);
    const mainRow = (await client.send('sessions.list', {})).sessions.find((r) => r.key === 'agent:main:main');
    assert.equal(mainRow.status, 'idle');
    assert.equal(mainRow.abortedLastRun, undefined);
    client.ws.close();
  } finally {
    await subServer.close();
  }
}
