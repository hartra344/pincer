import assert from 'node:assert/strict';
import { EXEC_OUTPUT, FAILED_OUTPUT, TOOL_CARDS_KEY } from '../tool-cards.mjs';

export async function run(ctx) {
  const { client } = ctx;
  const messages = (await client.send('chat.history', { sessionKey: TOOL_CARDS_KEY })).messages;
  const calls = messages.flatMap((m) => m.content.filter((b) => b.type === 'toolCall'));
  assert.deepEqual(calls.map((c) => c.name), ['exec', 'exec', 'read', 'edit', 'github__search_issues', 'web_fetch',
    'linear__create_issue', 'linear__list_teams', 'linear__update_issue', 'mcp__filesystem__read_file', 'acme-docs__search']);
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
}
