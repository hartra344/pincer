import { recordExecResolution } from './approvals.mjs';
import { recordAllowAlways } from './exec-approvals.mjs';
import { broadcast, canonicalJson, clone, nowMs, sendErr, sendRes } from './util.mjs';

export const MISC_METHODS = new Set(['artifacts.download', 'users.prefs.get', 'users.prefs.set', 'exec.approval.list', 'exec.approval.resolve']);

export function handleMiscRequest(state, conn, msg) {
  if (!MISC_METHODS.has(msg.method)) return false;
  dispatch(state, conn, msg);
  return true;
}

function dispatch(state, conn, msg) {
  const { id, method, params = {} } = msg;
  switch (method) {
    case 'artifacts.download': {
      const artifact = state.artifacts.get(params.artifactId);
      if (!artifact) return sendErr(conn, id, 'NOT_FOUND', 'artifact not found');
      sendRes(conn, id, {
        artifactId: params.artifactId,
        mimeType: artifact.mimeType,
        encoding: 'base64',
        data: artifact.data.toString('base64'),
      });
      break;
    }
    case 'users.prefs.get': {
      const prefs = state.userPrefs ?? (state.userPrefs = {});
      const keys = Array.isArray(params.keys) ? params.keys : Object.keys(prefs);
      const entries = Object.fromEntries(keys.filter((k) => k in prefs).map((k) => [k, clone(prefs[k])]));
      sendRes(conn, id, { status: 'ok', entries });
      break;
    }
    case 'users.prefs.set': {
      const prefs = state.userPrefs ?? (state.userPrefs = {});
      const entries = params.entries ?? {};
      if (process.env.MOCK_PREFS_NO_CAS && 'expectedEntries' in params) {
        return sendErr(conn, id, 'INVALID_REQUEST', "invalid users.prefs.set params: at root: unexpected property 'expectedEntries'");
      }
      for (const [key, expected] of Object.entries(params.expectedEntries ?? {})) {
        const current = key in prefs ? prefs[key] : null;
        if (canonicalJson(current) !== canonicalJson(expected)) {
          sendRes(conn, id, { status: 'conflict' });
          return;
        }
      }
      for (const [key, value] of Object.entries(entries)) {
        if (value === null) delete prefs[key];
        else prefs[key] = clone(value);
      }
      sendRes(conn, id, { status: 'ok' });
      broadcast(state, 'users.prefs.changed', { profileId: 'gateway-owner', keys: Object.keys(entries) });
      break;
    }
    case 'exec.approval.list': {
      const now = nowMs();
      sendRes(conn, id, { approvals: [...state.pendingApprovals.values()].filter((a) => a.expiresAtMs > now).map(clone) });
      break;
    }
    case 'exec.approval.resolve': {
      // Mirrors openclaw exec-approval.ts / approval-shared.ts / approval-errors.ts.
      if (!['allow-once', 'allow-always', 'deny'].includes(params.decision)) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid decision');
      }
      const resolvedDecision = state.resolvedApprovals.get(params.id);
      if (resolvedDecision !== undefined) {
        if (resolvedDecision === params.decision) return sendRes(conn, id, { ok: true });
        return sendErr(conn, id, 'INVALID_REQUEST', 'approval already resolved', { reason: 'APPROVAL_ALREADY_RESOLVED' });
      }
      const approval = state.pendingApprovals.get(params.id);
      if (!approval || approval.expiresAtMs <= nowMs()) {
        if (approval) state.pendingApprovals.delete(params.id);
        return sendErr(conn, id, 'INVALID_REQUEST', 'approval expired or not found', { reason: 'APPROVAL_NOT_FOUND' });
      }
      const allowed = approval.request?.allowedDecisions;
      if (Array.isArray(allowed) && !allowed.includes(params.decision)) {
        if (params.decision === 'allow-always') {
          return sendErr(conn, id, 'INVALID_REQUEST', 'allow-always is unavailable for this command', { reason: 'APPROVAL_ALLOW_ALWAYS_UNAVAILABLE' });
        }
        return sendErr(conn, id, 'INVALID_REQUEST', 'invalid decision');
      }
      recordExecResolution(state, approval, params.decision, conn.deviceId);
      if (params.decision === 'allow-always') recordAllowAlways(state, approval);
      state.pendingApprovals.delete(params.id);
      state.resolvedApprovals.set(params.id, params.decision);
      broadcast(state, 'exec.approval.resolved', { id: params.id, decision: params.decision });
      sendRes(conn, id, { ok: true, id: params.id, decision: params.decision });
      break;
    }
  }
}
