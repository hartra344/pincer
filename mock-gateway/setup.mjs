// What Pincer's setup wizard reads beyond `health`/`status`/`config.*`: `channels.status`
// (operator.read) and WhatsApp QR login through `web.login.start` / `web.login.wait`
// (operator.admin, and not advertised in hello, like the Gateway's `advertise: false`). Shapes
// follow the Gateway's channels schema and the WhatsApp plugin's login messages. The wizard's
// `skills.status` comes from skills.mjs, the same list as the Skills page.
// MOCK_WEB_LOGIN=link links on the first wait (default: the QR is refreshed once first);
// MOCK_WEB_LOGIN=timeout never links (every wait says it's still waiting).
// MOCK_WEB_LOGIN_WAIT_MS sets how long a wait takes (default 600).
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { ADMIN_SCOPE } from './config.mjs';

export const SETUP_METHODS = ['channels.status'];
/** Real Gateway methods that it doesn't list in `hello.features.methods`. */
export const WEB_LOGIN_METHODS = ['web.login.start', 'web.login.wait'];
export const WHATSAPP_NOT_LINKED = 'Not linked (no WhatsApp Web session).';
export const WHATSAPP_RELINK_FIX = 'Run: openclaw channels login (scan QR on the gateway host).';
const QR_TTL_MS = 3 * 60_000;
const WHATSAPP_SELF = '+15550100';
export const TELEGRAM_CONFLICT = 'getUpdates: 409 Conflict: terminated by other getUpdates request; make sure that only one bot instance is running';
export const CHANNEL_META = [
  { id: 'discord', label: 'Discord', detailLabel: 'Discord Bot' },
  { id: 'telegram', label: 'Telegram', detailLabel: 'Telegram Bot' },
  { id: 'whatsapp', label: 'WhatsApp', detailLabel: 'WhatsApp Web' },
  { id: 'slack', label: 'Slack', detailLabel: 'Slack App' },
];

export function createSetupState() {
  return { whatsapp: { linked: false, linkedAt: null }, login: null };
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkParams(params, allowed, method) {
  if (!isObject(params)) return `invalid ${method} params: must be object`;
  const extra = Object.keys(params).find((key) => !allowed.includes(key));
  return extra ? `invalid ${method} params: must NOT have additional properties (${extra})` : null;
}

// --- QR codes ------------------------------------------------------------------------------

let crcTable;
function crc32(buf) {
  crcTable ??= Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  let c = 0xffffffff;
  for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])));
  return Buffer.concat([len, typeBuf, data, crc]);
}

/** A QR-looking grayscale PNG (finder squares plus noise from `seed`) as a `data:` URL. */
export function makeQrDataUrl(seed) {
  const modules = 25;
  const quiet = 2;
  const scale = 6;
  const bits = crypto.createHash('sha256').update(String(seed)).digest();
  const finder = (x, y) => {
    for (const [ox, oy] of [[0, 0], [modules - 7, 0], [0, modules - 7]]) {
      const dx = x - ox;
      const dy = y - oy;
      if (dx >= 0 && dx < 7 && dy >= 0 && dy < 7) {
        const ring = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
        return ring !== 2;
      }
    }
    return undefined;
  };
  const dark = (x, y) => {
    const f = finder(x, y);
    if (f !== undefined) return f;
    const i = y * modules + x;
    return ((bits[i % bits.length] >> (i % 8)) & 1) === 1;
  };
  const size = (modules + quiet * 2) * scale;
  const raw = Buffer.alloc((size + 1) * size, 255);
  for (let py = 0; py < size; py++) {
    raw[py * (size + 1)] = 0;
    const my = Math.floor(py / scale) - quiet;
    for (let px = 0; px < size; px++) {
      const mx = Math.floor(px / scale) - quiet;
      if (mx >= 0 && my >= 0 && mx < modules && my < modules && dark(mx, my)) raw[py * (size + 1) + 1 + px] = 0;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 0;
  const png = Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
  return `data:image/png;base64,${png.toString('base64')}`;
}

// --- Channels ------------------------------------------------------------------------------

function discordEnabled(state) {
  return state.configState?.config?.channels?.discord?.enabled !== false;
}

/**
 * Per-account snapshots, shared by `health` and `channels.status`. Runtime state (running,
 * degraded, logged out) comes from `state.channelsState` (channels.mjs); WhatsApp's link from
 * `state.setupState`.
 */
export function channelAccountSnapshots(state) {
  const startedAt = state.healthState?.startedAt ?? Date.now();
  const runtime = state.channelsState ?? {};
  const discordRt = runtime.discord ?? { running: true };
  const telegramRt = runtime.telegram ?? { running: true, degraded: true, loggedOut: false };
  const whatsappRt = runtime.whatsapp ?? { stopped: false };
  const discordOn = discordEnabled(state);
  const discordConfigured = discordRt.loggedOut !== true;
  const discordRunning = discordOn && discordConfigured && discordRt.running !== false;
  const telegramConfigured = telegramRt.loggedOut !== true;
  const telegramRunning = telegramConfigured && telegramRt.running !== false;
  const telegramDegraded = telegramRunning && telegramRt.degraded === true;
  const wa = state.setupState?.whatsapp ?? { linked: false };
  const waRunning = wa.linked && whatsappRt.stopped !== true;
  return {
    discord: {
      accountId: 'default',
      name: 'Discord',
      enabled: discordOn,
      configured: discordConfigured,
      running: discordRunning,
      connected: discordRunning,
      restartPending: false,
      reconnectAttempts: 0,
      lastConnectedAt: discordRunning ? (discordRt.lastStartAt ?? startedAt) + 2_000 : (discordRt.lastConnectedAt ?? startedAt + 2_000),
      lastStartAt: discordRt.lastStartAt ?? startedAt,
      lastStopAt: discordRt.lastStopAt ?? null,
      lastInboundAt: Date.now() - 4 * 60_000,
      lastOutboundAt: Date.now() - 3 * 60_000,
      lastError: null,
      tokenSource: discordConfigured ? 'config' : 'none',
      dmPolicy: 'pairing',
      ...(discordRunning ? { healthState: 'healthy' } : {}),
    },
    // Running, but another bot instance holds the long poll: not connected, retrying, with the
    // Bot API's 409 as its last error, until someone reconnects it (stop + start) or restarts.
    telegram: {
      accountId: 'default',
      name: 'Telegram',
      enabled: true,
      configured: telegramConfigured,
      running: telegramRunning,
      connected: telegramRunning && !telegramDegraded,
      restartPending: false,
      reconnectAttempts: telegramDegraded ? 3 : 0,
      lastConnectedAt: telegramDegraded ? startedAt + 5_000 : telegramRunning ? (telegramRt.lastStartAt ?? startedAt) + 1_000 : null,
      lastStartAt: telegramRt.lastStartAt ?? startedAt,
      lastStopAt: telegramRt.lastStopAt ?? null,
      lastInboundAt: telegramDegraded ? startedAt + 60_000 : telegramRt.lastInboundAt ?? null,
      lastError: telegramDegraded ? TELEGRAM_CONFLICT : null,
      tokenSource: telegramConfigured ? 'env' : 'none',
      mode: 'polling',
      dmPolicy: 'pairing',
      ...(telegramDegraded ? { healthState: 'disconnected' } : telegramRunning ? { healthState: 'healthy' } : {}),
    },
    // Enabled in config, but no WhatsApp Web session yet: not configured until someone scans the QR.
    whatsapp: wa.linked
      ? {
          accountId: 'default',
          name: 'WhatsApp',
          enabled: true,
          configured: true,
          linked: true,
          running: waRunning,
          connected: waRunning,
          restartPending: false,
          reconnectAttempts: 0,
          lastConnectedAt: wa.linkedAt,
          lastStopAt: whatsappRt.lastStopAt ?? null,
          lastError: null,
          ...(waRunning ? { healthState: 'healthy' } : {}),
          dmPolicy: 'pairing',
        }
      : {
          accountId: 'default',
          name: 'WhatsApp',
          enabled: true,
          configured: false,
          linked: false,
          running: false,
          connected: false,
          restartPending: false,
          reconnectAttempts: 0,
          lastConnectedAt: null,
          lastError: null,
          dmPolicy: 'pairing',
        },
    slack: {
      accountId: 'default',
      name: 'Slack',
      enabled: false,
      configured: false,
      running: false,
      connected: false,
    },
  };
}

export function channelsStatus(state, { probe = false, channel } = {}) {
  const now = Date.now();
  const snapshots = channelAccountSnapshots(state);
  const ids = CHANNEL_META.map((m) => m.id).filter((id) => !channel || id === channel);
  const meta = CHANNEL_META.filter((m) => ids.includes(m.id));
  const channels = {};
  const channelAccounts = {};
  const channelDefaultAccountId = {};
  for (const id of ids) {
    const account = { ...snapshots[id] };
    if (probe && account.configured && account.enabled) {
      account.lastProbeAt = now;
      account.probe = account.lastError
        ? { ok: false, error: account.lastError, elapsedMs: 212 }
        : { ok: true, elapsedMs: 38 };
    }
    const { accountId: _accountId, name: _name, ...summary } = account;
    channels[id] = summary;
    channelAccounts[id] = [account];
    channelDefaultAccountId[id] = 'default';
  }
  const statusIssues = [];
  if (ids.includes('whatsapp') && !snapshots.whatsapp.linked) {
    statusIssues.push({ channel: 'whatsapp', accountId: 'default', kind: 'auth', message: WHATSAPP_NOT_LINKED, fix: WHATSAPP_RELINK_FIX });
  }
  return {
    ts: now,
    channelOrder: ids,
    channelLabels: Object.fromEntries(meta.map((m) => [m.id, m.label])),
    channelDetailLabels: Object.fromEntries(meta.map((m) => [m.id, m.detailLabel])),
    channelMeta: meta,
    channels,
    channelAccounts,
    channelDefaultAccountId,
    ...(statusIssues.length ? { statusIssues } : {}),
  };
}

// --- Web login -----------------------------------------------------------------------------

function loginFlow() {
  const flow = process.env.MOCK_WEB_LOGIN;
  return flow === 'link' || flow === 'timeout' ? flow : 'refresh';
}

function waitDelayMs() {
  const value = Number(process.env.MOCK_WEB_LOGIN_WAIT_MS ?? 600);
  return Number.isFinite(value) && value >= 0 ? value : 600;
}

function newQr(login) {
  login.qrSeq += 1;
  login.qrDataUrl = makeQrDataUrl(`${login.id}:${login.qrSeq}`);
  return login.qrDataUrl;
}

/** Links WhatsApp as if the QR was scanned (also used by tests). */
export function linkWhatsApp(state) {
  state.setupState.whatsapp = { linked: true, linkedAt: Date.now() };
  state.setupState.login = null;
}

function resolveWebLoginChannel(params, fail) {
  const raw = params.channel === undefined ? 'whatsapp' : String(params.channel).trim().toLowerCase();
  if (raw === 'whatsapp' || raw === 'wa') return 'whatsapp';
  if (CHANNEL_META.some((m) => m.id === raw)) {
    fail('INVALID_REQUEST', `web login is not supported by provider ${raw}`);
  } else {
    fail('INVALID_REQUEST', 'web login provider is not available');
  }
  return null;
}

export function handleSetupRequest(state, conn, msg, { sendRes, sendErr, broadcast, healthSummary }) {
  const { id, method } = msg;
  const params = msg.params ?? {};
  if (!SETUP_METHODS.includes(method) && !WEB_LOGIN_METHODS.includes(method)) return false;
  const fail = (code, message, details) => sendErr(conn, id, code, message, details);

  if (WEB_LOGIN_METHODS.includes(method) && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    fail('FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const setup = state.setupState;
  switch (method) {
    case 'channels.status': {
      const invalid = checkParams(params, ['probe', 'timeoutMs', 'channel'], method);
      if (invalid) return fail('INVALID_REQUEST', invalid), true;
      if (params.channel !== undefined) {
        const known = CHANNEL_META.some((m) => m.id === String(params.channel).trim().toLowerCase());
        if (!known) return fail('INVALID_REQUEST', `unknown channel: ${params.channel}`), true;
      }
      const channel = params.channel === undefined ? undefined : String(params.channel).trim().toLowerCase();
      sendRes(conn, id, channelsStatus(state, { probe: params.probe === true, channel }));
      return true;
    }
    case 'web.login.start': {
      const invalid = checkParams(params, ['channel', 'force', 'timeoutMs', 'verbose', 'accountId'], method);
      if (invalid) return fail('INVALID_REQUEST', invalid), true;
      if (!resolveWebLoginChannel(params, fail)) return true;
      if (setup.whatsapp.linked && params.force !== true) {
        sendRes(conn, id, { message: `WhatsApp is already linked (${WHATSAPP_SELF}). Say “relink” if you want a fresh QR.` });
        return true;
      }
      const fresh = setup.login && Date.now() - setup.login.startedAt < QR_TTL_MS;
      if (fresh && params.force !== true) {
        sendRes(conn, id, { qrDataUrl: setup.login.qrDataUrl, message: 'QR already active. Scan it in WhatsApp → Linked Devices.' });
        return true;
      }
      if (params.force === true) setup.whatsapp = { linked: false, linkedAt: null };
      setup.login = { id: crypto.randomUUID(), startedAt: Date.now(), qrSeq: 0, waits: 0, qrDataUrl: null };
      sendRes(conn, id, { qrDataUrl: newQr(setup.login), message: 'Scan this QR in WhatsApp → Linked Devices.' });
      return true;
    }
    case 'web.login.wait': {
      const invalid = checkParams(params, ['channel', 'sessionKey', 'timeoutMs', 'accountId', 'currentQrDataUrl'], method);
      if (invalid) return fail('INVALID_REQUEST', invalid), true;
      if (params.currentQrDataUrl !== undefined && !/^data:image\/png;base64,/.test(String(params.currentQrDataUrl))) {
        return fail('INVALID_REQUEST', 'invalid web.login.wait params: currentQrDataUrl must match pattern "^data:image/png;base64,"'), true;
      }
      if (!resolveWebLoginChannel(params, fail)) return true;
      const login = setup.login;
      if (!login) {
        sendRes(conn, id, { connected: false, message: 'No active WhatsApp login in progress.' });
        return true;
      }
      if (Date.now() - login.startedAt >= QR_TTL_MS) {
        setup.login = null;
        sendRes(conn, id, { connected: false, message: 'The login QR expired. Ask me to generate a new one.' });
        return true;
      }
      const timeoutMs = Number.isInteger(params.timeoutMs) ? params.timeoutMs : 120_000;
      const delayMs = waitDelayMs();
      const flow = loginFlow();
      const answer = () => {
        if (setup.login !== login) {
          sendRes(conn, id, { connected: false, message: 'WhatsApp login was replaced by a newer request.' });
          return;
        }
        if (flow === 'timeout' || timeoutMs < delayMs) {
          sendRes(conn, id, { connected: false, message: 'Still waiting for the QR scan. Let me know when you’ve scanned it.' });
          return;
        }
        login.waits += 1;
        if (flow === 'refresh' && login.waits === 1) {
          const qrDataUrl = newQr(login);
          sendRes(conn, id, { connected: false, message: 'QR refreshed. Scan the latest code in WhatsApp → Linked Devices.', qrDataUrl });
          return;
        }
        linkWhatsApp(state);
        sendRes(conn, id, { connected: true, message: '✅ Linked! WhatsApp is ready.' });
        if (healthSummary) broadcast(state, 'health', healthSummary(state));
      };
      setTimeout(answer, Math.min(delayMs, Math.max(0, timeoutMs)));
      return true;
    }
    default:
      return false;
  }
}
