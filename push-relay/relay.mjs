// Pincer push relay: receives Gateway Web Push messages and forwards them, still encrypted, to
// APNs. The Pincer Notification Service Extension decrypts them on the device.
//
//   POST /v1/register            {token, environment, topic}  → {id}
//   POST /v1/push/:id/:gateway   Web Push (Content-Encoding: aes128gcm) → APNs
//
// `id` is the APNs token sealed with the relay secret, so the relay keeps no state and a Gateway
// only ever learns an opaque endpoint. The relay never sees notification content.
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import http2 from 'node:http2';

export const MAX_BODY_BYTES = 3072;
const APNS_ORIGINS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_RE = /^[0-9a-f]{64,200}$/i;

export function sealId(secret, token, environment, topic) {
  const key = crypto.createHash('sha256').update(secret).digest();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(JSON.stringify({ v: 1, t: token, e: environment, a: topic })), cipher.final()]);
  return Buffer.concat([iv, body, cipher.getAuthTag()]).toString('base64url');
}

export function openId(secret, id) {
  try {
    const raw = Buffer.from(id, 'base64url');
    if (raw.length < 29) return null;
    const key = crypto.createHash('sha256').update(secret).digest();
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(raw.length - 16));
    const plain = Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()]);
    const value = JSON.parse(plain.toString('utf8'));
    if (value?.v !== 1 || !TOKEN_RE.test(value.t) || !(value.e in APNS_ORIGINS) || typeof value.a !== 'string') return null;
    return { token: value.t, environment: value.e, topic: value.a };
  } catch {
    return null;
  }
}

/** APNs provider token (ES256 JWT), refreshed every 40 minutes as Apple recommends. */
export function createProviderToken({ keyId, teamId, key }) {
  let cached = null;
  return () => {
    const now = Math.floor(Date.now() / 1000);
    if (cached && now - cached.iat < 40 * 60) return cached.jwt;
    const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: now })).toString('base64url');
    const signature = crypto
      .sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' })
      .toString('base64url');
    cached = { iat: now, jwt: `${header}.${claims}.${signature}` };
    return cached.jwt;
  };
}

function createApnsClient({ origins, providerToken }) {
  const sessions = new Map();
  const session = (origin) => {
    let existing = sessions.get(origin);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    existing = http2.connect(origin);
    existing.on('error', () => sessions.delete(origin));
    existing.on('close', () => sessions.delete(origin));
    sessions.set(origin, existing);
    return existing;
  };
  return {
    send({ environment, token, headers, payload }) {
      return new Promise((resolve) => {
        let stream;
        try {
          stream = session(origins[environment]).request({
            ':method': 'POST',
            ':path': `/3/device/${token}`,
            authorization: `bearer ${providerToken()}`,
            'content-type': 'application/json',
            ...headers,
          });
        } catch (error) {
          resolve({ status: 0, reason: String(error?.message ?? error) });
          return;
        }
        let status = 0;
        const chunks = [];
        stream.setTimeout(15_000, () => stream.close(http2.constants.NGHTTP2_CANCEL));
        stream.on('response', (h) => { status = Number(h[':status']); });
        stream.on('data', (chunk) => chunks.push(chunk));
        stream.on('error', (error) => resolve({ status: 0, reason: String(error?.message ?? error) }));
        stream.on('close', () => {
          let reason;
          try { reason = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}').reason; } catch {}
          resolve({ status, reason });
        });
        stream.end(JSON.stringify(payload));
      });
    },
    close() {
      for (const s of sessions.values()) s.close();
      sessions.clear();
    },
  };
}

/** Maps Web Push delivery headers (RFC 8030) to APNs headers. */
export function apnsHeaders(webPushHeaders, nowSeconds = Math.floor(Date.now() / 1000)) {
  const headers = { 'apns-push-type': 'alert' };
  const ttl = Number.parseInt(webPushHeaders.ttl ?? '', 10);
  headers['apns-expiration'] = String(Number.isFinite(ttl) && ttl > 0 ? nowSeconds + Math.min(ttl, 28 * 24 * 3600) : 0);
  const urgency = String(webPushHeaders.urgency ?? 'normal').toLowerCase();
  headers['apns-priority'] = urgency === 'low' || urgency === 'very-low' ? '5' : '10';
  const topic = String(webPushHeaders.topic ?? '');
  if (/^[A-Za-z0-9_-]{1,32}$/.test(topic)) headers['apns-collapse-id'] = topic;
  return headers;
}

export function apnsPayload(gatewayId, body) {
  return {
    aps: {
      alert: { title: 'Pincer', body: 'New notification' },
      sound: 'default',
      'mutable-content': 1,
      'thread-id': gatewayId,
    },
    pincer: { g: gatewayId, p: Buffer.from(body).toString('base64url') },
  };
}

function readBody(req, limit) {
  const tooLarge = () => Object.assign(new Error('too large'), { status: 413 });
  if (Number(req.headers['content-length'] ?? 0) > limit) {
    req.resume();
    return Promise.reject(tooLarge());
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      // Keep draining so the client still gets the 413, but stop buffering.
      if (size <= limit) chunks.push(chunk);
    });
    req.on('end', () => (size > limit ? reject(tooLarge()) : resolve(Buffer.concat(chunks))));
    req.on('error', reject);
  });
}

function reply(res, status, body) {
  const text = body === undefined ? '' : JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

/**
 * @param {object} options
 * @param {string} options.secret        Seals registration ids; keep it stable (≥ 32 chars).
 * @param {string} options.keyId         APNs auth key id.
 * @param {string} options.teamId        Apple team id.
 * @param {string|crypto.KeyObject} options.key  APNs .p8 key (PEM).
 * @param {string[]} [options.topics]    Allowed app bundle ids.
 * @param {object} [options.origins]     APNs origins by environment (tests).
 * @param {number} [options.ratePerMinute]  Per-registration push limit.
 */
export function createRelay(options) {
  if (!options?.secret || options.secret.length < 32) throw new Error('RELAY_SECRET must be at least 32 characters');
  const topics = options.topics?.length ? options.topics : ['chat.pincer.ios'];
  const apns = createApnsClient({
    origins: { ...APNS_ORIGINS, ...options.origins },
    providerToken: createProviderToken(options),
  });
  const ratePerMinute = options.ratePerMinute ?? 120;
  const buckets = new Map();
  const log = options.log ?? ((line) => console.log(line));

  const allow = (id) => {
    const now = Date.now();
    const bucket = buckets.get(id) ?? { start: now, count: 0 };
    if (now - bucket.start > 60_000) { bucket.start = now; bucket.count = 0; }
    bucket.count += 1;
    buckets.set(id, bucket);
    if (buckets.size > 10_000) buckets.clear();
    return bucket.count <= ratePerMinute;
  };

  const register = async (req, res) => {
    let params;
    try {
      params = JSON.parse((await readBody(req, 4096)).toString('utf8'));
    } catch (error) {
      return reply(res, error.status ?? 400, { error: 'invalid JSON' });
    }
    const token = String(params?.token ?? '');
    const environment = String(params?.environment ?? 'production');
    const topic = String(params?.topic ?? topics[0]);
    if (!TOKEN_RE.test(token)) return reply(res, 400, { error: 'invalid token' });
    if (!(environment in APNS_ORIGINS)) return reply(res, 400, { error: 'invalid environment' });
    if (!topics.includes(topic)) return reply(res, 400, { error: 'unknown app' });
    reply(res, 200, { id: sealId(options.secret, token, environment, topic) });
  };

  const push = async (req, res, id, gatewayId) => {
    const target = openId(options.secret, id);
    if (!target || !topics.includes(target.topic)) return reply(res, 404, { error: 'unknown subscription' });
    if (!UUID_RE.test(gatewayId)) return reply(res, 404, { error: 'unknown subscription' });
    if (String(req.headers['content-encoding'] ?? '').toLowerCase() !== 'aes128gcm') {
      return reply(res, 415, { error: 'Content-Encoding must be aes128gcm' });
    }
    let body;
    try {
      body = await readBody(req, MAX_BODY_BYTES);
    } catch (error) {
      return reply(res, error.status ?? 400, { error: 'payload too large' });
    }
    // 16-byte salt, 4-byte record size, key id length, 65-byte sender key, then ≥ 17 bytes of record.
    if (body.length < 21 + 65 + 17) return reply(res, 400, { error: 'malformed payload' });
    if (!allow(id)) return reply(res, 429, { error: 'rate limited' });

    const headers = { ...apnsHeaders(req.headers), 'apns-topic': target.topic };
    const payload = apnsPayload(gatewayId.toLowerCase(), body);
    let environment = target.environment;
    let result = await apns.send({ environment, token: target.token, headers, payload });
    if (result.status === 400 && result.reason === 'BadDeviceToken') {
      // Development builds get sandbox tokens; try the other environment before giving up.
      environment = environment === 'production' ? 'sandbox' : 'production';
      result = await apns.send({ environment, token: target.token, headers, payload });
    }
    log(`push ${result.status || 'error'} ${result.reason ?? ''}`.trim());
    if (result.status === 200) return reply(res, 201);
    if (result.status === 410 || (result.status === 400 && result.reason === 'BadDeviceToken')) {
      // Web Push semantics: the Gateway drops the subscription.
      return reply(res, 410, { error: 'subscription expired' });
    }
    if (result.status === 429) return reply(res, 429, { error: 'rate limited' });
    return reply(res, 502, { error: 'APNs delivery failed' });
  };

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://relay');
    if (req.method === 'GET' && url.pathname === '/healthz') return reply(res, 200, { ok: true });
    if (req.method === 'POST' && url.pathname === '/v1/register') {
      return void register(req, res).catch(() => reply(res, 500, { error: 'internal error' }));
    }
    const match = url.pathname.match(/^\/v1\/push\/([A-Za-z0-9_-]+)\/([^/]+)$/);
    if (req.method === 'POST' && match) {
      return void push(req, res, match[1], match[2]).catch(() => reply(res, 500, { error: 'internal error' }));
    }
    reply(res, 404, { error: 'not found' });
  });
  server.on('close', () => apns.close());
  return server;
}

/** Reads `.env`: `KEY=value` lines and `#` comments, with optional quotes. Empty values are skipped. */
export function loadEnvFile(file) {
  if (!fs.existsSync(file)) return {};
  const values = {};
  for (const raw of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!match) continue;
    let value = match[2];
    if (/^(['"]).*\1$/.test(value)) value = value.slice(1, -1);
    if (value) values[match[1]] = value;
  }
  return values;
}
