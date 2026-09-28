import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import * as fileEdits from '../file-edits.mjs';
import { applyUnified } from './helpers.mjs';

export async function run(ctx) {
  const { client, sessions, history, final } = ctx;
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

  Object.assign(ctx, { done });
}
