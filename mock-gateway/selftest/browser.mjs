import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { startServer } from '../server.mjs';
import { BROWSER_METHODS, BROWSER_TABS, CASE_BAD_LENGTH, CASE_OVERSIZED_HEADER } from '../browser.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Reads messages from the screencast socket until `count` have arrived or the socket closes.
function collect(url, count, { timeoutMs = 3000, onOpen } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const out = { messages: [], close: undefined };
    const timer = setTimeout(() => { ws.terminate(); reject(new Error('screencast timed out')); }, timeoutMs);
    const finish = () => { clearTimeout(timer); resolve(out); };
    ws.on('open', () => onOpen?.(ws));
    ws.on('message', (data, isBinary) => {
      out.messages.push({ isBinary, data: Buffer.from(data) });
      if (out.messages.length >= count) { ws.close(); }
    });
    ws.on('unexpected-response', (_req, res) => { out.status = res.statusCode; finish(); });
    ws.on('close', (code) => { out.close = code; finish(); });
    ws.on('error', () => {});
  });
}

function decodeFrame(buf) {
  const headerLength = buf.readUInt32BE(0);
  const header = JSON.parse(buf.subarray(4, 4 + headerLength).toString('utf8'));
  return { header, jpeg: buf.subarray(4 + headerLength) };
}

// Fresh server so tokens and sockets don't leak into the shared selftest server.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const port = server.address().port;
    const url = `ws://127.0.0.1:${port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    for (const method of BROWSER_METHODS) assert.ok(admin.hello.features.methods.includes(method), method);

    const gated = await reader.call('browser.request', { method: 'GET', path: '/tabs' });
    assert.equal(gated.ok, false);
    assert.equal(gated.error.code, 'FORBIDDEN');
    assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });

    const tabs = await admin.send('browser.request', { method: 'GET', path: '/tabs', query: { profile: 'openclaw' }, target: 'host' });
    assert.equal(tabs.running, true);
    assert.equal(tabs.canAutoResizeViewport, true);
    assert.deepEqual(tabs.tabs.map((tab) => [tab.targetId, tab.title]), BROWSER_TABS.map((tab) => [tab.targetId, tab.title]));
    assert.ok(tabs.tabs.every((tab) => /^https:\/\//.test(tab.url)));

    const bad = await admin.call('browser.request', { method: 'POST', path: '/screencast', body: { targetId: 'nope' } });
    assert.equal(bad.ok, false);
    assert.equal(bad.error.code, 'INVALID_REQUEST');

    const mint = (targetId) => admin.send('browser.request', {
      method: 'POST', path: '/screencast', body: { targetId, maxWidth: 800, maxHeight: 600 },
    });
    const minted = await mint(tabs.tabs[0].targetId);
    assert.equal(minted.targetId, tabs.tabs[0].targetId);
    assert.equal(minted.url, tabs.tabs[0].url);
    assert.ok(minted.token);
    assert.equal(minted.wsPath, `/browser/screencast?token=${minted.token}`);
    assert.equal(typeof minted.expiresAtMs, 'number');

    const wsUrl = `ws://127.0.0.1:${port}${minted.wsPath}`;
    const live = await collect(wsUrl, 3);
    const [ready, ...frames] = live.messages;
    assert.equal(ready.isBinary, false);
    assert.deepEqual(JSON.parse(ready.data.toString('utf8')), { type: 'ready', targetId: tabs.tabs[0].targetId, url: tabs.tabs[0].url, title: tabs.tabs[0].title });
    assert.ok(frames.length >= 1 && frames.every((m) => m.isBinary));
    const { header, jpeg } = decodeFrame(frames[0].data);
    assert.equal(header.url, tabs.tabs[0].url);
    assert.equal(typeof header.cssWidth, 'number');
    assert.equal(typeof header.cssHeight, 'number');
    assert.equal(typeof header.ts, 'number');
    assert.deepEqual([...jpeg.subarray(0, 3)], [0xff, 0xd8, 0xff]);
    assert.deepEqual([...jpeg.subarray(-2)], [0xff, 0xd9]);

    // Tokens are one-time, like upstream.
    assert.equal((await collect(wsUrl, 1)).status, 401);
    assert.equal((await collect(`ws://127.0.0.1:${port}/browser/screencast?token=bogus`, 1)).status, 401);

    // View-only: binary from the client closes the socket with 1003.
    const viewOnly = await collect(`ws://127.0.0.1:${port}${(await mint(tabs.tabs[1].targetId)).wsPath}`, 99, {
      onOpen: (ws) => ws.send(Buffer.from([1, 2, 3]), { binary: true }),
    });
    assert.equal(viewOnly.close, 1003);

    // Malformed-frame hooks, by minted token prefix and by ?case= on the URL.
    const badLength = await collect(`ws://127.0.0.1:${port}${(await mint(CASE_BAD_LENGTH)).wsPath}`, 2);
    const badFrame = badLength.messages[1].data;
    assert.ok(badFrame.readUInt32BE(0) > badFrame.length - 4, 'header length exceeds the data');
    const viaCase = await collect(`ws://127.0.0.1:${port}${(await mint(tabs.tabs[0].targetId)).wsPath}&case=${CASE_OVERSIZED_HEADER}`, 2);
    assert.equal(viaCase.messages[0].isBinary, false);
    assert.ok(viaCase.messages[1].data.readUInt32BE(0) > 64 * 1024, 'header over 64 KiB');
    const oversized = await collect(`ws://127.0.0.1:${port}${(await mint(CASE_OVERSIZED_HEADER)).wsPath}`, 2);
    assert.ok(oversized.messages[1].data.readUInt32BE(0) > 64 * 1024);

    admin.ws.close();
    reader.ws.close();
  } finally {
    await server.close();
  }
}
