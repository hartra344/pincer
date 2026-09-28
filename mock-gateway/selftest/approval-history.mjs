import assert from 'node:assert/strict';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { url, device, deviceToken, history, message } = ctx;
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
}
