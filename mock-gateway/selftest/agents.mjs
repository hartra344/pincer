import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { AGENT_MANAGEMENT_METHODS, MAX_WORKSPACE_FILE_BYTES, MOCK_STATE_DIR } from '../agents.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Agent management + workspace files, on a fresh server so the roster changes don't leak.
export async function run() {
  const sha = (text) => crypto.createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const agentsServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${agentsServer.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, adminScopes);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    for (const method of AGENT_MANAGEMENT_METHODS) assert.ok(admin.hello.features.methods.includes(method), method);

    // Scopes: reads with operator.read, mutations need operator.admin.
    for (const [method, params] of [
      ['agents.create', { name: 'Nope' }],
      ['agents.update', { agentId: 'main', name: 'Nope' }],
      ['agents.delete', { agentId: 'research' }],
      ['agents.files.set', { agentId: 'main', name: 'SOUL.md', content: 'x' }],
    ]) {
      const gated = await reader.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }
    const list = await reader.send('agents.list', {});
    assert.equal(list.defaultId, 'main');
    assert.deepEqual(list.agents.map((a) => a.id), ['main', 'research', 'coder', 'kiko']);
    assert.equal(list.agents[0].workspace, `${MOCK_STATE_DIR}/workspace`);
    assert.equal(list.agents[1].workspace, `${MOCK_STATE_DIR}/workspace-research`);
    assert.deepEqual(list.agents[2].model, { primary: 'anthropic/claude-sonnet-5' });
    assert.match((await reader.call('agents.list', { extra: 1 })).error.message, /^invalid agents\.list params: at root: unexpected property 'extra'/);

    // Identity.
    assert.deepEqual(await reader.send('agent.identity.get', { agentId: 'research' }), { agentId: 'research', name: 'Scout', nameSource: 'agent', avatar: '🔭', emoji: '🔭' });
    assert.equal((await reader.send('agent.identity.get', { sessionKey: 'agent:coder:main' })).name, 'Forge');
    assert.equal((await reader.send('agent.identity.get', {})).agentId, 'main');
    assert.deepEqual(await reader.send('agent.identity.get', { agentId: 'ghost' }), { agentId: 'ghost', name: 'Assistant', nameSource: 'default', avatar: 'A' });
    assert.match((await reader.call('agent.identity.get', { sessionKey: 'agent:' })).error.message, /malformed session key/);

    // Files: list hides IDENTITY.md (and BOOTSTRAP.md once onboarding is done); missing optional files are expected.
    const files = await reader.send('agents.files.list', { agentId: 'main' });
    assert.equal(files.workspace, `${MOCK_STATE_DIR}/workspace`);
    assert.deepEqual(files.files.map((f) => f.name), ['AGENTS.md', 'SOUL.md', 'USER.md', 'MEMORY.md']);
    const agentsMd = files.files[0];
    assert.equal(agentsMd.path, `${MOCK_STATE_DIR}/workspace/AGENTS.md`);
    assert.equal(agentsMd.missing, false);
    assert.ok(agentsMd.size > 0 && agentsMd.updatedAtMs > 0);
    assert.equal(agentsMd.hash, undefined, 'list carries no hash or content');
    assert.equal(agentsMd.content, undefined);
    const coderFiles = await reader.send('agents.files.list', { agentId: 'coder' });
    assert.deepEqual(coderFiles.files.map((f) => f.name), ['AGENTS.md', 'SOUL.md', 'USER.md', 'BOOTSTRAP.md', 'MEMORY.md']);
    assert.deepEqual(coderFiles.files[1], { name: 'SOUL.md', path: `${MOCK_STATE_DIR}/workspace-coder/SOUL.md`, missing: true, expectedAbsent: true });
    assert.equal(coderFiles.files[3].missing, false, 'coder has an unfinished bootstrap');
    assert.equal((await reader.call('agents.files.list', { agentId: 'nobody' })).error.message, 'agent "nobody" not found');

    const soul = (await reader.send('agents.files.get', { agentId: 'main', name: 'SOUL.md' })).file;
    assert.equal(soul.missing, false);
    assert.equal(soul.hash, sha(soul.content));
    assert.equal(soul.size, Buffer.byteLength(soul.content, 'utf8'));
    const identityFile = (await reader.send('agents.files.get', { agentId: 'main', name: 'IDENTITY.md' })).file;
    assert.match(identityFile.content, /\*\*Name:\*\* Claw/);
    assert.deepEqual((await reader.send('agents.files.get', { agentId: 'coder', name: 'SOUL.md' })).file,
      { name: 'SOUL.md', path: `${MOCK_STATE_DIR}/workspace-coder/SOUL.md`, missing: true, expectedAbsent: true });
    assert.equal((await reader.call('agents.files.get', { agentId: 'main', name: 'TOOLS.md' })).error.message, 'unsupported file "TOOLS.md"');
    assert.equal((await reader.call('agents.files.get', { agentId: 'main', name: '../secrets' })).error.message, 'unsupported file "../secrets"');
    assert.equal((await reader.call('agents.files.get', { agentId: 'main', name: 'HEARTBEAT.md' })).error.message, 'unsupported file "HEARTBEAT.md"');

    // Set: expectedHash CAS, conflict details, expectedMissing, unconditional overwrite.
    const edited = `${soul.content}\n- Never page Travis after 22:00.\n`;
    const saved = await admin.send('agents.files.set', { agentId: 'main', name: 'SOUL.md', content: edited, expectedHash: soul.hash });
    assert.equal(saved.ok, true);
    assert.equal(saved.file.hash, sha(edited));
    assert.equal(saved.file.content, edited);
    assert.equal(saved.file.size, Buffer.byteLength(edited, 'utf8'));
    assert.equal((await reader.send('agents.files.get', { agentId: 'main', name: 'SOUL.md' })).file.hash, saved.file.hash);
    const stale = await admin.call('agents.files.set', { agentId: 'main', name: 'SOUL.md', content: 'lost update', expectedHash: soul.hash });
    assert.equal(stale.error.code, 'INVALID_REQUEST');
    assert.equal(stale.error.message, 'agent file "SOUL.md" changed since it was read');
    assert.deepEqual(stale.error.details, { type: 'agent_file_conflict', name: 'SOUL.md', currentHash: saved.file.hash });
    assert.equal((await reader.send('agents.files.get', { agentId: 'main', name: 'SOUL.md' })).file.content, edited, 'stale write refused');
    const upper = await admin.send('agents.files.set', { agentId: 'main', name: 'SOUL.md', content: edited, expectedHash: saved.file.hash.toUpperCase() });
    assert.equal(upper.file.hash, saved.file.hash, 'expectedHash compares case-insensitively');
    const gone = await admin.call('agents.files.set', { agentId: 'coder', name: 'SOUL.md', content: 'x', expectedHash: soul.hash });
    assert.deepEqual(gone.error.details, { type: 'agent_file_conflict', name: 'SOUL.md' }, 'no currentHash when the file is missing');
    const created = await admin.send('agents.files.set', { agentId: 'coder', name: 'SOUL.md', content: '# SOUL.md\n\nShip it.\n', expectedMissing: true });
    assert.equal(created.file.missing, false);
    const raced = await admin.call('agents.files.set', { agentId: 'coder', name: 'SOUL.md', content: 'second', expectedMissing: true });
    assert.deepEqual(raced.error.details, { type: 'agent_file_conflict', name: 'SOUL.md' });
    const overwrite = await admin.send('agents.files.set', { agentId: 'coder', name: 'SOUL.md', content: 'forced' });
    assert.equal(overwrite.file.content, 'forced', 'no precondition keeps the unconditional overwrite');
    for (const [params, pattern] of [
      [{ agentId: 'main', name: 'SOUL.md', content: 'x', expectedHash: 'deadbeef' }, /at \/expectedHash: must match pattern/],
      [{ agentId: 'main', name: 'SOUL.md', content: 'x', expectedMissing: false }, /at \/expectedMissing/],
      [{ agentId: 'main', name: 'SOUL.md', content: 'x', expectedHash: saved.file.hash, expectedMissing: true }, /at root: must NOT be valid/],
      [{ agentId: 'main', name: 'SOUL.md' }, /must have required property 'content'/],
      [{ agentId: 'main', name: 'SOUL.md', content: 1 }, /at \/content: must be string/],
      [{ agentId: 'main', name: 'SOUL.md', content: 'x', force: true }, /unexpected property 'force'/],
    ]) {
      const res = await admin.call('agents.files.set', params);
      assert.equal(res.error.code, 'INVALID_REQUEST');
      assert.match(res.error.message, /^invalid agents\.files\.set params: /);
      assert.match(res.error.message, pattern);
    }
    assert.equal((await admin.call('agents.files.set', { agentId: 'main', name: 'NOTES.md', content: 'x' })).error.message, 'unsupported file "NOTES.md"');
    // A local workspace takes the 2 MiB bootstrap bound (clients cap edits there); multibyte sizes are bytes.
    const big = 'é'.repeat(MAX_WORKSPACE_FILE_BYTES / 2);
    const bigSaved = await admin.send('agents.files.set', { agentId: 'main', name: 'MEMORY.md', content: big });
    assert.equal(bigSaved.file.size, MAX_WORKSPACE_FILE_BYTES);

    // Create: id derivation, reserved/duplicate/invalid names, seeded workspace.
    const newAgent = await admin.send('agents.create', { name: '  Night Owl ', emoji: '🦉', model: 'openai/gpt-5.6-sol' });
    assert.deepEqual(newAgent, { ok: true, agentId: 'night-owl', name: 'Night Owl', workspace: `${MOCK_STATE_DIR}/workspace-night-owl`, model: 'openai/gpt-5.6-sol' });
    const afterCreate = (await reader.send('agents.list', {})).agents.find((a) => a.id === 'night-owl');
    assert.deepEqual(afterCreate.identity, { name: 'Night Owl', emoji: '🦉' });
    assert.deepEqual(afterCreate.model, { primary: 'openai/gpt-5.6-sol' });
    const owlFiles = (await reader.send('agents.files.list', { agentId: 'night-owl' })).files;
    assert.deepEqual(owlFiles.filter((f) => !f.missing).map((f) => f.name), ['AGENTS.md', 'SOUL.md', 'USER.md', 'BOOTSTRAP.md']);
    assert.match((await reader.send('agents.files.get', { agentId: 'night-owl', name: 'IDENTITY.md' })).file.content, /Night Owl[\s\S]*🦉/);
    assert.equal((await admin.call('agents.create', { name: 'Night Owl' })).error.message, 'agent "night-owl" already exists');
    assert.equal((await admin.call('agents.create', { name: 'OpenClaw' })).error.message, '"openclaw" is reserved');
    assert.equal((await admin.call('agents.create', { name: 'crestodian' })).error.message, '"crestodian" is reserved');
    assert.equal((await admin.call('agents.create', { name: '!!!' })).error.message, 'Agent name "!!!" has no valid id characters. Use at least one letter a-z or digit.');
    assert.equal((await admin.call('agents.create', { name: '   ' })).error.message, 'agent name is required');
    assert.match((await admin.call('agents.create', { name: '' })).error.message, /^invalid agents\.create params: at \/name: must NOT have fewer than 1 characters/);
    assert.match((await admin.call('agents.create', { name: 'x', bindings: [] })).error.message, /unexpected property 'bindings'/);
    const shared = await admin.send('agents.create', { name: 'Owl Twin', workspace: `${MOCK_STATE_DIR}/workspace-night-owl` });
    assert.equal(shared.workspace, `${MOCK_STATE_DIR}/workspace-night-owl`);
    assert.equal(shared.model, undefined);

    // Duplicate = create + copy files; copying into the fresh workspace uses the new file's hash.
    const dupe = await admin.send('agents.create', { name: 'Scout Copy', emoji: '🔭' });
    for (const f of (await reader.send('agents.files.list', { agentId: 'research' })).files.filter((f) => !f.missing)) {
      const source = (await reader.send('agents.files.get', { agentId: 'research', name: f.name })).file;
      const target = (await reader.send('agents.files.get', { agentId: dupe.agentId, name: f.name })).file;
      const precondition = target.missing ? { expectedMissing: true } : { expectedHash: target.hash };
      await admin.send('agents.files.set', { agentId: dupe.agentId, name: f.name, content: source.content, ...precondition });
    }
    const copiedSoul = (await reader.send('agents.files.get', { agentId: dupe.agentId, name: 'SOUL.md' })).file;
    assert.match(copiedSoul.content, /Scout/);

    // Update: identity fields rewrite IDENTITY.md, null clears the model, new workspace is seeded.
    assert.deepEqual(await admin.send('agents.update', { agentId: 'night-owl', name: 'Night\nHeron', emoji: '🪶', model: null }), { ok: true, agentId: 'night-owl' });
    const updated = (await reader.send('agents.list', {})).agents.find((a) => a.id === 'night-owl');
    assert.equal(updated.name, 'Night Heron', 'names are one line');
    assert.deepEqual(updated.identity, { name: 'Night Heron', emoji: '🪶' });
    assert.equal(updated.model, undefined);
    assert.match((await reader.send('agents.files.get', { agentId: 'night-owl', name: 'IDENTITY.md' })).file.content, /Night Heron[\s\S]*🪶/);
    await admin.send('agents.update', { agentId: 'Night-Owl', workspace: `${MOCK_STATE_DIR}/owl-2`, model: 'anthropic/claude-opus-4-8' });
    const moved = (await reader.send('agents.list', {})).agents.find((a) => a.id === 'night-owl');
    assert.equal(moved.workspace, `${MOCK_STATE_DIR}/owl-2`);
    assert.deepEqual(moved.model, { primary: 'anthropic/claude-opus-4-8' });
    assert.equal((await reader.send('agents.files.list', { agentId: 'night-owl' })).files[0].missing, false, 'new workspace seeded');
    assert.equal((await admin.call('agents.update', { agentId: 'nobody', name: 'x' })).error.message, 'agent "nobody" not found');
    assert.match((await admin.call('agents.update', { agentId: 'main', model: '' })).error.message, /^invalid agents\.update params: at \/model/);
    assert.match((await admin.call('agents.update', { agentId: 'main', bindings: [] })).error.message, /unexpected property 'bindings'/);

    // Delete: sessions go with the agent; files default to the trash; the sole agent stays.
    await reader.send('sessions.subscribe', {});
    const researchSessions = (await reader.send('sessions.list', { limit: 100 })).sessions.filter((s) => s.key.startsWith('agent:research:'));
    assert.ok(researchSessions.length > 0);
    const deletedEvent = reader.waitEvent('sessions.changed', (p) => p.reason === 'delete' && p.sessionKey.startsWith('agent:research:'));
    const deleted = await admin.send('agents.delete', { agentId: 'research' });
    assert.deepEqual(deleted, {
      ok: true,
      agentId: 'research',
      removedBindings: 0,
      removed: [
        { path: `${MOCK_STATE_DIR}/workspace-research`, method: 'trash' },
        { path: `${MOCK_STATE_DIR}/agents/research/agent`, method: 'trash' },
        { path: `${MOCK_STATE_DIR}/agents/research/sessions`, method: 'trash' },
      ],
      failed: [],
    });
    await deletedEvent;
    assert.ok(!(await reader.send('agents.list', {})).agents.some((a) => a.id === 'research'));
    assert.ok(!(await reader.send('sessions.list', { limit: 100 })).sessions.some((s) => s.key.startsWith('agent:research:')));
    assert.equal((await reader.call('agents.files.list', { agentId: 'research' })).error.message, 'agent "research" not found');
    assert.equal((await admin.call('agents.delete', { agentId: 'research' })).error.message, 'agent "research" not found');
    const kept = await admin.send('agents.delete', { agentId: 'owl-twin', deleteFiles: false });
    assert.deepEqual(kept.removed, [], 'deleteFiles:false leaves files alone');
    assert.equal((await admin.send('agents.delete', { agentId: 'night-owl' })).removed[0].method, 'trash');
    for (const agentId of ['coder', 'kiko', dupe.agentId]) await admin.send('agents.delete', { agentId });
    assert.equal((await admin.call('agents.delete', { agentId: 'main' })).error.message, 'Agent "main" is the only configured agent and cannot be deleted.');
    assert.match((await admin.call('agents.delete', { agentId: 'main', force: true })).error.message, /unexpected property 'force'/);
    admin.ws.close();
    reader.ws.close();
  } finally {
    await agentsServer.close();
  }

  // MOCK_NO_AGENT_MANAGEMENT=1: an older Gateway with only agents.list.
  process.env.MOCK_NO_AGENT_MANAGEMENT = '1';
  const legacyServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const legacy = await connectClient(`ws://127.0.0.1:${legacyServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    assert.ok(legacy.hello.features.methods.includes('agents.list'));
    for (const method of AGENT_MANAGEMENT_METHODS) {
      assert.ok(!legacy.hello.features.methods.includes(method));
      assert.equal((await legacy.call(method, { agentId: 'main' })).error.code, 'UNKNOWN_METHOD');
    }
    assert.equal((await legacy.send('agents.list', {})).agents.length, 4);
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_AGENT_MANAGEMENT;
    await legacyServer.close();
  }
}
