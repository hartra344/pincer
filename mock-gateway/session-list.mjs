import crypto from 'node:crypto';
import { applyArchived, archiveProtectionError } from './sessions.mjs';
import { isSpawnedBy } from './subagents.mjs';
import { MODEL_CATALOG, sessionDefaults } from './catalog.mjs';
import { abortMatchingRuns } from './chat.mjs';
import { DEFAULT_MODEL, broadcast, clone, makeMessage, nowMs, sendErr, sendRes, shortId, textBlock } from './util.mjs';

// `archived`: false/absent lists active rows, true only archived ones, "all" both (sessions.list).
export function sortedSessions(state, archived = false) {
  return [...state.sessions.values()]
    .filter((s) => (archived === 'all' ? true : archived === true ? Boolean(s.archived) : !s.archived))
    .sort((a, b) => {
      if (Boolean(a.pinned) !== Boolean(b.pinned)) return a.pinned ? -1 : 1;
      return (b.lastActivityAt ?? 0) - (a.lastActivityAt ?? 0);
    })
    .map(clone);
}

// Run timing on the row (GatewaySessionRow startedAt/endedAt/runtimeMs), for run durations.
export function markRunStarted(row) {
  row.startedAt = nowMs();
  delete row.endedAt;
  delete row.runtimeMs;
}

export function markRunEnded(row) {
  row.endedAt = nowMs();
  if (row.startedAt !== undefined) row.runtimeMs = Math.max(0, row.endedAt - row.startedAt);
}

export function updateSessionRow(row, patch = {}) {
  Object.assign(row, patch, { updatedAt: nowMs() });
  return row;
}

export function broadcastSessionChanged(state, sessionKey, reason, session) {
  broadcast(state, 'sessions.changed', { sessionKey, reason, session: clone(session) }, (conn) => conn.sessionSubscribed);
}

export function groupCatalog(state) {
  return { groups: state.groups.map((name, position) => ({ name, position })), sectionOrder: [] };
}

// Like the real gateway, a category assigned through sessions.patch/create joins the catalog.
export function registerGroup(state, name) {
  const trimmed = typeof name === 'string' ? name.trim() : '';
  if (trimmed && !state.groups.includes(trimmed)) state.groups.push(trimmed);
}

export function moveGroupMembers(state, from, to) {
  let updated = 0;
  for (const row of state.sessions.values()) {
    if (row.category !== from) continue;
    row.category = to ?? undefined;
    updated += 1;
    broadcastSessionChanged(state, row.key, 'patch', row);
  }
  return updated;
}

export function broadcastSessionMessage(state, sessionKey, message, messageSeq) {
  broadcast(
    state,
    'session.message',
    { sessionKey, message: clone(message), messageId: message.__openclaw.id, messageSeq, hasActiveRun: true },
    (conn) => conn.messageSubs.has(sessionKey),
  );
}

export const SESSION_LIST_METHODS = new Set(['sessions.subscribe', 'sessions.list', 'sessions.groups.list', 'sessions.groups.put', 'sessions.groups.rename', 'sessions.groups.delete', 'sessions.messages.subscribe', 'sessions.messages.unsubscribe', 'sessions.patch', 'sessions.create']);

export function handleSessionListRequest(state, conn, msg) {
  if (!SESSION_LIST_METHODS.has(msg.method)) return false;
  dispatch(state, conn, msg);
  return true;
}

function dispatch(state, conn, msg) {
  const { id, method, params = {} } = msg;
  switch (method) {
    case 'sessions.subscribe': {
      conn.sessionSubscribed = true;
      sendRes(conn, id, {
        subscribed: true,
        list: { sessions: sortedSessions(state, params.archived), defaults: sessionDefaults(), nextOffset: null, hasMore: false },
      });
      break;
    }
    case 'sessions.list': {
      let listed = sortedSessions(state, params.archived);
      if (typeof params.spawnedBy === 'string' && params.spawnedBy) listed = listed.filter((row) => isSpawnedBy(row, params.spawnedBy));
      sendRes(conn, id, { sessions: listed, defaults: sessionDefaults(), nextOffset: null, hasMore: false });
      break;
    }
    case 'sessions.groups.list': {
      sendRes(conn, id, groupCatalog(state));
      break;
    }
    case 'sessions.groups.put': {
      if (!Array.isArray(params.names)) return sendErr(conn, id, 'INVALID_REQUEST', 'names required');
      const names = [...new Set(params.names.map((n) => String(n).trim()).filter(Boolean))];
      const dropped = state.groups.filter((name) => !names.includes(name)
        && [...state.sessions.values()].some((row) => row.category === name));
      if (dropped.length) {
        return sendErr(conn, id, 'INVALID_REQUEST', `sessions.groups.put cannot drop groups that still have member sessions: ${dropped.join(', ')}`);
      }
      state.groups = names;
      sendRes(conn, id, { ok: true, ...groupCatalog(state) });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.groups.rename': {
      const from = String(params.name ?? '').trim();
      const to = String(params.to ?? '').trim();
      if (!from || !to) return sendErr(conn, id, 'INVALID_REQUEST', 'group rename requires non-empty names');
      if (!state.groups.includes(from)) return sendErr(conn, id, 'INVALID_REQUEST', `unknown session group: ${from}`);
      const updatedSessions = from === to ? 0 : moveGroupMembers(state, from, to);
      state.groups = state.groups.includes(to) && from !== to
        ? state.groups.filter((name) => name !== from)
        : state.groups.map((name) => (name === from ? to : name));
      sendRes(conn, id, { ok: true, ...groupCatalog(state), updatedSessions });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.groups.delete': {
      const name = String(params.name ?? '').trim();
      if (!name) return sendErr(conn, id, 'INVALID_REQUEST', 'group delete requires a non-empty name');
      const updatedSessions = moveGroupMembers(state, name, null);
      state.groups = state.groups.filter((group) => group !== name);
      sendRes(conn, id, { ok: true, ...groupCatalog(state), updatedSessions });
      broadcast(state, 'sessions.changed', { reason: 'groups' }, (c) => c.sessionSubscribed);
      break;
    }
    case 'sessions.messages.subscribe': {
      if (!state.sessions.has(params.key)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      conn.messageSubs.add(params.key);
      sendRes(conn, id, { subscribed: true, key: params.key });
      break;
    }
    case 'sessions.messages.unsubscribe': {
      conn.messageSubs.delete(params.key);
      sendRes(conn, id, { ok: true, key: params.key });
      break;
    }
    case 'sessions.patch': {
      const row = state.sessions.get(params.key);
      if (!row) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown session');
      if (params.expectedSessionId && params.expectedSessionId !== row.sessionId) {
        return sendErr(conn, id, 'INVALID_REQUEST', 'expectedSessionId mismatch');
      }
      if (params.archived === true) {
        const protectedError = archiveProtectionError(params.key);
        if (protectedError) return sendErr(conn, id, 'INVALID_REQUEST', protectedError);
      }
      for (const field of ['unread', 'pinned', 'label', 'category', 'color']) {
        if (Object.hasOwn(params, field)) row[field] = params[field];
      }
      if (Object.hasOwn(params, 'archived')) {
        // Upstream stops active work before archiving.
        if (params.archived === true) abortMatchingRuns(state, params.key);
        applyArchived(row, params.archived === true);
      }
      if (Object.hasOwn(params, 'model')) {
        if (params.model === null) {
          Object.assign(row, { model: DEFAULT_MODEL.model, modelProvider: DEFAULT_MODEL.provider, modelOverrideSource: null });
        } else {
          const [provider, ...rest] = String(params.model).split('/');
          const choice = MODEL_CATALOG.find((m) => m.provider === provider && m.id === rest.join('/'));
          if (!choice) return sendErr(conn, id, 'INVALID_REQUEST', `model not allowed: ${params.model}`);
          if (!choice.available) return sendErr(conn, id, 'UNAVAILABLE', `model unavailable: ${params.model}`);
          Object.assign(row, { model: choice.id, modelProvider: choice.provider, modelOverrideSource: 'user' });
        }
      }
      if (Object.hasOwn(params, 'label')) row.derivedTitle = params.label ?? (row.isMain ? 'Main' : row.derivedTitle);
      if (Object.hasOwn(params, 'category')) registerGroup(state, params.category);
      updateSessionRow(row, { lastActivityAt: nowMs() });
      sendRes(conn, id, { ok: true, key: params.key, entry: clone(row) });
      broadcastSessionChanged(state, params.key, 'patch', row);
      break;
    }
    case 'sessions.create': {
      const agentId = params.agentId ?? 'main';
      if (!state.agents.has(agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      const key = `agent:${agentId}:dashboard:${shortId()}`;
      const row = {
        key,
        sessionId: crypto.randomUUID(),
        kind: 'direct',
        label: params.label ?? null,
        displayName: undefined,
        derivedTitle: params.label ?? 'New session',
        lastMessagePreview: params.message ? String(params.message).slice(0, 120) : 'New session created.',
        channel: 'webchat',
        agentId,
        isMain: false,
        category: params.category,
        color: undefined,
        pinned: false,
        unread: false,
        archived: false,
        updatedAt: nowMs(),
        lastActivityAt: nowMs(),
        status: 'idle',
        parentSessionKey: params.parentSessionKey,
        spawnedBy: params.parentSessionKey,
        hasActiveRun: false,
        activeRunIds: [],
      };
      state.sessions.set(key, row);
      registerGroup(state, params.category);
      let seeded = params.message ? [makeMessage('user', [textBlock(String(params.message))])] : [];
      if (params.fork === true) {
        // Whole-chat fork through the parent's last completed assistant message.
        if (!state.sessions.has(params.parentSessionKey)) return sendErr(conn, id, 'INVALID_REQUEST', `session not found: ${params.parentSessionKey}`);
        const parent = state.transcripts.get(params.parentSessionKey) ?? [];
        const lastAssistant = parent.map((message) => message.role).lastIndexOf('assistant');
        seeded = clone(parent.slice(0, lastAssistant + 1));
        row.forkedFromParent = true;
        row.lastMessagePreview = seeded.length ? row.lastMessagePreview : undefined;
      }
      state.transcripts.set(key, seeded);
      sendRes(conn, id, { key, sessionId: row.sessionId, session: clone(row) });
      broadcastSessionChanged(state, key, 'create', row);
      break;
    }
  }
}
