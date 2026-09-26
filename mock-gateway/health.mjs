// Gateway health, presence and safe restart, shaped like OpenClaw's `health`, `status`,
// `last-heartbeat`, `system-presence` and `gateway.restart.request`.
import { ADMIN_SCOPE } from './config.mjs';

export const HEALTH_READ_METHODS = ['health', 'status', 'last-heartbeat', 'system-presence'];
export const RESTART_METHOD = 'gateway.restart.request';
export const HEALTH_METHODS = [...HEALTH_READ_METHODS, RESTART_METHOD];
export const HEALTH_EVENTS = ['health', 'heartbeat', 'presence', 'shutdown'];
export const RESTART_EXPECTED_MS = 1500;

/** `MOCK_NO_HEALTH=1` drops every health method, like an older Gateway. */
export function healthDisabled() {
  return process.env.MOCK_NO_HEALTH === '1';
}

export function createHealthState(base = Date.now()) {
  return {
    // A Gateway that has been up for a while.
    startedAt: base - (26 * 3600 + 12 * 60) * 1000,
    restartingUntil: 0,
    pendingRestart: undefined,
    restartCount: 0,
    lastHeartbeat: {
      ts: base - 4 * 60_000,
      status: 'ok-token',
      to: 'discord:#home',
      channel: 'discord',
      durationMs: 2800,
      indicatorType: 'ok',
    },
  };
}

export function uptimeMs(state) {
  return Math.max(0, Date.now() - state.healthState.startedAt);
}

/** While a simulated restart is under way, new sockets are refused. */
export function isRestarting(state) {
  return state.healthState.restartingUntil > Date.now();
}

export function healthSummary(state) {
  const now = Date.now();
  const discordEnabled = state.configState?.config?.channels?.discord?.enabled !== false;
  return {
    ok: true,
    ts: now,
    durationMs: 12,
    channels: {
      discord: {
        accountId: 'default',
        name: 'Discord',
        enabled: discordEnabled,
        configured: true,
        running: discordEnabled,
        connected: discordEnabled,
        restartPending: false,
        reconnectAttempts: 0,
        lastConnectedAt: state.healthState.startedAt + 2_000,
        lastError: null,
        lifecycle: discordEnabled ? 'ready' : 'stopped',
        accounts: {
          default: {
            accountId: 'default',
            enabled: discordEnabled,
            configured: true,
            running: discordEnabled,
            connected: discordEnabled,
            restartPending: false,
            lastError: null,
          },
        },
      },
      slack: {
        accountId: 'default',
        name: 'Slack',
        enabled: false,
        configured: false,
        running: false,
        connected: false,
      },
    },
    channelOrder: ['discord', 'slack'],
    channelLabels: { discord: 'Discord', slack: 'Slack' },
    heartbeatSeconds: 1800,
    defaultAgentId: 'main',
    agents: [...state.agents.values()].map((agent) => ({
      agentId: agent.id,
      name: agent.name,
      isDefault: agent.id === 'main',
      heartbeat: { enabled: agent.id === 'main', every: '30m', everyMs: 1_800_000 },
    })),
    sessions: { count: state.sessions.size, recent: [] },
    plugins: { loaded: ['discord', 'memory-core'], errors: [], unavailable: [] },
    deliveryQueues: { failed: [] },
    contextEngines: { quarantined: [] },
    modelPricing: { state: 'ok', sources: [] },
    configReload: { hotReloadStatus: 'active' },
  };
}

/** One presence entry per authenticated connection, plus a node that's always there. */
export function presenceEntries(state) {
  const now = Date.now();
  const entries = [];
  for (const conn of state.connections) {
    if (!conn.authenticated) continue;
    const client = conn.client ?? {};
    entries.push({
      text: `${client.displayName ?? 'client'} · ${client.mode ?? 'ui'}`,
      host: client.displayName ?? 'client',
      clientId: client.id,
      ip: '127.0.0.1',
      version: client.version,
      platform: client.platform,
      deviceFamily: client.deviceFamily,
      mode: client.mode,
      deviceId: conn.deviceId,
      instanceId: client.instanceId,
      roles: ['operator'],
      scopes: conn.scopes ?? [],
      ts: now,
      onlineSince: conn.connectedAt ?? now,
      lastActivityAt: conn.lastActivityAt ?? conn.connectedAt ?? now,
    });
  }
  entries.push({
    text: 'Node: kitchen-pi',
    host: 'kitchen-pi',
    clientId: 'node-host',
    ip: '100.64.0.7',
    version: '2026.1.0',
    platform: 'linux',
    deviceFamily: 'Raspberry Pi',
    mode: 'node',
    deviceId: 'c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2',
    instanceId: 'kitchen-pi',
    roles: ['node'],
    ts: now - 20_000,
    onlineSince: now - 2 * 86_400_000,
    lastActivityAt: now - 15 * 60_000,
  });
  return entries;
}

/** What `hello-ok.snapshot` carries. */
export function helloSnapshot(state) {
  return {
    presence: presenceEntries(state),
    health: healthSummary(state),
    stateVersion: { presence: state.healthState.restartCount + 1, health: state.healthState.restartCount + 1 },
    uptimeMs: uptimeMs(state),
  };
}

export function broadcastPresence(state, broadcast) {
  if (healthDisabled()) return;
  broadcast(state, 'presence', { presence: presenceEntries(state) });
}

function preflight(state) {
  const active = state.activeRuns.size;
  const counts = {
    queueSize: 0,
    pendingReplies: 0,
    embeddedRuns: active,
    cronRuns: state.cronState?.active?.size ?? 0,
    backgroundExecSessions: 0,
    rootRequests: 0,
    activeTasks: 0,
  };
  counts.totalActive = Object.values(counts).reduce((sum, n) => sum + n, 0);
  const blockers = [];
  if (counts.embeddedRuns) blockers.push({ message: `${counts.embeddedRuns} active agent run${counts.embeddedRuns === 1 ? '' : 's'}` });
  if (counts.cronRuns) blockers.push({ message: `${counts.cronRuns} running cron job${counts.cronRuns === 1 ? '' : 's'}` });
  return {
    safe: counts.totalActive === 0,
    counts,
    blockers,
    summary: blockers.length === 0 ? 'restart safe now' : `restart deferred: ${blockers.map((b) => b.message).join('; ')}`,
  };
}

/**
 * Like the Gateway: broadcast `shutdown`, close every socket with 1012, refuse new ones for
 * `RESTART_EXPECTED_MS`, then come back with a fresh uptime. Sessions and config survive.
 */
function performRestart(state, broadcast, reason, abortRun) {
  const hs = state.healthState;
  hs.pendingRestart = undefined;
  hs.restartCount += 1;
  hs.restartingUntil = Date.now() + RESTART_EXPECTED_MS;
  hs.startedAt = hs.restartingUntil;
  broadcast(state, 'shutdown', { reason: reason ?? 'gateway restart', restartExpectedMs: RESTART_EXPECTED_MS });
  // A restart kills whatever was still running.
  for (const run of [...state.activeRuns.values()]) abortRun?.(state, run);
  setTimeout(() => {
    for (const conn of state.connections) conn.ws.close(1012, 'service restart');
  }, 20);
  console.log(`Simulated restart (${reason ?? 'no reason'}); back in ${RESTART_EXPECTED_MS} ms`);
}

function scheduleRestart(state, broadcast, reason, deferred, abortRun) {
  const hs = state.healthState;
  const pending = { reason, timer: undefined };
  hs.pendingRestart = pending;
  const tick = () => {
    if (hs.pendingRestart !== pending) return;
    if (pending.skipDeferral || !deferred || preflight(state).safe) {
      performRestart(state, broadcast, pending.reason, abortRun);
    } else {
      pending.timer = setTimeout(tick, 100);
    }
  };
  pending.timer = setTimeout(tick, deferred ? 100 : 150);
  return pending;
}

export function cancelPendingRestart(state) {
  const pending = state.healthState.pendingRestart;
  if (pending?.timer) clearTimeout(pending.timer);
  state.healthState.pendingRestart = undefined;
}

export function handleHealthRequest(state, conn, msg, { sendRes, sendErr, broadcast, abortRun }) {
  const { id, method, params = {} } = msg;
  if (!HEALTH_METHODS.includes(method)) return false;
  if (healthDisabled()) {
    sendErr(conn, id, 'UNKNOWN_METHOD', `unknown method: ${method}`);
    return true;
  }
  const hs = state.healthState;
  switch (method) {
    case 'health':
      sendRes(conn, id, healthSummary(state));
      return true;
    case 'status':
      sendRes(conn, id, {
        ok: true,
        version: 'mock-2026.1',
        uptimeMs: uptimeMs(state),
        sessions: { count: state.sessions.size },
        heartbeatSeconds: 1800,
        channelSummary: ['Discord: connected'],
      });
      return true;
    case 'last-heartbeat':
      sendRes(conn, id, hs.lastHeartbeat ?? null);
      return true;
    case 'system-presence':
      sendRes(conn, id, presenceEntries(state));
      return true;
    case RESTART_METHOD: {
      if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
        sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
        return true;
      }
      if (typeof params !== 'object' || params === null || Array.isArray(params)) {
        sendErr(conn, id, 'INVALID_REQUEST', 'invalid gateway.restart.request params');
        return true;
      }
      const reason = typeof params.reason === 'string' && params.reason.trim() ? params.reason.trim().slice(0, 200) : undefined;
      const skipDeferral = params.skipDeferral === true;
      const check = preflight(state);
      if (hs.pendingRestart) {
        if (skipDeferral) hs.pendingRestart.skipDeferral = true;
        sendRes(conn, id, { ok: true, status: 'coalesced', preflight: check, restart: { coalesced: true, delayMs: 0 } });
        return true;
      }
      const deferred = !check.safe && !skipDeferral;
      scheduleRestart(state, broadcast, reason, deferred, abortRun);
      sendRes(conn, id, {
        ok: true,
        status: deferred ? 'deferred' : 'scheduled',
        preflight: check,
        restart: { coalesced: false, delayMs: 0 },
      });
      return true;
    }
    default:
      return false;
  }
}
