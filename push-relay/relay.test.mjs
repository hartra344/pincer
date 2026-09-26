import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http2 from 'node:http2';
import { after, before, beforeEach, test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { apnsHeaders, createProviderToken, createRelay, loadEnvFile, openId, sealId } from './relay.mjs';

const SECRET = 'test-secret-that-is-at-least-32-characters';
const TOKEN = 'ab'.repeat(32);
const GATEWAY = '0f8fad5b-d9cb-469f-a165-70867728950e';
const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });

let apns;
let apnsOrigin;
let requests = [];
let respond = () => ({ status: 200 });
let relay;
let relayOrigin;

before(async () => {
  apns = http2.createServer();
  apns.on('stream', (stream, headers) => {
    const chunks = [];
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      const request = { headers, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) };
      requests.push(request);
      const { status, reason } = respond(request);
      stream.respond({ ':status': status });
      stream.end(reason ? JSON.stringify({ reason }) : '');
    });
  });
  await new Promise((resolve) => apns.listen(0, '127.0.0.1', resolve));
  apnsOrigin = `http://127.0.0.1:${apns.address().port}`;
  relay = createRelay({
    secret: SECRET,
    keyId: 'KEY123',
    teamId: 'TEAM123',
    key: privateKey,
    origins: { production: `${apnsOrigin}`, sandbox: `${apnsOrigin}` },
    ratePerMinute: 5,
    log: () => {},
  });
  await new Promise((resolve) => relay.listen(0, '127.0.0.1', resolve));
  relayOrigin = `http://127.0.0.1:${relay.address().port}`;
});

after(async () => {
  await new Promise((resolve) => relay.close(resolve));
  await new Promise((resolve) => apns.close(resolve));
});

beforeEach(() => {
  requests = [];
  respond = () => ({ status: 200 });
});

async function register(body) {
  const res = await fetch(`${relayOrigin}/v1/register`, { method: 'POST', body: JSON.stringify(body) });
  return { status: res.status, json: await res.json() };
}

function webPushBody(size = 200) {
  return crypto.randomBytes(size);
}

async function push(id, { gateway = GATEWAY, body = webPushBody(), headers = {} } = {}) {
  const res = await fetch(`${relayOrigin}/v1/push/${id}/${gateway}`, {
    method: 'POST',
    headers: { 'content-encoding': 'aes128gcm', ttl: '300', urgency: 'high', topic: 'abcDEF_-123', ...headers },
    body,
  });
  return res.status;
}

test('sealed ids round-trip and resist tampering', () => {
  const id = sealId(SECRET, TOKEN, 'sandbox', 'chat.pincer.ios');
  assert.deepEqual(openId(SECRET, id), { token: TOKEN, environment: 'sandbox', topic: 'chat.pincer.ios' });
  assert.equal(openId('another-secret-that-is-32-characters-long', id), null);
  const raw = Buffer.from(id, 'base64url');
  raw[20] ^= 1;
  assert.equal(openId(SECRET, raw.toString('base64url')), null);
  assert.equal(openId(SECRET, 'garbage'), null);
  assert.ok(!id.includes(TOKEN), 'token is not visible in the endpoint');
});

test('register validates the token, environment and app', async () => {
  assert.equal((await register({ token: 'nothex', environment: 'production' })).status, 400);
  assert.equal((await register({ token: TOKEN, environment: 'staging' })).status, 400);
  assert.equal((await register({ token: TOKEN, environment: 'production', topic: 'com.evil' })).status, 400);
  const ok = await register({ token: TOKEN, environment: 'production', topic: 'chat.pincer.ios' });
  assert.equal(ok.status, 200);
  assert.match(ok.json.id, /^[A-Za-z0-9_-]+$/);
});

test('push forwards the encrypted body to APNs with mapped headers', async () => {
  const { json } = await register({ token: TOKEN, environment: 'production' });
  const body = webPushBody(240);
  assert.equal(await push(json.id, { body }), 201);
  assert.equal(requests.length, 1);
  const [{ headers, body: payload }] = requests;
  assert.equal(headers[':path'], `/3/device/${TOKEN}`);
  assert.equal(headers['apns-topic'], 'chat.pincer.ios');
  assert.equal(headers['apns-push-type'], 'alert');
  assert.equal(headers['apns-priority'], '10');
  assert.equal(headers['apns-collapse-id'], 'abcDEF_-123');
  assert.ok(Number(headers['apns-expiration']) > Date.now() / 1000);
  assert.match(headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(payload.aps['mutable-content'], 1);
  assert.equal(payload.pincer.g, GATEWAY);
  assert.deepEqual(Buffer.from(payload.pincer.p, 'base64url'), body, 'body is forwarded untouched');
});

test('provider token is a valid ES256 JWT for the team and key', () => {
  const jwt = createProviderToken({ keyId: 'KEY123', teamId: 'TEAM123', key: privateKey })();
  const [header, claims, signature] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEY123' });
  assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iss, 'TEAM123');
  assert.ok(crypto.verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature, 'base64url')));
});

test('rejects unknown ids, bad gateways, wrong encodings and oversized bodies', async () => {
  const { json } = await register({ token: TOKEN, environment: 'production' });
  assert.equal(await push('nope'), 404);
  assert.equal(await push(json.id, { gateway: 'not-a-uuid' }), 404);
  assert.equal(await push(json.id, { headers: { 'content-encoding': 'aesgcm' } }), 415);
  assert.equal(await push(json.id, { body: webPushBody(4000) }), 413);
  assert.equal(await push(json.id, { body: webPushBody(40) }), 400);
  assert.equal(requests.length, 0);
});

test('retries the other APNs environment on BadDeviceToken', async () => {
  const { json } = await register({ token: TOKEN, environment: 'production' });
  let calls = 0;
  respond = () => (++calls === 1 ? { status: 400, reason: 'BadDeviceToken' } : { status: 200 });
  assert.equal(await push(json.id), 201);
  assert.equal(requests.length, 2);
});

test('expired tokens become 410 so the Gateway drops the subscription', async () => {
  const { json } = await register({ token: TOKEN, environment: 'production' });
  respond = () => ({ status: 410, reason: 'Unregistered' });
  assert.equal(await push(json.id), 410);
  respond = () => ({ status: 400, reason: 'BadDeviceToken' });
  assert.equal(await push(json.id), 410);
  respond = () => ({ status: 500, reason: 'InternalServerError' });
  assert.equal(await push(json.id), 502);
});

test('rate limits each registration', async () => {
  const { json } = await register({ token: 'cd'.repeat(32), environment: 'production' });
  const statuses = [];
  for (let i = 0; i < 7; i += 1) statuses.push(await push(json.id));
  assert.deepEqual(statuses.slice(0, 5), [201, 201, 201, 201, 201]);
  assert.equal(statuses[6], 429);
});

test('maps Web Push TTL and urgency', () => {
  assert.equal(apnsHeaders({ ttl: '60', urgency: 'low' }, 1000)['apns-expiration'], '1060');
  assert.equal(apnsHeaders({ ttl: '60', urgency: 'low' }, 1000)['apns-priority'], '5');
  assert.equal(apnsHeaders({ ttl: '0' }, 1000)['apns-expiration'], '0');
  assert.equal(apnsHeaders({ topic: 'has spaces' }, 1000)['apns-collapse-id'], undefined);
});

test('end to end: a Gateway Web Push reaches APNs still encrypted, and decrypts with the device keys', async () => {
  const { createWebPushState, decryptWebPush, handleWebPushEvent } = await import('../mock-gateway/webpush.mjs');
  const device = crypto.createECDH('prime256v1');
  device.generateKeys();
  const auth = crypto.randomBytes(16).toString('base64url');
  const { json } = await register({ token: TOKEN, environment: 'sandbox' });
  const endpoint = `${relayOrigin}/v1/push/${json.id}/${GATEWAY}`;
  const state = { webPushState: createWebPushState() };
  state.webPushState.subscriptions.set(endpoint, { endpoint, keys: { p256dh: device.getPublicKey().toString('base64url'), auth } });

  handleWebPushEvent(state, 'exec.approval.requested', { id: 'appr-1' });
  const deadline = Date.now() + 3000;
  while (!state.webPushState.deliveries.length && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  assert.equal(state.webPushState.deliveries[0]?.status, 201);
  assert.equal(requests.length, 1);
  const [{ headers, body: payload }] = requests;
  assert.equal(headers['apns-priority'], '10');
  assert.equal(headers['apns-collapse-id'].length, 32);
  assert.ok(!JSON.stringify(payload).includes('approval requested'), 'APNs never sees the plaintext');
  const message = JSON.parse(decryptWebPush(Buffer.from(payload.pincer.p, 'base64url'), { privateKey: device.getPrivateKey(), auth }));
  assert.equal(message.url, 'approve/appr-1');
  assert.equal(message.title, 'OpenClaw approval requested');
});

test('.env files: comments, quotes and empty values', () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'relay-env-')), '.env');
  fs.writeFileSync(file, '# comment\nRELAY_SECRET=abc=def\nAPNS_KEY_ID = "KEY 1"\nAPNS_TEAM_ID=\n  PORT=9000\r\nnot a line\n');
  assert.deepEqual(loadEnvFile(file), { RELAY_SECRET: 'abc=def', APNS_KEY_ID: 'KEY 1', PORT: '9000' });
  assert.deepEqual(loadEnvFile(path.join(path.dirname(file), 'missing')), {});
  fs.rmSync(path.dirname(file), { recursive: true });
});
