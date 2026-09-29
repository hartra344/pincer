import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { connectClient, makeDevice } from './helpers.mjs';

async function sendAndFinish(client, message) {
  const started = await client.send('chat.send', {
    sessionKey: 'agent:main:main', message, idempotencyKey: `idem_${crypto.randomUUID()}`,
  });
  return client.waitEvent('chat', (p) => p.runId === started.runId && p.state === 'final', 30_000);
}

export async function run() {
  // Own server: earlier sections leave the shared client in an unknown state.
  const media = await startServer({ host: '127.0.0.1', port: 18922, pairing: 'off', mockToken: 'dev-token' });
  const conn = await connectClient('ws://127.0.0.1:18922', makeDevice(), 'dev-token', true);
  const client = conn.client ?? conn;
  try {
    await checkImages(client);
  } finally {
    conn.ws.close();
    await media.close();
  }
  await checkLongChat();
}

async function checkImages(client) {

  // `image huge`: one image whose artifact is over the 25 MiB cap, still a valid PNG.
  const huge = await sendAndFinish(client, 'image huge');
  const hugeBlocks = huge.message.content.filter((b) => b.type === 'image');
  assert.equal(hugeBlocks.length, 1);
  const hugeArtifact = await client.send('artifacts.download', { sessionKey: 'agent:main:main', artifactId: hugeBlocks[0].artifactId });
  assert.ok(hugeArtifact.data.length / 4 * 3 > 25 * 1024 * 1024, 'huge artifact is over 25 MiB');
  assert.equal(Buffer.from(hugeArtifact.data.slice(0, 16), 'base64').subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.ok(!huge.message.content.some((b) => b.artifactId === 'art-chart-1'), 'no small chart alongside');

  // `image many`: 40 distinct artifacts, 3000×2000 each.
  const many = await sendAndFinish(client, 'image many');
  const manyBlocks = many.message.content.filter((b) => b.type === 'image');
  assert.equal(manyBlocks.length, 40);
  assert.equal(new Set(manyBlocks.map((b) => b.artifactId)).size, 40);
  assert.ok(manyBlocks.every((b) => b.width === 3000 && b.height === 2000));
  const one = await client.send('artifacts.download', { sessionKey: 'agent:main:main', artifactId: manyBlocks[39].artifactId });
  const png = Buffer.from(one.data, 'base64');
  assert.equal(png.readUInt32BE(16), 3000);
  assert.equal(png.readUInt32BE(20), 2000);
  assert.ok(png.length < 25 * 1024 * 1024);

  // Plain `image` is unchanged.
  const plain = await sendAndFinish(client, 'show an image');
  assert.ok(plain.message.content.some((b) => b.type === 'image' && b.artifactId === 'art-chart-1'));

}

async function checkLongChat() {
  // MOCK_LONG_CHAT=<n>: one seeded chat with n mixed-length messages, paged like a real history.
  const long = await startServer({ host: '127.0.0.1', port: 18921, pairing: 'off', mockToken: 'dev-token', longChat: 3000 });
  try {
    const { ws, send } = await connectClient('ws://127.0.0.1:18921', makeDevice(), 'dev-token', true);
    const listed = await send('sessions.subscribe', { limit: 50 });
    assert.ok(listed.list.sessions.some((s) => s.key === 'agent:main:dashboard:long-chat'));
    const page = await send('chat.history', { sessionKey: 'agent:main:dashboard:long-chat', limit: 200 });
    assert.equal(page.totalMessages, 3000);
    assert.equal(page.messages.length, 200);
    assert.equal(page.hasMore, true);
    ws.close();
  } finally {
    await long.close();
  }
  const transcript = long.state.transcripts.get('agent:main:dashboard:long-chat');
  assert.equal(transcript.length, 3000);
  assert.deepEqual([transcript[0].role, transcript[1].role], ['user', 'assistant']);
  const lengths = transcript.map((m) => m.content[0].text.length);
  assert.ok(Math.max(...lengths) > 4 * Math.min(...lengths), 'mixed message lengths');
  assert.ok(transcript.every((m, i) => i === 0 || m.timestamp > transcript[i - 1].timestamp), 'timestamps ascend');
}
