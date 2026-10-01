// Session manager: sessions.preview/describe, sessions.branches.list/switch, sessions.rewind,
// sessions.recover, sessions.delete and sessions.patchMany. Mirrors openclaw
// src/gateway/server-methods/sessions-read.ts, sessions-read-by-key.ts, sessions-rewind.ts,
// sessions-recover.ts (+ session-recovery-service.ts), sessions-delete.ts, sessions-mutations.ts
// and packages/gateway-protocol/src/schema/sessions.ts, sessions-delete.ts, sessions-recover.ts,
// sessions-patch.ts:
// - scopes (src/gateway/methods/core-descriptors.ts, src/shared/session-method-scopes-base.ts):
//   preview/describe/branches.list need operator.read; branches.switch and rewind need
//   operator.admin; recover needs operator.write; delete needs operator.write only with
//   `archivedOnly: true` and nothing beyond key/agentId/deleteTranscript/expectedSessionId/
//   archivedOnly, else operator.admin; patchMany needs operator.write for the plain row fields.
// - preview items are {role: user|assistant, text}; text is trimmed and cut to maxChars with "...".
//   Unknown keys are `missing`, empty transcripts `empty`.
// - describe returns {session: row | null}; derivedTitle/lastMessagePreview only when asked for.
// - branches are transcript DAG tips: the active leaf first, then other tips newest first. The
//   mock keeps the active path in `state.transcripts` and inactive tips in `state.sessionBranches`.
//   Rewind moves the active path to just before a user message and returns its text as
//   `editorText` (plus `editorAttachments` [{mimeType, data}] for its image blocks); the old tip stays as a branch. Both refuse while a run is active.
// - recover turns a restart-tombstoned session (restartRecoveryStatus: "tombstoned") into a fresh
//   dashboard session of the same agent; the source is archived (archiveReason restart-recovery).
// - every mutation emits `sessions.changed` (reasons: branch-switch, rewind, archive, create,
//   recovery, delete, patch).
// MOCK_NO_SESSION_MANAGER=1 hides every method here; MOCK_NO_SESSIONS_RECOVER=1 and
// MOCK_NO_PATCH_MANY=1 hide just sessions.recover (2026.8+) / sessions.patchMany (2026.8+).
import crypto from 'node:crypto';
import { ADMIN_SCOPE } from './config.mjs';
import { MOCK_STATE_DIR } from './agents.mjs';

export const SESSION_MANAGER_METHODS = [
  'sessions.preview',
  'sessions.describe',
  'sessions.branches.list',
  'sessions.branches.switch',
  'sessions.rewind',
  'sessions.fork',
  'sessions.recover',
  'sessions.delete',
  'sessions.patchMany',
];
const READ_SCOPE = 'operator.read';
const WRITE_SCOPE = 'operator.write';
const READ_METHODS = new Set(['sessions.preview', 'sessions.describe', 'sessions.branches.list']);
const ADMIN_METHODS = new Set(['sessions.branches.switch', 'sessions.rewind']);
const DELETE_WRITE_FIELDS = new Set(['key', 'agentId', 'deleteTranscript', 'expectedSessionId', 'archivedOnly']);
/** Fields sessions.patch / patchMany accept at operator.write in the mock (SESSIONS_PATCH_WRITE_SCOPE_MUTATIONS). */
export const PATCH_WRITE_FIELDS = new Set(['label', 'autoLabel', 'icon', 'color', 'category', 'pinned', 'archived', 'unread', 'model']);
const PATCH_MANY_MAX_TARGETS = 100;
const PREVIEW_MAX_KEYS = 64;
const PREVIEW_MAX_CHARS_CAP = 800;
const BRANCH_HEADLINE_MAX_CHARS = 120;
const SESSION_CHANGED_REASON = 'session-changed';

export function sessionManagerDisabled() {
  return process.env.MOCK_NO_SESSION_MANAGER === '1';
}

/** Methods to leave out of hello `features.methods`. */
export function hiddenSessionManagerMethods() {
  if (sessionManagerDisabled()) return SESSION_MANAGER_METHODS;
  return [
    ...(process.env.MOCK_NO_SESSIONS_RECOVER === '1' ? ['sessions.recover'] : []),
    ...(process.env.MOCK_NO_PATCH_MANY === '1' ? ['sessions.patchMany'] : []),
  ];
}

function scopeApproved(scopes, scope) {
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE) || (scope === READ_SCOPE && scopes.includes(WRITE_SCOPE));
}

export function deleteRequiredScope(params) {
  if (!params || typeof params !== 'object' || params.archivedOnly !== true) return ADMIN_SCOPE;
  return Object.keys(params).every((key) => DELETE_WRITE_FIELDS.has(key)) ? WRITE_SCOPE : ADMIN_SCOPE;
}

function patchManyRequiredScope(params) {
  const patch = params?.patch;
  if (!patch || typeof patch !== 'object') return WRITE_SCOPE;
  return Object.keys(patch).every((key) => PATCH_WRITE_FIELDS.has(key)) ? WRITE_SCOPE : ADMIN_SCOPE;
}

function requiredScope(method, params) {
  if (READ_METHODS.has(method)) return READ_SCOPE;
  if (ADMIN_METHODS.has(method)) return ADMIN_SCOPE;
  if (method === 'sessions.delete') return deleteRequiredScope(params);
  if (method === 'sessions.patchMany') return patchManyRequiredScope(params);
  return WRITE_SCOPE;
}

export function isMainSessionKey(key) {
  return /^agent:[^:]+:main$/.test(key) || key === 'global';
}

/** Upstream protectedArchiveError (sessions-patch-archive.ts), shared with sessions.patch. */
export function archiveProtectionError(key) {
  if (key === 'unknown') return 'Cannot archive the unknown session sentinel.';
  if (isMainSessionKey(key)) return "Cannot archive an agent's main session.";
  return undefined;
}

/** Applies `archived` like upstream: archivedAt/archiveReason are set on archive and cleared on unarchive. */
export function applyArchived(row, archived, now = Date.now(), reason = 'manual') {
  if (archived) {
    row.archived = true;
    if (row.archivedAt === undefined) row.archivedAt = now;
    row.archiveReason = row.archiveReason ?? reason;
    row.archivedBy = row.archivedBy ?? { type: 'human', label: 'Operator' };
  } else {
    row.archived = false;
    delete row.archivedAt;
    delete row.archiveReason;
    delete row.archivedBy;
  }
}

// --- Params validation (closedObject schemas) ---

function unexpected(params, allowed) {
  return Object.keys(params).find((key) => !allowed.includes(key));
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function paramsProblem(method, params) {
  const shape = {
    'sessions.preview': ['keys', 'limit', 'maxChars'],
    'sessions.describe': ['key', 'agentId', 'includeDerivedTitles', 'includeLastMessage'],
    'sessions.branches.list': ['sessionKey', 'agentId'],
    'sessions.branches.switch': ['sessionKey', 'agentId', 'leafEntryId'],
    'sessions.rewind': ['sessionKey', 'agentId', 'entryId'],
    'sessions.fork': ['sessionKey', 'agentId', 'entryId'],
    'sessions.recover': ['key', 'agentId'],
    'sessions.delete': ['key', 'agentId', 'deleteTranscript', 'expectedSessionId', 'expectedLifecycleRevision', 'expectedSessionUpdatedAt', 'emitLifecycleHooks', 'archivedOnly'],
    'sessions.patchMany': ['targets', 'patch'],
  }[method];
  const extra = unexpected(params, shape);
  if (extra) return `at root: unexpected property '${extra}'`;
  const required = {
    'sessions.preview': ['keys'],
    'sessions.describe': ['key'],
    'sessions.branches.list': ['sessionKey'],
    'sessions.branches.switch': ['sessionKey', 'leafEntryId'],
    'sessions.rewind': ['sessionKey', 'entryId'],
    'sessions.fork': ['sessionKey', 'entryId'],
    'sessions.recover': ['key'],
    'sessions.delete': ['key'],
    'sessions.patchMany': ['targets', 'patch'],
  }[method];
  for (const field of required) {
    if (!Object.hasOwn(params, field)) return `at root: must have required property '${field}'`;
  }
  for (const field of ['key', 'sessionKey', 'leafEntryId', 'entryId', 'agentId', 'expectedSessionId']) {
    if (Object.hasOwn(params, field) && !nonEmpty(params[field])) return `at /${field}: must NOT have fewer than 1 characters`;
  }
  if (method === 'sessions.preview') {
    if (!Array.isArray(params.keys) || params.keys.length === 0) return 'at /keys: must NOT have fewer than 1 items';
    if (params.keys.some((key) => !nonEmpty(key))) return 'at /keys: must NOT have fewer than 1 characters';
    if (Object.hasOwn(params, 'limit') && !(Number.isInteger(params.limit) && params.limit >= 1)) return 'at /limit: must be >= 1';
    if (Object.hasOwn(params, 'maxChars') && !(Number.isInteger(params.maxChars) && params.maxChars >= 20)) return 'at /maxChars: must be >= 20';
  }
  if (method === 'sessions.patchMany') {
    if (!Array.isArray(params.targets) || params.targets.length === 0) return 'at /targets: must NOT have fewer than 1 items';
    if (params.targets.length > PATCH_MANY_MAX_TARGETS) return `at /targets: must NOT have more than ${PATCH_MANY_MAX_TARGETS} items`;
    for (const [index, target] of params.targets.entries()) {
      if (!target || typeof target !== 'object') return `at /targets/${index}: must be object`;
      const bad = unexpected(target, ['key', 'agentId', 'expectedSessionId', 'expectedLifecycleRevision', 'expectedSandboxMode', 'expectedPermissionMode', 'expectedNativeRuntimeConsent']);
      if (bad) return `at /targets/${index}: unexpected property '${bad}'`;
      if (!nonEmpty(target.key)) return `at /targets/${index}/key: must NOT have fewer than 1 characters`;
    }
    if (!params.patch || typeof params.patch !== 'object' || Array.isArray(params.patch)) return 'at /patch: must be object';
    if (Object.keys(params.patch).length === 0) return 'at /patch: must NOT have fewer than 1 properties';
  }
  for (const field of ['deleteTranscript', 'archivedOnly', 'includeDerivedTitles', 'includeLastMessage']) {
    if (Object.hasOwn(params, field) && typeof params[field] !== 'boolean') return `at /${field}: must be boolean`;
  }
  return undefined;
}

// --- Transcript helpers ---

function messageId(message) {
  return message?.__openclaw?.id;
}

function messageText(message) {
  if (typeof message?.content === 'string') return message.content;
  if (!Array.isArray(message?.content)) return typeof message?.text === 'string' ? message.text : undefined;
  const parts = message.content.filter((b) => (b?.type === 'text' || b?.type === 'input_text') && typeof b.text === 'string').map((b) => b.text);
  return parts.length ? parts.join('\n') : undefined;
}

/** Upstream editorAttachments: the message's image blocks as {mimeType, data} (base64). */
function editorAttachmentsOf(state, message) {
  if (!Array.isArray(message?.content)) return {};
  // Images sent through chat.send are stored as uploaded artifacts; those resolve back to their bytes.
  const editorAttachments = message.content.flatMap((b) => {
    if (b?.type !== 'image') return [];
    if (typeof b.data === 'string' && b.data.trim() && typeof b.mimeType === 'string' && b.mimeType.startsWith('image/')) return [{ mimeType: b.mimeType, data: b.data }];
    const artifact = typeof b.artifactId === 'string' ? state.artifacts.get(b.artifactId) : undefined;
    return artifact?.mimeType?.startsWith('image/') ? [{ mimeType: artifact.mimeType, data: Buffer.from(artifact.data).toString('base64') }] : [];
  });
  return editorAttachments.length ? { editorAttachments } : {};
}

/** A user message with a tiny inline image block (a 48x48 PNG of the bed), as chat.history stores pasted images. */
const DEMO_IMAGE_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAABC0lEQVR42u2VPWpCURCFz2rExh28IpWNjTvIDqyzAwlRRCRKCEEkiIi4BRP/f/O7jbODVBaCqPP0VqNjGPiqxzm8D+7Mvcj3aArcv9EUeHinKVDs0xQoDajN329aciyM8pCqxNpsiM2jMqIeJ2w2yAoex9QjKCQrqE2oR1BIVvA0pR5BIVnB84x6BIVkBS9z6hEUkhXUF9QjKCQraCypygmb2DxeV9Qm1uZYGM0PmgKtT5oC7S+aAp1vmgLdH5oCUTXakrxLbdn9fs4MLEjsCVmQ2M34kV3fkd3eJA7IZVIHnDODy/5eZlwoKGRuhswJZQuRKXyofcv+35b5WxaaIb+HfMt8y/wtu7DQGi5MKF8FwYahAAAAAElFTkSuQmCC';
function withImage(message) {
  return { ...message, content: [...message.content, { type: 'image', mimeType: 'image/png', data: DEMO_IMAGE_BASE64 }] };
}

/** projectSessionDisplayMessage: user/assistant text only, trimmed and capped. */
function previewItem(message, maxChars) {
  if (!message || message.display === false) return null;
  const role = String(message.role ?? '').toLowerCase();
  if (role !== 'user' && role !== 'assistant') return null;
  const text = messageText(message)?.trim();
  if (!text) return null;
  const limit = Math.min(PREVIEW_MAX_CHARS_CAP, Math.max(20, Math.floor(maxChars)));
  return { role, text: text.length <= limit ? text : `${text.slice(0, limit - 3)}...` };
}

export function buildPreviewItems(messages, maxItems, maxChars) {
  const items = [];
  for (let index = messages.length - 1; index >= 0 && items.length < maxItems; index -= 1) {
    const item = previewItem(messages[index], maxChars);
    if (item) items.push(item);
  }
  return items.reverse();
}

function headline(path) {
  for (let index = path.length - 1; index >= 0; index -= 1) {
    const message = path[index];
    if (message.role !== 'user' && message.role !== 'assistant') continue;
    const text = messageText(message)?.trim();
    if (!text) continue;
    return text.length <= BRANCH_HEADLINE_MAX_CHARS ? text : `${text.slice(0, BRANCH_HEADLINE_MAX_CHARS - 1)}…`;
  }
  return '';
}

function branchSummary(path, active) {
  const leaf = path[path.length - 1];
  return {
    leafEntryId: messageId(leaf),
    headline: headline(path),
    messageCount: path.length,
    ...(leaf?.timestamp ? { updatedAt: new Date(leaf.timestamp).toISOString() } : {}),
    active,
  };
}

function isPrefix(prefix, path) {
  return prefix.length <= path.length && prefix.every((message, index) => messageId(path[index]) === messageId(message));
}

function inactiveTips(state, key) {
  if (!state.sessionBranches.has(key)) state.sessionBranches.set(key, []);
  return state.sessionBranches.get(key);
}

/** Keeps a path as an inactive tip unless another tip already contains it. */
function retainTip(state, key, path) {
  if (!path.length) return;
  const tips = inactiveTips(state, key);
  if (tips.some((tip) => isPrefix(path, tip.path))) return;
  tips.push({ path, index: state.branchSeq = (state.branchSeq ?? 0) + 1 });
}

export function listBranches(state, key) {
  const active = state.transcripts.get(key) ?? [];
  const tips = [...inactiveTips(state, key)].filter((tip) => !isPrefix(tip.path, active)).sort((a, b) => b.index - a.index);
  return [...(active.length ? [branchSummary(active, true)] : []), ...tips.map((tip) => branchSummary(tip.path, false))];
}

// --- Seeds ---

/**
 * Session-manager seeds: a chat with three branches, archived chats, a running and a failed run,
 * and a restart-tombstoned chat to recover. `row` registers a session row (see server.mjs).
 */
export function seedSessionManager({ row, transcripts, makeMessage, textBlock, base }) {
  const MIN = 60_000;
  const DAY = 24 * 60 * MIN;
  const at = (message, ms) => Object.assign(message, { timestamp: ms });
  const user = (text, ms) => at(makeMessage('user', [textBlock(text)]), ms);
  const assistant = (text, ms) => at(makeMessage('assistant', [textBlock(text)]), ms);

  // Branches: one shared opening, then three follow-ups the user tried.
  row('agent:main:dashboard:garden', {
    agentId: 'main',
    label: 'Garden planner',
    derivedTitle: 'Garden planner',
    category: 'Home',
    age: 5 * 3_600_000,
    lastMessagePreview: 'Swap the tomatoes for lettuce, kale and chard; they cope with four hours of sun.',
    totalTokens: 18_400,
    contextTokens: 200_000,
  });
  const g0 = base - 2 * DAY;
  const opening = [
    user('Plan a spring vegetable bed for a 4×8 ft raised bed.', g0),
    assistant('Tomatoes along the north edge, peppers in the middle, and a row of bush beans in front.', g0 + MIN),
  ];
  const drip = [...opening, user('Add a drip irrigation plan.', g0 + 30 * MIN), assistant('Run a ½" mainline along the long edge with three ¼" drip lines, 12" emitter spacing.', g0 + 31 * MIN)];
  const herbs = [...opening, user('What about an herbs-only bed instead?', g0 + DAY), assistant('Basil, thyme, oregano and parsley in quadrants, with chives along the border.', g0 + DAY + MIN)];
  const shade = [
    ...opening,
    withImage(user('Make it shade tolerant; it only gets four hours of sun.', base - 5 * 3_600_000 - MIN)),
    assistant('Swap the tomatoes for lettuce, kale and chard; they cope with four hours of sun.', base - 5 * 3_600_000),
  ];
  transcripts.set('agent:main:dashboard:garden', shade);
  const branches = new Map([['agent:main:dashboard:garden', [{ path: drip, index: 1 }, { path: herbs, index: 2 }]]]);

  // Archived chats: hidden by default, listed with `archived: true` or "all".
  const tax = row('agent:main:dashboard:tax-2025', {
    agentId: 'main',
    label: '2025 taxes',
    derivedTitle: '2025 taxes',
    category: 'Personal',
    age: 40 * DAY,
    lastMessagePreview: 'All 1099s are in the folder; the estimate is ready for review.',
  });
  applyArchived(tax, true, base - 30 * DAY, 'manual');
  transcripts.get('agent:main:dashboard:tax-2025').push(
    user('Collect my 1099s and draft the tax estimate.', base - 40 * DAY),
    assistant('All 1099s are in the folder; the estimate is ready for review.', base - 40 * DAY + MIN),
  );
  const bench = row('agent:research:dashboard:gpu-bench', {
    agentId: 'research',
    label: 'GPU benchmarks',
    derivedTitle: 'GPU benchmarks',
    category: 'Work',
    age: 21 * DAY,
    lastMessagePreview: 'The 5090 is 38% faster on the diffusion benchmark.',
  });
  applyArchived(bench, true, base - 14 * DAY, 'stale-dashboard');
  bench.archivedBy = { type: 'system', label: 'Gateway' };
  transcripts.get('agent:research:dashboard:gpu-bench').push(
    user('Compare the last two GPU generations on diffusion workloads.', base - 21 * DAY),
    assistant('The 5090 is 38% faster on the diffusion benchmark.', base - 21 * DAY + MIN),
  );

  // A run in flight (started six minutes ago) and a failed one with its duration.
  const refactorStarted = base - 6 * MIN;
  const refactor = row('agent:coder:dashboard:refactor', {
    agentId: 'coder',
    label: 'Refactor auth module',
    derivedTitle: 'Refactor auth module',
    category: 'Work',
    age: 30_000,
    lastMessagePreview: 'Splitting TokenStore into a protocol and two implementations…',
    totalTokens: 64_000,
    contextTokens: 200_000,
  });
  Object.assign(refactor, { status: 'running', startedAt: refactorStarted, hasActiveRun: true, activeRunIds: ['run_seed_refactor'] });
  transcripts.get('agent:coder:dashboard:refactor').push(
    user('Refactor the auth module so tokens can live in the keychain or in memory.', refactorStarted),
    assistant('Splitting TokenStore into a protocol and two implementations…', refactorStarted + 20_000),
  );
  const ci = row('agent:coder:dashboard:ci-fix', {
    agentId: 'coder',
    label: 'Fix flaky CI',
    derivedTitle: 'Fix flaky CI',
    category: 'Work',
    age: 50 * MIN,
    lastMessagePreview: 'Build failed: 3 tests in CacheTests timed out.',
  });
  Object.assign(ci, {
    status: 'failed',
    lastRunError: 'Build failed: 3 tests in CacheTests timed out.',
    startedAt: base - 50 * MIN - 94_000,
    endedAt: base - 50 * MIN,
    runtimeMs: 94_000,
  });
  transcripts.get('agent:coder:dashboard:ci-fix').push(
    user('Find out why CI keeps failing on main.', base - 50 * MIN - 94_000),
    assistant('Build failed: 3 tests in CacheTests timed out.', base - 50 * MIN),
  );
  // Interrupted by a Gateway restart: recoverable into a fresh chat.
  const photo = row('agent:main:dashboard:photo-import', {
    agentId: 'main',
    label: 'Photo import',
    derivedTitle: 'Photo import',
    category: 'Home',
    age: 3 * DAY,
    lastMessagePreview: 'Imported 212 of 480 photos from the SD card…',
  });
  Object.assign(photo, {
    status: 'killed',
    restartRecoveryStatus: 'tombstoned',
    startedAt: base - 3 * DAY - 12 * MIN,
    endedAt: base - 3 * DAY,
    runtimeMs: 12 * MIN,
  });
  transcripts.get('agent:main:dashboard:photo-import').push(
    user('Import the SD card photos into the Family library and tag them by date.', base - 3 * DAY - 12 * MIN),
    assistant('Imported 212 of 480 photos from the SD card…', base - 3 * DAY - MIN),
  );

  const stubRuns = [{ runId: 'run_seed_refactor', sessionKey: 'agent:coder:dashboard:refactor', text: '', seq: 0, aborted: false, finished: false, timers: new Set(), waiters: new Set() }];
  return { branches, stubRuns };
}

// --- Handler ---

function describeRow(row, params, clone) {
  const session = clone(row);
  if (params.includeDerivedTitles !== true) delete session.derivedTitle;
  if (params.includeLastMessage !== true) delete session.lastMessagePreview;
  return session;
}

function sessionAgentId(key) {
  return /^agent:([^:]+):/.exec(key)?.[1] ?? 'main';
}

/**
 * helpers: { sendRes, sendErr, broadcast, broadcastSessionChanged, abortMatchingRuns, makeMessage,
 * textBlock, clone, registerSession }
 */
export function handleSessionManagerRequest(state, conn, msg, helpers) {
  const { id, method } = msg;
  if (!SESSION_MANAGER_METHODS.includes(method)) return false;
  if (hiddenSessionManagerMethods().includes(method)) return false;
  const { sendRes, sendErr, broadcast, broadcastSessionChanged, abortMatchingRuns, clone } = helpers;
  const params = msg.params ?? {};
  const invalid = (message, details) => (sendErr(conn, id, 'INVALID_REQUEST', message, details), true);
  const unavailable = (message, details) => (sendErr(conn, id, 'UNAVAILABLE', message, details), true);
  const problem = paramsProblem(method, params);
  if (problem) return invalid(`invalid ${method} params: ${problem}`);
  const required = requiredScope(method, params);
  if (!scopeApproved(conn.scopes ?? [], required)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${required}`, { code: 'MISSING_SCOPE', scope: required });
    return true;
  }
  const agentProblem = () => {
    const raw = params.agentId?.trim();
    if (raw && !state.agents.has(raw.toLowerCase())) return `unknown agent id "${raw}"`;
    return undefined;
  };
  if (agentProblem()) return invalid(agentProblem());
  const changed = (sessionKey, reason, extra = {}) =>
    broadcast(state, 'sessions.changed', { sessionKey, reason, ...extra }, (c) => c.sessionSubscribed);

  switch (method) {
    case 'sessions.preview': {
      const keys = params.keys.map((key) => key.trim()).filter(Boolean).slice(0, PREVIEW_MAX_KEYS);
      const limit = params.limit ?? 12;
      const maxChars = params.maxChars ?? 240;
      const previews = keys.map((key) => {
        const row = state.sessions.get(key);
        const transcript = state.transcripts.get(key);
        if (!row || !transcript) return { key, status: 'missing', items: [] };
        const items = buildPreviewItems(transcript, limit, maxChars);
        return { key, status: items.length ? 'ok' : 'empty', items };
      });
      sendRes(conn, id, { ts: Date.now(), previews });
      return true;
    }
    case 'sessions.describe': {
      const row = state.sessions.get(params.key.trim());
      sendRes(conn, id, { session: row ? describeRow(row, params, clone) : null });
      return true;
    }
    case 'sessions.branches.list': {
      const key = params.sessionKey.trim();
      if (!state.sessions.has(key)) return sendRes(conn, id, { branches: [] }), true;
      sendRes(conn, id, { branches: listBranches(state, key) });
      return true;
    }
    case 'sessions.branches.switch':
    case 'sessions.rewind': {
      const isSwitch = method === 'sessions.branches.switch';
      const key = params.sessionKey.trim();
      const entryId = (isSwitch ? params.leafEntryId : params.entryId).trim();
      const row = state.sessions.get(key);
      if (!row) return invalid(`session not found: ${key}`);
      if (row.hasActiveRun) {
        return unavailable(isSwitch ? 'Branch switch is unavailable while the agent is working.' : 'Rewind is unavailable while the agent is working.');
      }
      const active = state.transcripts.get(key) ?? [];
      const tips = inactiveTips(state, key);
      const everywhere = [active, ...tips.map((tip) => tip.path)];
      const known = everywhere.some((path) => path.some((message) => messageId(message) === entryId));
      if (isSwitch) {
        if (messageId(active[active.length - 1]) === entryId) return invalid(`branch is already active: ${entryId}`);
        const tipIndex = tips.findIndex((tip) => messageId(tip.path[tip.path.length - 1]) === entryId && !isPrefix(tip.path, active));
        if (tipIndex < 0) return invalid(known ? `entry is not a branch tip: ${entryId}` : `branch entry not found: ${entryId}`);
        const [tip] = tips.splice(tipIndex, 1);
        retainTip(state, key, active);
        state.transcripts.set(key, [...tip.path]);
        const leaf = tip.path[tip.path.length - 1];
        row.activeLeafEntryId = entryId;
        row.lastMessagePreview = messageText(leaf)?.slice(0, 120) ?? row.lastMessagePreview;
        row.updatedAt = Date.now();
        sendRes(conn, id, {});
        changed(key, 'branch-switch', { agentId: row.agentId ?? sessionAgentId(key), session: clone(row) });
        return true;
      }
      const index = active.findIndex((message) => messageId(message) === entryId);
      if (index < 0) return invalid(known ? `message entry is not on the active path: ${entryId}` : `message entry not found: ${entryId}`);
      const target = active[index];
      if (target.role !== 'user') return invalid(`entry is not a user message: ${entryId}`);
      retainTip(state, key, active);
      const kept = active.slice(0, index);
      state.transcripts.set(key, kept);
      row.activeLeafEntryId = messageId(kept[kept.length - 1]) ?? null;
      row.lastMessagePreview = kept.length ? messageText(kept[kept.length - 1])?.slice(0, 120) : undefined;
      row.updatedAt = Date.now();
      const editorText = messageText(target);
      sendRes(conn, id, { ...(editorText ? { editorText } : {}), ...editorAttachmentsOf(state, target) });
      changed(key, 'rewind', { agentId: row.agentId ?? sessionAgentId(key), session: clone(row) });
      return true;
    }
    case 'sessions.fork': {
      const key = params.sessionKey.trim();
      const entryId = params.entryId.trim();
      const row = state.sessions.get(key);
      if (!row) return invalid(`session not found: ${key}`);
      const active = state.transcripts.get(key) ?? [];
      const index = active.findIndex((message) => messageId(message) === entryId);
      if (index < 0) return invalid(`message entry not found: ${entryId}`);
      const target = active[index];
      if (target.role !== 'user') return invalid(`entry is not a user message: ${entryId}`);
      const agentId = row.agentId ?? sessionAgentId(key);
      const newKey = `agent:${agentId}:dashboard:${crypto.randomUUID().slice(0, 8)}`;
      const kept = clone(active.slice(0, index));
      const child = {
        ...clone(row),
        key: newKey,
        sessionId: crypto.randomUUID(),
        pinned: false,
        archived: false,
        unread: false,
        status: 'idle',
        hasActiveRun: false,
        activeRunIds: [],
        parentSessionKey: key,
        spawnedBy: undefined,
        forkedFromParent: true,
        activeLeafEntryId: messageId(kept[kept.length - 1]) ?? null,
        lastMessagePreview: kept.length ? messageText(kept[kept.length - 1])?.slice(0, 120) : undefined,
        updatedAt: Date.now(),
        lastActivityAt: Date.now(),
      };
      for (const field of ['archivedAt', 'archiveReason', 'archivedBy', 'lastRunError', 'startedAt', 'endedAt', 'runtimeMs']) delete child[field];
      state.sessions.set(newKey, child);
      state.transcripts.set(newKey, kept);
      const editorText = messageText(target);
      sendRes(conn, id, { sessionKey: newKey, ...(editorText ? { editorText } : {}), ...editorAttachmentsOf(state, target) });
      changed(newKey, 'fork', { agentId, session: clone(child) });
      return true;
    }
    case 'sessions.recover': {
      const key = params.key.trim();
      const source = state.sessions.get(key);
      if (!source) return invalid('Session recovery source was not found.');
      if (source.recoveredSessionKey && state.sessions.has(source.recoveredSessionKey)) {
        // Already recovered: the same successor comes back (upstream `already_recovered`).
        const successor = state.sessions.get(source.recoveredSessionKey);
        sendRes(conn, id, { ok: true, key: successor.key, sessionId: successor.sessionId, continuation: { status: 'started', runId: `run_${crypto.randomUUID().slice(0, 8)}` } });
        changed(successor.key, 'recovery', { session: clone(successor) });
        return true;
      }
      if (source.restartRecoveryStatus !== 'tombstoned') return invalid('Session recovery requires a restart-tombstoned session.');
      if (source.hasActiveRun) return invalid('Session recovery is unavailable while the source still has active work.');
      const agentId = source.agentId ?? sessionAgentId(key);
      const now = Date.now();
      const successorKey = `agent:${agentId}:dashboard:${crypto.randomUUID()}`;
      const note = helpers.makeMessage('assistant', [helpers.textBlock('Recovered after a Gateway restart; picking up where the last run stopped.')]);
      const successor = {
        ...clone(source),
        key: successorKey,
        sessionId: crypto.randomUUID(),
        status: 'done',
        startedAt: now,
        endedAt: now,
        runtimeMs: 0,
        updatedAt: now,
        lastActivityAt: now,
        lastMessagePreview: messageText(note),
        previousSessionId: source.sessionId,
        createdVia: 'operator',
        createdAt: now,
        pinned: false,
        unread: false,
        hasActiveRun: false,
        activeRunIds: [],
      };
      for (const field of ['restartRecoveryStatus', 'lastRunError', 'archived', 'archivedAt', 'archiveReason', 'archivedBy', 'recoveredSessionKey']) delete successor[field];
      successor.archived = false;
      helpers.registerSession(successorKey, successor, [...(state.transcripts.get(key) ?? []), note]);
      delete source.restartRecoveryStatus;
      source.recoveredSessionKey = successorKey;
      applyArchived(source, true, now, 'restart-recovery');
      source.updatedAt = now;
      const runId = `run_${crypto.randomUUID().slice(0, 8)}`;
      sendRes(conn, id, { ok: true, key: successorKey, sessionId: successor.sessionId, continuation: { status: 'started', runId } });
      changed(key, 'archive', { session: clone(source) });
      changed(successorKey, 'create', { session: clone(successor) });
      return true;
    }
    case 'sessions.delete': {
      const key = params.key.trim();
      if (isMainSessionKey(key)) return invalid(`Cannot delete the main session (${key}).`);
      const row = state.sessions.get(key);
      if (!row) return sendRes(conn, id, { ok: true, key, deleted: false, archived: [] }), true;
      if (params.archivedOnly === true && row.archivedAt === undefined) {
        return invalid(`Session ${key} is not archived. Archive it first, then delete it.`);
      }
      if (params.expectedSessionId && params.expectedSessionId.trim() !== row.sessionId) {
        return invalid(`Session ${key} changed before deletion. Retry.`, { details: { reason: SESSION_CHANGED_REASON } });
      }
      // Upstream stops active work before deleting.
      abortMatchingRuns(state, key);
      const agentId = row.agentId ?? sessionAgentId(key);
      const deleteTranscript = params.deleteTranscript ?? true;
      const archived = deleteTranscript && (state.transcripts.get(key)?.length ?? 0) > 0
        ? [`${MOCK_STATE_DIR}/agents/${agentId}/sessions/${row.sessionId}.jsonl.deleted.${new Date().toISOString().replace(/:/g, '-')}`]
        : [];
      state.sessions.delete(key);
      state.transcripts.delete(key);
      state.sessionBranches.delete(key);
      for (const c of state.connections) c.messageSubs?.delete(key);
      sendRes(conn, id, { ok: true, key, deleted: true, archived });
      changed(key, 'delete', { sessionId: row.sessionId, agentId });
      broadcast(state, 'sessions.changed', { reason: 'delete' }, (c) => c.sessionSubscribed);
      return true;
    }
    case 'sessions.patchMany': {
      const patch = params.patch;
      const unsupported = Object.keys(patch).find((field) => !PATCH_WRITE_FIELDS.has(field) || field === 'model' || field === 'autoLabel' || field === 'icon');
      if (unsupported) return invalid(`invalid sessions.patchMany params: at /patch: unexpected property '${unsupported}'`);
      const outcomes = params.targets.map((target) => {
        const key = target.key.trim();
        const identity = { key: target.key, ...(target.agentId ? { agentId: target.agentId } : {}) };
        const row = state.sessions.get(key);
        if (!row) return { ok: false, ...identity, error: { code: 'INVALID_REQUEST', message: 'unknown session' } };
        if (target.expectedSessionId && target.expectedSessionId !== row.sessionId) {
          return { ok: false, ...identity, error: { code: 'INVALID_REQUEST', message: `Session ${key} changed before patch. Retry.`, details: { reason: SESSION_CHANGED_REASON } } };
        }
        if (patch.archived === true) {
          const protectedError = archiveProtectionError(key);
          if (protectedError) return { ok: false, ...identity, error: { code: 'INVALID_REQUEST', message: protectedError } };
          // Upstream stops active work before archiving.
          abortMatchingRuns(state, key);
        }
        for (const field of ['unread', 'pinned', 'label', 'category', 'color']) {
          if (Object.hasOwn(patch, field)) row[field] = patch[field];
        }
        if (Object.hasOwn(patch, 'label')) row.derivedTitle = patch.label ?? (row.isMain ? 'Main' : row.derivedTitle);
        if (Object.hasOwn(patch, 'category')) helpers.registerGroup(patch.category);
        if (Object.hasOwn(patch, 'archived')) applyArchived(row, patch.archived === true);
        row.updatedAt = Date.now();
        broadcastSessionChanged(state, key, 'patch', row);
        return { ok: true, ...identity };
      });
      sendRes(conn, id, { outcomes });
      return true;
    }
    default:
      return false;
  }
}
