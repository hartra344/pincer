import { broadcastSessionChanged, updateSessionRow } from './session-list.mjs';
import { broadcast, sendErr, sendRes } from './util.mjs';

// Mock-only test control (never used by the app): the `mock.control` RPC, plus per-method RPC
// counters and delayed responses. Not advertised in hello-ok.
//   MOCK_DELAY_METHODS="sessions.subscribe=800,chat.history=300" delays those responses (the
//   handler still runs at once, so its snapshot is taken then; events sent meanwhile arrive first).
export const CONTROL_METHOD = 'mock.control';

export function parseDelays(text) {
  const delays = new Map();
  for (const part of String(text ?? '').split(',')) {
    const [method, ms] = part.split('=').map((s) => s.trim());
    if (method && Number.isFinite(Number(ms)) && Number(ms) > 0) delays.set(method, Number(ms));
  }
  return delays;
}

export function initControl(state, env = process.env) {
  state.control = { delays: parseDelays(env.MOCK_DELAY_METHODS), connections: [] };
}

// Called for every authenticated request except mock.control.
export function noteRequest(state, conn, msg) {
  if (!conn.rpcRecord) {
    conn.rpcRecord = { connId: conn.connId, counts: {}, log: [] };
    state.control.connections.push(conn.rpcRecord);
  }
  conn.rpcRecord.counts[msg.method] = (conn.rpcRecord.counts[msg.method] ?? 0) + 1;
  conn.rpcRecord.log.push(msg.method);
  const ms = state.control.delays.get(msg.method);
  if (ms) (conn.delayRes ??= new Map()).set(msg.id, ms);
}

function stats(state) {
  const total = {};
  for (const record of state.control.connections) {
    for (const [method, n] of Object.entries(record.counts)) total[method] = (total[method] ?? 0) + n;
  }
  return { total, connections: state.control.connections.map(({ connId, counts, log }) => ({ connId, counts, log })) };
}

export function handleControlRequest(state, conn, msg) {
  if (msg.method !== CONTROL_METHOD) return false;
  const { id, params = {} } = msg;
  const control = state.control;
  switch (params.action) {
    case 'stats':
      sendRes(conn, id, stats(state));
      break;
    case 'resetStats': {
      // Keep the calling connection's record out of it; everything else starts from zero.
      control.connections = [];
      for (const other of state.connections) other.rpcRecord = undefined;
      sendRes(conn, id, { ok: true });
      break;
    }
    case 'setDelay': {
      const delays = params.delays && typeof params.delays === 'object' ? params.delays : {};
      control.delays = new Map(Object.entries(delays).filter(([, ms]) => Number(ms) > 0).map(([m, ms]) => [m, Number(ms)]));
      sendRes(conn, id, { ok: true, delays: Object.fromEntries(control.delays) });
      break;
    }
    case 'emit': {
      if (typeof params.event !== 'string') return sendErr(conn, id, 'INVALID_REQUEST', 'event required');
      broadcast(state, params.event, params.payload ?? {}, (c) => c !== conn && (!params.subscribedOnly || c.sessionSubscribed));
      sendRes(conn, id, { ok: true });
      break;
    }
    case 'patchSession': {
      const row = state.sessions.get(params.key);
      if (!row) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      updateSessionRow(row, params.patch ?? {});
      broadcastSessionChanged(state, params.key, params.reason ?? 'patch', row);
      sendRes(conn, id, { ok: true });
      break;
    }
    case 'drop': {
      // Closes every other connection, like a network drop (the control connection stays).
      let dropped = 0;
      for (const other of [...state.connections]) {
        if (other === conn) continue;
        other.ws.close(params.code ?? 1012, 'mock drop');
        dropped += 1;
      }
      sendRes(conn, id, { ok: true, dropped });
      break;
    }
    default:
      sendErr(conn, id, 'INVALID_REQUEST', `unknown mock.control action: ${params.action}`);
  }
  return true;
}
