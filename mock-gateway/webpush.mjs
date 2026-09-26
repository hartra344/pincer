// Web Push, like the Gateway's `push.web.*`: operator devices subscribe an endpoint with RFC 8291
// keys, and attention events (finished replies, exec approvals) are encrypted to each subscription
// and POSTed there with `Content-Encoding: aes128gcm`. Copy is generic, like the real Gateway;
// the `url` names the chat or approval.
import crypto from 'node:crypto';

export const WEB_PUSH_METHODS = ['push.web.vapidPublicKey', 'push.web.subscribe', 'push.web.unsubscribe', 'push.web.test'];

export function createWebPushState() {
  const vapid = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const publicKey = vapid.publicKey.export({ format: 'jwk' });
  return {
    subscriptions: new Map(), // endpoint → { endpoint, keys, deviceId }
    deliveries: [], // { endpoint, status, payload } for the self-test
    vapid,
    vapidPublic: Buffer.concat([Buffer.from([4]), Buffer.from(publicKey.x, 'base64url'), Buffer.from(publicKey.y, 'base64url')]),
  };
}

// The real Gateway requires https://; the mock also allows loopback http for local relays.
function validEndpoint(endpoint) {
  try {
    const url = new URL(endpoint);
    if (endpoint.length > 2048) return false;
    return url.protocol === 'https:' || (url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname));
  } catch {
    return false;
  }
}

function hkdf(salt, ikm, info, length) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, length));
}

/** RFC 8291 / RFC 8188 single-record encryption. */
export function encryptWebPush(plaintext, { p256dh, auth }, { senderKeys, salt } = {}) {
  const receiverPublic = Buffer.from(p256dh, 'base64url');
  const authSecret = Buffer.from(auth, 'base64url');
  const sender = senderKeys ?? crypto.createECDH('prime256v1');
  if (!senderKeys) sender.generateKeys();
  const senderPublic = sender.getPublicKey();
  const shared = sender.computeSecret(receiverPublic);
  const keyInfo = Buffer.concat([Buffer.from('WebPush: info\0'), receiverPublic, senderPublic]);
  const ikm = hkdf(authSecret, shared, keyInfo, 32);
  const saltBytes = salt ?? crypto.randomBytes(16);
  const cek = hkdf(saltBytes, ikm, Buffer.from('Content-Encoding: aes128gcm\0'), 16);
  const nonce = hkdf(saltBytes, ikm, Buffer.from('Content-Encoding: nonce\0'), 12);
  const cipher = crypto.createCipheriv('aes-128-gcm', cek, nonce);
  const record = Buffer.concat([cipher.update(Buffer.concat([Buffer.from(plaintext), Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21);
  saltBytes.copy(header, 0);
  header.writeUInt32BE(4096, 16);
  header.writeUInt8(senderPublic.length, 20);
  return Buffer.concat([header, senderPublic, record]);
}

/** RFC 8291 decryption, for the self-test. */
export function decryptWebPush(body, { privateKey, auth }) {
  const salt = body.subarray(0, 16);
  const idLength = body.readUInt8(20);
  const senderPublic = body.subarray(21, 21 + idLength);
  const receiver = crypto.createECDH('prime256v1');
  receiver.setPrivateKey(privateKey);
  const shared = receiver.computeSecret(senderPublic);
  const keyInfo = Buffer.concat([Buffer.from('WebPush: info\0'), receiver.getPublicKey(), senderPublic]);
  const ikm = hkdf(Buffer.from(auth, 'base64url'), shared, keyInfo, 32);
  const cek = hkdf(salt, ikm, Buffer.from('Content-Encoding: aes128gcm\0'), 16);
  const nonce = hkdf(salt, ikm, Buffer.from('Content-Encoding: nonce\0'), 12);
  const record = body.subarray(21 + idLength);
  const decipher = crypto.createDecipheriv('aes-128-gcm', cek, nonce);
  decipher.setAuthTag(record.subarray(record.length - 16));
  const padded = Buffer.concat([decipher.update(record.subarray(0, record.length - 16)), decipher.final()]);
  let end = padded.length - 1;
  while (end >= 0 && padded[end] === 0) end -= 1;
  return padded.subarray(0, end);
}

function vapidHeader(webPush, endpoint) {
  const header = Buffer.from(JSON.stringify({ typ: 'JWT', alg: 'ES256' })).toString('base64url');
  const claims = Buffer.from(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: 'mailto:mock@openclaw.invalid',
  })).toString('base64url');
  const signature = crypto.sign('sha256', Buffer.from(`${header}.${claims}`), { key: webPush.vapid.privateKey, dsaEncoding: 'ieee-p1363' });
  return `vapid t=${header}.${claims}.${signature.toString('base64url')}, k=${webPush.vapidPublic.toString('base64url')}`;
}

/** Control UI session path, like `buildControlUiSessionPath(..., exactKey: true)`. */
export function sessionPath(sessionKey) {
  const [prefix, agentId, ...rest] = String(sessionKey).split(':');
  if (prefix !== 'agent' || !agentId || rest.length === 0) return 'sessions';
  if (rest.length === 1 && rest[0] === 'main') return `chat/${encodeURIComponent(agentId)}`;
  if (rest.length === 1) return `chat/${encodeURIComponent(agentId)}/~key/${encodeURIComponent(rest[0])}`;
  return `chat/${encodeURIComponent(agentId)}/${rest.map(encodeURIComponent).join('/')}`;
}

function topicFor(tag) {
  return crypto.createHash('sha256').update(tag).digest('base64url').slice(0, 32);
}

async function deliver(state, payload, { ttl, urgency, topic }, only = undefined) {
  const webPush = state.webPushState;
  const targets = only ? [only] : [...webPush.subscriptions.values()];
  await Promise.all(targets.map(async (subscription) => {
    let status = 0;
    try {
      const response = await fetch(subscription.endpoint, {
        method: 'POST',
        headers: {
          'content-encoding': 'aes128gcm',
          'content-type': 'application/octet-stream',
          ttl: String(ttl),
          urgency,
          topic,
          authorization: vapidHeader(webPush, subscription.endpoint),
        },
        body: encryptWebPush(JSON.stringify(payload), subscription.keys),
      });
      status = response.status;
    } catch {
      status = 0;
    }
    webPush.deliveries.push({ endpoint: subscription.endpoint, status, payload });
    if (webPush.deliveries.length > 50) webPush.deliveries.shift();
    // Like the Gateway: expired subscriptions are dropped.
    if (status === 404 || status === 410) webPush.subscriptions.delete(subscription.endpoint);
  }));
}

/** Called for every broadcast; mirrors the Gateway's event and approval Web Push. */
export function handleWebPushEvent(state, event, payload) {
  if (!state.webPushState?.subscriptions.size) return;
  if (event === 'chat' && payload?.state === 'final' && payload.yielded !== true) {
    const tag = `openclaw-agent-finished-${payload.runId ?? 'finished'}`;
    const agentId = String(payload.sessionKey ?? '').split(':')[1];
    void deliver(state, {
      title: 'OpenClaw agent finished',
      body: agentId ? `${agentId}: An agent completed its response.` : 'An agent completed its response.',
      tag,
      renotify: false,
      url: sessionPath(payload.sessionKey),
    }, { ttl: 300, urgency: 'normal', topic: topicFor(tag) });
  }
  if (event === 'exec.approval.requested' || event === 'exec.approval.resolved') {
    const approvalId = payload?.id ?? payload?.request?.id;
    if (!approvalId) return;
    const terminal = event === 'exec.approval.resolved';
    void deliver(state, {
      title: terminal ? 'OpenClaw approval updated' : 'OpenClaw approval requested',
      body: terminal ? 'Approval is no longer pending.' : 'Open OpenClaw to review an approval.',
      tag: `openclaw-approval-${approvalId}`,
      renotify: false,
      url: `approve/${encodeURIComponent(approvalId)}`,
    }, { ttl: terminal ? 300 : 120, urgency: 'high', topic: topicFor(`openclaw-approval:${approvalId}`) });
  }
}

export function handleWebPushRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method, params = {} } = msg;
  if (!WEB_PUSH_METHODS.includes(method)) return false;
  const webPush = state.webPushState;
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  if (!(conn.scopes ?? []).includes('operator.write')) {
    sendErr(conn, id, 'FORBIDDEN', 'missing scope: operator.write', { code: 'MISSING_SCOPE', scope: 'operator.write' });
    return true;
  }
  switch (method) {
    case 'push.web.vapidPublicKey':
      sendRes(conn, id, { vapidPublicKey: webPush.vapidPublic.toString('base64url') });
      return true;
    case 'push.web.subscribe': {
      const { endpoint, keys } = params;
      if (typeof endpoint !== 'string' || !validEndpoint(endpoint)) {
        return invalid('invalid push subscription endpoint: must be an HTTPS URL under 2048 chars'), true;
      }
      if (typeof keys?.p256dh !== 'string' || typeof keys?.auth !== 'string'
        || Buffer.from(keys.p256dh, 'base64url').length !== 65 || Buffer.from(keys.auth, 'base64url').length !== 16) {
        return invalid('invalid push subscription keys'), true;
      }
      const existing = webPush.subscriptions.get(endpoint);
      if (existing && existing.deviceId !== conn.deviceId) {
        sendErr(conn, id, 'FORBIDDEN', 'subscription is bound to another device');
        return true;
      }
      const subscriptionId = existing?.subscriptionId ?? crypto.randomUUID();
      webPush.subscriptions.set(endpoint, { endpoint, keys: { p256dh: keys.p256dh, auth: keys.auth }, deviceId: conn.deviceId, subscriptionId });
      sendRes(conn, id, { subscriptionId });
      return true;
    }
    case 'push.web.unsubscribe': {
      const existing = webPush.subscriptions.get(params.endpoint);
      if (existing && existing.deviceId !== conn.deviceId) {
        sendErr(conn, id, 'FORBIDDEN', 'subscription is bound to another device');
        return true;
      }
      sendRes(conn, id, { removed: webPush.subscriptions.delete(params.endpoint) });
      return true;
    }
    case 'push.web.test': {
      const existing = webPush.subscriptions.get(params.endpoint);
      if (!existing || existing.deviceId !== conn.deviceId) return invalid('unknown subscription'), true;
      void deliver(state, { title: 'OpenClaw test notification', body: 'Web Push is working.', tag: 'openclaw-test', url: 'sessions' },
        { ttl: 60, urgency: 'normal', topic: topicFor('openclaw-test') }, existing);
      sendRes(conn, id, { ok: true });
      return true;
    }
    default:
      return false;
  }
}
