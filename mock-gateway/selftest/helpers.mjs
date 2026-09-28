import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';

export function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

export function makeDevice() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const spki = publicKey.export({ format: 'der', type: 'spki' });
  const rawPublic = Buffer.from(spki).subarray(-32);
  const id = crypto.createHash('sha256').update(rawPublic).digest('hex');
  return { id, publicKey: b64url(rawPublic), privateKey };
}

export const BASE_SCOPES = ['operator.read', 'operator.write', 'operator.approvals', 'operator.questions'];

export function signConnect(device, challenge, token, scopes = BASE_SCOPES) {
  const client = {
    id: 'openclaw-macos',
    displayName: 'Pincer Selftest',
    version: '0.0.0',
    platform: 'macos',
    mode: 'ui',
    deviceFamily: 'desktop',
    instanceId: 'selftest',
  };
  const payload = `v2|${device.id}|${client.id}|${client.mode}|operator|${scopes.join(',')}|${challenge.ts}|${token}|${challenge.nonce}`;
  return {
    minProtocol: 4,
    maxProtocol: 4,
    client,
    role: 'operator',
    scopes,
    caps: ['tool-events'],
    auth: { token },
    device: {
      id: device.id,
      publicKey: device.publicKey,
      signature: b64url(crypto.sign(null, Buffer.from(payload, 'utf8'), device.privateKey)),
      signedAt: challenge.ts,
      nonce: challenge.nonce,
    },
  };
}

export async function connectClient(url, device, token, expectOk = true, scopes = BASE_SCOPES) {
  const ws = new WebSocket(url);
  const emitter = new EventEmitter();
  const pending = new Map();
  let nextId = 1;
  let challenge;
  let hello;

  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    if (msg.type === 'event') {
      if (msg.event === 'connect.challenge') challenge = msg.payload;
      emitter.emit(msg.event, msg.payload);
      emitter.emit('*', msg.event, msg.payload);
    } else if (msg.type === 'res') {
      const p = pending.get(msg.id);
      if (p) {
        pending.delete(msg.id);
        p(msg);
      }
    }
  });

  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  await waitUntil(() => challenge, 1000, 'challenge');
  const id = `req_${nextId++}`;
  const connectResP = new Promise((resolve) => pending.set(id, resolve));
  ws.send(JSON.stringify({ type: 'req', id, method: 'connect', params: signConnect(device, challenge, token, scopes) }));
  const connectRes = await connectResP;
  if (expectOk) {
    assert.equal(connectRes.ok, true, JSON.stringify(connectRes));
    hello = connectRes.payload;
    assert.equal(hello.type, 'hello-ok');
  } else {
    assert.equal(connectRes.ok, false, JSON.stringify(connectRes));
    return { ws, connectRes };
  }

  function call(method, params = {}) {
    const reqId = `req_${nextId++}`;
    const p = new Promise((resolve) => pending.set(reqId, resolve));
    ws.send(JSON.stringify({ type: 'req', id: reqId, method, params }));
    return p;
  }

  function send(method, params = {}) {
    return call(method, params).then((res) => {
      assert.equal(res.ok, true, `${method} failed: ${JSON.stringify(res)}`);
      return res.payload;
    });
  }

  function waitEvent(name, predicate = () => true, timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`timed out waiting for ${name}`));
      }, timeoutMs);
      function handler(payload) {
        try {
          if (predicate(payload)) {
            cleanup();
            resolve(payload);
          }
        } catch (err) {
          cleanup();
          reject(err);
        }
      }
      function cleanup() {
        clearTimeout(timer);
        emitter.off(name, handler);
      }
      emitter.on(name, handler);
    });
  }

  return { ws, hello, send, call, waitEvent, emitter };
}

// Applies a headers-only unified diff (as upstream's `details.patch`) to `text`.
export function applyUnified(text, patch) {
  const source = text === '' ? [] : text.replace(/\n$/, '').split('\n');
  const out = [];
  let cursor = 0;
  for (const hunk of patch.split(/^(?=@@ )/m).slice(1)) {
    const [header, ...body] = hunk.replace(/\n$/, '').split('\n');
    const oldStart = Number(/^@@ -(\d+)/.exec(header)[1]);
    const start = oldStart === 0 ? 0 : oldStart - 1;
    out.push(...source.slice(cursor, start));
    cursor = start;
    for (const line of body) {
      if (line[0] === '+') out.push(line.slice(1));
      else {
        assert.equal(source[cursor], line.slice(1), `patch context at line ${cursor + 1}`);
        if (line[0] === ' ') out.push(line.slice(1));
        cursor++;
      }
    }
  }
  out.push(...source.slice(cursor));
  return out.length ? `${out.join('\n')}\n` : '';
}

export async function waitUntil(fn, timeoutMs, label) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const value = fn();
    if (value) return value;
    await delay(20);
  }
  throw new Error(`timed out waiting for ${label}`);
}

// One connect with an arbitrary `auth` object; resolves with the response and close code.
export async function rawConnect(url, device, auth, scopes = BASE_SCOPES, { waitChallengeMs = 1000 } = {}) {
  const ws = new WebSocket(url);
  let challenge;
  let connectRes;
  const events = [];
  const closed = new Promise((resolve) => ws.once('close', (code) => resolve(code)));
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString('utf8'));
    if (msg.type === 'event') {
      if (msg.event === 'connect.challenge') challenge = msg.payload;
      events.push(msg.event);
    } else if (msg.type === 'res') connectRes = msg;
  });
  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  try {
    await waitUntil(() => challenge, waitChallengeMs, 'challenge');
  } catch {
    ws.close();
    return { challenge: undefined, events };
  }
  const params = signConnect(device, challenge, auth.token ?? '', scopes);
  params.auth = auth;
  ws.send(JSON.stringify({ type: 'req', id: 'c1', method: 'connect', params }));
  await waitUntil(() => connectRes, 2000, 'connect response');
  const closeCode = connectRes.ok ? undefined : await Promise.race([closed, delay(1000).then(() => undefined)]);
  return { ws, challenge, connectRes, closeCode, events };
}
