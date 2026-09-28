import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { server, url, device, deviceToken, agents, sessions, final, message, requested, unknown, missing, always, admin, invalid, changed } = ctx;
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

  Object.assign(ctx, { policy });
}
