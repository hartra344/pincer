import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import http from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { startServer } from './server.mjs';
import * as fileEdits from './file-edits.mjs';
import { AGENT_MANAGEMENT_METHODS, MAX_WORKSPACE_FILE_BYTES, MOCK_STATE_DIR } from './agents.mjs';
import { CLAWHUB_REGISTRY, MANAGED_SKILLS_DIR, SKILLS_METHODS, TOOLS_METHODS } from './skills.mjs';
import { SEEDED_HISTORY_COUNTS } from './approvals.mjs';
import { FAILED_DELIVERY_QUEUE, addFailedDelivery, createHealthState, healthSummary } from './health.mjs';
import { PAIRING_TTL_MS, PENDING_PER_ACCOUNT, addChannelPairingRequest, createChannelPairingState } from './pairing.mjs';
import { appendLogLine, readLogSlice } from './logs.mjs';
import { DEVICE_PAIRING_METHODS, NODE_METHODS, SEEDED_PENDING_REQUEST_IDS, deviceIdentityFor } from './devices.mjs';
import { decryptWebPush, sessionPath } from './webpush.mjs';
import { SEEDED_RUNNING_RUN_ID, SEEDED_SUBAGENTS, SUBAGENT_PARENT_KEY } from './subagents.mjs';
import { TELEGRAM_CONFLICT, WHATSAPP_NOT_LINKED, WHATSAPP_RELINK_FIX } from './setup.mjs';
import { CHANNEL_LIFECYCLE_METHODS } from './channels.mjs';

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function makeDevice() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const spki = publicKey.export({ format: 'der', type: 'spki' });
  const rawPublic = Buffer.from(spki).subarray(-32);
  const id = crypto.createHash('sha256').update(rawPublic).digest('hex');
  return { id, publicKey: b64url(rawPublic), privateKey };
}

const BASE_SCOPES = ['operator.read', 'operator.write', 'operator.approvals', 'operator.questions'];

function signConnect(device, challenge, token, scopes = BASE_SCOPES) {
  const client = {
    id: 'openclaw-macos',
    displayName: 'Pincer Selftest',
    version: '0.0.0',
    platform: 'macos',
    mode: 'ui',
    deviceFamily: 'desktop',
    instanceId: 'selftest',
  };
  const payload = `v2|${device.id}|${client.id}|${client.mode}|operator|${scopes.join(',')}|${challenge.ts}|${token}|${challenge.nonce}`;
  return {
    minProtocol: 4,
    maxProtocol: 4,
    client,
    role: 'operator',
    scopes,
    caps: ['tool-events'],
    auth: { token },
    device: {
      id: device.id,
      publicKey: device.publicKey,
      signature: b64url(crypto.sign(null, Buffer.from(payload, 'utf8'), device.privateKey)),
      signedAt: challenge.ts,
      nonce: challenge.nonce,
    },
  };
}

async function connectClient(url, device, token, expectOk = true, scopes = BASE_SCOPES) {
  const ws = new WebSocket(url);
  const emitter = new EventEmitter();
  const pending = new Map();
  let nextId = 1;
  let challenge;
  let hello;

  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    if (msg.type === 'event') {
      if (msg.event === 'connect.challenge') challenge = msg.payload;
      emitter.emit(msg.event, msg.payload);
      emitter.emit('*', msg.event, msg.payload);
    } else if (msg.type === 'res') {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        p(msg);
      }
    }
  });

  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  await waitUntil(() => challenge, 1000, 'challenge');
  const id = `req_${nextId++}`;
  const connectResP = new Promise((resolve) => pending.set(id, resolve));
  ws.send(JSON.stringify({ type: 'req', id, method: 'connect', params: signConnect(device, challenge, token, scopes) }));
  const connectRes = await connectResP;
  if (expectOk) {
    assert.equal(connectRes.ok, true, JSON.stringify(connectRes));
    hello = connectRes.payload;
    assert.equal(hello.type, 'hello-ok');
  } else {
    assert.equal(connectRes.ok, false, JSON.stringify(connectRes));
    return { ws, connectRes };
  }

  function call(method, params = {}) {
    const reqId = `req_${nextId++}`;
    const p = new Promise((resolve) => pending.set(reqId, resolve));
    ws.send(JSON.stringify({ type: 'req', id: reqId, method, params }));
    return p;
  }

  function send(method, params = {}) {
    return call(method, params).then((res) => {
      assert.equal(res.ok, true, `${method} failed: ${JSON.stringify(res)}`);
      return res.payload;
    });
  }

  function waitEvent(name, predicate = () => true, timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`timed out waiting for ${name}`));
      }, timeoutMs);
      function handler(payload) {
        try {
          if (predicate(payload)) {
            cleanup();
            resolve(payload);
          }
        } catch (err) {
          cleanup();
          reject(err);
        }
      }
      function cleanup() {
        clearTimeout(timer);
        emitter.off(name, handler);
      }
      emitter.on(name, handler);
    });
  }

  return { ws, hello, send, call, waitEvent, emitter };
}

// Applies a headers-only unified diff (as upstream's `details.patch`) to `text`.
function applyUnified(text, patch) {
  const source = text === '' ? [] : text.replace(/\n$/, '').split('\n');
  const out = [];
  let cursor = 0;
  for (const hunk of patch.split(/^(?=@@ )/m).slice(1)) {
    const [header, ...body] = hunk.replace(/\n$/, '').split('\n');
    const oldStart = Number(/^@@ -(\d+)/.exec(header)[1]);
    const start = oldStart === 0 ? 0 : oldStart - 1;
    out.push(...source.slice(cursor, start));
    cursor = start;
    for (const line of body) {
      if (line[0] === '+') out.push(line.slice(1));
      else {
        assert.equal(source[cursor], line.slice(1), `patch context at line ${cursor + 1}`);
        if (line[0] === ' ') out.push(line.slice(1));
        cursor++;
      }
    }
  }
  out.push(...source.slice(cursor));
  return out.length ? `${out.join('\n')}\n` : '';
}

async function waitUntil(fn, timeoutMs, label) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = fn();
    if (value) return value;
    await delay(20);
  }
  throw new Error(`timed out waiting for ${label}`);
}

// Agent management + workspace files, on a fresh server so the roster changes don't leak.
async function agentManagementSelftest() {
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
    assert.deepEqual(list.agents.map((a) => a.id), ['main', 'research', 'coder']);
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
    for (const agentId of ['coder', dupe.agentId]) await admin.send('agents.delete', { agentId });
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
    assert.equal((await legacy.send('agents.list', {})).agents.length, 3);
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_AGENT_MANAGEMENT;
    await legacyServer.close();
  }
}

// Subagent tree + run timeline (#35), on a fresh server so spawned rows don't leak.
async function subagentsSelftest() {
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

// Device pairing + node inventory (devices.mjs), on a fresh server so revocations don't leak.
async function devicePairingSelftest() {
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const pairingScopes = [...BASE_SCOPES, 'operator.pairing'];
  const sortedKeys = (o) => Object.keys(o).sort();
  const PENDING_KEYS = ['clientId', 'clientMode', 'deviceFamily', 'deviceId', 'displayName', 'isRepair', 'platform', 'publicKey',
    'remoteIp', 'requestId', 'role', 'roles', 'scopes', 'silent', 'ts'];
  const PAIRED_KEYS = ['approvedAtMs', 'approvedVia', 'clientId', 'clientMode', 'connected', 'createdAtMs', 'deviceFamily', 'deviceId',
    'displayName', 'lastSeenAtMs', 'operatorLabel', 'platform', 'publicKey', 'remoteIp', 'role', 'roles', 'scopes', 'tokens'];
  const devServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${devServer.address().port}`;
    const adminDevice = makeDevice();
    const firstTry = await connectClient(url, adminDevice, 'dev-token', false, adminScopes);
    assert.equal(firstTry.connectRes.error.details.code, 'PAIRING_REQUIRED');
    firstTry.ws.close();
    await delay(3500);
    const admin = await connectClient(url, adminDevice, 'dev-token', true, adminScopes);
    for (const m of [...DEVICE_PAIRING_METHODS, ...NODE_METHODS]) assert.ok(admin.hello.features.methods.includes(m), m);
    for (const e of ['device.pair.requested', 'device.pair.resolved', 'device.pair.changed']) assert.ok(admin.hello.features.events.includes(e), e);

    // Seeded list: two pending requests (a new iPad and a scope upgrade), Pincer itself plus three paired devices.
    const list = await admin.send('device.pair.list', {});
    assert.deepEqual(sortedKeys(list), ['paired', 'pending']);
    assert.deepEqual(list.pending.map((p) => p.requestId).sort(), [...SEEDED_PENDING_REQUEST_IDS].sort());
    for (const p of list.pending) {
      assert.ok(sortedKeys(p).every((k) => PENDING_KEYS.includes(k)), `pending keys ${sortedKeys(p)}`);
      assert.ok(p.requestId && p.deviceId && p.publicKey && Number.isInteger(p.ts), 'pending required fields');
      assert.equal(p.deviceId, crypto.createHash('sha256').update(Buffer.from(p.publicKey, 'base64url')).digest('hex'), 'deviceId is sha256(publicKey)');
    }
    const ipad = list.pending.find((p) => p.requestId === 'pair_ipad');
    assert.equal(ipad.displayName, "Travis's iPad");
    assert.equal(ipad.isRepair, false);
    assert.equal(ipad.deviceId, deviceIdentityFor('travis-ipad').deviceId);
    const upgradeReq = list.pending.find((p) => p.requestId === 'pair_studio_admin');
    assert.equal(upgradeReq.isRepair, true);
    assert.ok(upgradeReq.scopes.includes('operator.admin'));
    assert.deepEqual(list.paired.map((d) => d.displayName).sort(), ['Mac mini (home)', 'Pincer Selftest', 'Pixel 9', 'Studio MacBook Pro']);
    assert.ok(!JSON.stringify(list).includes('dt_'), 'no token material in device.pair.list');
    for (const d of list.paired) {
      assert.ok(sortedKeys(d).every((k) => PAIRED_KEYS.includes(k)), `paired keys ${sortedKeys(d)}`);
      assert.equal(typeof d.connected, 'boolean');
      assert.ok(Array.isArray(d.tokens) && d.tokens.every((t) => typeof t.role === 'string' && Array.isArray(t.scopes) && Number.isInteger(t.createdAtMs)));
      assert.ok(!('approvedScopes' in d) && !('deviceToken' in d));
    }
    const self = list.paired.find((d) => d.deviceId === adminDevice.id);
    assert.equal(self.connected, true);
    assert.equal(self.publicKey, adminDevice.publicKey);
    assert.equal(self.clientId, 'openclaw-macos');
    assert.equal(self.platform, 'macos');
    assert.ok(self.scopes.includes('operator.admin'));
    const studio = list.paired.find((d) => d.displayName === 'Studio MacBook Pro');
    assert.equal(studio.connected, false);
    assert.equal(studio.clientMode, 'cli');
    assert.ok(Date.now() - studio.lastSeenAtMs > 2 * 3_600_000);
    assert.deepEqual(list.paired.find((d) => d.displayName === 'Pixel 9').roles, ['node', 'operator']);

    // Closed params, like upstream's typebox schemas.
    assert.equal((await admin.call('device.pair.list', { limit: 5 })).error.message, "invalid device.pair.list params: at root: unexpected property 'limit'");
    assert.match((await admin.call('device.pair.approve', {})).error.message, /must have required property 'requestId'/);
    assert.equal((await admin.call('device.pair.reject', { requestId: '' })).error.code, 'INVALID_REQUEST');
    assert.match((await admin.call('device.pair.remove', { deviceId: 'x', force: true })).error.message, /unexpected property 'force'/);

    // A new device asks to pair: device.pair.requested reaches admins; retrying refreshes the same request.
    const newcomer = makeDevice();
    const requested = admin.waitEvent('device.pair.requested', (p) => p.deviceId === newcomer.id);
    const knock = await connectClient(url, newcomer, 'dev-token', false);
    knock.ws.close();
    const requestedEvent = await requested;
    assert.equal(requestedEvent.requestId, knock.connectRes.error.details.requestId);
    assert.equal(requestedEvent.publicKey, newcomer.publicKey);
    assert.equal(requestedEvent.displayName, 'Pincer Selftest');
    assert.deepEqual(requestedEvent.scopes, BASE_SCOPES);
    assert.ok(sortedKeys(requestedEvent).every((k) => PENDING_KEYS.includes(k)));
    const knockAgain = await connectClient(url, newcomer, 'dev-token', false);
    knockAgain.ws.close();
    assert.equal(knockAgain.connectRes.error.details.requestId, requestedEvent.requestId, 'same device refreshes its request');
    assert.equal((await admin.send('device.pair.list', {})).pending.filter((p) => p.deviceId === newcomer.id).length, 1);

    // Approve before the auto-approval: result + device.pair.resolved; a second approve is unknown.
    const resolvedApprove = admin.waitEvent('device.pair.resolved', (p) => p.requestId === requestedEvent.requestId);
    const approved = await admin.send('device.pair.approve', { requestId: requestedEvent.requestId });
    assert.deepEqual(sortedKeys(approved), ['device', 'requestId']);
    assert.equal(approved.device.deviceId, newcomer.id);
    assert.deepEqual(approved.device.scopes, BASE_SCOPES);
    assert.ok(!JSON.stringify(approved).includes('dt_'));
    const resolvedEvent = await resolvedApprove;
    assert.deepEqual(sortedKeys(resolvedEvent), ['decision', 'deviceId', 'requestId', 'ts']);
    assert.equal(resolvedEvent.decision, 'approved');
    assert.equal(resolvedEvent.deviceId, newcomer.id);
    const again = await admin.call('device.pair.approve', { requestId: requestedEvent.requestId });
    assert.equal(again.error.code, 'INVALID_REQUEST');
    assert.equal(again.error.message, 'unknown requestId');

    // Reject the iPad.
    const resolvedReject = admin.waitEvent('device.pair.resolved', (p) => p.requestId === 'pair_ipad');
    assert.deepEqual(await admin.send('device.pair.reject', { requestId: 'pair_ipad' }), { requestId: 'pair_ipad', deviceId: ipad.deviceId });
    assert.equal((await resolvedReject).decision, 'rejected');
    assert.equal((await admin.call('device.pair.reject', { requestId: 'pair_ipad' })).error.message, 'unknown requestId');
    assert.ok(!(await admin.send('device.pair.list', {})).pending.some((p) => p.requestId === 'pair_ipad'));

    // Without operator.pairing: FORBIDDEN for device.pair.* and node.rename, no pairing events; node.list only needs read.
    const reader = await connectClient(url, newcomer, 'dev-token', true);
    const denied = await reader.call('device.pair.list', {});
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', missingScope: 'operator.pairing', requiredScopes: ['operator.pairing'] });
    for (const [m, p] of [['device.pair.approve', { requestId: 'pair_studio_admin' }], ['device.pair.reject', { requestId: 'x' }],
      ['device.pair.remove', { deviceId: 'x' }], ['device.pair.rename', { deviceId: 'x', label: 'y' }], ['node.rename', { nodeId: 'x', displayName: 'y' }], ['node.pair.remove', { nodeId: 'x' }]]) {
      assert.equal((await reader.call(m, p)).error.details.missingScope, 'operator.pairing', m);
    }
    assert.equal((await reader.send('node.list', {})).nodes.length, 2);
    const readerEvents = [];
    reader.emitter.on('*', (event) => { if (event.startsWith('device.pair.')) readerEvents.push(event); });
    await admin.send('device.pair.rename', { deviceId: studio.deviceId, label: 'Studio' });
    await delay(200);
    assert.deepEqual(readerEvents, [], 'device.pair.* only reach operator.pairing clients');
    reader.ws.close();

    // operator.pairing without admin, on the device token: only its own device, and no cross-device changes.
    const newcomerToken = reader.hello.auth.deviceToken;
    const upgrade = await connectClient(url, newcomer, newcomerToken, false, pairingScopes);
    assert.equal(upgrade.connectRes.error.details.reason, 'scope-upgrade');
    upgrade.ws.close();
    const upgradeListed = (await admin.send('device.pair.list', {})).pending.find((p) => p.deviceId === newcomer.id);
    assert.equal(upgradeListed.isRepair, true);
    assert.ok(upgradeListed.scopes.includes('operator.pairing'));
    await admin.send('device.pair.approve', { requestId: upgradeListed.requestId });
    const pairer = await connectClient(url, newcomer, newcomerToken, true, pairingScopes);
    const ownList = await pairer.send('device.pair.list', {});
    assert.deepEqual(ownList.paired.map((d) => d.deviceId), [newcomer.id]);
    assert.deepEqual(ownList.pending, []);
    assert.equal((await pairer.call('device.pair.remove', { deviceId: studio.deviceId })).error.message, 'device pairing removal denied');
    assert.equal((await pairer.call('device.pair.rename', { deviceId: studio.deviceId, label: 'x' })).error.message, 'device pairing rename denied');
    assert.equal((await pairer.call('device.pair.approve', { requestId: 'pair_studio_admin' })).error.message, 'device pairing approval denied');
    assert.equal((await pairer.call('device.pair.reject', { requestId: 'pair_studio_admin' })).error.message, 'device pairing rejection denied');
    assert.equal((await pairer.call('node.rename', { nodeId: studio.deviceId, displayName: 'x' })).error.message, 'node rename denied');
    pairer.ws.close();
    // On the shared token it sees everything, but can't approve scopes it doesn't hold.
    const sharedPairer = await connectClient(url, newcomer, 'dev-token', true, pairingScopes);
    assert.ok((await sharedPairer.send('device.pair.list', {})).paired.length > 1);
    const tooMuch = await sharedPairer.call('device.pair.approve', { requestId: 'pair_studio_admin' });
    assert.equal(tooMuch.error.code, 'INVALID_REQUEST');
    assert.equal(tooMuch.error.message, 'missing scope: operator.admin');
    sharedPairer.ws.close();

    // Rename: device.pair.changed + operatorLabel.
    const changed = admin.waitEvent('device.pair.changed');
    assert.deepEqual(await admin.send('device.pair.rename', { deviceId: studio.deviceId, label: '  Studio Pro  ' }), { deviceId: studio.deviceId, label: 'Studio Pro' });
    assert.deepEqual(await changed, {});
    assert.equal((await admin.send('device.pair.list', {})).paired.find((d) => d.deviceId === studio.deviceId).operatorLabel, 'Studio Pro');
    assert.equal((await admin.call('device.pair.rename', { deviceId: studio.deviceId, label: '   ' })).error.message, 'label required');
    assert.match((await admin.call('device.pair.rename', { deviceId: studio.deviceId, label: 'x'.repeat(65) })).error.message, /more than 64/);
    assert.equal((await admin.call('device.pair.rename', { deviceId: 'nope', label: 'x' })).error.message, 'unknown deviceId');

    // Nodes: the Mac mini node host (connected) and the Pixel (offline).
    const nodes = await admin.send('node.list', {});
    assert.ok(Number.isInteger(nodes.ts));
    const mini = nodes.nodes.find((n) => n.displayName === 'Mac mini (home)');
    const pixelNode = nodes.nodes.find((n) => n.displayName === 'Pixel 9');
    assert.equal(mini.connected, true);
    assert.ok(mini.connectedAtMs < Date.now());
    assert.equal(pixelNode.connected, false);
    assert.ok(mini.caps.length > 0 && mini.commands.length > 0 && mini.version && mini.platform === 'darwin');
    assert.ok(nodes.nodes.every((n) => n.paired === true && n.approvalState === 'approved'));
    assert.ok(!nodes.nodes.some((n) => n.nodeId === adminDevice.id), 'operator-only devices are not nodes');
    const described = await admin.send('node.describe', { nodeId: mini.nodeId });
    assert.equal(described.nodeId, mini.nodeId);
    assert.ok(Number.isInteger(described.ts));
    assert.equal((await admin.call('node.describe', { nodeId: 'nope' })).error.message, 'unknown nodeId');
    assert.deepEqual(await admin.send('node.rename', { nodeId: mini.nodeId, displayName: 'Mac mini' }), { nodeId: mini.nodeId, displayName: 'Mac mini' });
    assert.equal((await admin.send('node.describe', { nodeId: mini.nodeId })).displayName, 'Mac mini');
    assert.equal((await admin.call('node.rename', { nodeId: 'nope', displayName: 'x' })).error.message, 'unknown nodeId');
    assert.equal((await admin.call('node.rename', { nodeId: mini.nodeId, displayName: ' ' })).error.message, 'displayName required');
    // node.pair.remove revokes the node role: the Pixel stays as an operator device, the node-only Mac mini goes.
    const nodeResolved = admin.waitEvent('node.pair.resolved', (p) => p.nodeId === pixelNode.nodeId);
    assert.deepEqual(await admin.send('node.pair.remove', { nodeId: pixelNode.nodeId }), { nodeId: pixelNode.nodeId });
    const nodeResolvedEvent = await nodeResolved;
    assert.equal(nodeResolvedEvent.decision, 'removed');
    assert.equal(nodeResolvedEvent.requestId, '');
    assert.equal((await admin.call('node.pair.remove', { nodeId: pixelNode.nodeId })).error.message, 'unknown nodeId');
    assert.deepEqual((await admin.send('device.pair.list', {})).paired.find((d) => d.deviceId === pixelNode.nodeId).roles, ['operator']);
    assert.deepEqual(await admin.send('node.pair.remove', { nodeId: mini.nodeId }), { nodeId: mini.nodeId });
    assert.deepEqual((await admin.send('node.list', {})).nodes, []);
    assert.ok(!(await admin.send('device.pair.list', {})).paired.some((d) => d.deviceId === mini.nodeId));

    // Remove: also drops that device's pending requests; removing yourself disconnects you.
    assert.deepEqual(await admin.send('device.pair.remove', { deviceId: studio.deviceId }), { deviceId: studio.deviceId });
    const afterRemove = await admin.send('device.pair.list', {});
    assert.ok(!afterRemove.paired.some((d) => d.deviceId === studio.deviceId));
    assert.ok(!afterRemove.pending.some((p) => p.requestId === 'pair_studio_admin'), 'removal drops pending repairs');
    assert.equal((await admin.call('device.pair.remove', { deviceId: studio.deviceId })).error.message, 'unknown deviceId');
    const closed = new Promise((resolve) => admin.ws.once('close', (code) => resolve(code)));
    assert.deepEqual(await admin.send('device.pair.remove', { deviceId: adminDevice.id }), { deviceId: adminDevice.id });
    assert.equal(await closed, 1008);
    const revoked = await connectClient(url, adminDevice, 'dev-token', false, adminScopes);
    assert.equal(revoked.connectRes.error.details.reason, 'not-paired');
    revoked.ws.close();
  } finally {
    await devServer.close();
  }

  // Older Gateways: no device.pair.* / node.* methods.
  process.env.MOCK_DEVICE_PAIRING = 'off';
  process.env.MOCK_NODES = 'off';
  const oldServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${oldServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    for (const m of [...DEVICE_PAIRING_METHODS, ...NODE_METHODS]) assert.ok(!client.hello.features.methods.includes(m), m);
    assert.ok(!client.hello.features.events.includes('device.pair.requested'));
    assert.equal((await client.call('device.pair.list', {})).error.code, 'UNKNOWN_METHOD');
    assert.equal((await client.call('node.list', {})).error.code, 'UNKNOWN_METHOD');
    client.ws.close();
  } finally {
    delete process.env.MOCK_DEVICE_PAIRING;
    delete process.env.MOCK_NODES;
    await oldServer.close();
  }
}

// Skills browser + effective tools, on a fresh server so installs and toggles don't leak.
async function skillsToolsSelftest() {
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const skillsServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${skillsServer.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, adminScopes);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    const nobody = await connectClient(url, makeDevice(), 'dev-token', true, ['operator.approvals']);
    for (const method of [...SKILLS_METHODS, ...TOOLS_METHODS]) assert.ok(admin.hello.features.methods.includes(method), method);

    // Scopes: reads need operator.read (write implies it), install/update need operator.admin.
    for (const [method, params] of [
      ['skills.install', { name: 'github', installId: 'brew' }],
      ['skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' }],
      ['skills.update', { skillKey: 'slack', enabled: true }],
      ['skills.update', { source: 'clawhub', all: true }],
    ]) {
      const gated = await reader.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }
    for (const [method, params] of [['skills.status', {}], ['skills.search', {}], ['skills.detail', { slug: 'nas-report' }], ['tools.catalog', {}], ['tools.effective', { sessionKey: 'agent:main:main' }]]) {
      const gated = await nobody.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.equal(gated.error.message, 'missing scope: operator.read');
    }
    nobody.ws.close();

    // skills.status: one entry per state.
    const status = await reader.send('skills.status', {});
    assert.equal(status.agentId, 'main');
    assert.equal(status.workspaceDir, '/Users/claw/.openclaw/workspace');
    assert.equal(status.managedSkillsDir, MANAGED_SKILLS_DIR);
    assert.equal(status.agentSkillFilter, undefined);
    const byName = (report) => Object.fromEntries(report.skills.map((s) => [s.name, s]));
    let skills = byName(status);
    const keys = ['name', 'description', 'source', 'bundled', 'filePath', 'baseDir', 'skillKey', 'always', 'disabled', 'blockedByAllowlist', 'blockedByAgentFilter', 'eligible', 'platformIncompatible', 'modelVisible', 'userInvocable', 'commandVisible', 'requirements', 'missing', 'configChecks', 'install'];
    for (const skill of status.skills) for (const key of keys) assert.ok(key in skill, `${skill.name}.${key}`);
    assert.equal(skills.weather.eligible, true);
    assert.equal(skills.weather.bundled, true);
    assert.equal(skills.weather.source, 'openclaw-bundled');
    assert.equal(skills.weather.modelVisible, true);
    assert.deepEqual(skills.weather.requirements, { bins: ['curl'], anyBins: [], env: [], config: [], os: [] });
    assert.equal(skills.github.eligible, false);
    assert.deepEqual(skills.github.missing.bins, ['gh']);
    assert.deepEqual(skills.github.install, [{ id: 'brew', kind: 'brew', label: 'Install GitHub CLI (brew)', bins: ['gh'] }]);
    assert.deepEqual(skills['video-frames'].install, [{ id: 'brew', kind: 'brew', label: 'Install ffmpeg (brew)', bins: ['ffmpeg'] }]);
    assert.deepEqual(skills.notion.missing.env, ['NOTION_API_KEY']);
    assert.equal(skills.notion.primaryEnv, 'NOTION_API_KEY');
    assert.deepEqual(skills['voice-call'].configChecks, [{ path: 'plugins.entries.voice-call.enabled', satisfied: false }]);
    assert.equal(skills['apple-notes'].eligible, true);
    assert.equal(skills['apt-updates'].platformIncompatible, true);
    assert.deepEqual(skills['apt-updates'].missing.os, ['linux']);
    assert.equal(skills.slack.disabled, true);
    assert.equal(skills.slack.eligible, false);
    assert.deepEqual(skills.slack.missing, { bins: [], anyBins: [], env: [], config: [], os: [] }, 'disabled but otherwise ready');
    assert.equal(skills['openai-image-gen'].blockedByAllowlist, true);
    assert.equal(skills['openai-image-gen'].eligible, false);
    assert.equal(skills.summarize.source, 'openclaw-managed');
    assert.equal(skills.summarize.bundled, false);
    assert.equal(skills.summarize.filePath, `${MANAGED_SKILLS_DIR}/summarize/SKILL.md`);
    assert.equal(skills['homelab-runbook'].source, 'openclaw-workspace');
    assert.equal(skills['homelab-runbook'].baseDir, '/Users/claw/.openclaw/workspace/skills/homelab-runbook');
    assert.equal(skills['nas-report'].clawhub.status, 'linked');
    assert.equal(skills['nas-report'].clawhub.installedVersion, '1.2.0');
    assert.equal(skills['nas-report'].clawhub.registry, CLAWHUB_REGISTRY);
    // research filters its skills: the rest are blockedByAgentFilter but still reported.
    const research = await reader.send('skills.status', { agentId: 'research' });
    assert.deepEqual(research.agentSkillFilter, ['weather', 'summarize', 'github', 'notion']);
    assert.equal(research.workspaceDir, '/Users/claw/.openclaw/workspace-research');
    assert.equal(byName(research)['homelab-runbook'].blockedByAgentFilter, true);
    assert.equal(byName(research)['homelab-runbook'].eligible, true, 'the agent filter does not change eligible');
    assert.equal(byName(research)['homelab-runbook'].modelVisible, false);
    assert.equal(byName(research).weather.blockedByAgentFilter, false);
    assert.equal((await reader.call('skills.status', { agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');
    assert.equal((await reader.call('skills.status', { sessionKey: 'agent:main:gone' })).error.message, 'Session not found.');
    assert.equal((await reader.send('skills.status', { sessionKey: 'agent:main:main' })).agentId, 'main');
    assert.match((await reader.call('skills.status', { extra: 1 })).error.message, /^invalid skills\.status params: at root: unexpected property 'extra'/);

    // skills.search / skills.detail.
    const trending = (await reader.send('skills.search', {})).results;
    assert.ok(trending.length >= 5);
    assert.ok(trending.every((r) => r.score === 0 && r.registry === CLAWHUB_REGISTRY));
    const nas = (await reader.send('skills.search', { query: 'nas' })).results;
    assert.equal(nas[0].slug, 'nas-report');
    assert.equal(nas[0].installRef, '@clawdia/nas-report');
    assert.equal(nas[0].version, '1.3.0');
    assert.equal(nas[0].ownerHandle, 'clawdia');
    const ext = (await reader.send('skills.search', { query: 'obsidian' })).results[0];
    assert.equal(ext.installOnly, true);
    assert.equal(ext.trustState, 'not-scanned-by-clawhub');
    assert.equal(ext.installRef, 'skills-sh:vaultsmith/obsidian-skills/obsidian-daily');
    assert.deepEqual((await reader.send('skills.search', { query: 'zzzz-nothing' })).results, []);
    assert.equal((await reader.send('skills.search', { query: 'a', limit: 2 })).results.length, 2);
    assert.match((await reader.call('skills.search', { limit: 0 })).error.message, /^invalid skills\.search params: at \/limit: must be >= 1/);
    assert.match((await reader.call('skills.search', { query: '' })).error.message, /at \/query: must NOT have fewer than 1 characters/);
    const detail = await reader.send('skills.detail', { slug: '@clawdia/nas-report' });
    assert.equal(detail.skill.slug, 'nas-report');
    assert.equal(detail.latestVersion.version, '1.3.0');
    assert.equal(detail.owner.handle, 'clawdia');
    assert.equal((await reader.send('skills.detail', { slug: 'home-assistant' })).skill.isOfficial, true);
    assert.match((await reader.call('skills.detail', { slug: ext.installRef })).error.message, /external skill sources are install-only/);
    const missingDetail = await reader.call('skills.detail', { slug: 'nope' });
    assert.equal(missingDetail.error.code, 'UNAVAILABLE');
    assert.match(missingDetail.error.message, /404/);

    // skills.install (gateway installer): the missing bin appears, the skill becomes eligible.
    const installed = await admin.send('skills.install', { name: 'github', installId: 'brew' });
    assert.equal(installed.ok, true);
    assert.equal(installed.message, 'Installed');
    assert.equal(installed.code, 0);
    assert.equal(byName(await reader.send('skills.status', {})).github.eligible, true);
    assert.equal((await admin.call('skills.install', { name: 'github', installId: 'apt' })).error.message, 'Installer not found: apt');
    assert.equal((await admin.call('skills.install', { name: 'nope', installId: 'brew' })).error.message, 'Skill not found: nope');
    assert.match((await admin.call('skills.install', { name: 'github' })).error.message, /must have required property 'installId'/);
    assert.match((await admin.call('skills.install', { source: 'clawhub', slug: 'x', bogus: 1 })).error.message, /unexpected property 'bogus'/);
    // ClawHub install lands in the agent's workspace, tracked.
    const ha = await admin.send('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' });
    assert.deepEqual(ha, { ok: true, message: 'Installed home-assistant@2.4.1', stdout: '', stderr: '', code: 0, slug: 'home-assistant', version: '2.4.1', targetDir: '/Users/claw/.openclaw/workspace/skills/home-assistant' });
    skills = byName(await reader.send('skills.status', {}));
    assert.equal(skills['home-assistant'].source, 'openclaw-workspace');
    assert.equal(skills['home-assistant'].clawhub.installedVersion, '2.4.1');
    assert.deepEqual(skills['home-assistant'].missing.env, ['HASS_TOKEN']);
    const again = await admin.call('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' });
    assert.equal(again.error.code, 'UNAVAILABLE');
    assert.match(again.error.message, /already installed/);
    assert.equal((await admin.send('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant', force: true })).ok, true);
    const extInstall = await admin.send('skills.install', { source: 'clawhub', slug: ext.installRef });
    assert.match(extInstall.warning, /not scanned by ClawHub/);

    // skills.update config: toggles and write-only keys (redacted in the reply).
    assert.deepEqual(await admin.send('skills.update', { skillKey: 'slack', enabled: true }), { ok: true, skillKey: 'slack', config: { enabled: true } });
    assert.equal(byName(await reader.send('skills.status', {})).slack.eligible, true);
    const keyed = await admin.send('skills.update', { skillKey: 'notion', apiKey: '  ntn_secret  ' });
    assert.deepEqual(keyed.config, { apiKey: '__OPENCLAW_REDACTED__' });
    assert.equal(byName(await reader.send('skills.status', {})).notion.eligible, true, 'apiKey satisfies primaryEnv');
    assert.deepEqual((await admin.send('skills.update', { skillKey: 'notion', apiKey: '__OPENCLAW_REDACTED__' })).config, { apiKey: '__OPENCLAW_REDACTED__' }, 'sentinel keeps the key');
    assert.deepEqual((await admin.send('skills.update', { skillKey: 'notion', apiKey: '' })).config, {}, 'empty clears the key');
    assert.equal(byName(await reader.send('skills.status', {})).notion.eligible, false);
    const envd = await admin.send('skills.update', { skillKey: 'home-assistant', env: { HASS_TOKEN: 'abc', HASS_URL: 'http://ha.local:8123' } });
    assert.deepEqual(envd.config, { env: { HASS_TOKEN: '__OPENCLAW_REDACTED__', HASS_URL: 'http://ha.local:8123' } });
    assert.equal(byName(await reader.send('skills.status', {})).notion.disabled, false);
    assert.match((await admin.call('skills.update', { skillKey: 'slack', enabled: 'yes' })).error.message, /at \/enabled: must be boolean/);

    // skills.update ClawHub: nas-report has an update; grocery-list was edited locally.
    assert.equal((await admin.call('skills.update', { source: 'clawhub' })).error.message, 'clawhub skills.update requires "slug" or "all"');
    assert.equal((await admin.call('skills.update', { source: 'clawhub', slug: 'nas-report', all: true })).error.message, 'clawhub skills.update accepts either "slug" or "all", not both');
    const updated = await admin.send('skills.update', { source: 'clawhub', slug: 'nas-report' });
    assert.deepEqual(updated, { ok: true, skillKey: 'nas-report', config: { source: 'clawhub', results: [{ ok: true, slug: 'nas-report', previousVersion: '1.2.0', version: '1.3.0', changed: true, targetDir: '/Users/claw/.openclaw/workspace/skills/nas-report' }] } });
    assert.equal(byName(await reader.send('skills.status', {}))['nas-report'].clawhub.installedVersion, '1.3.0');
    const blocked = await admin.call('skills.update', { source: 'clawhub', slug: 'grocery-list' });
    assert.equal(blocked.error.code, 'UNAVAILABLE');
    assert.equal(blocked.error.details.results[0].code, 'force_required');
    assert.match(blocked.error.message, /Updating replaces the installed skill directory\.$/);
    const forced = await admin.send('skills.update', { source: 'clawhub', slug: 'grocery-list', force: true });
    assert.deepEqual(forced.config.results[0], { ok: true, slug: 'grocery-list', previousVersion: '0.9.0', version: '1.0.0', changed: true, targetDir: '/Users/claw/.openclaw/workspace/skills/grocery-list' });
    const all = await admin.send('skills.update', { source: 'clawhub', all: true });
    assert.equal(all.skillKey, '*');
    assert.ok(all.config.results.every((r) => r.ok));
    assert.equal(all.config.results.find((r) => r.slug === 'nas-report').changed, false);
    const untracked = await admin.call('skills.update', { source: 'clawhub', slug: 'weather' });
    assert.match(untracked.error.message, /not installed from ClawHub/);

    // tools.catalog.
    const catalog = await reader.send('tools.catalog', {});
    assert.equal(catalog.agentId, 'main');
    assert.deepEqual(catalog.profiles.map((p) => p.id), ['minimal', 'coding', 'messaging', 'full']);
    assert.deepEqual(catalog.groups.slice(0, 3).map((g) => [g.id, g.label, g.source]), [['fs', 'Files', 'core'], ['runtime', 'Runtime', 'core'], ['web', 'Web', 'core']]);
    const exec = catalog.groups.find((g) => g.id === 'runtime').tools.find((t) => t.id === 'exec');
    assert.deepEqual(exec.defaultProfiles, ['coding']);
    const pluginGroups = catalog.groups.filter((g) => g.source === 'plugin');
    assert.ok(pluginGroups.length >= 1 && pluginGroups.every((g) => g.pluginId));
    assert.equal(pluginGroups.flatMap((g) => g.tools).find((t) => t.id === 'voice_call').optional, true);
    assert.ok(!(await reader.send('tools.catalog', { agentId: 'coder', includePlugins: false })).groups.some((g) => g.source === 'plugin'));
    assert.equal((await reader.call('tools.catalog', { agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');

    // tools.effective: allowed + excluded with reasons, session overrides, notices.
    const eff = await reader.send('tools.effective', { sessionKey: 'agent:main:main' });
    assert.equal(eff.agentId, 'main');
    assert.equal(eff.profile, 'coding');
    assert.deepEqual(eff.groups.map((g) => g.source), ['core', 'plugin', 'mcp']);
    const effIds = eff.groups.flatMap((g) => g.tools.map((t) => t.id));
    assert.ok(effIds.includes('exec') && effIds.includes('read') && !effIds.includes('x_search') && !effIds.includes('browser'));
    const mcpTool = eff.groups.find((g) => g.source === 'mcp').tools[0];
    assert.equal(mcpTool.mcpServer, 'home-assistant');
    for (const tool of eff.groups.flatMap((g) => g.tools)) assert.equal(typeof tool.rawDescription, 'string');
    const access = Object.fromEntries(eff.toolAccess.tools.map((t) => [t.id, t]));
    assert.equal(eff.toolAccess.checked, 'live-session');
    assert.deepEqual(eff.toolAccess.profiles, [{ profile: 'coding', source: 'tools.profile', active: true }]);
    assert.deepEqual(access.read, { id: 'read', status: 'available', reasons: [] });
    assert.deepEqual(access.x_search, { id: 'x_search', status: 'excluded', reasons: [{ kind: 'deny', label: 'Denied by tools.deny', source: 'tools.deny' }] });
    assert.deepEqual(access.browser, { id: 'browser', status: 'excluded', reasons: [{ kind: 'profile', label: 'coding profile', source: 'tools.profile', profile: 'coding' }], alsoAllowPath: 'tools.alsoAllow' });
    assert.ok(eff.notices.some((n) => n.id === 'browser-filtered-by-profile' && n.severity === 'info'));
    assert.ok(eff.notices.some((n) => n.severity === 'warning' && n.servers?.length));
    const discord = await reader.send('tools.effective', { sessionKey: 'agent:main:discord:channel:123' });
    const discordExec = discord.groups.find((g) => g.id === 'core').tools.find((t) => t.id === 'exec');
    assert.equal(discordExec.deniedBySession, true);
    assert.equal(discord.toolAccess.tools.find((t) => t.id === 'exec').reasons[0].kind, 'session');
    assert.equal(discord.groups.find((g) => g.source === 'channel').tools[0].channelId, 'discord');
    const scout = await reader.send('tools.effective', { sessionKey: 'agent:research:main' });
    assert.deepEqual(scout.toolAccess.tools.find((t) => t.id === 'exec').reasons, [{ kind: 'allowlist', label: 'Not included in agents.entries.research.tools.allow', source: 'agents.entries.research.tools.allow' }]);
    const forge = await reader.send('tools.effective', { sessionKey: 'agent:coder:main', agentId: 'coder' });
    assert.equal(forge.profile, 'full');
    assert.equal(forge.notices, undefined);
    assert.ok(forge.toolAccess.tools.every((t) => t.status === 'available'));
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:gone' })).error.message, 'unknown session key "agent:main:gone"');
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:main', agentId: 'coder' })).error.message, 'agent id "coder" does not match session agent "main"');
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:main', agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');
    assert.match((await reader.call('tools.effective', {})).error.message, /^invalid tools\.effective params: at root: must have required property 'sessionKey'/);
    reader.ws.close();
    admin.ws.close();
  } finally {
    await skillsServer.close();
  }

  // MOCK_CLAWHUB_OFFLINE=1: status still works, ClawHub calls are UNAVAILABLE.
  process.env.MOCK_CLAWHUB_OFFLINE = '1';
  const offlineServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${offlineServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    assert.ok((await client.send('skills.status', {})).skills.length > 0);
    assert.equal((await client.call('skills.search', { query: 'nas' })).error.code, 'UNAVAILABLE');
    assert.equal((await client.call('skills.install', { source: 'clawhub', slug: '@clawdia/pi-fleet' })).error.code, 'UNAVAILABLE');
    client.ws.close();
  } finally {
    delete process.env.MOCK_CLAWHUB_OFFLINE;
    await offlineServer.close();
  }

  // MOCK_NO_SKILLS=1 / MOCK_NO_TOOLS=1: an older Gateway without these methods.
  process.env.MOCK_NO_SKILLS = '1';
  process.env.MOCK_NO_TOOLS = '1';
  const legacyServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const legacy = await connectClient(`ws://127.0.0.1:${legacyServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    for (const method of [...SKILLS_METHODS, ...TOOLS_METHODS]) {
      assert.ok(!legacy.hello.features.methods.includes(method), method);
      assert.equal((await legacy.call(method, {})).error.code, 'UNKNOWN_METHOD', method);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_SKILLS;
    delete process.env.MOCK_NO_TOOLS;
    await legacyServer.close();
  }
}

const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', mockToken: 'dev-token' });
try {
  const port = server.address().port;
  const url = `ws://127.0.0.1:${port}`;
  const device = makeDevice();

  const first = await connectClient(url, device, 'dev-token', false);
  assert.equal(first.connectRes.error.code, 'NOT_PAIRED');
  assert.equal(first.connectRes.error.details.code, 'PAIRING_REQUIRED');
  first.ws.close();

  await delay(3500);

  const paired = await connectClient(url, device, 'dev-token', true);
  const deviceToken = paired.hello.auth.deviceToken;
  assert.match(deviceToken, /^dt_/);
  paired.ws.close();

  const client = await connectClient(url, device, deviceToken, true);
  assert.equal(client.hello.auth.deviceToken, deviceToken);

  const agents = await client.send('agents.list');
  assert.equal(agents.defaultId, 'main');
  assert.ok(agents.agents.some((a) => a.id === 'research'));

  const scoutIdentity = await client.send('agent.identity.get', { agentId: 'research' });
  assert.deepEqual(scoutIdentity, { agentId: 'research', name: 'Scout', nameSource: 'agent', emoji: '🔭', avatar: '🔭' });
  const mainIdentity = await client.send('agent.identity.get', { sessionKey: 'agent:main:main' });
  assert.equal(mainIdentity.agentId, 'main');
  assert.equal(mainIdentity.name, 'Claw');

  const sessions = await client.send('sessions.subscribe', { limit: 20 });
  assert.ok(sessions.list.sessions.some((s) => s.key === 'agent:main:main'));

  const history = await client.send('chat.history', { sessionKey: 'agent:main:main', limit: 20 });
  const blocks = history.messages.flatMap((m) => m.content);
  assert.ok(blocks.some((b) => b.type === 'thinking'));
  assert.ok(blocks.some((b) => b.type === 'toolCall'));
  assert.ok(blocks.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));

  const artifact = await client.send('artifacts.download', { sessionKey: 'agent:main:main', artifactId: 'art-chart-1' });
  const png = Buffer.from(artifact.data, 'base64');
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');

  await client.send('sessions.messages.subscribe', { key: 'agent:main:main' });
  let deltaCount = 0;
  let sawTool = false;
  client.emitter.on('chat', (payload) => {
    if (payload.state === 'delta' && payload.deltaText !== undefined) deltaCount += 1;
  });
  client.emitter.on('agent', (payload) => {
    if (payload.stream === 'tool' && payload.data?.phase === 'result') sawTool = true;
  });

  const started = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'show me a tool and an image',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.match(started.runId, /^run_/);
  const final = await client.waitEvent('chat', (p) => p.runId === started.runId && p.state === 'final', 10_000);
  assert.ok(final.message.content.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));
  assert.ok(deltaCount > 0, 'expected chat deltas');
  assert.equal(sawTool, true, 'expected tool result event');

  // File-mutating tools: upstream-shaped `edit`/`write`/`apply_patch` calls with their `details` receipts.
  const retryKey = 'agent:coder:dashboard:retry-fix';
  const retryHistory = (await client.send('chat.history', { sessionKey: retryKey })).messages;
  const retryCalls = retryHistory.flatMap((m) => m.content.filter((b) => b.type === 'toolCall'));
  assert.deepEqual(retryCalls.map((c) => c.name), ['edit', 'write', 'apply_patch']);
  const resultFor = (id) => retryHistory.find((m) => m.role === 'toolResult' && m.toolCallId === id);
  const [editCall, writeCall, patchCall] = retryCalls;
  assert.equal(editCall.arguments.path, fileEdits.RETRY_PATH);
  assert.equal(editCall.arguments.edits.length, 2);
  const editDetails = resultFor(editCall.id).details;
  assert.equal(editDetails.changed, true);
  assert.equal(applyUnified(fileEdits.RETRY_BEFORE, editDetails.patch), fileEdits.RETRY_AFTER, 'edit receipt patch reproduces the edit');
  assert.equal((editDetails.patch.match(/^@@ /gm) ?? []).length, 2, 'two edits, two hunks');
  assert.match(editDetails.diff, /^\+ ?\d+ import \{ isRetryable \}/m);
  assert.equal(editDetails.firstChangedLine, 1);
  const writeDetails = resultFor(writeCall.id).details;
  assert.equal(writeDetails.created, true);
  assert.equal(writeCall.arguments.content, fileEdits.RETRY_TEST);
  assert.match(writeDetails.patch, /^@@ -0,0 \+1,17 @@$/m);
  assert.equal(applyUnified('', writeDetails.patch), fileEdits.RETRY_TEST);
  const patchInput = patchCall.arguments.input;
  assert.ok(patchInput.startsWith('*** Begin Patch\n') && patchInput.endsWith('\n*** End Patch'));
  for (const marker of ['*** Update File: src/net/client.ts', '*** Move to: src/net/http-errors.ts', '*** Add File: docs/retry.md', '*** Delete File: src/net/legacy-retry.ts']) {
    assert.ok(patchInput.includes(marker), marker);
  }
  assert.equal((patchInput.match(/^@@/gm) ?? []).length, 4);
  const patchResult = resultFor(patchCall.id);
  assert.deepEqual(patchResult.details.summary, fileEdits.CLIENT_PATCH_SUMMARY);
  assert.match(patchResult.content[0].text, /^Success\. Updated the following files:\nA docs\/retry\.md\nM src\/net\/client\.ts/);

  await client.send('sessions.messages.subscribe', { key: retryKey });
  const editStart = client.waitEvent('agent', (p) => p.sessionKey === retryKey && p.stream === 'tool' && p.data.phase === 'start' && p.data.name === 'edit');
  const editDone = client.waitEvent('agent', (p) => p.sessionKey === retryKey && p.stream === 'tool' && p.data.phase === 'result' && p.data.name === 'edit');
  const editRun = await client.send('chat.send', { sessionKey: retryKey, message: 'show me the config patch', idempotencyKey: `idem_${crypto.randomUUID()}` });
  const editStarted = await editStart;
  assert.equal(editStarted.data.args.path, 'config/retry.json');
  assert.equal(typeof editStarted.data.args.oldText, 'string');
  assert.equal(typeof editStarted.data.args.newText, 'string');
  const done = await editDone;
  assert.equal(done.data.toolCallId, editStarted.data.toolCallId);
  assert.match(done.data.result.content[0].text, /^Successfully replaced 1 block\(s\) in config\/retry\.json\.$/);
  assert.match(done.data.result.details.patch, /^@@ -1,4 \+1,4 @@$/m);
  await client.waitEvent('chat', (p) => p.runId === editRun.runId && p.state === 'final', 10_000);
  const afterEdit = (await client.send('chat.history', { sessionKey: retryKey })).messages;
  const liveResult = afterEdit.find((m) => m.role === 'toolResult' && m.toolCallId === done.data.toolCallId);
  assert.deepEqual(liveResult?.details, done.data.result.details, 'live edit persisted with its receipt');

  // Test hooks for failed sends: one refused, one that drops the connection.
  const refused = await client.call('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'nope [mock:fail-send]',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.equal(refused.ok, false);
  assert.equal(refused.error.code, 'UNAVAILABLE');
  const dropped = await connectClient(url, device, deviceToken, true);
  const closed = new Promise((resolve) => dropped.ws.once('close', resolve));
  dropped.call('chat.send', { sessionKey: 'agent:main:main', message: 'bye [mock:drop]', idempotencyKey: `idem_${crypto.randomUUID()}` });
  assert.equal(await closed, 1012);
  const afterHooks = await client.send('chat.history', { sessionKey: 'agent:main:main' });
  assert.ok(!afterHooks.messages.some((m) => JSON.stringify(m.content).includes('[mock:')), 'hooked sends leave no messages');

  // `[mock:fail-run]` ends the run with a chat `error` and an `error` lifecycle phase, like a provider timeout.
  const failedChat = client.waitEvent('chat', (p) => p.sessionKey === 'agent:research:main' && p.state === 'error', 10_000);
  const failedLifecycle = client.waitEvent('agent', (p) => p.sessionKey === 'agent:research:main' && p.stream === 'lifecycle' && p.data?.phase === 'error', 10_000);
  const failing = await client.send('chat.send', {
    sessionKey: 'agent:research:main',
    message: 'this one breaks [mock:fail-run]',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const failed = await failedChat;
  assert.equal(failed.runId, failing.runId);
  assert.equal(failed.errorKind, 'timeout');
  assert.ok(failed.errorMessage);
  assert.equal((await failedLifecycle).runId, failing.runId);

  // Replies: replyToId persists the quoted target's id and a preview, like upstream.
  const quotedTarget = afterHooks.messages.find((m) => m.role === 'assistant' && m.content.some((b) => b.type === 'text'));
  const replyRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'replying to that',
    replyToId: quotedTarget.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === replyRun.runId && p.state === 'final', 10_000);
  const afterReply = await client.send('chat.history', { sessionKey: 'agent:main:main' });
  const replyEntry = afterReply.messages.find((m) => m.__openclaw?.runId === replyRun.runId && m.role === 'user');
  assert.equal(replyEntry.__openclaw.replyToId, quotedTarget.__openclaw.id);
  assert.equal(replyEntry.__openclaw.replyToPreview.senderLabel, 'Claw');
  assert.ok(replyEntry.__openclaw.replyToPreview.text.length > 0);
  assert.ok(replyEntry.__openclaw.replyToPreview.text.length <= 2000);
  const ownTarget = afterReply.messages.find((m) => m.role === 'user' && m.__openclaw?.id);
  const ownRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main', message: 'about my own message', replyToId: ownTarget.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === ownRun.runId && p.state === 'final', 10_000);
  const unknownRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main', message: 'unknown target', replyToId: 'pending:nope',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === unknownRun.runId && p.state === 'final', 10_000);
  const afterOwn = (await client.send('chat.history', { sessionKey: 'agent:main:main' })).messages;
  assert.equal(afterOwn.find((m) => m.__openclaw?.runId === ownRun.runId && m.role === 'user').__openclaw.replyToPreview.senderLabel,
    'Pincer Selftest');
  assert.equal(afterOwn.find((m) => m.__openclaw?.runId === unknownRun.runId && m.role === 'user').__openclaw.replyToId, undefined,
    'unknown targets send without reply metadata');
  // MOCK_NO_REPLY_TO=1 is a Gateway from before replies.
  process.env.MOCK_NO_REPLY_TO = '1';
  try {
    const noReply = await client.call('chat.send', {
      sessionKey: 'agent:main:main', message: 'x', replyToId: quotedTarget.__openclaw.id, idempotencyKey: `idem_${crypto.randomUUID()}`,
    });
    assert.equal(noReply.error.code, 'INVALID_REQUEST');
    assert.equal(noReply.error.message, "invalid chat.send params: at root: unexpected property 'replyToId'");
  } finally {
    delete process.env.MOCK_NO_REPLY_TO;
  }

  // Reactions: the seeded Discord message has its channel id, the agent reacted 👀 with `message`,
  // and message.action reacts on Discord only.
  assert.ok(client.hello.features.methods.includes('message.action'));
  const lab = (await client.send('chat.history', { sessionKey: 'agent:main:discord:channel:123' })).messages;
  const sensor = lab.find((m) => m.__openclaw?.transport?.messageId === '1300000000000000001');
  assert.equal(sensor.__openclaw.transport.channel, 'discord');
  assert.equal(sensor.__openclaw.transport.conversationRef, 'channel:123');
  const ackCall = lab.flatMap((m) => m.content).find((b) => b.type === 'toolCall' && b.name === 'message');
  assert.deepEqual(ackCall.arguments, { action: 'react', emoji: '👀', messageId: '1300000000000000001' });
  const reactKey = `idem_${crypto.randomUUID()}`;
  const reactParams = {
    channel: 'discord', action: 'react', sessionKey: 'agent:main:discord:channel:123',
    params: { messageId: '1300000000000000001', emoji: '👍', to: 'channel:123' }, idempotencyKey: reactKey,
  };
  assert.deepEqual(await client.send('message.action', reactParams), { ok: true, added: '👍' });
  assert.deepEqual(await client.send('message.action', reactParams), { ok: true, added: '👍' }, 'idempotent');
  assert.equal(server.state.reactionLog.length, 1);
  assert.deepEqual(await client.send('message.action', {
    ...reactParams, params: { ...reactParams.params, remove: true }, idempotencyKey: `idem_${crypto.randomUUID()}`,
  }), { ok: true, removed: '👍' });
  assert.equal((await client.call('message.action', { ...reactParams, channel: 'webchat', idempotencyKey: `idem_${crypto.randomUUID()}` }))
    .error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('message.action', { ...reactParams, action: 'pin', idempotencyKey: `idem_${crypto.randomUUID()}` }))
    .error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('message.action', { channel: 'discord', action: 'react', params: {} })).error.code, 'INVALID_REQUEST');
  for (const params of [{ messageId: '1300000000000000001' }, { emoji: '👍' }, { messageId: '', emoji: '👍' }]) {
    const missing = await client.call('message.action', { ...reactParams, params, idempotencyKey: `idem_${crypto.randomUUID()}` });
    assert.equal(missing.error.code, 'INVALID_REQUEST', `react without ${JSON.stringify(params)} is rejected`);
  }
  assert.equal((await client.call('message.action', { ...reactParams, idempotencyKey: undefined })).error.code, 'INVALID_REQUEST',
    'idempotencyKey is required');
  assert.equal(server.state.reactionLog.length, 2, 'only accepted reactions are logged');
  assert.deepEqual(server.state.reactionLog.map((entry) => [entry.emoji, entry.remove ?? false]), [['👍', false], ['👍', true]]);

  // Reply previews are cut to 2000 characters, like upstream.
  const report = (await client.send('chat.history', { sessionKey: 'agent:research:main' })).messages
    .find((m) => m.role === 'assistant' && JSON.stringify(m.content).includes('Long report'));
  const reportRun = await client.send('chat.send', {
    sessionKey: 'agent:research:main', message: 'about the report', replyToId: report.__openclaw.id,
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === reportRun.runId && p.state === 'final', 10_000);
  const reportReply = (await client.send('chat.history', { sessionKey: 'agent:research:main' })).messages
    .find((m) => m.__openclaw?.runId === reportRun.runId && m.role === 'user');
  assert.equal(reportReply.__openclaw.replyToPreview.text.length, 2000);
  assert.ok(reportReply.__openclaw.replyToPreview.text.startsWith('## Long report'));
  assert.equal(reportReply.__openclaw.replyToPreview.senderLabel, 'Scout');

  // Web Push: finished replies and approvals are encrypted to the subscription's keys.
  const pushed = [];
  const pushSink = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      pushed.push({ path: req.url, headers: req.headers, body: Buffer.concat(chunks) });
      res.writeHead(201).end();
    });
  });
  await new Promise((resolve) => pushSink.listen(0, '127.0.0.1', resolve));
  const receiver = crypto.createECDH('prime256v1');
  receiver.generateKeys();
  const pushKeys = { p256dh: b64url(receiver.getPublicKey()), auth: b64url(crypto.randomBytes(16)) };
  const endpoint = `http://127.0.0.1:${pushSink.address().port}/v1/push/abc/gw`;
  assert.equal((await client.call('push.web.subscribe', { endpoint: 'http://example.com/x', keys: pushKeys })).ok, false);
  assert.equal((await client.call('push.web.subscribe', { endpoint, keys: { p256dh: 'short', auth: 'x' } })).ok, false);
  const subscribed = await client.send('push.web.subscribe', { endpoint, keys: pushKeys });
  assert.ok(subscribed.subscriptionId);
  assert.equal((await client.send('push.web.subscribe', { endpoint, keys: pushKeys })).subscriptionId, subscribed.subscriptionId,
    'subscribe upserts by endpoint');
  const pushedRun = await client.send('chat.send', {
    sessionKey: 'agent:main:discord:channel:123',
    message: 'hello push',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  await client.waitEvent('chat', (p) => p.runId === pushedRun.runId && p.state === 'final', 10_000);
  await waitUntil(() => pushed.length >= 1, 3000, 'web push delivery');
  const [delivery] = pushed;
  assert.equal(delivery.path, '/v1/push/abc/gw');
  assert.equal(delivery.headers['content-encoding'], 'aes128gcm');
  assert.equal(delivery.headers.ttl, '300');
  assert.match(delivery.headers.topic, /^[\w-]{32}$/);
  assert.match(delivery.headers.authorization, /^vapid t=/);
  const message = JSON.parse(decryptWebPush(delivery.body, { privateKey: receiver.getPrivateKey(), auth: pushKeys.auth }).toString('utf8'));
  assert.equal(message.title, 'OpenClaw agent finished');
  assert.equal(message.url, 'chat/main/discord/channel/123');
  assert.equal(message.tag, `openclaw-agent-finished-${pushedRun.runId}`);
  assert.ok(!JSON.stringify(message).includes('hello push'), 'push carries no message content');
  assert.equal(sessionPath('agent:main:main'), 'chat/main');
  assert.equal(sessionPath('agent:research:dashboard'), 'chat/research/~key/dashboard');
  const requestedP = client.waitEvent('exec.approval.requested');
  const approvalRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'please approve this',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const requested = await requestedP;
  await client.waitEvent('chat', (p) => p.runId === approvalRun.runId && p.state === 'final', 10_000);
  await waitUntil(() => pushed.length >= 3, 3000, 'approval web push');
  const approvalPushes = pushed.slice(1).map((p) => JSON.parse(decryptWebPush(p.body, { privateKey: receiver.getPrivateKey(), auth: pushKeys.auth })));
  const approvalPush = approvalPushes.find((p) => p.tag === `openclaw-approval-${requested.id}`);
  assert.equal(approvalPush.url, `approve/${requested.id}`);
  assert.equal(approvalPush.title, 'OpenClaw approval requested');
  assert.equal(pushed.find((p) => p.headers.urgency === 'high')?.headers.ttl, '120');
  const pendingLookup = await client.send('approval.get', { id: requested.id });
  assert.equal(pendingLookup.approval.status, 'pending');
  assert.equal(pendingLookup.approval.presentation.commandText, 'rm -rf ./build');
  assert.ok(!JSON.stringify(pendingLookup).includes('/home/claw'), 'approval snapshots never carry cwd');
  await client.send('exec.approval.resolve', { id: requested.id, decision: 'deny' });
  assert.deepEqual(requested.request.allowedDecisions, ['allow-once', 'allow-always', 'deny']);
  // Identical retry is idempotent; a conflicting one is already resolved (openclaw approval-shared.ts).
  assert.equal((await client.send('exec.approval.resolve', { id: requested.id, decision: 'deny' })).ok, true);
  const conflicting = await client.call('exec.approval.resolve', { id: requested.id, decision: 'allow-once' });
  assert.equal(conflicting.ok, false);
  assert.equal(conflicting.error.code, 'INVALID_REQUEST');
  assert.equal(conflicting.error.message, 'approval already resolved');
  assert.equal(conflicting.error.details.reason, 'APPROVAL_ALREADY_RESOLVED');
  assert.ok(!(await client.send('exec.approval.list')).approvals.some((a) => a.id === requested.id));
  const unknown = await client.call('exec.approval.resolve', { id: 'approval_missing', decision: 'allow-once' });
  assert.equal(unknown.ok, false);
  assert.equal(unknown.error.code, 'INVALID_REQUEST');
  assert.equal(unknown.error.message, 'approval expired or not found');
  assert.equal(unknown.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal((await client.call('exec.approval.resolve', { id: 'approval_missing', decision: 'maybe' })).error.message, 'invalid decision');

  // Approval history: newest-first terminal ledger with opaque cursors and a kind filter.
  const seededTotal = Object.values(SEEDED_HISTORY_COUNTS).reduce((a, b) => a + b, 0);
  assert.ok(client.hello.features.methods.includes('approval.history'));
  assert.ok(client.hello.features.methods.includes('approval.get'));
  const page1 = await client.send('approval.history', {});
  assert.equal(page1.items.length, 50, 'default limit is 50');
  assert.ok(page1.nextCursor);
  const page2 = await client.send('approval.history', { cursor: page1.nextCursor });
  assert.equal(page2.nextCursor, undefined);
  const allItems = [...page1.items, ...page2.items];
  assert.equal(allItems.length, seededTotal + 1, 'seeded history plus the approval just resolved');
  assert.equal(new Set(allItems.map((r) => r.id)).size, allItems.length, 'no duplicates across pages');
  assert.ok(allItems.every((r, i) => i === 0 || allItems[i - 1].resolvedAtMs >= r.resolvedAtMs), 'newest first');
  assert.ok(allItems.every((r) => r.status !== 'pending' && !('cwd' in r.presentation)));
  assert.deepEqual(new Set(allItems.map((r) => r.status)), new Set(['allowed', 'denied', 'expired', 'cancelled']));
  assert.deepEqual(new Set(allItems.map((r) => r.resolver?.kind ?? 'none')), new Set(['device', 'channel', 'runtime', 'system', 'none']));
  const [top] = page1.items;
  assert.equal(top.id, requested.id, 'resolved approval is at the top');
  assert.equal(top.status, 'denied');
  assert.equal(top.decision, 'deny');
  assert.equal(top.reason, 'user');
  assert.deepEqual(top.resolver, { kind: 'device', id: device.id });
  assert.deepEqual(top.source, { agentId: 'main', sessionKey: 'agent:main:main' });
  const resolvedLookup = await client.send('approval.get', { id: requested.id });
  assert.equal(resolvedLookup.approval.status, 'denied');
  assert.equal((await client.send('approval.history', { limit: 100 })).items.length, seededTotal + 1);
  assert.equal((await client.call('approval.history', { limit: 101 })).error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('approval.history', { limit: 0 })).error.code, 'INVALID_REQUEST');
  assert.equal((await client.call('approval.history', { kind: 'bogus' })).error.code, 'INVALID_REQUEST');
  for (const kind of ['exec', 'plugin', 'system-agent']) {
    const expected = SEEDED_HISTORY_COUNTS[kind] + (kind === 'exec' ? 1 : 0);
    const small1 = await client.send('approval.history', { kind, limit: 7 });
    assert.ok(small1.items.every((r) => r.presentation.kind === kind), `${kind} filter`);
    const filtered = [...small1.items];
    let cursor = small1.nextCursor;
    while (cursor) {
      const next = await client.send('approval.history', { kind, limit: 7, cursor });
      assert.ok(next.items.every((r) => r.presentation.kind === kind));
      filtered.push(...next.items);
      cursor = next.nextCursor;
    }
    assert.equal(filtered.length, expected, `${kind} total`);
    assert.equal(new Set(filtered.map((r) => r.id)).size, expected);
  }
  const execCursor = (await client.send('approval.history', { kind: 'exec', limit: 5 })).nextCursor;
  const kindMismatch = await client.call('approval.history', { kind: 'plugin', cursor: execCursor });
  assert.equal(kindMismatch.error.code, 'INVALID_REQUEST', 'cursor is bound to its filter');
  for (const cursor of ['not-a-cursor', Buffer.from('{"v":1,"after":"nope"}').toString('base64url')]) {
    const badCursor = await client.call('approval.history', { cursor });
    assert.equal(badCursor.ok, false);
    assert.equal(badCursor.error.code, 'INVALID_REQUEST');
    assert.equal(badCursor.error.message, 'invalid approval.history cursor');
  }
  const plugin = allItems.find((r) => r.presentation.kind === 'plugin');
  assert.deepEqual((await client.send('approval.get', { id: plugin.id })).approval, plugin, 'approval.get round-trips a history row');
  const system = allItems.find((r) => r.presentation.kind === 'system-agent');
  assert.deepEqual((await client.send('approval.get', { id: system.id })).approval, system);
  const missing = await client.call('approval.get', { id: 'approval_missing' });
  assert.equal(missing.error.code, 'INVALID_REQUEST');
  assert.equal(missing.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal((await client.send('push.web.unsubscribe', { endpoint })).removed, true);
  pushSink.close();

  // `approve once-only` leaves allow-always out; asking for it anyway keeps the approval pending.
  const onceOnlyP = client.waitEvent('exec.approval.requested');
  const onceOnlyRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'approve once-only',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const onceOnly = await onceOnlyP;
  assert.deepEqual(onceOnly.request.allowedDecisions, ['allow-once', 'deny']);
  const always = await client.call('exec.approval.resolve', { id: onceOnly.id, decision: 'allow-always' });
  assert.equal(always.ok, false);
  assert.equal(always.error.code, 'INVALID_REQUEST');
  assert.equal(always.error.message, 'allow-always is unavailable for this command');
  assert.equal(always.error.details.reason, 'APPROVAL_ALLOW_ALWAYS_UNAVAILABLE');
  assert.ok((await client.send('exec.approval.list')).approvals.some((a) => a.id === onceOnly.id), 'still pending');
  const onceResolvedEvent = client.waitEvent('exec.approval.resolved', (p) => p.id === onceOnly.id);
  assert.equal((await client.send('exec.approval.resolve', { id: onceOnly.id, decision: 'allow-once' })).ok, true);
  assert.equal((await onceResolvedEvent).decision, 'allow-once');
  await client.waitEvent('chat', (p) => p.runId === onceOnlyRun.runId && p.state === 'final', 10_000);

  // `approve short-lived` expires after 3 s and then reads as not found.
  const shortP = client.waitEvent('exec.approval.requested');
  const shortRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'approve short-lived',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const shortLived = await shortP;
  assert.ok(shortLived.expiresAtMs - shortLived.createdAtMs <= 3_000);
  await client.waitEvent('chat', (p) => p.runId === shortRun.runId && p.state === 'final', 10_000);
  await delay(Math.max(0, shortLived.expiresAtMs - Date.now()) + 50);
  assert.ok(!(await client.send('exec.approval.list')).approvals.some((a) => a.id === shortLived.id), 'expired approval is not listed');
  const expired = await client.call('exec.approval.resolve', { id: shortLived.id, decision: 'deny' });
  assert.equal(expired.error.details.reason, 'APPROVAL_NOT_FOUND');
  assert.equal(expired.error.message, 'approval expired or not found');

  const asked = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'ask me something',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const askedPrompt = await client.waitEvent('question.requested', (p) => p.runId === asked.runId);
  assert.equal(askedPrompt.status, 'pending');
  assert.equal(askedPrompt.sessionKey, 'agent:main:main');
  assert.equal(askedPrompt.questions[0].questionId, 'discord_remove');
  assert.equal(askedPrompt.questions[0].options.length, 3);
  assert.equal(askedPrompt.questions[0].isOther, true);
  const listed = await client.send('question.list');
  assert.ok(listed.questions.some((q) => q.id === askedPrompt.id));
  const incomplete = await client.call('question.resolve', { id: askedPrompt.id, answers: { answers: {} } });
  assert.equal(incomplete.error.details.reason, 'QUESTION_INVALID_ANSWER');
  const resolvedEvent = client.waitEvent('question.resolved', (p) => p.id === askedPrompt.id);
  const resolution = await client.send('question.resolve', {
    id: askedPrompt.id,
    answers: { answers: { discord_remove: ['Stop watching Discord channels here'] } },
  });
  assert.equal(resolution.status, 'answered');
  assert.deepEqual((await resolvedEvent).answers.answers.discord_remove, ['Stop watching Discord channels here']);
  const askedFinal = await client.waitEvent('chat', (p) => p.runId === asked.runId && p.state === 'final', 10_000);
  assert.ok(askedFinal.message.content.some((b) => b.type === 'text' && b.text.includes('Stop watching Discord channels here')));
  const resolvedAgain = await client.call('question.resolve', { id: askedPrompt.id, cancel: true });
  assert.equal(resolvedAgain.error.details.reason, 'QUESTION_ALREADY_TERMINAL');
  assert.equal((await client.call('question.resolve', { id: 'ask_missing', cancel: true })).error.details.reason, 'QUESTION_NOT_FOUND');

  // Skipping cancels the prompt and the run carries on.
  const skippedRun = await client.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'ask again',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const skippedPrompt = await client.waitEvent('question.requested', (p) => p.runId === skippedRun.runId);
  assert.equal((await client.send('question.resolve', { id: skippedPrompt.id, cancel: true })).status, 'cancelled');
  const skippedFinal = await client.waitEvent('chat', (p) => p.runId === skippedRun.runId && p.state === 'final', 10_000);
  assert.ok(skippedFinal.message.content.some((b) => b.type === 'text' && b.text.includes('skipping')));

  // Config and plugins: reads need operator.read, writes operator.admin.
  const snapshot = await client.send('config.get');
  assert.equal(snapshot.valid, true, JSON.stringify(snapshot.issues));
  assert.equal(snapshot.config.gateway.auth.token, '__OPENCLAW_REDACTED__');
  const schema = await client.send('config.schema');
  assert.equal(schema.uiHints['gateway.auth.token'].sensitive, true);
  // Cron: reads with operator.read, writes need operator.admin.
  const cronStatus = await client.send('cron.status');
  assert.equal(cronStatus.enabled, true);
  assert.equal(cronStatus.jobs, 3);
  const cronList = await client.send('cron.list', { includeDisabled: true, limit: 2, sortBy: 'nextRunAtMs', sortDir: 'asc' });
  assert.equal(cronList.total, 3);
  assert.equal(cronList.hasMore, true);
  const cronRest = await client.send('cron.list', { includeDisabled: true, limit: 2, offset: cronList.nextOffset });
  assert.equal(cronList.jobs.length + cronRest.jobs.length, 3);
  const enabledOnly = await client.send('cron.list', {});
  assert.ok(enabledOnly.jobs.every((job) => job.enabled), 'disabled jobs hidden by default');
  const diskRuns = await client.send('cron.runs', { scope: 'job', id: 'disk-check', limit: 50, sortDir: 'desc' });
  assert.equal(diskRuns.entries[0].status, 'error');
  assert.equal(diskRuns.entries[0].sessionKey, 'agent:main:cron:disk-check');
  assert.equal((await client.call('cron.run', { id: 'disk-check' })).error.details.code, 'MISSING_SCOPE');
  const denied = await client.call('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}}}', baseHash: snapshot.hash });
  assert.equal(denied.ok, false);
  assert.match(denied.error.message, /operator\.admin/);
  client.ws.close();

  // A device paired before Pincer asked for operator.questions: the Gateway refuses the new
  // scope with approvedScopes, so the client can drop it and connect with what it had.
  const legacyScopes = BASE_SCOPES.filter((s) => s !== 'operator.questions');
  const legacyDevice = makeDevice();
  const legacyFirst = await connectClient(url, legacyDevice, 'dev-token', false, legacyScopes);
  assert.equal(legacyFirst.connectRes.error.details.reason, 'not-paired');
  legacyFirst.ws.close();
  await delay(3500);
  const legacyPaired = await connectClient(url, legacyDevice, 'dev-token', true, legacyScopes);
  const legacyToken = legacyPaired.hello.auth.deviceToken;
  legacyPaired.ws.close();
  const legacyUpgrade = await connectClient(url, legacyDevice, legacyToken, false, BASE_SCOPES);
  assert.equal(legacyUpgrade.connectRes.error.details.reason, 'scope-upgrade');
  assert.deepEqual([...legacyUpgrade.connectRes.error.details.approvedScopes].sort(), [...legacyScopes].sort());
  assert.match(legacyUpgrade.connectRes.error.details.requestId, /^pair_/);
  legacyUpgrade.ws.close();
  const legacyFallback = await connectClient(url, legacyDevice, legacyToken, true, legacyScopes);
  assert.deepEqual(legacyFallback.hello.auth.scopes, legacyScopes);
  legacyFallback.ws.close();

  const noQuestions = await connectClient(url, device, deviceToken, true, BASE_SCOPES.filter((s) => s !== 'operator.questions'));
  const unscoped = await noQuestions.call('question.list');
  assert.equal(unscoped.error.details.code, 'MISSING_SCOPE');
  assert.equal(unscoped.error.details.missingScope, 'operator.questions');
  noQuestions.ws.close();

  // Asking for more than was approved at pairing parks a scope upgrade, like the Gateway.
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const upgrade = await connectClient(url, device, deviceToken, false, adminScopes);
  assert.equal(upgrade.connectRes.error.details.code, 'PAIRING_REQUIRED');
  assert.equal(upgrade.connectRes.error.details.reason, 'scope-upgrade');
  assert.ok(upgrade.connectRes.error.details.approvedScopes.includes('operator.questions'));
  assert.ok(!upgrade.connectRes.error.details.approvedScopes.includes('operator.admin'));
  upgrade.ws.close();
  await delay(3500);

  const admin = await connectClient(url, device, deviceToken, true, adminScopes);
  const stale = await admin.call('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}}}', baseHash: 'nope' });
  assert.match(stale.error.message, /config changed since last load/);
  const invalid = await admin.call('config.patch', { raw: '{"gateway":{"port":70000}}', baseHash: snapshot.hash });
  assert.equal(invalid.ok, false);
  assert.equal(invalid.error.details.issues[0].path, 'gateway.port');
  const hot = await admin.send('config.patch', { raw: '{"agents":{"defaults":{"timeoutSeconds":5}},"gateway":{"auth":{"token":"__OPENCLAW_REDACTED__"}}}', baseHash: snapshot.hash });
  assert.deepEqual(hot.changedPaths, ['agents.defaults.timeoutSeconds']);
  assert.equal(hot.restart, undefined);
  assert.equal(server.state.configState.config.gateway.auth.token, 'dev-token', 'redacted secret restored');
  const restart = await admin.send('config.patch', { raw: '{"gateway":{"port":18790}}', baseHash: hot.hash });
  assert.equal(restart.restart.delayMs, 2000);

  const added = await admin.send('cron.add', {
    name: 'Selftest job',
    agentId: 'main',
    schedule: { kind: 'every', everyMs: 3_600_000 },
    sessionTarget: 'isolated',
    wakeMode: 'now',
    payload: { kind: 'agentTurn', message: 'Say hi' },
    delivery: { mode: 'none' },
  });
  assert.ok(added.id && added.state.nextRunAtMs > Date.now());
  const mismatched = await admin.call('cron.add', { name: 'Bad', schedule: { kind: 'every', everyMs: 1000 }, sessionTarget: 'main', wakeMode: 'now', payload: { kind: 'agentTurn', message: 'x' } });
  assert.match(mismatched.error.message, /systemEvent/);
  const paused = await admin.send('cron.update', { id: added.id, expectedConfigRevision: added.configRevision, patch: { enabled: false } });
  assert.equal(paused.enabled, false);
  assert.equal(paused.state.nextRunAtMs, undefined);
  const staleCron = await admin.call('cron.update', { id: added.id, expectedConfigRevision: added.configRevision, patch: { name: 'x' } });
  assert.match(staleCron.error.message, /revision/);
  const cronStarted = admin.waitEvent('cron', (p) => p.jobId === added.id && p.action === 'started');
  const cronFinished = admin.waitEvent('cron', (p) => p.jobId === added.id && p.action === 'finished');
  const ran = await admin.send('cron.run', { id: added.id, mode: 'force' });
  assert.equal(ran.enqueued, true);
  await cronStarted;
  await cronFinished;
  const addedRuns = await admin.send('cron.runs', { scope: 'job', id: added.id });
  assert.equal(addedRuns.entries[0].runId, ran.runId);
  assert.equal(addedRuns.entries[0].status, 'ok');
  const runChat = await admin.send('chat.history', { sessionKey: addedRuns.entries[0].sessionKey });
  assert.ok(runChat.messages.some((m) => m.content.some((b) => b.text === 'Say hi')), 'run linked to its chat');
  await admin.send('cron.remove', { id: added.id });
  assert.equal((await admin.call('cron.get', { id: added.id })).ok, false);

  const plugins = await admin.send('plugins.list');
  assert.equal(plugins.plugins.find((p) => p.id === 'weather').state, 'needs-setup');
  const consent = await admin.call('plugins.setEnabled', { pluginId: 'browser', enabled: true });
  assert.equal(consent.error.details.capabilityConsentCode, 'PLUGIN_CAPABILITY_CONSENT_REQUIRED');
  const changed = admin.waitEvent('plugins.changed');
  const enabled = await admin.send('plugins.setEnabled', { pluginId: 'browser', enabled: true, acknowledgeCapabilities: { reviewToken: consent.error.details.reviewToken } });
  assert.equal(enabled.plugin.enabled, true);
  await changed;
  const installed = await admin.send('plugins.install', { source: 'npm', spec: 'openclaw-plugin-todo@1.0.0' });
  assert.equal(installed.plugin.id, 'todo');
  const removed = await admin.send('plugins.uninstall', { pluginId: 'todo' });
  assert.equal(removed.pluginId, 'todo');
  const bundled = await admin.call('plugins.uninstall', { pluginId: 'browser' });
  assert.equal(bundled.ok, false);

  // Command policy (exec.approvals.get/set): operator.admin only, token redacted, base-hash CAS.
  assert.ok(admin.hello.features.methods.includes('exec.approvals.get'));
  assert.ok(admin.hello.features.methods.includes('exec.approvals.set'));
  const policyReader = await connectClient(url, device, deviceToken, true);
  for (const method of ['exec.approvals.get', 'exec.approvals.set']) {
    const gated = await policyReader.call(method, {});
    assert.equal(gated.error.code, 'FORBIDDEN', 'operator.approvals alone is not enough');
    assert.equal(gated.error.message, 'missing scope: operator.admin');
    assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
  }
  policyReader.ws.close();
  const policy = await admin.send('exec.approvals.get', {});
  assert.equal(policy.path, '~/.openclaw/exec-approvals.json');
  assert.equal(policy.exists, true);
  assert.match(policy.hash, /^[0-9a-f]{64}$/);
  assert.deepEqual(policy.file.socket, { path: '~/.openclaw/exec-approvals.sock' }, 'socket token redacted');
  assert.ok(!JSON.stringify(policy).includes('mock-secret'));
  assert.deepEqual(policy.file.defaults, { security: 'allowlist', ask: 'on-miss' });
  assert.deepEqual(policy.resolvedDefaults, { security: 'allowlist', ask: 'on-miss', askFallback: 'deny', autoAllowSkills: false });
  assert.equal(policy.file.agents.main.allowlist.length, 2);
  assert.equal(policy.file.agents.main.allowlist.filter((e) => e.source === 'allow-always').length, 1);
  assert.equal(policy.file.agents.main.mcpTools.length, 1);
  assert.equal(policy.file.agents.research.ask, 'always');
  assert.ok(!agents.agents.some((a) => a.id === 'ghost') && policy.file.agents.ghost.allowlist.length === 1);
  const badGet = await admin.call('exec.approvals.get', { extra: true });
  assert.equal(badGet.error.code, 'INVALID_REQUEST');
  assert.match(badGet.error.message, /^invalid exec\.approvals\.get params: /);

  const schemaErrors = [
    { file: { ...policy.file, extra: 1 }, baseHash: policy.hash },
    { file: { ...policy.file, version: 2 }, baseHash: policy.hash },
    { file: { version: 1, agents: { main: { allowlist: [{ source: 'allow-always' }] } } }, baseHash: policy.hash },
    { file: { version: 1, agents: { main: { mcpTools: [{ server: 'github', tool: 'x', source: 'allow-always' }] } } }, baseHash: policy.hash },
    { file: { version: 1, defaults: { autoAllowSkills: 'yes' } }, baseHash: policy.hash },
    { file: policy.file, baseHash: policy.hash, extra: 1 },
  ];
  for (const params of schemaErrors) {
    const res = await admin.call('exec.approvals.set', params);
    assert.equal(res.error.code, 'INVALID_REQUEST', JSON.stringify(params));
    assert.match(res.error.message, /^invalid exec\.approvals\.set params: /);
  }
  // Schema errors come before hash checks, like upstream.
  assert.match((await admin.call('exec.approvals.set', { file: { version: 2 } })).error.message, /^invalid exec\.approvals\.set params/);
  const noBase = await admin.call('exec.approvals.set', { file: policy.file });
  assert.equal(noBase.error.code, 'INVALID_REQUEST');
  assert.equal(noBase.error.message, 'exec approvals base hash required; re-run exec.approvals.get and retry');
  const staleSet = await admin.call('exec.approvals.set', { file: policy.file, baseHash: 'deadbeef' });
  assert.equal(staleSet.error.message, 'exec approvals changed since last load; re-run exec.approvals.get and retry');
  assert.equal((await admin.call('exec.approvals.set', { baseHash: policy.hash })).error.message, 'exec approvals file is required');

  // Round trip without the token: unknown enum values survive, the stored token is kept.
  const edited = structuredClone(policy.file);
  edited.defaults.ask = 'off';
  edited.agents.research.security = 'future-mode';
  edited.agents.main.allowlist = edited.agents.main.allowlist.slice(0, 1);
  const saved = await admin.send('exec.approvals.set', { file: edited, baseHash: policy.hash });
  assert.notEqual(saved.hash, policy.hash);
  assert.deepEqual(saved.file, edited);
  assert.equal(server.state.execApprovalsState.file.socket.token, 'mock-secret', 'socket token preserved');
  assert.deepEqual(await admin.send('exec.approvals.get', {}), saved);
  const lostUpdate = await admin.call('exec.approvals.set', { file: policy.file, baseHash: policy.hash });
  assert.match(lostUpdate.error.message, /changed since last load/);
  const noSocket = structuredClone(saved.file);
  delete noSocket.socket;
  const savedAgain = await admin.send('exec.approvals.set', { file: noSocket, baseHash: saved.hash });
  assert.deepEqual(savedAgain.file.socket, { path: '~/.openclaw/exec-approvals.sock' });
  assert.equal(server.state.execApprovalsState.file.socket.token, 'mock-secret');

  // Always allow in chat adds the command to that agent's allowlist and changes the hash.
  const coderChat = await admin.send('sessions.create', { agentId: 'coder', label: 'Policy selftest' });
  const alwaysRequested = admin.waitEvent('exec.approval.requested', (p) => p.request.sessionKey === coderChat.key);
  const alwaysRun = await admin.send('chat.send', { sessionKey: coderChat.key, message: 'approve this', idempotencyKey: `idem_${crypto.randomUUID()}` });
  const alwaysApproval = await alwaysRequested;
  await admin.send('exec.approval.resolve', { id: alwaysApproval.id, decision: 'allow-always' });
  await admin.waitEvent('chat', (p) => p.runId === alwaysRun.runId && p.state === 'final', 10_000);
  const afterAlways = await admin.send('exec.approvals.get', {});
  assert.notEqual(afterAlways.hash, savedAgain.hash);
  assert.ok(!savedAgain.file.agents.coder, 'coder had no policy entry before');
  const coderEntry = afterAlways.file.agents.coder.allowlist.at(-1);
  assert.equal(coderEntry.source, 'allow-always');
  assert.equal(coderEntry.pattern, 'rm -rf ./build');
  assert.equal(coderEntry.commandText, 'rm -rf ./build');
  assert.ok(coderEntry.id && coderEntry.lastUsedAt > Date.now() - 60_000);
  assert.match((await admin.call('exec.approvals.set', { file: afterAlways.file, baseHash: savedAgain.hash })).error.message, /changed since last load/);

  // Context usage and compaction.
  const reader = await connectClient(url, device, deviceToken, true);
  const rows = (await reader.send('sessions.list', { limit: 50 })).sessions;
  const papersRow = rows.find((s) => s.key === 'agent:research:dashboard:papers');
  assert.equal(papersRow.totalTokens, 96_000);
  assert.equal(papersRow.contextTokens, 200_000);
  assert.equal((await reader.send('sessions.list', {})).defaults.contextTokens, 128_000);
  const plainModels = await reader.send('models.list', { agentId: 'main' });
  assert.equal(plainModels.models[0].contextTokens, undefined, 'contextTokens only with includeDetails');
  assert.equal(plainModels.models[0].contextWindow, 1_000_000);
  const detailed = await reader.send('models.list', { agentId: 'main', includeDetails: true });
  assert.equal(detailed.models[0].contextTokens, 200_000);
  const compactDenied = await reader.call('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(compactDenied.error.details.code, 'MISSING_SCOPE');
  const compacted = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(compacted.compacted, true);
  assert.deepEqual(compacted.result, { tokensBefore: 96_000, tokensAfter: 17_280 });
  const papersHistory = await reader.send('chat.history', { sessionKey: 'agent:research:dashboard:papers' });
  assert.equal(papersHistory.messages.at(-1).__openclaw.kind, 'compaction');
  const again = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(again.compacted, true, 'still above the minimum');
  const nothing = await admin.send('sessions.compact', { key: 'agent:research:dashboard:papers' });
  assert.equal(nothing.compacted, false);
  assert.match(nothing.reason, /Nothing to compact/);

  await reader.send('sessions.messages.subscribe', { key: 'agent:coder:main' });
  const compactRun = await reader.send('chat.send', {
    sessionKey: 'agent:coder:main',
    message: '/compact keep the build notes',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  const compactEnd = reader.waitEvent('agent', (p) => p.runId === compactRun.runId && p.stream === 'compaction' && p.data.phase === 'end');
  const compactFinal = await reader.waitEvent('chat', (p) => p.runId === compactRun.runId && p.state === 'final', 10_000);
  await compactEnd;
  assert.match(compactFinal.message.content[0].text, /190000 → 34200 tokens\), keeping: keep the build notes/);
  const coderRow = (await reader.send('sessions.list', {})).sessions.find((s) => s.key === 'agent:coder:main');
  assert.equal(coderRow.totalTokens, 34_200);
  reader.ws.close();
  admin.ws.close();

  // Approval history needs operator.approvals; MOCK_NO_APPROVAL_HISTORY=1 hides it entirely.
  const noApprovals = await connectClient(url, device, 'dev-token', true, ['operator.read']);
  const noScope = await noApprovals.call('approval.history', {});
  assert.equal(noScope.error.details.code, 'MISSING_SCOPE');
  noApprovals.ws.close();
  process.env.MOCK_NO_APPROVAL_HISTORY = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true);
    assert.ok(!legacy.hello.features.methods.includes('approval.history'));
    assert.ok(!legacy.hello.features.methods.includes('approval.get'));
    assert.ok(legacy.hello.features.methods.includes('exec.approval.resolve'));
    for (const method of ['approval.history', 'approval.get']) {
      const unknown = await legacy.call(method, { id: 'x' });
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_APPROVAL_HISTORY;
  }
  // logs.tail: byte-offset polling with the Gateway's cursor, reset and truncation rules.
  {
    const tailer = await connectClient(url, device, deviceToken, true);
    assert.ok(tailer.hello.features.methods.includes('logs.tail'));
    const first = await tailer.send('logs.tail', {});
    assert.match(first.file, /^\/tmp\/openclaw\/openclaw-\d{4}-\d{2}-\d{2}\.log$/);
    assert.ok(first.lines.length > 100 && first.lines.length <= 500, `seeded lines: ${first.lines.length}`);
    assert.equal(first.cursor, first.size);
    assert.equal(first.reset, false);
    assert.equal(first.skippedBytes, undefined);
    const parsed = first.lines.map((line) => { try { return JSON.parse(line); } catch { return null; } });
    const levels = new Set(parsed.filter(Boolean).map((obj) => obj._meta.logLevelName));
    for (const level of ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL']) assert.ok(levels.has(level), `seeded ${level}`);
    assert.ok(parsed.some((obj) => obj === null), 'seeded plain-text lines');
    const boot = parsed.find((obj) => obj?.['1'] === 'listening on ws://127.0.0.1:18789');
    assert.equal(boot?.['0'], undefined);
    assert.equal(parsed.find((obj) => obj?.['0'] === obj?._meta.name)?.['1'], 'control UI served at /');
    appendLogLine(server.state.logsState, 'info', 'gateway', 'selftest marker line');
    const next = await tailer.send('logs.tail', { cursor: first.cursor });
    assert.equal(next.file, first.file);
    assert.ok(next.lines.some((line) => line.includes('selftest marker line')));
    assert.ok(next.cursor > first.cursor);
    assert.equal(next.reset, false);
    const idle = await tailer.send('logs.tail', { cursor: server.state.logsState.size });
    assert.deepEqual(idle.lines, []);
    for (const params of [{ follow: true }, { limit: 0 }, { limit: 5001 }, { limit: 1.5 }, { maxBytes: 0 }, { maxBytes: 1_000_001 }, { cursor: -1 }, { cursor: '10' }]) {
      const bad = await tailer.call('logs.tail', params);
      assert.equal(bad.error.code, 'INVALID_REQUEST', JSON.stringify(params));
      assert.match(bad.error.message, /^invalid logs\.tail params/);
    }
    const limited = await tailer.send('logs.tail', { limit: 3 });
    assert.equal(limited.lines.length, 3);
    assert.equal(limited.truncated, true);
    const midLine = await tailer.send('logs.tail', { cursor: first.cursor - 5, limit: 5000 });
    assert.ok(midLine.lines.every((line) => !line.startsWith('"')), 'partial first line dropped');
    const small = await tailer.send('logs.tail', { maxBytes: 1000 });
    assert.equal(small.truncated, true);
    assert.ok(small.lines.reduce((n, line) => n + Buffer.byteLength(line, 'utf8') + 1, 0) <= 1000, 'maxBytes counts UTF-8 bytes');
    const RESULT_KEYS = new Set(['file', 'cursor', 'size', 'lines', 'truncated', 'reset', 'skippedBytes']);
    for (const res of [first, next, idle, limited, midLine, small]) {
      for (const key of Object.keys(res)) assert.ok(RESULT_KEYS.has(key), `unexpected result key ${key}`);
      for (const key of ['file', 'cursor', 'size', 'lines']) assert.ok(key in res, `missing result key ${key}`);
      assert.ok(Number.isInteger(res.cursor) && res.cursor >= 0 && res.cursor <= res.size);
    }
    const ahead = await tailer.send('logs.tail', { cursor: server.state.logsState.size + 1000 });
    assert.equal(ahead.reset, true);
    assert.equal(ahead.skippedBytes, undefined);
    for (const params of [null, [], 'x']) {
      const bad = await tailer.call('logs.tail', params);
      assert.equal(bad.error?.code, 'INVALID_REQUEST', `params ${JSON.stringify(params)}`);
    }
    // Byte offsets, not characters: a detached in-memory file with multi-byte lines.
    {
      const file = { file: '/tmp/openclaw/openclaw-2026-09-26.log', lines: [], starts: [], size: 0, counter: 0 };
      const wide = 'é🦞 → done';
      appendLogLine(file, 'info', 'gateway', 'first');
      const afterFirst = file.size;
      assert.equal(afterFirst, Buffer.byteLength(file.lines[0], 'utf8') + 1);
      file.lines.push(wide); file.starts.push(file.size); file.size += Buffer.byteLength(wide, 'utf8') + 1;
      assert.equal(file.size - afterFirst, 16);
      assert.notEqual(Buffer.byteLength(wide, 'utf8'), wide.length);
      const tail = readLogSlice(file, { cursor: afterFirst });
      assert.deepEqual(tail.lines, [wide]);
      assert.equal(tail.cursor, file.size);
      file.lines.push('after'); file.starts.push(file.size); file.size += 6;
      assert.deepEqual(readLogSlice(file, { cursor: afterFirst + 2 }).lines, ['after'], 'cursor mid multi-byte line skips the partial line');
      assert.deepEqual(readLogSlice(file, { cursor: file.size }).lines, []);
      const exact = readLogSlice(file, { cursor: file.size - 10, maxBytes: 10 });
      assert.equal(exact.reset, false);
      const behind = readLogSlice(file, { cursor: 0, maxBytes: 10 });
      assert.equal(behind.reset, true);
      assert.equal(behind.skippedBytes, file.size - 10);
      assert.deepEqual(behind.lines, ['after']);
      const limitedSlice = readLogSlice(file, { cursor: 0, limit: 1 });
      assert.deepEqual(limitedSlice.lines, ['after']);
      assert.equal(limitedSlice.truncated, true);
      assert.equal(limitedSlice.reset, false);
      const empty = readLogSlice({ ...file, lines: [], starts: [], size: 0 }, {});
      assert.deepEqual([empty.lines, empty.cursor, empty.size], [[], 0, 0]);
    }

    const sendTrigger = (text) => tailer.send('chat.send', { sessionKey: 'agent:main:main', message: text, idempotencyKey: `idem_${crypto.randomUUID()}` });
    await tailer.send('sessions.messages.subscribe', { key: 'agent:main:main' });
    const beforeRotate = await tailer.send('logs.tail', {});
    await sendTrigger('rotate please [mock:rotate-logs]');
    const rotated = await tailer.send('logs.tail', { cursor: beforeRotate.cursor });
    assert.notEqual(rotated.file, beforeRotate.file);
    assert.equal(rotated.reset, true);
    assert.ok(rotated.lines.some((line) => line.includes('log file opened')));
    await sendTrigger('truncate please [mock:truncate-logs]');
    const truncated = await tailer.send('logs.tail', { cursor: rotated.cursor });
    assert.equal(truncated.file, rotated.file);
    assert.equal(truncated.reset, true);
    assert.equal(truncated.skippedBytes, undefined);
    const beforeBurst = await tailer.send('logs.tail', {});
    await sendTrigger('burst please [mock:log-burst]');
    const burst = await tailer.send('logs.tail', { cursor: beforeBurst.cursor });
    assert.equal(burst.reset, true);
    assert.equal(burst.truncated, true);
    assert.ok(burst.skippedBytes > 0);
    assert.ok(burst.lines.length > 0 && burst.lines.length <= 500);
    await sendTrigger('fail please [mock:logs-unavailable]');
    for (let i = 0; i < 2; i += 1) {
      const failed = await tailer.call('logs.tail', { cursor: burst.cursor });
      assert.equal(failed.error.code, 'UNAVAILABLE');
      assert.match(failed.error.message, /^log read failed: EACCES/);
    }
    assert.equal((await tailer.call('logs.tail', { cursor: burst.cursor })).ok, true);
    tailer.ws.close();
    const noRead = await connectClient(url, device, 'dev-token', true, ['operator.approvals']);
    const noReadScope = await noRead.call('logs.tail', {});
    assert.equal(noReadScope.error.details.code, 'MISSING_SCOPE');
    assert.equal(noReadScope.error.details.scope, 'operator.read');
    noRead.ws.close();
    process.env.MOCK_NO_LOGS = '1';
    try {
      const noLogs = await connectClient(url, device, deviceToken, true);
      assert.ok(!noLogs.hello.features.methods.includes('logs.tail'));
      const unknown = await noLogs.call('logs.tail', {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      noLogs.ws.close();
    } finally {
      delete process.env.MOCK_NO_LOGS;
    }
  }

  // MOCK_NO_EXEC_APPROVALS=1 hides the command policy methods, like an older Gateway.
  process.env.MOCK_NO_EXEC_APPROVALS = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true, adminScopes);
    assert.ok(!legacy.hello.features.methods.some((m) => m.startsWith('exec.approvals.')));
    assert.ok(legacy.hello.features.methods.includes('exec.approval.resolve'));
    for (const method of ['exec.approvals.get', 'exec.approvals.set']) {
      const unknown = await legacy.call(method, {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_EXEC_APPROVALS;
  }

  // MOCK_EXEC_APPROVALS_MISSING=1 starts without a policy file; saving creates it.
  process.env.MOCK_EXEC_APPROVALS_MISSING = '1';
  const missingServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  delete process.env.MOCK_EXEC_APPROVALS_MISSING;
  try {
    const fresh = await connectClient(`ws://127.0.0.1:${missingServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    const empty = await fresh.send('exec.approvals.get', {});
    assert.equal(empty.exists, false);
    assert.deepEqual(empty.file, { version: 1 });
    assert.match(empty.hash, /^[0-9a-f]{64}$/);
    assert.deepEqual(empty.resolvedDefaults, { security: 'full', ask: 'off', askFallback: 'deny', autoAllowSkills: false });
    const wrongBase = await fresh.call('exec.approvals.set', { file: { version: 1 }, baseHash: 'deadbeef' });
    assert.equal(wrongBase.error.message, 'exec approvals changed since last load; re-run exec.approvals.get and retry');
    const created = await fresh.send('exec.approvals.set', { file: { version: 1, defaults: { security: 'deny' } }, baseHash: empty.hash });
    assert.equal(created.exists, true);
    assert.notEqual(created.hash, empty.hash);
    assert.deepEqual(created.file, { version: 1, defaults: { security: 'deny' } });
    assert.deepEqual(created.resolvedDefaults, { security: 'deny', ask: 'off', askFallback: 'deny', autoAllowSkills: false }, 'unset fields use built-in values');
    const requiredNow = await fresh.call('exec.approvals.set', { file: created.file });
    assert.match(requiredNow.error.message, /base hash required/);
    fresh.ws.close();
  } finally {
    await missingServer.close();
  }

  // Usage & cost: shapes and the Gateway's validation; MOCK_NO_USAGE=1 hides all five methods.
  const usage = await connectClient(url, device, deviceToken, true);
  for (const method of ['usage.status', 'usage.cost', 'sessions.usage', 'sessions.usage.timeseries', 'sessions.usage.logs']) {
    assert.ok(usage.hello.features.methods.includes(method), method);
  }
  const zone = { mode: 'specific', timeZone: 'Asia/Kolkata', utcOffset: 'UTC+5:30' };
  const status = await usage.send('usage.status', {});
  assert.ok(status.updatedAt > 0);
  assert.ok(status.providers.length >= 2);
  assert.ok(status.providers.some((p) => p.windows.some((w) => w.usedPercent >= 90 && w.resetAt - Date.now() < 3_600_000)));
  assert.ok(status.providers.some((p) => p.error));
  assert.ok(status.providers.some((p) => p.billing?.some((b) => b.type === 'budget')));
  const week = { startDate: '2000-01-01', endDate: '2000-01-07' };
  const todayKey = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const shift = (key, days) => { const [y, m, d] = key.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10); };
  const last7 = { ...zone, startDate: shift(todayKey, -6), endDate: todayKey };
  const cost = await usage.send('usage.cost', { ...last7, agentScope: 'all' });
  assert.equal(cost.days, 7);
  assert.ok(cost.daily.length > 0 && cost.daily.every((d) => d.date >= last7.startDate && d.date <= last7.endDate));
  assert.ok(cost.totals.totalTokens > 0 && cost.totals.totalCost > 0);
  const mainOnly = await usage.send('usage.cost', last7);
  assert.ok(mainOnly.totals.totalTokens < cost.totals.totalTokens, 'without agentScope only main is counted');
  // Like the Gateway, timeZone only counts with mode "specific"; +14 and -11 are always on different days.
  const today = async (params) => (await usage.send('usage.cost', { days: 1, agentScope: 'all', ...params })).daily.map((d) => d.date);
  const utcToday = new Date().toISOString().slice(0, 10);
  assert.deepEqual(await today({ timeZone: 'Pacific/Kiritimati' }), [utcToday], 'timeZone without mode is UTC');
  assert.notDeepEqual(await today({ mode: 'specific', timeZone: 'Pacific/Kiritimati' }), await today({ mode: 'specific', timeZone: 'Pacific/Pago_Pago' }));
  assert.deepEqual(await today({ mode: 'specific', timeZone: 'Nope/Zone', utcOffset: 'UTC+0' }), [utcToday], 'bad zone falls back to utcOffset');
  const empty = await usage.send('usage.cost', { ...week, agentScope: 'all' });
  assert.deepEqual(empty.daily, []);
  assert.equal(empty.totals.totalTokens, 0);
  const sessionsUsage = await usage.send('sessions.usage', { ...last7, agentScope: 'all', groupBy: 'instance', limit: 3, includeContextWeight: false });
  assert.equal(sessionsUsage.startDate, last7.startDate);
  assert.equal(sessionsUsage.endDate, last7.endDate);
  assert.equal(sessionsUsage.sessions.length, 3);
  assert.ok(sessionsUsage.aggregates.sessionCount > 3, 'aggregates cover sessions beyond the limit');
  assert.equal(sessionsUsage.totals.totalTokens, cost.totals.totalTokens);
  assert.ok(sessionsUsage.aggregates.byModel.some((m) => m.totals.missingCostEntries > 0 && m.totals.totalCost > 0), 'partial cost');
  assert.ok(sessionsUsage.aggregates.byModel.some((m) => m.totals.missingCostEntries > 0 && m.totals.totalCost === 0), 'unknown cost');
  assert.deepEqual(sessionsUsage.aggregates.byAgent.map((a) => a.agentId), ['coder', 'main', 'research']);
  assert.ok(sessionsUsage.aggregates.daily.length > 0 && sessionsUsage.aggregates.costDaily.length > 0);
  const quarter = await usage.send('sessions.usage', { ...zone, startDate: shift(todayKey, -89), endDate: todayKey, agentScope: 'all', limit: 200 });
  const computingRow = quarter.sessions.find((s) => s.computing);
  assert.equal(computingRow.usage, null);
  assert.equal(quarter.cacheStatus.status, 'partial');
  const one = await usage.send('sessions.usage', { ...last7, key: 'agent:main:main', agentId: 'main', limit: 1 });
  assert.equal(one.sessions.length, 1);
  assert.equal(one.sessions[0].key, 'agent:main:main');
  assert.ok(one.sessions[0].usage.totalTokens > 0);
  assert.ok(one.sessions[0].usage.messageCounts.total > 0);
  const quiet = await usage.send('sessions.usage', { ...last7, key: 'agent:main:cron:disk-check', limit: 1 });
  assert.equal(quiet.sessions.length, 1);
  assert.equal(quiet.sessions[0].usage.totalTokens, 0);
  const expectInvalid = async (method, params, message) => {
    const { error } = await usage.call(method, params);
    assert.equal(error?.code, 'INVALID_REQUEST', `${method} ${JSON.stringify(params)}`);
    if (message) assert.match(error.message, message);
  };
  await expectInvalid('usage.cost', { startDate: '2026-01-01' }, /startDate and endDate must be provided together/);
  await expectInvalid('sessions.usage', { endDate: '2026-01-01' }, /provided together/);
  await expectInvalid('usage.cost', { startDate: '2026-02-30', endDate: '2026-03-01' }, /invalid startDate/);
  await expectInvalid('usage.cost', { startDate: '2026-03-02', endDate: '2026-03-01' }, /must not be after/);
  await expectInvalid('usage.cost', { startDate: '2026-02-30' }, /invalid startDate/);
  await expectInvalid('usage.cost', { mode: 'specific', timeZone: 'Nope/Zone' }, /invalid timeZone/);
  await expectInvalid('usage.cost', { mode: 'specific', utcOffset: 'UTC+15' }, /invalid utcOffset/);
  await expectInvalid('usage.cost', { agentScope: 'all', agentId: 'main' }, /agentScope=all cannot be combined with agentId/);
  await expectInvalid('sessions.usage', { agentScope: 'all', key: 'agent:main:main' }, /agentScope=all cannot be combined with key or agentId/);
  await expectInvalid('sessions.usage', { key: 'agent:main:nope' }, /Invalid session key: agent:main:nope/);
  await expectInvalid('sessions.usage.timeseries', {}, /key is required for timeseries/);
  await expectInvalid('sessions.usage.logs', {}, /key is required for logs/);
  await expectInvalid('sessions.usage.timeseries', { key: 'agent:main:nope' }, /Invalid session key/);
  await expectInvalid('sessions.usage.logs', { key: 'agent:main:nope' }, /Invalid session key/);
  await expectInvalid('sessions.usage.timeseries', { key: 'agent:main:cron:disk-check' }, /No transcript found for session/);
  const series = await usage.send('sessions.usage.timeseries', { key: 'agent:main:main', agentId: 'main' });
  assert.ok(series.points.length > 0 && series.points.length <= 50);
  assert.ok(series.points.every((p, i) => i === 0 || p.cumulativeTokens >= series.points[i - 1].cumulativeTokens));
  const logs = await usage.send('sessions.usage.logs', { key: 'agent:main:main', limit: 200 });
  assert.equal(logs.logs.length, 20);
  assert.deepEqual([...new Set(logs.logs.map((l) => l.role))].sort(), ['assistant', 'tool', 'toolResult', 'user']);
  assert.equal((await usage.send('sessions.usage.logs', { key: 'agent:main:main', limit: 5 })).logs.length, 5);
  usage.ws.close();
  process.env.MOCK_USAGE_FORBIDDEN = '1';
  try {
    const restricted = await connectClient(url, device, deviceToken, true);
    assert.equal((await restricted.call('usage.cost', { agentScope: 'all' })).error.code, 'FORBIDDEN');
    restricted.ws.close();
  } finally {
    delete process.env.MOCK_USAGE_FORBIDDEN;
  }
  process.env.MOCK_NO_USAGE = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true);
    for (const method of ['usage.status', 'usage.cost', 'sessions.usage', 'sessions.usage.timeseries', 'sessions.usage.logs']) {
      assert.ok(!legacy.hello.features.methods.includes(method), method);
      const unknown = await legacy.call(method, { key: 'agent:main:main' });
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
    }
    assert.ok(legacy.hello.features.methods.includes('sessions.list'));
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_USAGE;
  }
  // Channel pairing: operator.pairing (or operator.admin) for every method, upstream-shaped results.
  const unpaired = await connectClient(url, device, deviceToken, true);
  assert.ok(unpaired.hello.features.methods.includes('channels.pairing.list'));
  const pairingDenied = await unpaired.call('channels.pairing.list', {});
  assert.equal(pairingDenied.error.code, 'FORBIDDEN');
  assert.equal(pairingDenied.error.details.code, 'MISSING_SCOPE');
  assert.equal(pairingDenied.error.details.missingScope, 'operator.pairing');
  assert.deepEqual(pairingDenied.error.details.requiredScopes, ['operator.pairing']);
  assert.equal((await unpaired.call('channels.pairing.dismiss', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya' })).error.details.code,
    'MISSING_SCOPE');
  unpaired.ws.close();
  const pairer = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.pairing']);
  const pairingList = await pairer.send('channels.pairing.list', {});
  assert.deepEqual(pairingList.accounts.map((a) => `${a.channel}:${a.accountId}:${a.notifySupported}`),
    ['telegram:home:true', 'discord:family:false']);
  assert.deepEqual(pairingList.requests.map((r) => r.requestId), ['pr_maya', 'pr_discord', 'pr_soon']);
  assert.equal(pairingList.commandOwnerConfigured, true);
  assert.deepEqual(pairingList.limits, { pendingPerAccount: PENDING_PER_ACCOUNT, ttlMs: PAIRING_TTL_MS });
  // Closed objects: exactly the upstream keys, optional ones only when present.
  const sortedKeys = (o) => Object.keys(o).sort();
  assert.deepEqual(sortedKeys(pairingList), ['accounts', 'commandOwnerConfigured', 'limits', 'requests']);
  const ACCOUNT_KEYS = ['accountId', 'accountLabel', 'channel', 'channelLabel', 'notifySupported'];
  for (const a of pairingList.accounts) {
    assert.deepEqual(sortedKeys(a).filter((k) => k !== 'accountLabel'), ACCOUNT_KEYS.filter((k) => k !== 'accountLabel'));
    assert.ok(sortedKeys(a).every((k) => ACCOUNT_KEYS.includes(k)));
    assert.equal(typeof a.notifySupported, 'boolean');
  }
  const REQUEST_KEYS = ['accountId', 'accountLabel', 'channel', 'channelLabel', 'createdAt', 'expiresAt', 'lastSeenAt', 'metadata',
    'notifySupported', 'requestId', 'senderId', 'senderLabel'];
  const REQUIRED_REQUEST_KEYS = REQUEST_KEYS.filter((k) => k !== 'accountLabel' && k !== 'metadata');
  for (const r of pairingList.requests) {
    assert.ok(sortedKeys(r).every((k) => REQUEST_KEYS.includes(k)), `request keys ${sortedKeys(r)}`);
    assert.ok(REQUIRED_REQUEST_KEYS.every((k) => k in r), `required request keys ${sortedKeys(r)}`);
    assert.ok(Object.values(r.metadata ?? {}).every((v) => typeof v === 'string'));
    for (const k of ['createdAt', 'lastSeenAt', 'expiresAt']) assert.equal(new Date(r[k]).toISOString(), r[k]);
  }
  const maya = pairingList.requests[0];
  assert.equal(maya.metadata.name, 'Maya Chen');
  assert.equal(maya.senderLabel, 'Telegram user id');
  assert.ok(Date.parse(maya.expiresAt) - Date.parse(maya.createdAt) === PAIRING_TTL_MS && !Number.isNaN(Date.parse(maya.lastSeenAt)));
  assert.equal(pairingList.requests[1].metadata, undefined);
  assert.ok(Date.parse(pairingList.requests[2].expiresAt) - Date.now() < 11 * 60_000);
  assert.deepEqual((await pairer.send('channels.pairing.list', { channel: 'discord' })).requests.map((r) => r.requestId), ['pr_discord']);
  assert.match((await pairer.call('channels.pairing.list', { channel: 'signal' })).error.message, /^unknown pairing channel: signal$/);
  assert.equal((await pairer.call('channels.pairing.list', { limit: 5 })).error.code, 'INVALID_REQUEST');
  assert.equal((await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', code: 'x' })).error.code,
    'INVALID_REQUEST', 'approve params are closed');
  const ownerDenied = await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', bootstrapCommandOwner: true });
  assert.equal(ownerDenied.error.details.missingScope, 'operator.admin', 'bootstrapCommandOwner needs operator.admin');
  assert.deepEqual(await pairer.send('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya', notify: true }),
    { requestId: 'pr_maya', senderId: '5550142', notification: 'sent', commandOwnerBootstrap: 'not-requested' });
  const staleApprove = await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_maya' });
  assert.equal(staleApprove.error.code, 'INVALID_REQUEST');
  assert.equal(staleApprove.error.message, 'pending DM access request no longer exists');
  assert.equal((await pairer.call('channels.pairing.dismiss', { channel: 'slack', accountId: 'work', requestId: 'pr_discord' })).error.message,
    'channel account does not use DM pairing: slack:work');
  assert.deepEqual(await pairer.send('channels.pairing.dismiss', { channel: 'discord', accountId: 'family', requestId: 'pr_discord' }),
    { requestId: 'pr_discord', senderId: '418820017734812160' });
  assert.equal((await pairer.call('channels.pairing.dismiss', { channel: 'discord', accountId: 'family', requestId: 'pr_discord' })).error.message,
    'pending DM access request no longer exists');
  assert.equal((await pairer.call('channels.pairing.approve', { channel: 'telegram', accountId: 'home', requestId: 'pr_soon', notify: 'yes' })).error.code,
    'INVALID_REQUEST', 'notify must be a boolean');
  const newRequest = addChannelPairingRequest(server.state);
  const afterAdd = await pairer.send('channels.pairing.list', {});
  assert.deepEqual(afterAdd.requests.map((r) => r.requestId).sort(), ['pr_soon', newRequest.requestId].sort());
  assert.ok(afterAdd.requests.every((r) => sortedKeys(r).every((k) => REQUEST_KEYS.includes(k))), 'added requests keep the upstream shape');
  // Discord can't notify; notify omitted → not-requested.
  const discordAdded = addChannelPairingRequest(server.state);
  assert.equal(discordAdded.channel, 'discord');
  assert.deepEqual(await pairer.send('channels.pairing.approve',
    { channel: 'discord', accountId: 'family', requestId: discordAdded.requestId, notify: true }),
    { requestId: discordAdded.requestId, senderId: discordAdded.senderId, notification: 'unsupported', commandOwnerBootstrap: 'not-requested' });
  const quietAdded = addChannelPairingRequest(server.state);
  assert.deepEqual(sortedKeys(await pairer.send('channels.pairing.approve',
    { channel: quietAdded.channel, accountId: quietAdded.accountId, requestId: quietAdded.requestId })),
  ['commandOwnerBootstrap', 'notification', 'requestId', 'senderId']);
  assert.equal(server.state.channelPairingState.requests.some((r) => r.requestId === quietAdded.requestId), false);
  // Expired requests are dropped from the list and can't be approved.
  const expiredAdded = addChannelPairingRequest(server.state, Date.now() - PAIRING_TTL_MS - 1000);
  assert.ok(!(await pairer.send('channels.pairing.list', {})).requests.some((r) => r.requestId === expiredAdded.requestId));
  assert.equal((await pairer.call('channels.pairing.approve',
    { channel: expiredAdded.channel, accountId: expiredAdded.accountId, requestId: expiredAdded.requestId })).error.message,
  'pending DM access request no longer exists');
  // A full account drops its oldest request.
  const cap = createChannelPairingState();
  const capState = { channelPairingState: cap };
  for (let i = 0; i < 9; i += 1) addChannelPairingRequest(capState);
  for (const account of ['telegram:home', 'discord:family']) {
    assert.ok(cap.requests.filter((r) => `${r.channel}:${r.accountId}` === account).length <= PENDING_PER_ACCOUNT, `cap on ${account}`);
  }
  pairer.ws.close();
  const pairingAdmin = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.admin']);
  server.state.channelPairingState.commandOwnerConfigured = false;
  assert.deepEqual(await pairingAdmin.send('channels.pairing.approve',
    { channel: newRequest.channel, accountId: newRequest.accountId, requestId: newRequest.requestId, notify: true, bootstrapCommandOwner: true }),
    { requestId: newRequest.requestId, senderId: newRequest.senderId, notification: newRequest.notifySupported ? 'sent' : 'unsupported', commandOwnerBootstrap: 'configured' });
  assert.equal((await pairingAdmin.send('channels.pairing.list', {})).commandOwnerConfigured, true, 'admin covers operator.pairing');
  pairingAdmin.ws.close();
  process.env.MOCK_CHANNEL_PAIRING = 'off';
  try {
    const noPairing = await connectClient(url, device, deviceToken, true, [...BASE_SCOPES, 'operator.admin']);
    for (const method of ['channels.pairing.list', 'channels.pairing.approve', 'channels.pairing.dismiss']) {
      assert.ok(!noPairing.hello.features.methods.includes(method));
      const unknown = await noPairing.call(method, {});
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
      assert.equal(unknown.error.message, `unknown method: ${method}`);
    }
    noPairing.ws.close();
  } finally {
    delete process.env.MOCK_CHANNEL_PAIRING;
  }

  // Health, presence and a safe restart.
  const watcher = await connectClient(url, device, deviceToken, true);
  for (const method of ['health', 'status', 'last-heartbeat', 'system-presence', 'gateway.restart.request']) {
    assert.ok(watcher.hello.features.methods.includes(method), method);
  }
  for (const event of ['health', 'heartbeat', 'presence', 'shutdown']) assert.ok(watcher.hello.features.events.includes(event), event);
  const helloSnap = watcher.hello.snapshot;
  assert.ok(Array.isArray(helloSnap.presence) && helloSnap.presence.some((p) => p.deviceId === device.id));
  assert.equal(helloSnap.health.ok, true);
  assert.ok(helloSnap.uptimeMs > 86_400_000, 'mock has been up for a day');
  const healthNow = await watcher.send('health');
  assert.equal(healthNow.channels.discord.connected, true);
  assert.equal(healthNow.heartbeatSeconds, 1800);
  // One failed delivery that stays failed, so Pincer shows a dismissable issue.
  assert.equal(healthNow.deliveryQueues.failed.length, 1);
  assert.equal(healthNow.deliveryQueues.failed[0].queueName, FAILED_DELIVERY_QUEUE);
  assert.equal(healthNow.deliveryQueues.failed[0].count, 1);
  assert.ok(healthNow.deliveryQueues.failed[0].oldestFailedAt > 0);
  assert.deepEqual(helloSnap.health.deliveryQueues.failed, healthNow.deliveryQueues.failed);
  assert.equal((await watcher.send('last-heartbeat')).status, 'ok-token');
  assert.ok((await watcher.send('system-presence')).some((p) => p.mode === 'node'));
  assert.ok((await watcher.send('status')).uptimeMs > 0);
  const restartDenied = await watcher.call('gateway.restart.request', { reason: 'nope' });
  assert.equal(restartDenied.error.details.code, 'MISSING_SCOPE');

  const restarter = await connectClient(url, device, deviceToken, true, adminScopes);
  // A live run defers the restart; skipDeferral escalates it (coalesced into the pending one).
  const liveRun = await watcher.send('chat.send', {
    sessionKey: 'agent:main:main',
    message: 'keep going for a while',
    idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  assert.ok(server.state.activeRuns.size > 0);
  const deferredRestart = await restarter.send('gateway.restart.request', { reason: 'selftest' });
  assert.equal(deferredRestart.status, 'deferred');
  assert.equal(deferredRestart.preflight.safe, false);
  assert.ok(deferredRestart.preflight.blockers[0].message.includes('active agent run'));
  const shutdownSeen = restarter.waitEvent('shutdown');
  const restarterClosed = new Promise((resolve) => restarter.ws.once('close', (code) => resolve(code)));
  const coalescedRestart = await restarter.send('gateway.restart.request', { reason: 'selftest', skipDeferral: true });
  assert.equal(coalescedRestart.status, 'coalesced');
  const shutdownPayload = await shutdownSeen;
  assert.equal(shutdownPayload.restartExpectedMs, 1500);
  assert.equal(await restarterClosed, 1012);
  void liveRun;
  const refusedSocket = new WebSocket(url);
  const refusedCode = await new Promise((resolve) => refusedSocket.once('close', (code) => resolve(code)));
  assert.equal(refusedCode, 1013, 'refuses connections while restarting');
  await delay(1700);
  const back = await connectClient(url, device, deviceToken, true, adminScopes);
  assert.ok(back.hello.snapshot.uptimeMs < 60_000, 'fresh uptime after restart');
  // Nothing running: scheduled right away.
  const backClosed = new Promise((resolve) => back.ws.once('close', (code) => resolve(code)));
  const scheduled = await back.send('gateway.restart.request', { reason: 'selftest again' });
  assert.equal(scheduled.status, 'scheduled');
  assert.equal(scheduled.preflight.safe, true);
  assert.equal(await backClosed, 1012);
  await delay(1700);

  // MOCK_NO_HEALTH=1 is an older Gateway without any of it.
  process.env.MOCK_NO_HEALTH = '1';
  try {
    const old = await connectClient(url, device, deviceToken, true, adminScopes);
    assert.ok(!old.hello.features.methods.includes('health'));
    assert.ok(!old.hello.features.methods.includes('gateway.restart.request'));
    assert.deepEqual(old.hello.snapshot, {});
    assert.equal((await old.call('health')).error.code, 'UNKNOWN_METHOD');
    assert.equal((await old.call('gateway.restart.request', {})).error.code, 'UNKNOWN_METHOD');
    old.ws.close();
  } finally {
    delete process.env.MOCK_NO_HEALTH;
  }

  // The failed delivery survived the restarts; MOCK_FAILED_DELIVERY_EVERY adds more, MOCK_FAILED_DELIVERY=off drops it.
  const afterRestart = await connectClient(url, device, deviceToken, true);
  assert.equal((await afterRestart.send('health')).deliveryQueues.failed[0].count, 1);
  afterRestart.ws.close();
  const fakeState = { agents: new Map(), sessions: new Map(), healthState: createHealthState() };
  const sent = [];
  addFailedDelivery(fakeState, (_state, event, payload) => sent.push({ event, payload }));
  assert.equal(fakeState.healthState.failedDelivery.count, 2);
  assert.equal(sent[0].event, 'health');
  assert.equal(sent[0].payload.deliveryQueues.failed[0].count, 2);
  process.env.MOCK_FAILED_DELIVERY = 'off';
  try {
    const quiet = { agents: new Map(), sessions: new Map(), healthState: createHealthState() };
    assert.deepEqual(healthSummary(quiet).deliveryQueues.failed, []);
    addFailedDelivery(quiet, () => assert.fail('nothing to add'));
  } finally {
    delete process.env.MOCK_FAILED_DELIVERY;
  }
  // Through the env vars on a real server: the timer broadcasts `health` with a higher count;
  // MOCK_FAILED_DELIVERY=off reports no failed queue in `health` or the hello snapshot.
  process.env.MOCK_FAILED_DELIVERY_EVERY = '0.2';
  const everyServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  delete process.env.MOCK_FAILED_DELIVERY_EVERY;
  try {
    const client = await connectClient(`ws://127.0.0.1:${everyServer.address().port}`, makeDevice(), 'dev-token');
    const grown = await client.waitEvent('health', (p) => p.deliveryQueues?.failed?.[0]?.count >= 2, 3000);
    assert.equal(grown.deliveryQueues.failed[0].queueName, FAILED_DELIVERY_QUEUE);
    assert.ok((await client.send('health')).deliveryQueues.failed[0].count >= 2);
    client.ws.close();
  } finally {
    await everyServer.close();
  }
  process.env.MOCK_FAILED_DELIVERY = 'off';
  const offServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token', failedDeliveryEvery: 0.1 });
  delete process.env.MOCK_FAILED_DELIVERY;
  try {
    const client = await connectClient(`ws://127.0.0.1:${offServer.address().port}`, makeDevice(), 'dev-token');
    assert.deepEqual(client.hello.snapshot.health.deliveryQueues.failed, []);
    await delay(300);
    assert.deepEqual((await client.send('health')).deliveryQueues.failed, []);
    client.ws.close();
  } finally {
    await offServer.close();
  }
  // Setup wizard: channels.status (WhatsApp not linked), skills.status (one missing CLI) and
  // WhatsApp QR login over web.login.* (admin only, not advertised).
  process.env.MOCK_WEB_LOGIN_WAIT_MS = '50';
  const setupServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const setupUrl = `ws://127.0.0.1:${setupServer.address().port}`;
    const setupAdminScopes = [...BASE_SCOPES, 'operator.admin'];
    const reader = await connectClient(setupUrl, makeDevice(), 'dev-token');
    const methods = reader.hello.features.methods;
    for (const m of ['health', 'status', 'config.schema', 'config.patch', 'channels.status', 'skills.status', 'agents.list', 'models.list', 'chat.send']) {
      assert.ok(methods.includes(m), `advertises ${m}`);
    }
    assert.ok(!methods.includes('web.login.start') && !methods.includes('web.login.wait'), 'web.login.* is not advertised');

    const channels = await reader.send('channels.status', { probe: false });
    assert.deepEqual(channels.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(channels.channelLabels.whatsapp, 'WhatsApp');
    assert.equal(channels.channelDefaultAccountId.discord, 'default');
    assert.equal(channels.channelAccounts.discord[0].connected, true);
    assert.equal(channels.channels.discord.connected, true);
    const wa = channels.channelAccounts.whatsapp[0];
    assert.equal(wa.accountId, 'default');
    assert.equal(wa.linked, false);
    assert.equal(wa.configured, false);
    assert.equal(channels.channelAccounts.slack[0].configured, false);
    assert.deepEqual(channels.statusIssues, [{ channel: 'whatsapp', accountId: 'default', kind: 'auth', message: WHATSAPP_NOT_LINKED, fix: WHATSAPP_RELINK_FIX }]);
    const probed = await reader.send('channels.status', { probe: true, timeoutMs: 1000, channel: 'discord' });
    assert.deepEqual(probed.channelOrder, ['discord']);
    assert.ok(probed.channelAccounts.discord[0].lastProbeAt > 0);
    assert.equal((await reader.call('channels.status', { channel: 'irc' })).error.message, 'unknown channel: irc');
    assert.equal((await reader.call('channels.status', { nope: 1 })).error.code, 'INVALID_REQUEST');
    // Health agrees: WhatsApp isn't configured yet, so it isn't a problem there.
    const setupHealth = await reader.send('health');
    assert.equal(setupHealth.channels.whatsapp.configured, false);
    assert.equal(setupHealth.channels.whatsapp.accounts.default.linked, false);

    // The wizard reads the same skills.status as the Skills page (skills.mjs).
    const skills = await reader.send('skills.status', {});
    assert.equal(skills.agentId, 'main');
    assert.ok(skills.workspaceDir && skills.managedSkillsDir);
    const missing = skills.skills.filter((s) => !s.eligible && !s.disabled && !s.blockedByAllowlist && !s.blockedByAgentFilter && !s.platformIncompatible);
    assert.deepEqual(missing.map((s) => s.name), ['github', 'video-frames', 'notion', 'voice-call']);
    assert.deepEqual(missing[0].missing, { bins: ['gh'], anyBins: [], env: [], config: [], os: [] });
    assert.deepEqual(missing[0].install, [{ id: 'brew', kind: 'brew', label: 'Install GitHub CLI (brew)', bins: ['gh'] }]);
    const otherOS = skills.skills.find((s) => s.name === 'apt-updates');
    assert.equal(otherOS.platformIncompatible, true);
    assert.deepEqual(otherOS.install, []);
    assert.ok(skills.skills.filter((s) => s.eligible).length >= 3);
    for (const s of skills.skills) {
      for (const key of ['name', 'description', 'source', 'bundled', 'filePath', 'baseDir', 'skillKey', 'always', 'disabled', 'modelVisible', 'userInvocable', 'commandVisible', 'requirements', 'configChecks']) {
        assert.ok(key in s, `skill ${s.name} has ${key}`);
      }
    }
    assert.equal((await reader.send('skills.status', { agentId: 'coder' })).agentId, 'coder');
    assert.equal((await reader.call('skills.status', { agentId: 'ghost' })).error.message, 'unknown agent id "ghost"');
    assert.equal((await reader.call('skills.status', { sessionKey: 'agent:main:nope' })).error.message, 'Session not found.');

    const denied = await reader.call('web.login.start', { channel: 'whatsapp' });
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.equal(denied.error.details.code, 'MISSING_SCOPE');
    assert.equal((await reader.call('web.login.wait', {})).error.details.scope, 'operator.admin');
    reader.ws.close();

    const admin = await connectClient(setupUrl, makeDevice(), 'dev-token', true, setupAdminScopes);
    assert.equal((await admin.call('web.login.start', { channel: 'discord' })).error.message, 'web login is not supported by provider discord');
    assert.equal((await admin.call('web.login.start', { channel: 'irc' })).error.message, 'web login provider is not available');
    assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).message, 'No active WhatsApp login in progress.');
    const start = await admin.send('web.login.start', { channel: 'whatsapp', force: false, timeoutMs: 30000 });
    assert.match(start.qrDataUrl, /^data:image\/png;base64,/);
    assert.ok(start.qrDataUrl.length <= 16_384, 'QR fits the schema limit');
    const png = Buffer.from(start.qrDataUrl.split(',')[1], 'base64');
    assert.equal(png.subarray(1, 4).toString('ascii'), 'PNG');
    assert.equal(start.message, 'Scan this QR in WhatsApp → Linked Devices.');
    assert.equal(start.connected, undefined);
    const again = await admin.send('web.login.start', { channel: 'whatsapp' });
    assert.equal(again.qrDataUrl, start.qrDataUrl, 'an active QR is reused');
    assert.match(again.message, /QR already active/);
    const stillWaiting = await admin.send('web.login.wait', { channel: 'whatsapp', timeoutMs: 10, currentQrDataUrl: start.qrDataUrl });
    assert.deepEqual(stillWaiting, { connected: false, message: 'Still waiting for the QR scan. Let me know when you’ve scanned it.' });
    const refreshed = await admin.send('web.login.wait', { channel: 'whatsapp', timeoutMs: 120000, currentQrDataUrl: start.qrDataUrl });
    assert.equal(refreshed.connected, false);
    assert.match(refreshed.qrDataUrl, /^data:image\/png;base64,/);
    assert.notEqual(refreshed.qrDataUrl, start.qrDataUrl, 'the QR rotates');
    const healthEvent = admin.waitEvent('health', (p) => p.channels?.whatsapp?.connected === true, 3000);
    const linked = await admin.send('web.login.wait', { timeoutMs: 120000, currentQrDataUrl: refreshed.qrDataUrl });
    assert.deepEqual(linked, { connected: true, message: '✅ Linked! WhatsApp is ready.' });
    await healthEvent;
    const after = await admin.send('channels.status', {});
    assert.equal(after.channelAccounts.whatsapp[0].linked, true);
    assert.equal(after.channelAccounts.whatsapp[0].connected, true);
    assert.equal(after.statusIssues, undefined, 'no issues once linked');
    assert.match((await admin.send('web.login.start', { channel: 'whatsapp' })).message, /already linked/);
    const relink = await admin.send('web.login.start', { channel: 'whatsapp', force: true });
    assert.match(relink.qrDataUrl, /^data:image\/png;base64,/);
    assert.equal((await admin.send('channels.status', {})).channelAccounts.whatsapp[0].linked, false, 'force relinks');
    assert.equal((await admin.call('web.login.wait', { currentQrDataUrl: 'nope' })).error.code, 'INVALID_REQUEST');
    process.env.MOCK_WEB_LOGIN = 'link';
    try {
      assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).connected, true, 'MOCK_WEB_LOGIN=link links on the first wait');
    } finally {
      delete process.env.MOCK_WEB_LOGIN;
    }
    admin.ws.close();
  } finally {
    delete process.env.MOCK_WEB_LOGIN_WAIT_MS;
    await setupServer.close();
  }


  // Channel status and lifecycle (#31): Discord connected, Telegram degraded, WhatsApp logged out,
  // Slack disabled; channels.start/stop/logout need operator.admin and change status and health.
  process.env.MOCK_WEB_LOGIN = 'link';
  process.env.MOCK_WEB_LOGIN_WAIT_MS = '20';
  const lifecycleServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const lcUrl = `ws://127.0.0.1:${lifecycleServer.address().port}`;
    const reader = await connectClient(lcUrl, makeDevice(), 'dev-token');
    for (const m of ['channels.status', ...CHANNEL_LIFECYCLE_METHODS]) assert.ok(reader.hello.features.methods.includes(m), `advertises ${m}`);
    const account = (status, channel) => status.channelAccounts[channel][0];
    const seeded = await reader.send('channels.status', {});
    assert.deepEqual(seeded.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(seeded.channelLabels.telegram, 'Telegram');
    const discord = account(seeded, 'discord');
    assert.equal(discord.running, true);
    assert.equal(discord.connected, true);
    assert.ok(discord.lastInboundAt > 0 && discord.lastOutboundAt > 0, 'Discord has recent activity');
    const telegram = account(seeded, 'telegram');
    assert.deepEqual([telegram.enabled, telegram.configured, telegram.running, telegram.connected], [true, true, true, false]);
    assert.equal(telegram.lastError, TELEGRAM_CONFLICT);
    assert.equal(telegram.healthState, 'disconnected');
    assert.ok(telegram.reconnectAttempts > 0);
    assert.equal(seeded.channels.telegram.lastError, TELEGRAM_CONFLICT, 'channel summary carries the error');
    const whatsapp = account(seeded, 'whatsapp');
    assert.deepEqual([whatsapp.enabled, whatsapp.configured, whatsapp.linked, whatsapp.running], [true, false, false, false]);
    assert.deepEqual([account(seeded, 'slack').enabled, account(seeded, 'slack').configured], [false, false]);
    // Probing fails for the degraded account and passes for the healthy one.
    const probed = await reader.send('channels.status', { probe: true, timeoutMs: 1000 });
    assert.deepEqual(account(probed, 'telegram').probe, { ok: false, error: TELEGRAM_CONFLICT, elapsedMs: 212 });
    assert.equal(account(probed, 'discord').probe.ok, true);
    assert.ok(account(probed, 'telegram').lastProbeAt > 0);
    assert.equal(account(probed, 'whatsapp').probe, undefined, 'unconfigured accounts are not probed');
    assert.equal(account(await reader.send('channels.status', {}), 'telegram').probe, undefined, 'plain status has no probe');
    // Health agrees with channels.status.
    const seededHealth = await reader.send('health');
    assert.deepEqual(seededHealth.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(seededHealth.channels.telegram.lastError, TELEGRAM_CONFLICT);
    assert.equal(seededHealth.channels.telegram.lifecycle, 'recovering');
    assert.equal(seededHealth.channels.telegram.accounts.default.connected, false);
    // Lifecycle needs operator.admin.
    for (const method of CHANNEL_LIFECYCLE_METHODS) {
      const denied = await reader.call(method, { channel: 'telegram' });
      assert.equal(denied.error.code, 'FORBIDDEN', method);
      assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }
    assert.equal(account(await reader.send('channels.status', {}), 'telegram').running, true, 'denied calls change nothing');

    const admin = await connectClient(lcUrl, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    assert.equal((await admin.call('channels.start', {})).error.code, 'INVALID_REQUEST');
    assert.equal((await admin.call('channels.stop', { channel: 'telegram', nope: 1 })).error.code, 'INVALID_REQUEST');
    assert.equal((await admin.call('channels.start', { channel: 'irc' })).error.message, 'invalid channels.start channel');
    assert.equal((await admin.call('channels.logout', { channel: 'slack' })).error.message, 'channel slack does not support logout');
    assert.equal((await admin.call('channels.logout', { channel: 'discord' })).error.message, 'channel discord does not support logout');
    assert.equal((await admin.send('health')).channels.discord.running, true, 'an unsupported logout stops nothing');
    // Starting a running account is a no-op the Gateway reports as owned by its task.
    assert.deepEqual(await admin.send('channels.start', { channel: 'discord' }),
      { channel: 'discord', accountId: 'default', started: true, outcome: { status: 'retry', reason: 'task-owned' } });
    // Reconnect Account: stop, then start, clears Telegram's conflict.
    const stoppedEvent = admin.waitEvent('health', (p) => p.channels?.telegram?.running === false, 3000);
    assert.deepEqual(await admin.send('channels.stop', { channel: 'telegram' }), { channel: 'telegram', accountId: 'default', stopped: true });
    const stoppedHealth = await stoppedEvent;
    assert.equal(stoppedHealth.channels.telegram.lifecycle, 'stopped');
    const stopped = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([stopped.running, stopped.connected, stopped.lastError], [false, false, null]);
    assert.ok(stopped.lastStopAt > 0);
    assert.deepEqual(await admin.send('channels.stop', { channel: 'telegram', accountId: 'default' }),
      { channel: 'telegram', accountId: 'default', stopped: true }, 'stopping twice is fine');
    const startedEvent = admin.waitEvent('health', (p) => p.channels?.telegram?.connected === true, 3000);
    assert.deepEqual(await admin.send('channels.start', { channel: 'telegram' }),
      { channel: 'telegram', accountId: 'default', started: true, outcome: { status: 'handed-off' } });
    await startedEvent;
    const reconnected = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([reconnected.running, reconnected.connected, reconnected.lastError, reconnected.reconnectAttempts], [true, true, null, 0]);
    assert.equal(reconnected.healthState, 'healthy');
    // Unknown accounts: stop is a no-op, start is skipped.
    assert.deepEqual(await admin.send('channels.start', { channel: 'discord', accountId: 'ghost' }),
      { channel: 'discord', accountId: 'ghost', started: false, outcome: { status: 'skipped', reason: 'unconfigured' } });
    assert.deepEqual(await admin.send('channels.start', { channel: 'slack' }),
      { channel: 'slack', accountId: 'default', started: false, outcome: { status: 'skipped', reason: 'disabled' } });
    // WhatsApp needs a QR login before it can start; once linked, stop/start/logout work.
    assert.deepEqual(await admin.send('channels.start', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', started: false, outcome: { status: 'skipped', reason: 'unlinked' } });
    assert.match((await admin.send('web.login.start', { channel: 'whatsapp' })).qrDataUrl, /^data:image\/png;base64,/);
    assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).connected, true);
    assert.equal(account(await admin.send('channels.status', {}), 'whatsapp').connected, true);
    await admin.send('channels.stop', { channel: 'whatsapp' });
    const waStopped = account(await admin.send('channels.status', {}), 'whatsapp');
    assert.deepEqual([waStopped.linked, waStopped.running, waStopped.connected], [true, false, false]);
    assert.equal((await admin.send('channels.start', { channel: 'whatsapp' })).outcome.status, 'handed-off');
    assert.equal(account(await admin.send('channels.status', {}), 'whatsapp').running, true);
    const loggedOutEvent = admin.waitEvent('health', (p) => p.channels?.whatsapp?.linked === false, 3000);
    assert.deepEqual(await admin.send('channels.logout', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', cleared: true, loggedOut: true });
    await loggedOutEvent;
    const waOut = await admin.send('channels.status', {});
    assert.deepEqual([account(waOut, 'whatsapp').linked, account(waOut, 'whatsapp').running], [false, false]);
    assert.equal(waOut.statusIssues[0].message, WHATSAPP_NOT_LINKED, 'logged out WhatsApp needs the QR again');
    assert.deepEqual(await admin.send('channels.logout', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', cleared: false, loggedOut: false }, 'nothing left to clear');
    // Logging out a token channel clears its credentials: not configured, and start is skipped.
    assert.deepEqual(await admin.send('channels.logout', { channel: 'telegram' }),
      { channel: 'telegram', accountId: 'default', cleared: true, loggedOut: true });
    const tgOut = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([tgOut.configured, tgOut.running, tgOut.tokenSource], [false, false, 'none']);
    assert.equal((await admin.send('channels.start', { channel: 'telegram' })).outcome.reason, 'unconfigured');
    // Discord stopped shows as stopped in health (a problem there) until started again.
    await admin.send('channels.stop', { channel: 'discord' });
    const discordStopped = await admin.send('health');
    assert.deepEqual([discordStopped.channels.discord.running, discordStopped.channels.discord.lifecycle], [false, 'stopped']);
    await admin.send('channels.start', { channel: 'discord' });
    assert.equal((await admin.send('health')).channels.discord.connected, true);
    reader.ws.close();
    admin.ws.close();
  } finally {
    delete process.env.MOCK_WEB_LOGIN;
    delete process.env.MOCK_WEB_LOGIN_WAIT_MS;
    await lifecycleServer.close();
  }

  await agentManagementSelftest();
  await subagentsSelftest();
  await devicePairingSelftest();
  await skillsToolsSelftest();
  console.log('PASS');
} finally {
  await server.close();
}
