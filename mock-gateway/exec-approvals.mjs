// Exec approval policy ("command policy"): exec.approvals.get / exec.approvals.set read and replace
// the Gateway host's exec approvals file with base-hash protection. Mirrors openclaw
// src/gateway/server-methods/exec-approvals.ts and the gateway-protocol exec-approvals schema:
// both methods need operator.admin, socket.token never leaves the Gateway, set merges the current
// socket back in, and checks run in upstream order (params schema, base hash, file present).
// MOCK_NO_EXEC_APPROVALS=1 makes the mock look like a Gateway without these methods;
// MOCK_EXEC_APPROVALS_MISSING=1 starts without a policy file.
import crypto from 'node:crypto';
import { ADMIN_SCOPE } from './config.mjs';

export const EXEC_APPROVALS_METHODS = ['exec.approvals.get', 'exec.approvals.set'];
export const EXEC_APPROVALS_PATH = '~/.openclaw/exec-approvals.json';
export const EXEC_APPROVALS_SOCKET_TOKEN = 'mock-secret';
const SOCKET_PATH = '~/.openclaw/exec-approvals.sock';

const SECURITY = ['deny', 'allowlist', 'full'];
const ASK = ['off', 'on-miss', 'always'];
// Built-in values when the file sets none, like upstream exec-approvals-config.ts.
const FALLBACKS = { security: 'full', ask: 'off', askFallback: 'deny', autoAllowSkills: false };

export function execApprovalsDisabled() {
  return process.env.MOCK_NO_EXEC_APPROVALS === '1';
}

function seededFile(base) {
  return {
    version: 1,
    socket: { path: SOCKET_PATH, token: EXEC_APPROVALS_SOCKET_TOKEN },
    defaults: { security: 'allowlist', ask: 'on-miss' },
    agents: {
      main: {
        allowlist: [
          {
            id: 'allow_main_git_status',
            pattern: '/usr/bin/git',
            source: 'allow-always',
            commandText: 'git status --short',
            argPattern: '^status( --short)?$',
            lastUsedAt: base - 2 * 60 * 60_000,
            lastUsedCommand: 'git status --short',
            lastResolvedPath: '/usr/bin/git',
          },
          { id: 'allow_main_ls', pattern: '/bin/ls' },
        ],
        mcpTools: [
          { server: 'github', tool: 'search_code', source: 'allow-always', addedAt: base - 3 * 24 * 60 * 60_000, lastUsedAt: base - 30 * 60_000 },
        ],
      },
      research: { ask: 'always', allowlist: [] },
      ghost: {
        allowlist: [{ id: 'allow_ghost_curl', pattern: '/usr/bin/curl', source: 'allow-always', commandText: 'curl -s https://example.com', lastUsedAt: base - 10 * 24 * 60 * 60_000 }],
      },
    },
  };
}

export function createExecApprovalsState(base = Date.now()) {
  if (process.env.MOCK_EXEC_APPROVALS_MISSING === '1') return { exists: false, file: { version: 1 } };
  return { exists: true, file: seededFile(base) };
}

// A missing file hashes as empty content, so every snapshot has a non-empty hash, like upstream.
export function execApprovalsHash(state) {
  return crypto.createHash('sha256').update(state.exists ? JSON.stringify(state.file) : '').digest('hex');
}

function resolvedDefaults(file) {
  const d = file.defaults ?? {};
  return {
    security: SECURITY.includes(d.security) ? d.security : FALLBACKS.security,
    ask: ASK.includes(d.ask) ? d.ask : FALLBACKS.ask,
    askFallback: SECURITY.includes(d.askFallback) ? d.askFallback : FALLBACKS.askFallback,
    autoAllowSkills: typeof d.autoAllowSkills === 'boolean' ? d.autoAllowSkills : FALLBACKS.autoAllowSkills,
  };
}

// Socket connection material is runtime-only; clients only see its path.
export function execApprovalsSnapshot(state) {
  const file = structuredClone(state.file);
  const socketPath = file.socket?.path?.trim();
  delete file.socket;
  return {
    path: EXEC_APPROVALS_PATH,
    exists: state.exists,
    hash: execApprovalsHash(state),
    file: socketPath ? { version: file.version, socket: { path: socketPath }, ...withoutVersion(file) } : file,
    resolvedDefaults: resolvedDefaults(state.file),
  };
}

function withoutVersion(file) {
  const { version, ...rest } = file;
  return rest;
}

// --- Params schema (closed objects, like the gateway-protocol typebox schema) ---

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function closed(value, path, allowed, required = []) {
  if (!isObject(value)) return `${path}: must be object`;
  for (const key of required) if (!(key in value)) return `${path}: must have required property '${key}'`;
  for (const key of Object.keys(value)) if (!allowed.includes(key)) return `${path}: unexpected property '${key}'`;
  return undefined;
}

function checkString(value, path) {
  return typeof value === 'string' ? undefined : `${path}: must be string`;
}

function checkNonNegative(value, path) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? undefined : `${path}: must be number >= 0`;
}

const POLICY_KEYS = ['security', 'ask', 'askFallback', 'autoAllowSkills'];

// Upstream stores policy fields as plain strings (unknown values survive), only autoAllowSkills is typed.
function checkPolicy(value, path) {
  for (const key of ['security', 'ask', 'askFallback']) {
    if (key in value) {
      const err = checkString(value[key], `${path}/${key}`);
      if (err) return err;
    }
  }
  if ('autoAllowSkills' in value && typeof value.autoAllowSkills !== 'boolean') return `${path}/autoAllowSkills: must be boolean`;
  return undefined;
}

function checkAllowlistEntry(entry, path) {
  const keys = ['id', 'pattern', 'source', 'commandText', 'argPattern', 'lastUsedAt', 'lastUsedCommand', 'lastResolvedPath'];
  const err = closed(entry, path, keys, ['pattern']);
  if (err) return err;
  if ('id' in entry && (typeof entry.id !== 'string' || !entry.id.length)) return `${path}/id: must NOT have fewer than 1 characters`;
  if ('source' in entry && entry.source !== 'allow-always') return `${path}/source: must be equal to constant 'allow-always'`;
  for (const key of ['pattern', 'commandText', 'argPattern', 'lastUsedCommand', 'lastResolvedPath']) {
    if (key in entry) {
      const e = checkString(entry[key], `${path}/${key}`);
      if (e) return e;
    }
  }
  if ('lastUsedAt' in entry) return checkNonNegative(entry.lastUsedAt, `${path}/lastUsedAt`);
  return undefined;
}

function checkMcpTool(entry, path) {
  const err = closed(entry, path, ['server', 'tool', 'source', 'addedAt', 'lastUsedAt'], ['server', 'tool', 'source', 'addedAt']);
  if (err) return err;
  for (const key of ['server', 'tool']) {
    if (typeof entry[key] !== 'string' || !/\S/.test(entry[key])) return `${path}/${key}: must be a non-blank string`;
  }
  if (entry.source !== 'allow-always') return `${path}/source: must be equal to constant 'allow-always'`;
  const added = checkNonNegative(entry.addedAt, `${path}/addedAt`);
  if (added) return added;
  if ('lastUsedAt' in entry) return checkNonNegative(entry.lastUsedAt, `${path}/lastUsedAt`);
  return undefined;
}

function checkAgent(agent, path) {
  const err = closed(agent, path, [...POLICY_KEYS, 'allowlist', 'mcpTools']) ?? checkPolicy(agent, path);
  if (err) return err;
  if ('allowlist' in agent) {
    if (!Array.isArray(agent.allowlist)) return `${path}/allowlist: must be array`;
    for (const [i, entry] of agent.allowlist.entries()) {
      const e = checkAllowlistEntry(entry, `${path}/allowlist/${i}`);
      if (e) return e;
    }
  }
  if ('mcpTools' in agent) {
    if (!Array.isArray(agent.mcpTools)) return `${path}/mcpTools: must be array`;
    for (const [i, entry] of agent.mcpTools.entries()) {
      const e = checkMcpTool(entry, `${path}/mcpTools/${i}`);
      if (e) return e;
    }
  }
  return undefined;
}

function checkFile(file, path) {
  const err = closed(file, path, ['version', 'socket', 'defaults', 'agents'], ['version']);
  if (err) return err;
  if (file.version !== 1) return `${path}/version: must be equal to constant 1`;
  if ('socket' in file) {
    const e = closed(file.socket, `${path}/socket`, ['path', 'token']);
    if (e) return e;
    for (const key of ['path', 'token']) {
      if (key in file.socket) {
        const s = checkString(file.socket[key], `${path}/socket/${key}`);
        if (s) return s;
      }
    }
  }
  if ('defaults' in file) {
    const e = closed(file.defaults, `${path}/defaults`, POLICY_KEYS) ?? checkPolicy(file.defaults, `${path}/defaults`);
    if (e) return e;
  }
  if ('agents' in file) {
    if (!isObject(file.agents)) return `${path}/agents: must be object`;
    for (const [agentId, agent] of Object.entries(file.agents)) {
      const e = checkAgent(agent, `${path}/agents/${agentId}`);
      if (e) return e;
    }
  }
  return undefined;
}

// `file` is optional at the schema level here so the upstream "file is required" check stays reachable.
function checkSetParams(params) {
  const err = closed(params, 'root', ['file', 'baseHash']);
  if (err) return err;
  if ('baseHash' in params && (typeof params.baseHash !== 'string' || !params.baseHash.length)) {
    return 'baseHash: must NOT have fewer than 1 characters';
  }
  if ('file' in params && params.file !== undefined && params.file !== null) return checkFile(params.file, 'file');
  return undefined;
}

function resolveBaseHash(params) {
  const raw = typeof params.baseHash === 'string' ? params.baseHash.trim() : '';
  return raw || undefined;
}

function mergeSocket(incoming, current) {
  const path = incoming.socket?.path?.trim() || current.socket?.path?.trim();
  const token = incoming.socket?.token?.trim() || current.socket?.token?.trim();
  const next = structuredClone(incoming);
  delete next.socket;
  const socket = { ...(path ? { path } : {}), ...(token ? { token } : {}) };
  return Object.keys(socket).length ? { version: next.version, socket, ...withoutVersion(next) } : next;
}

/** Agent id for an approval: the request's agentId, else the `agent:<id>:…` session key, else main. */
export function agentIdForApproval(request = {}) {
  if (typeof request.agentId === 'string' && request.agentId) return request.agentId;
  const match = /^agent:([^:]+):/.exec(String(request.sessionKey ?? ''));
  return match ? match[1] : 'main';
}

// An allow-always decision adds the command to the agent's allowlist, as the Gateway does.
export function recordAllowAlways(state, approval) {
  const request = approval.request ?? {};
  const agentId = agentIdForApproval(request);
  const policy = state.execApprovalsState;
  const file = policy.file;
  file.agents ??= {};
  const agent = (file.agents[agentId] ??= {});
  agent.allowlist ??= [];
  const commandText = String(request.command ?? '');
  agent.allowlist.push({
    id: `allow_${crypto.randomUUID()}`,
    pattern: request.resolvedPath || commandText,
    source: 'allow-always',
    ...(commandText ? { commandText } : {}),
    lastUsedAt: Date.now(),
  });
  policy.exists = true;
  return agentId;
}

export function handleExecApprovalsRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  const params = msg.params ?? {};
  if (!EXEC_APPROVALS_METHODS.includes(method) || execApprovalsDisabled()) return false;
  if (!(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  const policy = state.execApprovalsState;
  if (method === 'exec.approvals.get') {
    const err = closed(params, 'root', []);
    if (err) return invalid(`invalid exec.approvals.get params: ${err}`), true;
    sendRes(conn, id, execApprovalsSnapshot(policy));
    return true;
  }

  const schemaError = checkSetParams(params);
  if (schemaError) return invalid(`invalid exec.approvals.set params: ${schemaError}`), true;
  const changed = 'exec approvals changed since last load; re-run exec.approvals.get and retry';
  const currentHash = execApprovalsHash(policy);
  const baseHash = resolveBaseHash(params);
  if (!policy.exists) {
    if (baseHash && baseHash !== currentHash) return invalid(changed), true;
  } else {
    if (!baseHash) return invalid('exec approvals base hash required; re-run exec.approvals.get and retry'), true;
    if (baseHash !== currentHash) return invalid(changed), true;
  }
  if (!isObject(params.file)) return invalid('exec approvals file is required'), true;
  policy.file = mergeSocket(params.file, policy.file);
  policy.exists = true;
  sendRes(conn, id, execApprovalsSnapshot(policy));
  return true;
}
