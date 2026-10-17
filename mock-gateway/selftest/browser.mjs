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
  await runControls();
  await runStreamShapes();
}

const BACK = '() => { history.go(-1); return true; }';
const FORWARD = '() => { history.go(1); return true; }';

async function withAdmin(env, body) {
  const saved = {};
  for (const [key, value] of Object.entries(env)) { saved[key] = process.env[key]; process.env[key] = value; }
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const port = server.address().port;
    const admin = await connectClient(`ws://127.0.0.1:${port}`, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    await body(admin, port);
    admin.ws.close();
  } finally {
    await server.close();
    for (const [key, value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  }
}

// PR 3: navigation, history, tabs, evaluate, download and the hooks.
async function runControls() {
  await withAdmin({}, async (admin, port) => {
    const req = (method, path, body) => admin.call('browser.request', { method, path, body });
    const ok = async (method, path, body) => { const r = await req(method, path, body); assert.equal(r.ok, true, JSON.stringify(r.error)); return r.payload; };
    const t1 = BROWSER_TABS[0].targetId;

    const nav = await ok('POST', '/navigate', { url: 'http://example.com/', targetId: t1 });
    assert.equal(nav.ok, true);
    assert.equal(nav.targetId, t1);
    assert.equal(nav.url, 'http://example.com/');
    let list = (await ok('GET', '/tabs')).tabs;
    assert.equal(list[0].url, 'http://example.com/');
    assert.equal(list[0].title, 'Example Domain');
    assert.equal((await req('POST', '/navigate', { url: 'javascript:alert(1)', targetId: t1 })).error.code, 'INVALID_REQUEST');

    const blocked = await req('POST', '/navigate', { url: 'https://blocked.example/x', targetId: t1 });
    assert.equal(blocked.ok, false);
    assert.equal(blocked.error.details.reason, 'navigation_blocked');

    await ok('POST', '/act', { kind: 'evaluate', targetId: t1, fn: BACK });
    list = (await ok('GET', '/tabs')).tabs;
    assert.equal(list[0].url, BROWSER_TABS[0].url);
    await ok('POST', '/act', { kind: 'evaluate', targetId: t1, fn: FORWARD });
    assert.equal((await ok('GET', '/tabs')).tabs[0].url, 'http://example.com/');
    assert.equal((await req('POST', '/act', { kind: 'evaluate', targetId: t1, fn: '() => document.cookie' })).error.code, 'INVALID_REQUEST');

    const opened = await ok('POST', '/tabs/open', { url: 'https://docs.openclaw.ai/' });
    assert.ok(opened.targetId && opened.title === 'OpenClaw Docs' && opened.url === 'https://docs.openclaw.ai/');
    assert.equal((await ok('GET', '/tabs')).tabs.length, 3);
    await ok('DELETE', `/tabs/${encodeURIComponent(opened.targetId)}`);
    assert.equal((await ok('GET', '/tabs')).tabs.length, 2);
    assert.equal((await req('DELETE', `/tabs/${encodeURIComponent(opened.targetId)}`)).ok, false);

    // A screencast viewer follows the page: meta message on navigation, close 4004 when the tab closes.
    const cast = await ok('POST', '/screencast', { targetId: t1 });
    const viewer = await collect(`ws://127.0.0.1:${port}${cast.wsPath}`, 99, {
      onOpen: () => { setTimeout(() => ok('POST', '/navigate', { url: 'https://docs.openclaw.ai/', targetId: t1 }), 100); setTimeout(() => ok('DELETE', `/tabs/${t1}`), 400); },
    });
    assert.ok(viewer.messages.some((m) => !m.isBinary && JSON.parse(m.data.toString()).type === 'meta'), 'meta on navigation');
    assert.equal(viewer.close, 4004);

    const t2 = BROWSER_TABS[1].targetId;
    const dl = (await ok('POST', '/download', { targetId: t2, currentDocument: true, expectedUrl: BROWSER_TABS[1].url, timeoutMs: 10000 })).download;
    assert.ok(dl.path.startsWith('/') && dl.suggestedFilename.endsWith('.html'));
    assert.equal((await req('POST', '/download', { targetId: t2, currentDocument: true, expectedUrl: 'https://elsewhere.test/' })).ok, false);
    const media = `http://127.0.0.1:${port}/__openclaw__/assistant-media?source=${encodeURIComponent(dl.path)}`;
    assert.equal((await fetch(media)).status, 401);
    const got = await fetch(media, { headers: { authorization: 'Bearer dev-token' } });
    assert.equal(got.status, 200);
    assert.match(await got.text(), /<h1>/);
    assert.equal((await fetch(`${media}x`, { headers: { authorization: 'Bearer dev-token' } })).status, 404);
  });

  await withAdmin({ MOCK_BROWSER_RETARGET: '1' }, async (admin) => {
    const t1 = BROWSER_TABS[0].targetId;
    const nav = (await admin.send('browser.request', { method: 'POST', path: '/navigate', body: { url: 'https://example.com/', targetId: t1 } }));
    assert.notEqual(nav.targetId, t1);
    assert.equal((await admin.send('browser.request', { method: 'GET', path: '/tabs' })).tabs[0].targetId, nav.targetId);
  });

  await withAdmin({ MOCK_BROWSER_EVALUATE_DISABLED: '1' }, async (admin) => {
    const r = await admin.call('browser.request', { method: 'POST', path: '/act', body: { kind: 'evaluate', targetId: BROWSER_TABS[0].targetId, fn: BACK } });
    assert.equal(r.ok, false);
    assert.equal(r.error.details.code, 'ACT_EVALUATE_DISABLED');
  });

  await withAdmin({ MOCK_BROWSER_STOPPED: '1' }, async (admin) => {
    const stopped = await admin.send('browser.request', { method: 'GET', path: '/tabs' });
    assert.equal(stopped.running, false);
    assert.equal((await admin.call('browser.request', { method: 'POST', path: '/navigate', body: { url: 'https://example.com/', targetId: BROWSER_TABS[0].targetId } })).ok, false);
    await admin.send('browser.request', { method: 'POST', path: '/start', body: {} });
    const running = await admin.send('browser.request', { method: 'GET', path: '/tabs' });
    assert.equal(running.running, true);
    assert.equal(running.tabs.length, 2);
  });
}

// #1027: upstream-shaped stream behaviour: static pages, unsupported browsers and viewport resize.
async function runStreamShapes() {
  await withAdmin({}, async (admin, port) => {
    const ok = async (method, path, body) => { const r = await admin.call('browser.request', { method, path, body }); assert.equal(r.ok, true, JSON.stringify(r.error)); return r.payload; };
    const tabs = await ok('GET', '/tabs');
    assert.equal(tabs.canAutoResizeViewport, true);
    const t1 = tabs.tabs[0].targetId;
    const open = async (url) => (await ok('POST', '/tabs/open', { url })).targetId;
    const wsFor = async (targetId) => `ws://127.0.0.1:${port}${(await ok('POST', '/screencast', { targetId })).wsPath}`;

    // A static page: ready, then nothing until it repaints.
    const staticId = await open('https://static.example/');
    const quiet = await collect(await wsFor(staticId), 2, { timeoutMs: 700 }).catch((e) => e);
    assert.ok(quiet instanceof Error, 'a static page sends no frames after ready');
    const repainted = collect(await wsFor(staticId), 2);
    await new Promise((r) => setTimeout(r, 150));
    await ok('POST', '/act', { kind: 'resize', targetId: staticId, width: 500, height: 900 });
    const got = await repainted;
    assert.equal(JSON.parse(got.messages[0].data.toString('utf8')).type, 'ready');
    const resized = decodeFrame(got.messages[1].data).header;
    assert.deepEqual([resized.cssWidth, resized.cssHeight], [500, 900]);

    // The default viewport is landscape; resize is validated like upstream.
    const first = decodeFrame((await collect(await wsFor(t1), 2)).messages[1].data).header;
    assert.ok(first.cssWidth > first.cssHeight);
    const bad = await admin.call('browser.request', { method: 'POST', path: '/act', body: { kind: 'resize', targetId: t1, width: 0, height: 10 } });
    assert.equal(bad.ok, false);

    // An unsupported browser: ready, then close 4005.
    const unsupportedId = await open('https://unsupported.example/');
    const closed = await collect(await wsFor(unsupportedId), 99);
    assert.equal(closed.close, 4005);
  });
}
