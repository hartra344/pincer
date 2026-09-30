import assert from 'node:assert/strict';
import { EXEC_OUTPUT, FAILED_OUTPUT, SWIFT_TEXT, TOOL_CARDS_KEY } from '../tool-cards.mjs';

export async function run(ctx) {
  const { client } = ctx;
  const messages = (await client.send('chat.history', { sessionKey: TOOL_CARDS_KEY })).messages;
  const calls = messages.flatMap((m) => m.content.filter((b) => b.type === 'toolCall'));
  assert.deepEqual(calls.map((c) => c.name), ['exec', 'exec', 'read', 'edit', 'github__search_issues', 'web_fetch',
    'linear__create_issue', 'linear__list_teams', 'linear__update_issue', 'mcp__filesystem__read_file', 'acme-docs__search', 'web_search', 'read']);
  const resultFor = (id) => messages.find((m) => m.role === 'toolResult' && m.toolCallId === id);
  const exec = resultFor(calls[0].id);
  assert.equal(exec.content[0].text, EXEC_OUTPUT);
  assert.equal(exec.details.exitCode, 0);
  assert.equal(exec.details.aggregated, EXEC_OUTPUT);
  const failed = resultFor(calls[1].id);
  assert.equal(failed.isError, true);
  assert.equal(failed.details.exitCode, 1);
  assert.equal(failed.content[0].text, FAILED_OUTPUT);
  assert.equal(resultFor(calls[5].id).details.status, 200);
  assert.ok(Array.isArray(JSON.parse(resultFor(calls[4].id).content[0].text)));
  assert.equal(calls[6].arguments.priority, 2);
  assert.ok(JSON.parse(resultFor(calls[6].id).content[0].text).id);
  assert.deepEqual(calls[7].arguments, {});
  assert.equal(resultFor(calls[8].id).isError, true);
  assert.equal(exec.details.durationMs, 1240);
  const search = resultFor(calls[11].id);
  const payload = search.details;
  assert.equal(payload.kind, 'results');
  assert.equal(payload.provider, 'brave');
  assert.equal(payload.count, payload.results.length);
  assert.equal(payload.results.length, 5);
  assert.equal(typeof payload.tookMs, 'number');
  assert.deepEqual(payload.externalContent, { untrusted: true, source: 'web_search', wrapped: true, provider: 'brave' });
  assert.equal(search.content[0].text, JSON.stringify(payload, null, 2));
  const envelope = /^<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>\nSource: Web Search\n---\n[\s\S]+\n<<<END_EXTERNAL_UNTRUSTED_CONTENT id="\1">>>$/;
  for (const row of payload.results) {
    assert.match(row.title, envelope);
    assert.match(row.url, /^https:\/\//);
    if (row.snippet) assert.match(row.snippet, envelope);
    if (row.siteName) assert.match(row.siteName, envelope);
  }
  assert.ok(payload.results.some((row) => !row.snippet), 'one result has no snippet');
  assert.equal(calls[12].arguments.path.endsWith('.swift'), true);
  assert.equal(resultFor(calls[12].id).content[0].text, SWIFT_TEXT);
}
