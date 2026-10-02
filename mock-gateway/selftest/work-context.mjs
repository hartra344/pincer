import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { captureWorkContext, validWorkContext, withWorkContext, projectWorkContextForDisplay } from '../work-context.mjs';

export async function run(ctx) {
  const { client } = ctx;
  const authored = 'Nearby cafe';
  const context = { page: 'Pincer location', selection: 'Location context (shared by Pincer): 📍 37.774900, -122.419400 ±18m; observed 2027-01-15T08:00:00Z' };
  assert.equal(validWorkContext(context), true);
  assert.equal(validWorkContext({ ...context, selection: 'x'.repeat(641) }), false);
  assert.deepEqual(captureWorkContext(context), context);
  const prepared = withWorkContext(authored, context);
  assert.equal(prepared.facts.workContext.text, authored);
  assert.ok(prepared.text.includes(context.selection));
  for (const command of ['/help', '!uptime']) assert.deepEqual(withWorkContext(command, context), { text: command, facts: {} });
  const raw = { role: 'user', content: [{ type: 'input_text', text: prepared.text }, { type: 'text', text: 'duplicate' }, { type: 'image', artifactId: 'image' }],
    __openclaw: { id: 'stable', workContext: prepared.facts.workContext } };
  const projected = projectWorkContextForDisplay(raw);
  assert.equal(projected.content[0].text, authored);
  assert.equal(projected.content[1].artifactId, 'image');
  assert.equal(projected.__openclaw.id, 'stable');
  assert.equal(projected.__openclaw.workContext.text, undefined);
  assert.equal(raw.content[0].text, prepared.text);
  assert.deepEqual(projectWorkContextForDisplay(projected), projected);
  const idempotencyKey = `location_${crypto.randomUUID()}`;
  const committed = client.waitEvent('session.message', (event) => event.message?.__openclaw?.idempotencyKey === `${idempotencyKey}:user`, 10_000);
  const params = { sessionKey: 'agent:main:main', message: authored, idempotencyKey, workContext: context };
  const send = await client.send('chat.send', params);
  const event = await committed;
  assert.ok(event.message.content[0].text.includes(context.selection), 'raw session.message contains actual model context');
  assert.equal(event.message.__openclaw.workContext.text, authored);
  assert.deepEqual(event.message.__openclaw.workContext.snapshot, context);
  const duplicate = await client.send('chat.send', params);
  assert.equal(duplicate.runId, send.runId);
  const history = await client.send('chat.history', { sessionKey: params.sessionKey, limit: 20 });
  const copies = history.messages.filter((message) => message.__openclaw?.idempotencyKey === `${idempotencyKey}:user`);
  assert.equal(copies.length, 1);
  assert.equal(copies[0].content[0].text, authored);
  assert.deepEqual(copies[0].__openclaw.workContext, { snapshot: context });
  await client.send('chat.abort', { sessionKey: params.sessionKey, runId: send.runId });
}
