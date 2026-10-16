import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { SEEDED_RUNNING_RUN_ID, SEEDED_SUBAGENTS, SUBAGENT_PARENT_KEY } from '../subagents.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

const REFACTOR = 'agent:coder:dashboard:refactor';
const REFACTOR_RUN = 'run_seed_refactor';

// sessions.abort (#981), on a fresh server so the seeded runs it stops don't leak into other sections.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const client = await connectClient(url, makeDevice(), 'dev-token');
    const readOnly = await connectClient(url, makeDevice(), 'dev-token', true, ['operator.read']);
    assert.ok(client.hello.features.methods.includes('sessions.abort'), 'sessions.abort is advertised');
    await client.send('sessions.subscribe', {});

    // Scope: operator.write.
    const denied = await readOnly.call('sessions.abort', { key: REFACTOR });
    assert.equal(denied.ok, false);
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', scope: 'operator.write' });

    const rows = async () => new Map((await client.send('sessions.list', {})).sessions.map((r) => [r.key, r]));
    assert.equal((await rows()).get(REFACTOR).hasActiveRun, true);

    // Errors.
    const unknown = await client.call('sessions.abort', { key: 'agent:main:dashboard:nope' });
    assert.equal(unknown.ok, false);
    assert.equal(unknown.error.code, 'INVALID_REQUEST');
    assert.equal(unknown.error.message, 'session target is unavailable');
    const noTarget = await client.call('sessions.abort', {});
    assert.equal(noTarget.error.message, 'session target is unavailable');
    const mismatch = await client.call('sessions.abort', { key: REFACTOR, runId: 'run_not_mine' });
    assert.equal(mismatch.error.code, 'INVALID_REQUEST');
    assert.equal(mismatch.error.message, 'runId does not match session');
    assert.equal((await rows()).get(REFACTOR).hasActiveRun, true, 'a rejected abort stops nothing');

    // Key-only abort: result shape, aborted lifecycle and chat events, row cleared.
    const lifecycle = client.waitEvent('agent', (p) => p.runId === REFACTOR_RUN && p.stream === 'lifecycle');
    const chatAborted = client.waitEvent('chat', (p) => p.runId === REFACTOR_RUN && p.state === 'aborted');
    const aborted = await client.send('sessions.abort', { key: REFACTOR, clearQueued: true });
    assert.deepEqual(aborted, { ok: true, abortedRunId: REFACTOR_RUN, status: 'aborted' });
    const end = await lifecycle;
    assert.deepEqual([end.data.phase, end.data.aborted, end.data.status], ['end', true, 'cancelled']);
    await chatAborted;
    const after = (await rows()).get(REFACTOR);
    assert.deepEqual([after.hasActiveRun, after.activeRunIds], [false, []]);

    // Nothing running now.
    assert.deepEqual(await client.send('sessions.abort', { key: REFACTOR, clearQueued: true }), { ok: true, abortedRunId: null, status: 'no-active-run' });
    assert.deepEqual(await client.send('sessions.abort', { key: 'agent:main:main' }), { ok: true, abortedRunId: null, status: 'no-active-run' });

    // The agentId must match the key's agent.
    const wrongAgent = await client.call('sessions.abort', { key: REFACTOR, agentId: 'research' });
    assert.equal(wrongAgent.error.code, 'INVALID_REQUEST');
    assert.equal(wrongAgent.error.message, 'session key agent does not match agentId');

    // Cascade: stopping the parent also stops its running subagent child.
    const before = await rows();
    assert.equal(before.get(SEEDED_SUBAGENTS.running).hasActiveRun, true);
    const childEnd = client.waitEvent('agent', (p) => p.runId === SEEDED_RUNNING_RUN_ID && p.stream === 'lifecycle');
    const cascaded = await client.send('sessions.abort', { key: SUBAGENT_PARENT_KEY, clearQueued: true });
    assert.equal(cascaded.ok, true);
    assert.ok(['aborted', 'no-active-run'].includes(cascaded.status));
    const childEvent = await childEnd;
    assert.deepEqual([childEvent.data.phase, childEvent.data.aborted, childEvent.data.status], ['end', true, 'cancelled']);
    assert.equal(childEvent.spawnedBy, SUBAGENT_PARENT_KEY);
    const final = await rows();
    const child = final.get(SEEDED_SUBAGENTS.running);
    assert.deepEqual([child.status, child.abortedLastRun, child.hasActiveRun], ['killed', true, false]);
    assert.equal(final.get(SUBAGENT_PARENT_KEY).hasActiveSubagentRun, false);

    // runId-only targets the run's session.
    const again = await client.call('sessions.abort', { runId: 'run_gone' });
    assert.equal(again.error.message, 'session target is unavailable');
  } finally {
    await server.close();
  }
}
