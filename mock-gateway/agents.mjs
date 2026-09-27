// Agent management and workspace files: agents.list/create/update/delete, agent.identity.get and
// agents.files.list/get/set. Mirrors openclaw src/gateway/server-methods/agents.ts,
// agents-files.ts, agent-identity.ts and src/agents/agent-create.ts:
// - scopes (src/gateway/methods/core-descriptors.ts): list/identity/files.list/files.get need
//   operator.read; create/update/delete/files.set need operator.admin.
// - ids follow normalizeAgentIdStrict; `openclaw` and `crestodian` are reserved system agents.
// - files are the canonical bootstrap files; `hash` is lowercase SHA-256 hex of the UTF-8 bytes;
//   stale `expectedHash` or `expectedMissing` on an existing file is an `agent_file_conflict`.
// - There is no agents-changed event: clients re-fetch agents.list after their own mutations.
// MOCK_NO_AGENT_MANAGEMENT=1 makes the mock look like a Gateway without these methods (only
// agents.list stays, as it has for a long time).
import crypto from 'node:crypto';
import { ADMIN_SCOPE } from './config.mjs';

export const AGENT_MANAGEMENT_METHODS = [
  'agents.create',
  'agents.update',
  'agents.delete',
  'agent.identity.get',
  'agents.files.list',
  'agents.files.get',
  'agents.files.set',
];
const ADMIN_METHODS = new Set(['agents.create', 'agents.update', 'agents.delete', 'agents.files.set']);

export const MOCK_STATE_DIR = '/Users/claw/.openclaw';
/** Upstream MAX_WORKSPACE_BOOTSTRAP_FILE_BYTES (src/agents/workspace-bootstrap-read.ts). */
export const MAX_WORKSPACE_FILE_BYTES = 2 * 1024 * 1024;
/** WORKSPACE_BOOTSTRAP_FILENAMES, in prompt order: the names agents.files.get/set accept. */
export const WORKSPACE_FILE_NAMES = ['AGENTS.md', 'SOUL.md', 'IDENTITY.md', 'USER.md', 'BOOTSTRAP.md', 'MEMORY.md'];
// IDENTITY.md is rewritten by agents.update, so it isn't listed as an editor tab (still writable).
const LISTED_FILE_NAMES = WORKSPACE_FILE_NAMES.filter((name) => name !== 'IDENTITY.md');
const EXPECTED_ABSENT = new Set(['SOUL.md', 'IDENTITY.md', 'USER.md', 'MEMORY.md']);
const RESERVED_IDS = new Set(['openclaw', 'crestodian']);
const DEFAULT_AGENT_ID = 'main';

const VALID_ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/i;

export function agentManagementDisabled() {
  return process.env.MOCK_NO_AGENT_MANAGEMENT === '1';
}

/** normalizeAgentIdStrict from packages/normalization-core/src/agent-id.ts; undefined when unrepresentable. */
export function normalizeAgentIdStrict(value) {
  const trimmed = String(value ?? '').trim();
  const normalized = trimmed.toLowerCase();
  if (VALID_ID_RE.test(trimmed)) return normalized;
  const id = normalized.replace(/[^a-z0-9_-]+/g, '-').replace(/^-+/, '').replace(/-+$/, '').slice(0, 64);
  return id || undefined;
}

export function workspaceFileHash(content) {
  return crypto.createHash('sha256').update(Buffer.from(content, 'utf8')).digest('hex');
}

export function defaultWorkspaceDir(agentId) {
  return agentId === DEFAULT_AGENT_ID ? `${MOCK_STATE_DIR}/workspace` : `${MOCK_STATE_DIR}/workspace-${agentId}`;
}

function oneLine(value) {
  return String(value).replace(/[\r\n]+/g, ' ').trim();
}

function identityMarkdown(identity = {}) {
  const lines = ['# IDENTITY.md - Who Am I?', ''];
  lines.push(`- **Name:** ${identity.name ?? ''}`);
  if (identity.emoji) lines.push(`- **Emoji:** ${identity.emoji}`);
  if (identity.avatar) lines.push(`- **Avatar:** ${identity.avatar}`);
  return `${lines.join('\n')}\n`;
}

// ensureAgentWorkspace's seeded templates: never overwrite a file that is already there.
function templates(agent) {
  const name = agent.identity?.name ?? agent.name ?? agent.id;
  return {
    'AGENTS.md': `# AGENTS.md - Your Workspace\n\nThis folder is home. Treat it that way.\n\n## Every Session\n\n1. Read SOUL.md - this is who you are.\n2. Read USER.md - this is who you're helping.\n3. Check MEMORY.md for anything you wrote down last time.\n`,
    'SOUL.md': `# SOUL.md - Who You Are\n\nBe genuinely helpful, not performatively helpful. Have opinions. Be resourceful before asking.\n`,
    'IDENTITY.md': identityMarkdown(agent.identity ?? { name }),
    'USER.md': `# USER.md - About Your Human\n\n- **Name:**\n- **Timezone:**\n- **Notes:**\n`,
    'BOOTSTRAP.md': `# BOOTSTRAP.md - Hello, World\n\nYou just woke up. Figure out who you are with your human, fill in IDENTITY.md and SOUL.md, then delete this file.\n`,
  };
}

function workspaceFor(state, dir) {
  let ws = state.agentWorkspaces.get(dir);
  if (!ws) {
    ws = { files: new Map(), setupCompleted: false };
    state.agentWorkspaces.set(dir, ws);
  }
  return ws;
}

function writeFile(ws, name, content, at = Date.now()) {
  ws.files.set(name, { content, updatedAtMs: Math.floor(at) });
}

function ensureWorkspace(state, agent, at = Date.now()) {
  const ws = workspaceFor(state, agent.workspace);
  for (const [name, content] of Object.entries(templates(agent))) {
    if (!ws.files.has(name)) writeFile(ws, name, content, at);
  }
  return ws;
}

const SEEDED_FILES = {
  main: {
    'AGENTS.md': `# AGENTS.md - Claw's Workspace\n\nThis folder is home. Treat it that way.\n\n## Every Session\n\n1. Read SOUL.md - this is who you are.\n2. Read USER.md - this is who you're helping.\n3. Read MEMORY.md for long-term context.\n\n## Safety\n\n- Don't exfiltrate private data.\n- Ask before running anything destructive.\n- \`trash\` > \`rm\`.\n`,
    'SOUL.md': `# SOUL.md - Who You Are\n\nYou're Claw 🦞, the house assistant for a small home lab.\n\n- Be concise. Lead with the answer.\n- Have opinions and share them.\n- Earn trust through competence.\n`,
    'USER.md': `# USER.md - About Your Human\n\n- **Name:** Travis\n- **Timezone:** America/New_York\n- **Notes:** Prefers short status updates; runs a NAS and a few Raspberry Pis.\n`,
    'MEMORY.md': `# MEMORY.md\n\n- 2026-09-20: NAS scrub finished clean; next one scheduled monthly.\n- Travis likes disk reports as a table.\n`,
  },
  research: {
    'AGENTS.md': `# AGENTS.md - Scout's Workspace\n\nYou investigate papers, repos, and docs. Cite sources with links.\n`,
    'SOUL.md': `# SOUL.md\n\nYou're Scout 🔭: curious, skeptical, and precise. Say "I don't know" when you don't.\n`,
  },
  coder: {
    'AGENTS.md': `# AGENTS.md - Forge's Workspace\n\nYou edit code, run builds, and report concise status.\n\n- Run the tests before saying something works.\n- Keep diffs small.\n`,
  },
};

/** Seeds per-agent workspaces for the seeded roster; main and research have finished onboarding. */
export function createAgentWorkspaces(agents, base = Date.now()) {
  const state = { agentWorkspaces: new Map() };
  for (const agent of agents.values()) {
    agent.workspace ??= defaultWorkspaceDir(agent.id);
    const ws = workspaceFor(state, agent.workspace);
    for (const [name, content] of Object.entries(SEEDED_FILES[agent.id] ?? {})) writeFile(ws, name, content, base - 3 * 60 * 60_000);
    writeFile(ws, 'IDENTITY.md', identityMarkdown(agent.identity ?? { name: agent.name }), base - 24 * 60 * 60_000);
    if (agent.id === 'coder') writeFile(ws, 'BOOTSTRAP.md', templates(agent)['BOOTSTRAP.md'], base - 60 * 60_000);
    ws.setupCompleted = agent.id !== 'coder';
  }
  return state.agentWorkspaces;
}

// --- Params schema (closed objects, like the gateway-protocol typebox schemas) ---

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const SHA256_RE = /^[a-fA-F0-9]{64}$/;
const fieldType = {
  nonEmpty: (v) => (typeof v !== 'string' ? 'must be string' : v.length ? undefined : 'must NOT have fewer than 1 characters'),
  string: (v) => (typeof v === 'string' ? undefined : 'must be string'),
  boolean: (v) => (typeof v === 'boolean' ? undefined : 'must be boolean'),
  nullableNonEmpty: (v) => (v === null ? undefined : fieldType.nonEmpty(v)),
  sha256: (v) => (typeof v === 'string' && SHA256_RE.test(v) ? undefined : 'must match pattern "^[a-fA-F0-9]{64}$"'),
  trueLiteral: (v) => (v === true ? undefined : 'must be equal to constant'),
};

const SCHEMAS = {
  'agents.list': { fields: {} },
  'agents.create': { required: ['name'], fields: { name: 'nonEmpty', workspace: 'nonEmpty', model: 'nonEmpty', emoji: 'string', avatar: 'string' } },
  'agents.update': {
    required: ['agentId'],
    fields: { agentId: 'nonEmpty', name: 'nonEmpty', workspace: 'nonEmpty', model: 'nullableNonEmpty', agentRuntime: 'nonEmpty', emoji: 'string', avatar: 'string' },
  },
  'agents.delete': { required: ['agentId'], fields: { agentId: 'nonEmpty', deleteFiles: 'boolean' } },
  'agent.identity.get': { fields: { agentId: 'nonEmpty', sessionKey: 'string' } },
  'agents.files.list': { required: ['agentId'], fields: { agentId: 'nonEmpty' } },
  'agents.files.get': { required: ['agentId', 'name'], fields: { agentId: 'nonEmpty', name: 'nonEmpty' } },
  'agents.files.set': {
    required: ['agentId', 'name', 'content'],
    fields: { agentId: 'nonEmpty', name: 'nonEmpty', content: 'string', expectedHash: 'sha256', expectedMissing: 'trueLiteral' },
  },
};

export function agentParamsProblem(method, params) {
  const schema = SCHEMAS[method];
  if (!isObject(params)) return 'at root: must be object';
  for (const key of schema.required ?? []) if (!(key in params)) return `at root: must have required property '${key}'`;
  for (const [key, value] of Object.entries(params)) {
    const type = schema.fields[key];
    if (!type) return `at root: unexpected property '${key}'`;
    const problem = fieldType[type](value);
    if (problem) return `at /${key}: ${problem}`;
  }
  if (method === 'agents.files.set' && 'expectedHash' in params && 'expectedMissing' in params) return 'at root: must NOT be valid';
  return undefined;
}

// --- Projections ---

function summary(agent) {
  return structuredClone({
    id: agent.id,
    ...(agent.name ? { name: agent.name } : {}),
    ...(agent.identity && Object.keys(agent.identity).length ? { identity: agent.identity } : {}),
    ...(agent.workspace ? { workspace: agent.workspace } : {}),
    ...(agent.model ? { model: { primary: agent.model } } : {}),
    ...(agent.agentRuntime ? { agentRuntime: agent.agentRuntime } : {}),
    ...(agent.createdAt ? { createdAt: agent.createdAt, createdVia: 'operator' } : {}),
  });
}

export function agentsListPayload(state) {
  return {
    defaultId: state.agents.has(DEFAULT_AGENT_ID) ? DEFAULT_AGENT_ID : ([...state.agents.keys()][0] ?? DEFAULT_AGENT_ID),
    mainKey: 'main',
    scope: 'per-sender',
    agents: [...state.agents.values()].map(summary),
  };
}

function listedEntry(dir, ws, name) {
  const file = ws?.files.get(name);
  const entry = { name, path: `${dir}/${name}`, missing: !file };
  if (!file) return { ...entry, expectedAbsent: EXPECTED_ABSENT.has(name) };
  return { ...entry, size: Buffer.byteLength(file.content, 'utf8'), updatedAtMs: file.updatedAtMs };
}

function fullEntry(dir, ws, name) {
  const file = ws?.files.get(name);
  if (!file) return listedEntry(dir, ws, name);
  return { ...listedEntry(dir, ws, name), hash: workspaceFileHash(file.content), content: file.content };
}

function identityPayload(state, agentId) {
  const agent = state.agents.get(agentId);
  const name = agent?.identity?.name ?? agent?.name;
  const avatar = [agent?.identity?.avatar, agent?.identity?.emoji].find((v) => typeof v === 'string' && v.trim()) ?? 'A';
  return {
    agentId,
    name: name ?? 'Assistant',
    nameSource: name ? 'agent' : 'default',
    avatar,
    ...(agent?.identity?.emoji ? { emoji: agent.identity.emoji } : {}),
  };
}

// --- Handler ---

export function handleAgentsRequest(state, conn, msg, { sendRes, sendErr, broadcast }) {
  const { id, method } = msg;
  const params = msg.params ?? {};
  if (method !== 'agents.list' && (!AGENT_MANAGEMENT_METHODS.includes(method) || agentManagementDisabled())) return false;
  if (ADMIN_METHODS.has(method) && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const invalid = (message, details) => (sendErr(conn, id, 'INVALID_REQUEST', message, details), true);
  const problem = agentParamsProblem(method, params);
  if (problem) return invalid(`invalid ${method} params: ${problem}`);
  const notFound = (agentId) => invalid(`agent "${agentId}" not found`);
  const configuredId = (raw) => {
    const agentId = normalizeAgentIdStrict(raw);
    return agentId && state.agents.has(agentId) ? agentId : undefined;
  };

  switch (method) {
    case 'agents.list':
      sendRes(conn, id, agentsListPayload(state));
      return true;

    case 'agent.identity.get': {
      const sessionKey = typeof params.sessionKey === 'string' ? params.sessionKey.trim() : '';
      let agentId = params.agentId?.trim() ? (normalizeAgentIdStrict(params.agentId) ?? DEFAULT_AGENT_ID) : undefined;
      if (sessionKey.startsWith('agent:') && !/^agent:[^:]+:.+/.test(sessionKey)) {
        return invalid(`invalid agent.identity.get params: malformed session key "${sessionKey}"`);
      }
      if (sessionKey || !agentId) {
        const fromKey = /^agent:([^:]+):/.exec(sessionKey)?.[1];
        agentId = normalizeAgentIdStrict(fromKey) ?? agentId ?? DEFAULT_AGENT_ID;
      }
      sendRes(conn, id, identityPayload(state, agentId));
      return true;
    }

    case 'agents.create': {
      const rawName = params.name.trim();
      if (!rawName) return invalid('agent name is required');
      const agentId = normalizeAgentIdStrict(rawName);
      if (!agentId) return invalid(`Agent name "${rawName}" has no valid id characters. Use at least one letter a-z or digit.`);
      if (RESERVED_IDS.has(agentId)) return invalid(`"${agentId}" is reserved`);
      if (state.agents.has(agentId)) return invalid(`agent "${agentId}" already exists`);
      const name = oneLine(rawName);
      const emoji = params.emoji?.trim();
      const avatar = params.avatar?.trim();
      const model = params.model?.trim();
      const agent = {
        id: agentId,
        name,
        identity: { name, ...(emoji ? { emoji } : {}), ...(avatar ? { avatar } : {}) },
        workspace: params.workspace?.trim() || defaultWorkspaceDir(agentId),
        ...(model ? { model } : {}),
        createdAt: Date.now(),
      };
      state.agents.set(agentId, agent);
      ensureWorkspace(state, agent);
      sendRes(conn, id, { ok: true, agentId, name, workspace: agent.workspace, ...(model ? { model } : {}) });
      return true;
    }

    case 'agents.update': {
      const agentId = configuredId(params.agentId);
      if (!agentId) return notFound(normalizeAgentIdStrict(params.agentId) ?? params.agentId);
      const agent = state.agents.get(agentId);
      const name = params.name?.trim() ? oneLine(params.name) : undefined;
      const emoji = params.emoji?.trim();
      const avatar = params.avatar?.trim();
      const workspace = params.workspace?.trim();
      const hasIdentity = Boolean(name || emoji || avatar);
      if (name) agent.name = name;
      if (hasIdentity) {
        agent.identity = { ...(agent.identity ?? {}), ...(name ? { name } : {}), ...(emoji ? { emoji } : {}), ...(avatar ? { avatar } : {}) };
      }
      if (workspace) agent.workspace = workspace;
      if (params.model === null) delete agent.model;
      else if (params.model?.trim()) agent.model = params.model.trim();
      if (params.agentRuntime) agent.agentRuntime = params.agentRuntime.trim();
      if (workspace) ensureWorkspace(state, agent);
      if (workspace || hasIdentity) writeFile(workspaceFor(state, agent.workspace), 'IDENTITY.md', identityMarkdown(agent.identity ?? { name: agent.name }));
      sendRes(conn, id, { ok: true, agentId });
      return true;
    }

    case 'agents.delete': {
      const agentId = configuredId(params.agentId);
      if (!agentId) return notFound(normalizeAgentIdStrict(params.agentId) ?? params.agentId);
      if (state.agents.size === 1) return invalid(`Agent "${agentId}" is the only configured agent and cannot be deleted.`);
      const agent = state.agents.get(agentId);
      const deleteFiles = params.deleteFiles ?? true;
      state.agents.delete(agentId);
      const removed = [];
      if (deleteFiles) {
        const shared = [...state.agents.values()].some((other) => other.workspace === agent.workspace);
        if (!shared) {
          removed.push({ path: agent.workspace, method: state.agentWorkspaces.delete(agent.workspace) ? 'trash' : 'missing' });
        }
        removed.push({ path: `${MOCK_STATE_DIR}/agents/${agentId}/agent`, method: 'trash' });
        removed.push({ path: `${MOCK_STATE_DIR}/agents/${agentId}/sessions`, method: 'trash' });
      }
      for (const [key, row] of [...state.sessions]) {
        if (row.agentId !== agentId && !key.startsWith(`agent:${agentId}:`)) continue;
        state.sessions.delete(key);
        state.transcripts?.delete(key);
        broadcast(state, 'sessions.changed', { sessionKey: key, reason: 'delete' }, (c) => c.sessionSubscribed);
      }
      sendRes(conn, id, { ok: true, agentId, removedBindings: 0, removed, failed: [] });
      return true;
    }

    case 'agents.files.list': {
      const agentId = configuredId(params.agentId);
      if (!agentId) return notFound(params.agentId);
      const dir = state.agents.get(agentId).workspace;
      const ws = state.agentWorkspaces.get(dir);
      const names = ws?.setupCompleted ? LISTED_FILE_NAMES.filter((n) => n !== 'BOOTSTRAP.md') : LISTED_FILE_NAMES;
      sendRes(conn, id, { agentId, workspace: dir, files: names.map((name) => listedEntry(dir, ws, name)) });
      return true;
    }

    case 'agents.files.get':
    case 'agents.files.set': {
      const agentId = configuredId(params.agentId);
      if (!agentId) return notFound(params.agentId);
      const name = params.name.trim();
      if (!WORKSPACE_FILE_NAMES.includes(name)) return invalid(`unsupported file "${name}"`);
      const dir = state.agents.get(agentId).workspace;
      if (method === 'agents.files.get') {
        sendRes(conn, id, { agentId, workspace: dir, file: fullEntry(dir, state.agentWorkspaces.get(dir), name) });
        return true;
      }
      const ws = workspaceFor(state, dir);
      const current = ws.files.get(name);
      const conflict = (currentHash) =>
        invalid(`agent file "${name}" changed since it was read`, { type: 'agent_file_conflict', name, ...(currentHash ? { currentHash } : {}) });
      if (params.expectedMissing && current) return conflict(undefined);
      if (params.expectedHash) {
        const currentHash = current ? workspaceFileHash(current.content) : undefined;
        if (currentHash !== params.expectedHash.toLowerCase()) return conflict(currentHash);
      }
      writeFile(ws, name, params.content);
      sendRes(conn, id, { ok: true, agentId, workspace: dir, file: fullEntry(dir, ws, name) });
      return true;
    }
  }
  return false;
}
