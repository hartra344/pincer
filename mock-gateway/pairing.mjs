// Channel DM pairing: senders who messaged a channel account with dmPolicy "pairing" wait in
// channels.pairing.list until someone approves (lets them DM the agent) or dismisses them (the
// sender isn't blocked and can ask again). Shapes follow the Gateway's channel-pairing schema;
// every method needs operator.pairing (operator.admin covers it), and bootstrapCommandOwner
// also needs operator.admin. There is no pairing event, so clients poll.
// MOCK_CHANNEL_PAIRING=off makes the mock look like a Gateway without these methods;
// MOCK_CHANNEL_PAIRING_EVERY=<seconds> adds a new request every so often.
import crypto from 'node:crypto';

export const CHANNEL_PAIRING_METHODS = ['channels.pairing.list', 'channels.pairing.approve', 'channels.pairing.dismiss'];
export const PAIRING_SCOPE = 'operator.pairing';
const ADMIN_SCOPE = 'operator.admin';
export const PAIRING_TTL_MS = 60 * 60_000;
export const PENDING_PER_ACCOUNT = 3;
const LIST_PARAMS = new Set(['channel', 'accountId']);
const APPROVE_PARAMS = new Set(['channel', 'accountId', 'requestId', 'notify', 'bootstrapCommandOwner']);
const DISMISS_PARAMS = new Set(['channel', 'accountId', 'requestId']);

export const PAIRING_ACCOUNTS = [
  { channel: 'telegram', channelLabel: 'Telegram', accountId: 'home', accountLabel: 'Home bot', notifySupported: true },
  { channel: 'discord', channelLabel: 'Discord', accountId: 'family', accountLabel: 'Family server', notifySupported: false },
];
const SENDER_LABELS = { telegram: 'Telegram user id', discord: 'Discord user id' };
const EXTRA_SENDERS = [
  { account: 0, senderId: '5550177', metadata: { name: 'Sam Rivera', username: 'samr' } },
  { account: 1, senderId: '418820017799' },
  { account: 0, senderId: '5550188', metadata: { username: 'weekend_hacker', languageCode: 'de' } },
];

export function channelPairingDisabled() {
  return process.env.MOCK_CHANNEL_PAIRING === 'off';
}

function iso(ms) {
  return new Date(ms).toISOString();
}

function makeRequest(account, { requestId, senderId, metadata, createdAtMs, lastSeenAtMs }) {
  return {
    requestId,
    channel: account.channel,
    channelLabel: account.channelLabel,
    accountId: account.accountId,
    ...(account.accountLabel ? { accountLabel: account.accountLabel } : {}),
    senderId,
    senderLabel: SENDER_LABELS[account.channel] ?? 'Sender id',
    ...(metadata ? { metadata: { ...metadata } } : {}),
    createdAt: iso(createdAtMs),
    lastSeenAt: iso(lastSeenAtMs ?? createdAtMs),
    expiresAt: iso(createdAtMs + PAIRING_TTL_MS),
    notifySupported: account.notifySupported,
  };
}

// Same senders as the in-app demo: a named Telegram sender, a Discord sender with only an id,
// and a Telegram request about to expire.
export function createChannelPairingState(base = Date.now()) {
  const [telegram, discord] = PAIRING_ACCOUNTS;
  return {
    commandOwnerConfigured: true,
    added: 0,
    requests: [
      makeRequest(telegram, {
        requestId: 'pr_maya', senderId: '5550142', metadata: { name: 'Maya Chen', username: 'mayac', languageCode: 'en' },
        createdAtMs: base - 5 * 60_000, lastSeenAtMs: base - 2 * 60_000,
      }),
      makeRequest(discord, { requestId: 'pr_discord', senderId: '418820017734', createdAtMs: base - 20 * 60_000 }),
      makeRequest(telegram, {
        requestId: 'pr_soon', senderId: '5550199', metadata: { username: 'night_owl' },
        createdAtMs: base - PAIRING_TTL_MS + 2 * 60_000,
      }),
    ],
  };
}

function prune(pairing, now = Date.now()) {
  pairing.requests = pairing.requests.filter((r) => Date.parse(r.expiresAt) > now);
}

// A new sender asks for access; the oldest request on that account goes when it's full.
export function addChannelPairingRequest(state, now = Date.now()) {
  const pairing = state.channelPairingState;
  prune(pairing, now);
  const template = EXTRA_SENDERS[pairing.added % EXTRA_SENDERS.length];
  pairing.added += 1;
  const account = PAIRING_ACCOUNTS[template.account];
  const onAccount = pairing.requests
    .filter((r) => r.channel === account.channel && r.accountId === account.accountId)
    .sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt));
  if (onAccount.length >= PENDING_PER_ACCOUNT) {
    pairing.requests = pairing.requests.filter((r) => r !== onAccount[0]);
  }
  const request = makeRequest(account, {
    requestId: `pr_${crypto.randomBytes(6).toString('hex')}`,
    senderId: `${template.senderId}${pairing.added}`,
    metadata: template.metadata,
    createdAtMs: now,
  });
  pairing.requests.push(request);
  return request;
}

function hasScope(conn, scope) {
  const scopes = conn.scopes ?? [];
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE);
}

function isObject(params) {
  return params && typeof params === 'object' && !Array.isArray(params);
}

export function handleChannelPairingRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method, params = {} } = msg;
  if (!CHANNEL_PAIRING_METHODS.includes(method) || channelPairingDisabled()) return false;
  const missing = (scope) =>
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${scope}`, { code: 'MISSING_SCOPE', missingScope: scope, requiredScopes: [scope] });
  if (!hasScope(conn, PAIRING_SCOPE)) return missing(PAIRING_SCOPE), true;
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  const pairing = state.channelPairingState;
  prune(pairing);

  if (method === 'channels.pairing.list') {
    if (!isObject(params) || Object.keys(params).some((key) => !LIST_PARAMS.has(key))) {
      return invalid('invalid channels.pairing.list params'), true;
    }
    if (params.channel !== undefined && !PAIRING_ACCOUNTS.some((a) => a.channel === params.channel)) {
      return invalid(`unknown pairing channel: ${params.channel}`), true;
    }
    const matches = (r) =>
      (params.channel === undefined || r.channel === params.channel) && (params.accountId === undefined || r.accountId === params.accountId);
    sendRes(conn, id, {
      accounts: PAIRING_ACCOUNTS.filter(matches).map((a) => ({ ...a })),
      requests: pairing.requests.filter(matches).map((r) => structuredClone(r)),
      commandOwnerConfigured: pairing.commandOwnerConfigured,
      limits: { pendingPerAccount: PENDING_PER_ACCOUNT, ttlMs: PAIRING_TTL_MS },
    });
    return true;
  }

  const allowed = method === 'channels.pairing.approve' ? APPROVE_PARAMS : DISMISS_PARAMS;
  const badParams =
    !isObject(params) || Object.keys(params).some((key) => !allowed.has(key))
    || ['channel', 'accountId', 'requestId'].some((key) => typeof params[key] !== 'string' || !params[key])
    || (params.notify !== undefined && typeof params.notify !== 'boolean')
    || (params.bootstrapCommandOwner !== undefined && typeof params.bootstrapCommandOwner !== 'boolean');
  if (badParams) return invalid(`invalid ${method} params`), true;
  if (params.bootstrapCommandOwner === true && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) return missing(ADMIN_SCOPE), true;
  const account = PAIRING_ACCOUNTS.find((a) => a.channel === params.channel && a.accountId === params.accountId);
  if (!account) return invalid(`channel account does not use DM pairing: ${params.channel}:${params.accountId}`), true;
  const index = pairing.requests.findIndex(
    (r) => r.requestId === params.requestId && r.channel === params.channel && r.accountId === params.accountId,
  );
  if (index < 0) return invalid('pending DM access request no longer exists'), true;
  const [request] = pairing.requests.splice(index, 1);

  if (method === 'channels.pairing.dismiss') {
    sendRes(conn, id, { requestId: request.requestId, senderId: request.senderId });
    return true;
  }
  let notification = 'not-requested';
  if (params.notify === true) notification = account.notifySupported ? 'sent' : 'unsupported';
  let commandOwnerBootstrap = 'not-requested';
  if (params.bootstrapCommandOwner === true) {
    commandOwnerBootstrap = pairing.commandOwnerConfigured ? 'already-configured' : 'configured';
    pairing.commandOwnerConfigured = true;
  }
  sendRes(conn, id, { requestId: request.requestId, senderId: request.senderId, notification, commandOwnerBootstrap });
  return true;
}
