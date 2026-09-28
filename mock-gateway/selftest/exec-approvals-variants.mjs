import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { port, url, device, deviceToken, message, adminScopes, changed, policy } = ctx;
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

}
