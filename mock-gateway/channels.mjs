// Channel account lifecycle: `channels.start`, `channels.stop` and `channels.logout`
// (operator.admin, advertised), shaped like the Gateway's `server-methods/channels.ts`:
//   start  → { channel, accountId, started, outcome: { status: 'handed-off' | 'retry' | 'skipped', reason? } }
//   stop   → { channel, accountId, stopped }
//   logout → { channel, accountId, cleared, loggedOut } (stops the account first; Telegram and WhatsApp only)
// Seeds: Discord connected, Telegram running but degraded (409 Conflict) until it is restarted
// (stop + start, or a Gateway restart), WhatsApp enabled but logged out (needs the QR login in
// setup.mjs), Slack disabled. `channels.status` and `health` read this state through
// `channelAccountSnapshots` (setup.mjs); every change broadcasts a `health` event.
import { ADMIN_SCOPE } from './config.mjs';
import { CHANNEL_META } from './setup.mjs';

export const CHANNEL_LIFECYCLE_METHODS = ['channels.start', 'channels.stop', 'channels.logout'];
/** Channels whose plugin implements `logoutAccount` (upstream: WhatsApp and Telegram, not Discord or Slack). */
export const LOGOUT_CHANNELS = ['telegram', 'whatsapp'];

export function createChannelsState() {
  return {
    discord: { running: true, loggedOut: false, lastStartAt: null, lastStopAt: null },
    telegram: { running: true, degraded: true, loggedOut: false, lastStartAt: null, lastStopAt: null },
    whatsapp: { stopped: false, lastStopAt: null },
  };
}

/** A Gateway restart starts every configured account again; Telegram's conflict is gone by then. */
export function resetChannelsForRestart(state) {
  const rt = state.channelsState;
  if (!rt) return;
  rt.discord.running = true;
  rt.discord.lastStartAt = null;
  rt.telegram.running = true;
  rt.telegram.degraded = false;
  rt.telegram.lastStartAt = null;
  rt.whatsapp.stopped = false;
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkParams(params, method) {
  if (!isObject(params)) return `invalid ${method} params: must be object`;
  const extra = Object.keys(params).find((key) => key !== 'channel' && key !== 'accountId');
  if (extra) return `invalid ${method} params: must NOT have additional properties (${extra})`;
  if (typeof params.channel !== 'string' || params.channel.length === 0) {
    return `invalid ${method} params: must have required property 'channel'`;
  }
  if (params.accountId !== undefined && typeof params.accountId !== 'string') {
    return `invalid ${method} params: accountId must be string`;
  }
  return null;
}

function whatsappLinked(state) {
  return state.setupState?.whatsapp?.linked === true;
}

function discordEnabled(state) {
  return state.configState?.config?.channels?.discord?.enabled !== false;
}

function start(state, channel, accountId) {
  const rt = state.channelsState;
  const now = Date.now();
  const payload = (started, outcome) => ({ channel, accountId, started, outcome });
  if (accountId !== 'default') return payload(false, { status: 'skipped', reason: 'unconfigured' });
  switch (channel) {
    case 'discord': {
      if (!discordEnabled(state)) return payload(false, { status: 'skipped', reason: 'disabled' });
      if (rt.discord.loggedOut) return payload(false, { status: 'skipped', reason: 'unconfigured' });
      if (rt.discord.running) return payload(true, { status: 'retry', reason: 'task-owned' });
      rt.discord.running = true;
      rt.discord.lastStartAt = now;
      return payload(true, { status: 'handed-off' });
    }
    case 'telegram': {
      if (rt.telegram.loggedOut) return payload(false, { status: 'skipped', reason: 'unconfigured' });
      if (rt.telegram.running) return payload(true, { status: 'retry', reason: 'task-owned' });
      // A fresh long poll: the conflicting instance has gone away by now.
      rt.telegram.running = true;
      rt.telegram.degraded = false;
      rt.telegram.lastStartAt = now;
      rt.telegram.lastInboundAt = null;
      return payload(true, { status: 'handed-off' });
    }
    case 'whatsapp': {
      if (!whatsappLinked(state)) return payload(false, { status: 'skipped', reason: 'unlinked' });
      if (!rt.whatsapp.stopped) return payload(true, { status: 'retry', reason: 'task-owned' });
      rt.whatsapp.stopped = false;
      return payload(true, { status: 'handed-off' });
    }
    case 'slack':
      return payload(false, { status: 'skipped', reason: 'disabled' });
    default:
      return payload(false, { status: 'skipped', reason: 'unsupported' });
  }
}

function stop(state, channel, accountId) {
  const rt = state.channelsState;
  const now = Date.now();
  if (accountId === 'default') {
    if (channel === 'discord' && rt.discord.running) {
      rt.discord.running = false;
      rt.discord.lastStopAt = now;
    } else if (channel === 'telegram' && rt.telegram.running) {
      rt.telegram.running = false;
      rt.telegram.lastStopAt = now;
    } else if (channel === 'whatsapp' && !rt.whatsapp.stopped) {
      rt.whatsapp.stopped = true;
      rt.whatsapp.lastStopAt = now;
    }
  }
  return { channel, accountId, stopped: true };
}

function logout(state, channel, accountId) {
  const rt = state.channelsState;
  stop(state, channel, accountId);
  if (accountId !== 'default') return { channel, accountId, cleared: false, loggedOut: false };
  let cleared = false;
  if (channel === 'whatsapp') {
    cleared = whatsappLinked(state);
    state.setupState.whatsapp = { linked: false, linkedAt: null };
    state.setupState.login = null;
    rt.whatsapp.stopped = false;
  } else if (channel === 'telegram') {
    cleared = !rt.telegram.loggedOut;
    rt.telegram.loggedOut = true;
    rt.telegram.degraded = false;
  }
  return { channel, accountId, cleared, loggedOut: cleared };
}

export function handleChannelsRequest(state, conn, msg, { sendRes, sendErr, broadcast, healthSummary }) {
  const { id, method } = msg;
  if (!CHANNEL_LIFECYCLE_METHODS.includes(method)) return false;
  const params = msg.params ?? {};
  const fail = (code, message, details) => sendErr(conn, id, code, message, details);
  if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    fail('FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const invalid = checkParams(params, method);
  if (invalid) return fail('INVALID_REQUEST', invalid), true;
  const channel = params.channel.trim().toLowerCase();
  if (!CHANNEL_META.some((m) => m.id === channel)) {
    return fail('INVALID_REQUEST', `invalid ${method} channel`), true;
  }
  const accountId = params.accountId?.trim() || 'default';
  let result;
  switch (method) {
    case 'channels.start':
      result = start(state, channel, accountId);
      break;
    case 'channels.stop':
      result = stop(state, channel, accountId);
      break;
    case 'channels.logout':
      if (!LOGOUT_CHANNELS.includes(channel)) return fail('INVALID_REQUEST', `channel ${channel} does not support logout`), true;
      result = logout(state, channel, accountId);
      break;
    default:
      return false;
  }
  sendRes(conn, id, result);
  if (healthSummary) broadcast(state, 'health', healthSummary(state));
  return true;
}
