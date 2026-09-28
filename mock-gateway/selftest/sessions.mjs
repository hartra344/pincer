import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { SESSION_MANAGER_METHODS } from '../sessions.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Session manager: previews, describe, archive/delete, branches, rewind and recover.
export async function run() {
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const smServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${smServer.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, adminScopes);
    const writer = await connectClient(url, makeDevice(), 'dev-token');
    const nobody = await connectClient(url, makeDevice(), 'dev-token', true, ['operator.approvals']);
    for (const method of SESSION_MANAGER_METHODS) assert.ok(writer.hello.features.methods.includes(method), method);
    await writer.send('sessions.subscribe', {});

    // Scopes.
    const forbidden = async (client, method, params, scope) => {
      const res = await client.call(method, params);
      assert.equal(res.ok, false, `${method} should be forbidden`);
      assert.equal(res.error.code, 'FORBIDDEN', method);
      assert.deepEqual(res.error.details, { code: 'MISSING_SCOPE', scope }, method);
    };
    await forbidden(nobody, 'sessions.preview', { keys: ['agent:main:main'] }, 'operator.read');
    await forbidden(nobody, 'sessions.describe', { key: 'agent:main:main' }, 'operator.read');
    await forbidden(nobody, 'sessions.branches.list', { sessionKey: 'agent:main:main' }, 'operator.read');
    await forbidden(nobody, 'sessions.recover', { key: 'agent:main:dashboard:photo-import' }, 'operator.write');
    await forbidden(writer, 'sessions.branches.switch', { sessionKey: 'agent:main:dashboard:garden', leafEntryId: 'x' }, 'operator.admin');
    await forbidden(writer, 'sessions.rewind', { sessionKey: 'agent:main:dashboard:garden', entryId: 'x' }, 'operator.admin');
    await forbidden(writer, 'sessions.delete', { key: 'agent:main:dashboard:tax-2025' }, 'operator.admin');
    await forbidden(writer, 'sessions.delete', { key: 'agent:main:dashboard:tax-2025', archivedOnly: false }, 'operator.admin');
    await forbidden(writer, 'sessions.delete', { key: 'agent:main:dashboard:tax-2025', archivedOnly: true, emitLifecycleHooks: false }, 'operator.admin');

    // sessions.list archived filters: default active only, true archived only, "all" both.
    const keysOf = (list) => list.sessions.map((row) => row.key);
    const active = keysOf(await writer.send('sessions.list', {}));
    const archivedOnly = keysOf(await writer.send('sessions.list', { archived: true }));
    const all = keysOf(await writer.send('sessions.list', { archived: 'all' }));
    assert.deepEqual(archivedOnly.sort(), ['agent:main:dashboard:tax-2025', 'agent:research:dashboard:gpu-bench']);
    assert.ok(!active.includes('agent:main:dashboard:tax-2025') && active.includes('agent:main:dashboard:garden'));
    assert.equal(all.length, active.length + archivedOnly.length);
    const rows = Object.fromEntries((await writer.send('sessions.list', { archived: 'all' })).sessions.map((row) => [row.key, row]));
    assert.equal(rows['agent:main:dashboard:tax-2025'].archiveReason, 'manual');
    assert.equal(typeof rows['agent:main:dashboard:tax-2025'].archivedAt, 'number');
    assert.equal(rows['agent:research:dashboard:gpu-bench'].archiveReason, 'stale-dashboard');
    const refactor = rows['agent:coder:dashboard:refactor'];
    assert.equal(refactor.status, 'running');
    assert.equal(refactor.hasActiveRun, true);
    assert.ok(Date.now() - refactor.startedAt >= 5 * 60_000, 'running for minutes');
    const ci = rows['agent:coder:dashboard:ci-fix'];
    assert.deepEqual([ci.status, ci.runtimeMs, ci.endedAt - ci.startedAt], ['failed', 94_000, 94_000]);
    assert.equal(ci.lastRunError, 'Build failed: 3 tests in CacheTests timed out.');
    assert.equal(rows['agent:main:dashboard:photo-import'].restartRecoveryStatus, 'tombstoned');

    // sessions.preview.
    const preview = await writer.send('sessions.preview', { keys: ['agent:main:dashboard:garden', 'agent:main:ghost', 'agent:main:dashboard:tax-2025'], limit: 2, maxChars: 20 });
    assert.equal(typeof preview.ts, 'number');
    assert.deepEqual(preview.previews.map((p) => [p.key, p.status, p.items.length]), [
      ['agent:main:dashboard:garden', 'ok', 2],
      ['agent:main:ghost', 'missing', 0],
      ['agent:main:dashboard:tax-2025', 'ok', 2],
    ]);
    assert.deepEqual(preview.previews[0].items[0], { role: 'user', text: 'Make it shade tol...' });
    assert.deepEqual(preview.previews[0].items.map((i) => i.role), ['user', 'assistant']);
    const full = (await writer.send('sessions.preview', { keys: ['agent:main:main'] })).previews[0];
    assert.ok(full.items.every((i) => i.role === 'user' || i.role === 'assistant'), 'tool results are left out');
    assert.ok(full.items.length <= 12);
    const created = await writer.send('sessions.create', { agentId: 'main', label: 'Empty' });
    assert.equal((await writer.send('sessions.preview', { keys: [created.key] })).previews[0].status, 'empty');
    assert.match((await writer.call('sessions.preview', { keys: [] })).error.message, /^invalid sessions\.preview params: at \/keys: must NOT have fewer than 1 items/);
    assert.match((await writer.call('sessions.preview', { keys: ['x'], maxChars: 5 })).error.message, /at \/maxChars: must be >= 20/);
    assert.match((await writer.call('sessions.preview', { keys: ['x'], bogus: 1 })).error.message, /unexpected property 'bogus'/);

    // sessions.describe.
    const described = (await writer.send('sessions.describe', { key: 'agent:coder:dashboard:ci-fix' })).session;
    assert.equal(described.key, 'agent:coder:dashboard:ci-fix');
    assert.equal(described.runtimeMs, 94_000);
    assert.equal(described.derivedTitle, undefined, 'titles only when asked');
    assert.equal(described.lastMessagePreview, undefined, 'last message only when asked');
    const withExtras = (await writer.send('sessions.describe', { key: 'agent:coder:dashboard:ci-fix', includeDerivedTitles: true, includeLastMessage: true })).session;
    assert.equal(withExtras.derivedTitle, 'Fix flaky CI');
    assert.equal(withExtras.lastMessagePreview, 'Build failed: 3 tests in CacheTests timed out.');
    assert.deepEqual(await writer.send('sessions.describe', { key: 'agent:main:ghost' }), { session: null });
    assert.equal((await writer.send('sessions.describe', { key: 'agent:main:dashboard:tax-2025' })).session.archived, true, 'archived rows describe too');
    assert.equal((await writer.call('sessions.describe', { key: 'agent:main:main', agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');

    // Archive / unarchive (sessions.patch and patchMany), main sessions are protected.
    assert.equal((await writer.call('sessions.patch', { key: 'agent:main:main', archived: true })).error.message, "Cannot archive an agent's main session.");
    const archiveEvent = writer.waitEvent('sessions.changed', (p) => p.sessionKey === 'agent:main:dashboard:trip' && p.session?.archived === true);
    const many = await writer.send('sessions.patchMany', {
      targets: [{ key: 'agent:main:dashboard:trip' }, { key: 'agent:main:main' }, { key: 'agent:main:ghost', agentId: 'main' }, { key: 'agent:coder:dashboard:refactor' }],
      patch: { archived: true },
    });
    await archiveEvent;
    assert.deepEqual(many.outcomes.map((o) => [o.key, o.ok, o.error?.message]), [
      ['agent:main:dashboard:trip', true, undefined],
      ['agent:main:main', false, "Cannot archive an agent's main session."],
      ['agent:main:ghost', false, 'unknown session'],
      ['agent:coder:dashboard:refactor', true, undefined],
    ]);
    assert.equal(many.outcomes[2].agentId, 'main', 'outcomes echo the target identity');
    let listed = Object.fromEntries((await writer.send('sessions.list', { archived: 'all' })).sessions.map((row) => [row.key, row]));
    assert.equal(listed['agent:main:dashboard:trip'].archived, true);
    assert.equal(listed['agent:main:dashboard:trip'].archiveReason, 'manual');
    assert.equal(listed['agent:coder:dashboard:refactor'].hasActiveRun, false, 'archiving stops the run');
    await writer.send('sessions.patchMany', { targets: [{ key: 'agent:main:dashboard:trip' }], patch: { archived: false } });
    listed = Object.fromEntries((await writer.send('sessions.list', {})).sessions.map((row) => [row.key, row]));
    assert.equal(listed['agent:main:dashboard:trip'].archived, false);
    assert.equal(listed['agent:main:dashboard:trip'].archivedAt, undefined, 'unarchive clears archivedAt');
    await forbidden(writer, 'sessions.patchMany', { targets: [{ key: 'agent:main:dashboard:trip' }], patch: { sandboxMode: 'off' } }, 'operator.admin');
    assert.match((await writer.call('sessions.patchMany', { targets: [], patch: { archived: true } })).error.message, /at \/targets: must NOT have fewer than 1 items/);
    assert.match((await writer.call('sessions.patchMany', { targets: [{ key: 'agent:main:dashboard:trip' }], patch: {} })).error.message, /at \/patch: must NOT have fewer than 1 properties/);

    // sessions.delete: archive-then-delete at write scope; everything else needs admin.
    assert.equal((await writer.call('sessions.delete', { key: 'agent:main:dashboard:trip', archivedOnly: true })).error.message,
      'Session agent:main:dashboard:trip is not archived. Archive it first, then delete it.');
    const taxId = rows['agent:main:dashboard:tax-2025'].sessionId;
    const stale = await writer.call('sessions.delete', { key: 'agent:main:dashboard:tax-2025', archivedOnly: true, expectedSessionId: 'nope' });
    assert.equal(stale.error.message, 'Session agent:main:dashboard:tax-2025 changed before deletion. Retry.');
    assert.equal(stale.error.details.details.reason, 'session-changed');
    const deleteEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'delete' && p.sessionKey === 'agent:main:dashboard:tax-2025');
    const deleted = await writer.send('sessions.delete', { key: 'agent:main:dashboard:tax-2025', archivedOnly: true, expectedSessionId: taxId, deleteTranscript: true });
    assert.equal(deleted.ok, true);
    assert.equal(deleted.deleted, true);
    assert.equal(deleted.key, 'agent:main:dashboard:tax-2025');
    assert.equal(deleted.archived.length, 1);
    assert.match(deleted.archived[0], new RegExp(`/agents/main/sessions/${taxId}\\.jsonl\\.deleted\\.`));
    assert.equal((await deleteEvent).sessionId, taxId);
    assert.ok(!keysOf(await writer.send('sessions.list', { archived: 'all' })).includes('agent:main:dashboard:tax-2025'));
    assert.deepEqual(await writer.send('sessions.delete', { key: 'agent:main:dashboard:tax-2025', archivedOnly: true }), { ok: true, key: 'agent:main:dashboard:tax-2025', deleted: false, archived: [] });
    assert.equal((await admin.call('sessions.delete', { key: 'agent:main:main' })).error.message, 'Cannot delete the main session (agent:main:main).');
    const adminDeleted = await admin.send('sessions.delete', { key: created.key, deleteTranscript: false });
    assert.deepEqual([adminDeleted.deleted, adminDeleted.archived], [true, []], 'admin deletes active sessions; nothing to archive');

    // Branches: active first, then the other tips newest first.
    const garden = 'agent:main:dashboard:garden';
    let branches = (await writer.send('sessions.branches.list', { sessionKey: garden })).branches;
    assert.equal(branches.length, 3);
    assert.deepEqual(branches.map((b) => [b.headline.slice(0, 16), b.messageCount, b.active]), [
      ['Swap the tomatoe', 4, true],
      ['Basil, thyme, or', 4, false],
      ['Run a ½" mainlin', 4, false],
    ]);
    for (const branch of branches) {
      assert.ok(branch.leafEntryId && !Number.isNaN(Date.parse(branch.updatedAt)), 'leaf id and ISO updatedAt');
      assert.deepEqual(Object.keys(branch).sort(), ['active', 'headline', 'leafEntryId', 'messageCount', 'updatedAt']);
    }
    assert.deepEqual(await writer.send('sessions.branches.list', { sessionKey: 'agent:main:ghost' }), { branches: [] });
    assert.equal((await writer.send('sessions.branches.list', { sessionKey: 'agent:research:main' })).branches.length, 1, 'a linear chat has one branch');

    // Switch to the herbs branch: the history follows, the old tip stays listed.
    const herbs = branches[1].leafEntryId;
    const shade = branches[0].leafEntryId;
    assert.equal((await admin.call('sessions.branches.switch', { sessionKey: garden, leafEntryId: shade })).error.message, `branch is already active: ${shade}`);
    assert.equal((await admin.call('sessions.branches.switch', { sessionKey: garden, leafEntryId: 'nope' })).error.message, 'branch entry not found: nope');
    const history = await writer.send('chat.history', { sessionKey: garden });
    const opening = history.messages[0].__openclaw.id;
    assert.equal((await admin.call('sessions.branches.switch', { sessionKey: garden, leafEntryId: opening })).error.message, `entry is not a branch tip: ${opening}`);
    assert.equal((await admin.call('sessions.branches.switch', { sessionKey: 'agent:main:ghost', leafEntryId: 'x' })).error.message, 'session not found: agent:main:ghost');
    const switchEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'branch-switch' && p.sessionKey === garden);
    assert.deepEqual(await admin.send('sessions.branches.switch', { sessionKey: garden, leafEntryId: herbs }), {});
    await switchEvent;
    branches = (await writer.send('sessions.branches.list', { sessionKey: garden })).branches;
    assert.deepEqual(branches.map((b) => [b.leafEntryId, b.active]).slice(0, 1), [[herbs, true]]);
    assert.ok(branches.some((b) => b.leafEntryId === shade && !b.active), 'the previous tip is still a branch');
    assert.equal(branches.length, 3);
    const afterSwitch = (await writer.send('chat.history', { sessionKey: garden })).messages;
    assert.match(afterSwitch.at(-1).content[0].text, /^Basil, thyme/);

    // Rewind to the herbs question: the editor gets its text back, a new branch appears on send.
    const question = afterSwitch[2];
    assert.equal(question.role, 'user');
    assert.equal((await admin.call('sessions.rewind', { sessionKey: garden, entryId: afterSwitch[1].__openclaw.id })).error.message,
      `entry is not a user message: ${afterSwitch[1].__openclaw.id}`);
    assert.equal((await admin.call('sessions.rewind', { sessionKey: garden, entryId: shade })).error.message, `message entry is not on the active path: ${shade}`);
    assert.equal((await admin.call('sessions.rewind', { sessionKey: garden, entryId: 'nope' })).error.message, 'message entry not found: nope');
    const rewindEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'rewind' && p.sessionKey === garden);
    assert.deepEqual(await admin.send('sessions.rewind', { sessionKey: garden, entryId: question.__openclaw.id }), { editorText: 'What about an herbs-only bed instead?' });
    await rewindEvent;
    assert.equal((await writer.send('chat.history', { sessionKey: garden })).messages.length, 2);
    branches = (await writer.send('sessions.branches.list', { sessionKey: garden })).branches;
    assert.equal(branches[0].active, true);
    assert.equal(branches[0].messageCount, 2, 'the active leaf is listed even when it is not a tip');
    assert.equal(branches.filter((b) => !b.active).length, 3, 'all three follow-ups remain as branches');
    // Busy chats refuse both.
    const busy = 'agent:coder:dashboard:ci-fix';
    // `approve` holds the run on an exec approval.
    const approval = writer.waitEvent('exec.approval.requested', (p) => p.request?.sessionKey === busy);
    await writer.send('chat.send', { sessionKey: busy, message: 'please approve the cleanup', idempotencyKey: crypto.randomUUID() });
    await approval;
    assert.equal((await writer.send('sessions.describe', { key: busy })).session.hasActiveRun, true);
    const firstUser = (await writer.send('chat.history', { sessionKey: busy })).messages[0].__openclaw.id;
    assert.equal((await admin.call('sessions.rewind', { sessionKey: busy, entryId: firstUser })).error.message, 'Rewind is unavailable while the agent is working.');
    const busySwitch = await admin.call('sessions.branches.switch', { sessionKey: busy, leafEntryId: firstUser });
    assert.deepEqual([busySwitch.error.code, busySwitch.error.message], ['UNAVAILABLE', 'Branch switch is unavailable while the agent is working.']);
    await writer.send('chat.abort', { sessionKey: busy });
    const timed = (await writer.send('sessions.describe', { key: busy })).session;
    assert.equal(typeof timed.startedAt, 'number');
    assert.equal(typeof timed.endedAt, 'number', 'runs record their end');
    assert.equal(timed.runtimeMs, timed.endedAt - timed.startedAt);

    // sessions.recover.
    const photo = 'agent:main:dashboard:photo-import';
    assert.equal((await writer.call('sessions.recover', { key: 'agent:main:dashboard:garden' })).error.message, 'Session recovery requires a restart-tombstoned session.');
    assert.equal((await writer.call('sessions.recover', { key: 'agent:main:ghost' })).error.message, 'Session recovery source was not found.');
    const createEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'create' && p.sessionKey?.startsWith('agent:main:dashboard:'));
    const archivedEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'archive' && p.sessionKey === photo);
    const recovered = await writer.send('sessions.recover', { key: photo });
    assert.equal(recovered.ok, true);
    assert.match(recovered.key, /^agent:main:dashboard:[0-9a-f-]{36}$/);
    assert.equal(typeof recovered.sessionId, 'string');
    assert.equal(recovered.continuation.status, 'started');
    assert.equal(typeof recovered.continuation.runId, 'string');
    await createEvent;
    await archivedEvent;
    listed = Object.fromEntries((await writer.send('sessions.list', { archived: 'all' })).sessions.map((row) => [row.key, row]));
    assert.equal(listed[photo].archived, true);
    assert.equal(listed[photo].archiveReason, 'restart-recovery');
    assert.equal(listed[photo].restartRecoveryStatus, undefined);
    assert.equal(listed[recovered.key].label, 'Photo import');
    assert.equal(listed[recovered.key].restartRecoveryStatus, undefined);
    assert.equal(listed[recovered.key].archived, false);
    const recoveredHistory = (await writer.send('chat.history', { sessionKey: recovered.key })).messages;
    assert.match(recoveredHistory.at(-1).content[0].text, /^Recovered after a Gateway restart/);
    assert.equal(recoveredHistory.length, 3, 'the successor carries the transcript');
    const replayEvent = writer.waitEvent('sessions.changed', (p) => p.reason === 'recovery' && p.sessionKey === recovered.key);
    assert.equal((await writer.send('sessions.recover', { key: photo })).key, recovered.key, 'recovering again returns the same successor');
    await replayEvent;
    assert.match((await writer.call('sessions.recover', { sessionKey: photo })).error.message, /invalid sessions\.recover params/, 'recover takes key, not sessionKey (closed object)');

    admin.ws.close();
    writer.ws.close();
    nobody.ws.close();
  } finally {
    await smServer.close();
  }

  // Older Gateways: without the session manager, or just without recover / patchMany.
  for (const [flag, hidden] of [
    ['MOCK_NO_SESSION_MANAGER', SESSION_MANAGER_METHODS],
    ['MOCK_NO_SESSIONS_RECOVER', ['sessions.recover']],
    ['MOCK_NO_PATCH_MANY', ['sessions.patchMany']],
  ]) {
    process.env[flag] = '1';
    const old = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
    try {
      const client = await connectClient(`ws://127.0.0.1:${old.address().port}`, makeDevice(), 'dev-token');
      for (const method of SESSION_MANAGER_METHODS) {
        assert.equal(client.hello.features.methods.includes(method), !hidden.includes(method), `${flag}: ${method}`);
      }
      const res = await client.call(hidden[0], { key: 'agent:main:main' });
      assert.equal(res.ok, false);
      assert.equal(res.error.code, 'UNKNOWN_METHOD', `${flag}: hidden methods are unknown`);
      client.ws.close();
    } finally {
      delete process.env[flag];
      await old.close();
    }
  }
}
