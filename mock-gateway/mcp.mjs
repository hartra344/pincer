// Mock of MCP server management: the `mcp.servers` config (seeded in config.mjs) drives a status
// table served by the proposed mcp.status / mcp.reconnect / mcp.oauth.* RPCs (#327-#329), plus a
// tiny HTTP OAuth consent flow (/mcp-oauth/authorize and /mcp-oauth/callback).
import crypto from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';

export const MCP_METHODS = [
  'mcp.status',
  'mcp.reconnect',
  'mcp.probe',
  'mcp.oauth.status',
  'mcp.oauth.start',
  'mcp.oauth.complete',
  'mcp.oauth.cancel',
  'mcp.oauth.logout',
];
export const MCP_EVENTS = ['mcp.oauth.changed', 'mcp.status.changed'];

const REDACTED = '__OPENCLAW_REDACTED__';
const ADMIN_SCOPE = 'operator.admin';
const READ_SCOPE = 'operator.read';
const ADMIN_METHODS = new Set(['mcp.reconnect', 'mcp.probe', 'mcp.oauth.start', 'mcp.oauth.complete', 'mcp.oauth.cancel', 'mcp.oauth.logout']);
const ATTEMPT_TTL_MS = 10 * 60 * 1000;
const CONNECT_DELAY_MS = 800;
const DEMO_ACCOUNT = 'demo@pincer.app';
const GENERIC_TOOLS = ['echo', 'ping', 'time'];

export function mcpDisabled() {
  return process.env.MOCK_NO_MCP === '1';
}

/** Seeded plugin-declared MCP servers: names and unavailable names, as `plugins.inspect` reports them. */
const PLUGIN_MCP = {
  linear: { servers: ['linear'], unavailable: [] },
  asana: { servers: ['asana', 'asana-beta'], unavailable: ['asana-beta'] },
};

/**
 * The MCP parts of a `plugins.inspect` result. Like upstream, `mcpAuth` only has entries for servers that match a
 * configured OAuth `mcp.servers` entry (here by name), and carries that server's live sign-in state, so plugin
 * `linear` follows the configured `linear` server; `asana` has no configured entry and so no `mcpAuth`.
 */
export function pluginMcpInspect(state, pluginId) {
  const mcp = PLUGIN_MCP[pluginId];
  if (!mcp) return { declared: {}, components: {} };
  const runtime = mcpState(state).runtime;
  const servers = configServers(state);
  const auth = mcp.servers
    .filter((name) => servers[name]?.auth === 'oauth' && runtime.get(name)?.auth)
    .map((name) => ({ serverName: name, state: runtime.get(name).auth.state }));
  return {
    declared: { mcpServers: [...mcp.servers] },
    components: { mcpServers: mcp.servers.filter((name) => !mcp.unavailable.includes(name)), unavailable: { mcpServers: [...mcp.unavailable] } },
    ...(auth.length ? { mcpAuth: auth } : {}),
  };
}

/** Seeded `mcp.servers` config; the demo gateway mirrors it. */
export function seedMcpServers() {
  return {
    filesystem: {
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-filesystem', '/Users/demo/Projects'],
      env: { LOG_LEVEL: 'info' },
    },
    'home-assistant': {
      command: 'uvx',
      args: ['mcp-server-home-assistant', '--url', 'http://homeassistant.local:8123', '--token', 'ha-long-lived-token'],
      env: { HA_TOKEN: 'ha-long-lived-token' },
    },
    github: {
      url: 'https://api.githubcopilot.com/mcp/',
      transport: 'streamable-http',
      headers: { Authorization: 'Bearer ghp_mocktoken123' },
    },
    linear: { url: 'https://mcp.linear.app/mcp', transport: 'streamable-http', auth: 'oauth' },
    'acme.docs': { url: 'https://mcp.acme.example/docs', transport: 'streamable-http' },
    notion: { url: 'https://mcp.notion.com/mcp', transport: 'streamable-http', auth: 'oauth' },
    postgres: {
      command: 'uvx',
      args: ['mcp-server-postgres', '--dsn', '******db.local/app'],
      env: { PGPASSWORD: 'mock-pg-password' },
    },
    sentry: { url: 'https://mcp.sentry.dev/sse', transport: 'sse', enabled: false },
  };
}

const TOOL_DESCRIPTIONS = {
  get_state: 'Read the state of a Home Assistant entity',
  call_service: 'Call a Home Assistant service',
};
const SEED_TOOLS = {
  filesystem: ['read_file', 'write_file', 'list_directory', 'search_files'],
  'home-assistant': ['get_state', 'call_service'],
  'acme.docs': ['search', 'get_page'],
  github: ['get_issue', 'list_issues', 'create_issue', 'search_code', 'get_pull_request', 'list_pull_requests'],
};
const LINEAR_TOOLS = ['list_issues', 'get_issue', 'create_issue', 'update_issue', 'search_documentation'];

function transportOf(server) {
  if (server.command) return 'stdio';
  if (server.url) return server.transport ?? 'sse';
  return undefined;
}

function authModeOf(server) {
  if (server.auth !== 'oauth') return undefined;
  if (server.oauth?.identity === 'per-requester') return 'oauth-per-requester';
  return server.oauth?.authProfileId ? 'oauth-profile' : 'oauth-shared';
}

const signatureOf = (server) => JSON.stringify([server.enabled !== false, server.command, server.args, server.url, server.transport, server.auth]);

function blank(server) {
  const mode = authModeOf(server);
  return {
    state: 'idle',
    tools: [],
    lastError: undefined,
    nextRetryAt: undefined,
    auth: mode ? { mode, state: 'requires-authorization' } : undefined,
    signature: signatureOf(server),
  };
}

function seedRuntime(name, server) {
  const rt = blank(server);
  if (SEED_TOOLS[name]) Object.assign(rt, { state: 'connected', tools: [...SEED_TOOLS[name]] });
  if (name === 'notion') {
    Object.assign(rt, { state: 'error', lastError: { message: 'OAuth token expired', at: Date.now() - 3_600_000 } });
    rt.auth.expiresAt = Date.now() - 86_400_000;
  }
  if (name === 'postgres') Object.assign(rt, { state: 'error', lastError: { message: 'spawn uvx ENOENT', at: Date.now() - 60_000 } });
  if (server.enabled === false) rt.state = 'disabled';
  return rt;
}

function mcpState(state) {
  if (!state.mcpState) {
    const servers = state.configState.config.mcp?.servers ?? {};
    state.mcpState = {
      runtime: new Map(Object.entries(servers).map(([name, server]) => [name, seedRuntime(name, server)])),
      attempts: new Map(),
      timers: new Set(),
    };
  }
  return state.mcpState;
}

const configServers = (state) => state.configState.config.mcp?.servers ?? {};

function later(mcp, ms, fn) {
  const timer = setTimeout(() => {
    mcp.timers.delete(timer);
    fn();
  }, ms);
  timer.unref?.();
  mcp.timers.add(timer);
}

/** Connects a server after a short delay: OAuth servers that aren't signed in stay idle. */
function connect(state, name, broadcast, { fail } = {}) {
  const mcp = mcpState(state);
  const rt = mcp.runtime.get(name);
  const server = configServers(state)[name];
  if (!rt || !server) return;
  if (server.enabled === false) {
    Object.assign(rt, { state: 'disabled', tools: [], lastError: undefined });
    return;
  }
  if (!transportOf(server)) {
    Object.assign(rt, { state: 'invalid', tools: [], lastError: undefined });
    return;
  }
  if (rt.auth && rt.auth.state !== 'authorized') {
    if (rt.state !== 'error') Object.assign(rt, { state: 'idle', tools: [] });
    return;
  }
  Object.assign(rt, { state: 'connecting', lastError: undefined, nextRetryAt: undefined });
  const signature = rt.signature;
  later(mcp, CONNECT_DELAY_MS, () => {
    const current = mcp.runtime.get(name);
    if (!current || current.signature !== signature || current.state !== 'connecting') return;
    if (fail || name === 'postgres') {
      Object.assign(current, { state: 'error', tools: [], lastError: { message: 'spawn uvx ENOENT', at: Date.now() } });
    } else {
      Object.assign(current, { state: 'connected', tools: toolsFor(name, current) });
    }
    broadcast(state, 'mcp.status.changed', { servers: [name] });
  });
}

function toolsFor(name, rt) {
  if (name === 'linear' && rt.auth?.state === 'authorized') return [...LINEAR_TOOLS];
  return [...(SEED_TOOLS[name] ?? GENERIC_TOOLS)];
}

/** Brings the status table in line with `mcp.servers` after a config write. */
export function syncMcpFromConfig(state, broadcast) {
  const mcp = mcpState(state);
  const servers = configServers(state);
  const touched = [];
  for (const name of [...mcp.runtime.keys()]) {
    if (!servers[name]) {
      mcp.runtime.delete(name);
      touched.push(name);
    }
  }
  for (const [name, server] of Object.entries(servers)) {
    const rt = mcp.runtime.get(name);
    if (rt && rt.signature === signatureOf(server)) continue;
    const fresh = blank(server);
    // Editing a signed-in server keeps its sign-in.
    if (rt?.auth?.state === 'authorized' && fresh.auth) fresh.auth = rt.auth;
    mcp.runtime.set(name, fresh);
    connect(state, name, broadcast);
    touched.push(name);
  }
  if (touched.length) broadcast(state, 'mcp.status.changed', { servers: touched });
}

function statusEntry(state, name) {
  const server = configServers(state)[name];
  const rt = mcpState(state).runtime.get(name);
  const entry = { name, enabled: server.enabled !== false, source: 'config' };
  const transport = transportOf(server);
  if (transport) entry.transport = transport;
  entry.state = rt.state;
  if (rt.state === 'connected') Object.assign(entry, { toolCount: rt.tools.length, tools: [...rt.tools] });
  if (rt.lastError) entry.lastError = { ...rt.lastError };
  if (rt.nextRetryAt) entry.nextRetryAt = rt.nextRetryAt;
  if (rt.auth) entry.auth = { ...rt.auth };
  return entry;
}

function names(state, filter) {
  const all = Object.keys(configServers(state));
  return Array.isArray(filter) ? all.filter((name) => filter.includes(name)) : all;
}

/** Tools of connected MCP servers, for tools.effective. */
export function mcpEffectiveTools(state) {
  const tools = [];
  for (const name of names(state)) {
    const rt = mcpState(state).runtime.get(name);
    if (rt?.state !== 'connected') continue;
    for (const tool of rt.tools) {
      tools.push({ server: name, tool, description: TOOL_DESCRIPTIONS[tool] ?? `${tool} (${name})`, ...(tool === 'call_service' ? { risk: 'medium' } : {}) });
    }
  }
  return tools;
}

/** tools.effective notices: connection errors plus not-yet-connected servers. */
export function mcpNotices(state) {
  const notices = [];
  const connecting = [];
  for (const name of names(state)) {
    const rt = mcpState(state).runtime.get(name);
    if (rt.state === 'error' && rt.auth?.state !== 'requires-authorization') {
      notices.push({ id: `mcp-server-diagnostic:${name}`, severity: 'warning', message: rt.lastError?.message ?? 'connection failed', servers: [name] });
    } else if (rt.state === 'connecting') {
      connecting.push(name);
    }
  }
  if (connecting.length) {
    notices.push({ id: 'mcp-not-yet-connected', severity: 'info', message: 'Some MCP servers are still connecting; their tools will appear once they are ready.', servers: connecting });
  }
  return notices;
}

/** Replaces redacted sentinels in a probed draft with the saved entry's values. */
function restoreRedacted(value, saved) {
  if (value === REDACTED) return saved;
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, restoreRedacted(item, saved?.[key])]));
  }
  return value;
}

const PROBE_COUNTS = { github: [3, 2], filesystem: [1, 0], linear: [2, 1] };

/**
 * One-off connection test: never touches the status table. Results by server name:
 * `postgres` fails with three diagnostics; `home-assistant` succeeds after ~2 s (or times out when timeoutMs < 2000);
 * OAuth servers that aren't signed in (`linear`, `notion`) need authorization; `github` succeeds with 6 tools, 3
 * resources and 2 prompts, `filesystem` with 4 tools and 1 resource; anything else succeeds with its tools. A
 * command containing "nonexistent"/"missing", a non-http(s) URL or no transport fails.
 */
function probeResult(state, name, server, isSaved, timeoutMs) {
  const transport = transportOf(server);
  const failure = (...messages) => ({ ok: false, tools: [], resources: 0, prompts: 0, diagnostics: messages.map((message) => ({ message })) });
  if (!transport) return { result: failure('Server needs a command or a url.') };
  if (server.command && /nonexistent|missing/.test(server.command)) {
    return { result: failure(`spawn ${server.command} ENOENT`, `Check that ${server.command} is installed and on the Gateway's PATH.`) };
  }
  if (server.url && !/^https?:\/\//.test(server.url)) return { result: failure(`Invalid url: ${server.url}`) };
  if (server.auth === 'oauth') {
    const rt = isSaved ? mcpState(state).runtime.get(name) : undefined;
    const auth = rt?.auth ?? { mode: authModeOf(server), state: 'requires-authorization' };
    if (auth.state !== 'authorized') return { result: { ...failure('Authorization required.'), auth: { mode: auth.mode, state: auth.state } } };
  }
  if (name === 'postgres') {
    return { result: failure('spawn uvx ENOENT', "uvx was not found on the Gateway's PATH.", 'Install uv (https://docs.astral.sh/uv/) on the Gateway host.') };
  }
  const limit = Number.isFinite(timeoutMs) ? timeoutMs : 15_000;
  let delay = 0;
  if (name === 'home-assistant') {
    if (limit < 2000) return { delay: limit, result: failure(`Timed out after ${limit} ms waiting for the server to initialize.`) };
    delay = 2000;
  }
  const filter = server.toolFilter ?? {};
  const kept = toolsFor(name, mcpState(state).runtime.get(name) ?? {})
    .filter((tool) => (!filter.include?.length || matchesToolPattern(tool, filter.include)) && !matchesToolPattern(tool, filter.exclude ?? []));
  const [resources, prompts] = PROBE_COUNTS[name] ?? [0, 0];
  return { delay, result: { ok: true, tools: kept, resources, prompts, diagnostics: [] } };
}

function authorizeAttempt(state, broadcast, attempt, { account = DEMO_ACCOUNT } = {}) {
  const mcp = mcpState(state);
  const rt = mcp.runtime.get(attempt.server);
  mcp.attempts.delete(attempt.id);
  if (!rt) return;
  rt.auth = { mode: rt.auth?.mode ?? 'oauth-shared', state: 'authorized', account, expiresAt: Date.now() + 3_600_000 };
  Object.assign(rt, { state: 'idle', lastError: undefined });
  connect(state, attempt.server, broadcast);
  broadcast(state, 'mcp.oauth.changed', { serverName: attempt.server, state: 'authorized', account });
  broadcast(state, 'mcp.status.changed', { servers: [attempt.server] });
}

function denyAttempt(state, broadcast, attempt) {
  const mcp = mcpState(state);
  mcp.attempts.delete(attempt.id);
  const rt = mcp.runtime.get(attempt.server);
  if (rt?.auth?.state === 'pending-authorization') rt.auth.state = 'requires-authorization';
  broadcast(state, 'mcp.oauth.changed', { serverName: attempt.server, state: 'requires-authorization' });
  broadcast(state, 'mcp.status.changed', { servers: [attempt.server] });
}

function liveAttempt(mcp, id) {
  const attempt = mcp.attempts.get(id);
  return attempt && attempt.expiresAt > Date.now() ? attempt : undefined;
}

const escapeHtml = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function page(res, status, title, body) {
  res.writeHead(status, { 'content-type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(title)}</title>` +
    `<body style="font-family:-apple-system,sans-serif;max-width:28rem;margin:4rem auto;padding:0 1rem"><h1>${escapeHtml(title)}</h1>${body}</body>`);
}

/** Serves the mock OAuth consent pages; returns false for other paths. */
export function handleMcpHttp(state, req, res, broadcast) {
  const url = new URL(req.url ?? '/', 'http://mock');
  if (url.pathname !== '/mcp-oauth/authorize' && url.pathname !== '/mcp-oauth/callback') return false;
  const mcp = mcpState(state);
  const attempt = liveAttempt(mcp, url.searchParams.get('attempt') ?? '');
  if (!attempt) {
    page(res, 400, 'Sign-in expired', '<p>This sign-in attempt is unknown or has expired. Start again from Pincer.</p>');
    return true;
  }
  if (url.pathname === '/mcp-oauth/authorize') {
    const base = `/mcp-oauth/callback?attempt=${encodeURIComponent(attempt.id)}`;
    page(res, 200, `Authorize Pincer Mock for ${attempt.server}`,
      `<p>Pincer Mock is asking to access <b>${escapeHtml(attempt.server)}</b> as ${DEMO_ACCOUNT}.</p>` +
      `<p><a href="${base}&amp;code=mock-code" style="font-size:1.2rem">Allow</a> &nbsp; <a href="${base}&amp;error=access_denied">Deny</a></p>`);
    return true;
  }
  const denied = url.searchParams.has('error') || !url.searchParams.get('code');
  if (denied) denyAttempt(state, broadcast, attempt);
  else authorizeAttempt(state, broadcast, attempt);
  if (attempt.returnUrl) {
    let target;
    try {
      target = new URL(attempt.returnUrl);
      target.searchParams.set('state', denied ? 'denied' : 'authorized');
    } catch {
      target = undefined;
    }
    if (target) {
      res.writeHead(302, { location: target.toString() });
      res.end();
      return true;
    }
  }
  page(res, 200, denied ? 'Sign-in denied' : 'Signed in', '<p>You can close this window.</p>');
  return true;
}

function scopeApproved(scopes, scope) {
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE) || (scope === READ_SCOPE && scopes.includes('operator.write'));
}

/** Handles an mcp.* request; returns false when the method isn't one of ours. */
export function handleMcpRequest(state, conn, msg, { sendRes, sendErr, broadcast }) {
  const { id, method } = msg;
  if (!MCP_METHODS.includes(method) || mcpDisabled()) return false;
  const params = msg.params ?? {};
  const required = ADMIN_METHODS.has(method) ? ADMIN_SCOPE : READ_SCOPE;
  if (!scopeApproved(conn.scopes ?? [], required)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${required}`, { code: 'MISSING_SCOPE', scope: required });
    return true;
  }
  const invalid = (message) => (sendErr(conn, id, 'INVALID_REQUEST', message), true);
  const mcp = mcpState(state);
  const servers = configServers(state);
  const known = (name) => (typeof name === 'string' && servers[name] ? undefined : `unknown MCP server: ${name}`);
  const oauthServer = (name) => {
    const problem = known(name);
    if (problem) return { problem };
    return servers[name].auth === 'oauth' ? {} : { problem: `MCP server ${name} does not use OAuth` };
  };
  if (Array.isArray(params.serverNames) && (method === 'mcp.reconnect' || method === 'mcp.oauth.status')) {
    for (const name of params.serverNames) {
      const problem = known(name);
      if (problem) return invalid(problem);
    }
  }

  switch (method) {
    case 'mcp.status':
      sendRes(conn, id, { generatedAt: Date.now(), servers: names(state, params.serverNames).map((name) => statusEntry(state, name)) });
      break;
    case 'mcp.probe': {
      const saved = servers[params.serverName];
      const draft = params.server && typeof params.server === 'object' ? restoreRedacted(params.server, saved) : undefined;
      const candidate = draft ?? saved;
      if (!candidate) return invalid(`unknown MCP server: ${params.serverName}`);
      const { delay = 0, result } = probeResult(state, params.serverName, candidate, !draft || isDeepStrictEqual(draft, saved), params.timeoutMs);
      if (delay) later(mcp, delay, () => sendRes(conn, id, result));
      else sendRes(conn, id, result);
      break;
    }
    case 'mcp.oauth.status':
      sendRes(conn, id, {
        servers: names(state, params.serverNames)
          .filter((name) => servers[name].auth === 'oauth')
          .map((name) => {
            const { auth } = statusEntry(state, name);
            return { name, ...auth };
          }),
      });
      break;
    case 'mcp.reconnect': {
      const disposed = names(state, params.serverNames).filter((name) => servers[name].enabled !== false);
      for (const name of disposed) {
        const rt = mcp.runtime.get(name);
        if (rt.state === 'error' && rt.auth?.state === 'requires-authorization') continue;
        connect(state, name, broadcast);
      }
      sendRes(conn, id, { ok: true, disposed });
      if (disposed.length) broadcast(state, 'mcp.status.changed', { servers: disposed });
      break;
    }
    case 'mcp.oauth.start': {
      const { problem } = oauthServer(params.serverName);
      if (problem) return invalid(problem);
      const base = conn.baseUrl ?? state.httpBaseUrl ?? `http://127.0.0.1:${process.env.PORT ?? 18789}`;
      const attempt = {
        id: `oauth_${crypto.randomBytes(8).toString('hex')}`,
        server: params.serverName,
        returnUrl: typeof params.returnUrl === 'string' ? params.returnUrl : undefined,
        expiresAt: Date.now() + ATTEMPT_TTL_MS,
      };
      mcp.attempts.set(attempt.id, attempt);
      const rt = mcp.runtime.get(attempt.server);
      rt.auth = { ...rt.auth, state: 'pending-authorization' };
      sendRes(conn, id, {
        attemptId: attempt.id,
        authorizationUrl: `${base}/mcp-oauth/authorize?attempt=${attempt.id}`,
        redirectUrl: `${base}/mcp-oauth/callback`,
        expiresAt: attempt.expiresAt,
      });
      broadcast(state, 'mcp.oauth.changed', { serverName: attempt.server, state: 'pending-authorization' });
      broadcast(state, 'mcp.status.changed', { servers: [attempt.server] });
      break;
    }
    case 'mcp.oauth.complete': {
      const attempt = liveAttempt(mcp, String(params.attemptId ?? ''));
      if (!attempt) return invalid('unknown or expired OAuth attempt');
      let code = typeof params.code === 'string' ? params.code : undefined;
      if (!code && typeof params.callbackUrl === 'string') {
        try {
          code = new URL(params.callbackUrl).searchParams.get('code') ?? undefined;
        } catch {
          code = undefined;
        }
      }
      if (!code) return invalid('missing authorization code');
      authorizeAttempt(state, broadcast, attempt);
      sendRes(conn, id, { state: 'authorized', account: DEMO_ACCOUNT });
      break;
    }
    case 'mcp.oauth.cancel': {
      const attempt = mcp.attempts.get(String(params.attemptId ?? ''));
      if (attempt) denyAttempt(state, broadcast, attempt);
      sendRes(conn, id, { cancelled: Boolean(attempt) });
      break;
    }
    case 'mcp.oauth.logout': {
      const { problem } = oauthServer(params.serverName);
      if (problem) return invalid(problem);
      const rt = mcp.runtime.get(params.serverName);
      const cleared = rt.auth?.state === 'authorized';
      rt.auth = { mode: rt.auth.mode, state: 'requires-authorization' };
      Object.assign(rt, { state: 'idle', tools: [], lastError: undefined });
      sendRes(conn, id, { cleared });
      broadcast(state, 'mcp.oauth.changed', { serverName: params.serverName, state: 'requires-authorization' });
      broadcast(state, 'mcp.status.changed', { servers: [params.serverName] });
      break;
    }
    default:
      return false;
  }
  return true;
}

// Like the Gateway: `*` is the only wildcard; include applies first, then exclude.
function matchesToolPattern(tool, patterns) {
  return patterns.some((pattern) => new RegExp(`^${pattern.split('*').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`).test(tool));
}
