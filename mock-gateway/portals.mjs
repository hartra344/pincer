// Mock of Gateway portals (#974 PR 2): `portal.list` (operator.read; url/tokenQuery only for operator.write or
// admin), `portal.close` (operator.write) and the redacted `portal.changed` event. Shapes follow upstream
// src/gateway/server-methods/portals.ts and src/gateway/portals/{portal-service,portal-http-proxy}.ts.
// Each portal is backed by a real tiny HTTP server (a ticking clock) behind the `openclaw_portal` token check:
// a query token sets the HttpOnly `openclaw_portal_<port>` cookie; neither token nor cookie is a 401.
// `portal.open` is not mocked: the agent opens portals, Pincer doesn't.
import crypto from 'node:crypto';
import http from 'node:http';

export const PORTAL_METHODS = ['portal.list', 'portal.close'];
export const PORTAL_EVENTS = ['portal.changed'];
export const SEED_PORTAL_TITLE = 'Studio clock';
export const SECOND_PORTAL_TITLE = 'Build dashboard';

const WRITE_SCOPE = 'operator.write';
const ADMIN_SCOPE = 'operator.admin';
const READ_SCOPE = 'operator.read';
const APP_PORT = 4173;

export function portalLoopbackOnly() {
  return process.env.MOCK_PORTAL_LOOPBACK === '1';
}

export function portalsDisabled() {
  return process.env.MOCK_NO_PORTALS === '1';
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Studio clock</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 16px -apple-system, system-ui, sans-serif; background: #101418; color: #e8eef4; }
  main { text-align: center; }
  #time { font-size: 64px; font-variant-numeric: tabular-nums; letter-spacing: 2px; }
  #date { margin-top: 8px; opacity: .6; }
</style></head>
<body><main><div id="time">--:--:--</div><div id="date"></div></main>
<script>
  function tick() {
    const now = new Date();
    document.getElementById('time').textContent = now.toLocaleTimeString([], { hour12: false });
    document.getElementById('date').textContent = now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' });
  }
  tick(); setInterval(tick, 1000);
</script></body></html>`;

function readCookie(header, name) {
  for (const segment of String(header ?? '').split(';')) {
    const i = segment.indexOf('=');
    if (i >= 0 && segment.slice(0, i).trim() === name) return segment.slice(i + 1).trim();
  }
  return undefined;
}

function tokensEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function startPortalHttp(portal) {
  const cookieName = () => `openclaw_portal_${portal.listenPort}`;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (url.pathname === '/redirect-out' && (tokensEqual(url.searchParams.get('openclaw_portal'), portal.token) || tokensEqual(readCookie(req.headers.cookie, cookieName()), portal.token))) {
      res.writeHead(302, { location: 'http://example.com/' });
      res.end();
      return;
    }
    const queryToken = url.searchParams.get('openclaw_portal');
    const setCookie = tokensEqual(queryToken, portal.token);
    if (!setCookie && !tokensEqual(readCookie(req.headers.cookie, cookieName()), portal.token)) {
      res.writeHead(401, { 'content-type': 'text/plain' });
      res.end('portal authorization required');
      return;
    }
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      ...(setCookie ? { 'set-cookie': `${cookieName()}=${portal.token}; HttpOnly; SameSite=Lax; Path=/` } : {}),
    });
    res.end(PAGE);
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      portal.listenPort = server.address().port;
      portal.publicOrigin = `http://127.0.0.1:${portal.listenPort}`;
      portal.server = server;
      resolve();
    });
  });
}

function stopPortalHttp(portal) {
  const server = portal.server;
  portal.server = undefined;
  if (!server) return Promise.resolve();
  return new Promise((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections?.();
  });
}

/** Seeds the portals and starts their HTTP servers. Call once while starting the mock. */
export async function initPortals(state) {
  state.portals = { entries: new Map() };
  if (portalsDisabled()) return;
  const seeds = [
    { id: 'portal_studio_clock', title: SEED_PORTAL_TITLE, description: 'A live clock for the studio wall display.', port: APP_PORT, ageMs: 5 * 60_000 },
    { id: 'portal_build_dashboard', title: SECOND_PORTAL_TITLE, description: 'CI status for the main branch.', port: APP_PORT + 1, ageMs: 2 * 60_000 },
  ];
  for (const seed of seeds) {
    // Each portal has its own listener port and token, so one portal's cookie never opens another.
    const portal = {
      id: seed.id,
      title: seed.title,
      description: seed.description,
      port: seed.port,
      path: '/',
      token: crypto.randomBytes(18).toString('base64url'),
      createdAtMs: Date.now() - seed.ageMs,
    };
    await startPortalHttp(portal);
    state.portals.entries.set(portal.id, portal);
  }
}

export async function stopPortals(state) {
  const entries = state.portals?.entries;
  if (!entries) return;
  await Promise.all([...entries.values()].map(stopPortalHttp));
  entries.clear();
}

function summarize(portal) {
  const publicUrl = `${portal.publicOrigin}${portal.path ?? '/'}`;
  const openable = new URL(publicUrl);
  openable.searchParams.set('openclaw_portal', portal.token);
  return {
    id: portal.id,
    title: portal.title,
    port: portal.port,
    listenPort: portal.listenPort,
    tokenQuery: `openclaw_portal=${portal.token}`,
    url: openable.toString(),
    publicUrl,
    // Non-loopback unless MOCK_PORTAL_LOOPBACK=1 makes the first portal report loopback-only.
    exposure: { kind: portalLoopbackOnly() && portal.id === 'portal_studio_clock' ? 'loopback-only' : 'non-loopback', browserReachability: 'unverified' },
    path: portal.path,
    description: portal.description,
    createdAtMs: portal.createdAtMs,
  };
}

function redact(summary) {
  const { tokenQuery: _tokenQuery, url: _url, ...rest } = summary;
  return rest;
}

function canSeeTokens(conn) {
  const scopes = conn.scopes ?? [];
  return scopes.includes(WRITE_SCOPE) || scopes.includes(ADMIN_SCOPE);
}

function listFor(state) {
  return [...(state.portals?.entries.values() ?? [])].map(summarize);
}

/** Handles portal.* requests; returns false when the method isn't ours. */
export function handlePortalsRequest(state, conn, msg, { sendRes, sendErr, broadcast }) {
  const { id, method } = msg;
  if (!PORTAL_METHODS.includes(method) || portalsDisabled()) return false;
  const scopes = conn.scopes ?? [];
  const required = method === 'portal.close' ? WRITE_SCOPE : READ_SCOPE;
  const allowed = scopes.includes(required) || scopes.includes(ADMIN_SCOPE) || (required === READ_SCOPE && scopes.includes(WRITE_SCOPE));
  if (!allowed) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${required}`, { code: 'MISSING_SCOPE', scope: required });
    return true;
  }
  const params = msg.params ?? {};
  if (params.environmentId !== undefined && typeof params.environmentId !== 'string') {
    sendErr(conn, id, 'INVALID_REQUEST', 'invalid portal params: environmentId must be a string');
    return true;
  }
  if (method === 'portal.list') {
    const portals = listFor(state);
    sendRes(conn, id, { portals: canSeeTokens(conn) ? portals : portals.map(redact) });
    return true;
  }
  if (typeof params.id !== 'string' || !params.id) {
    sendErr(conn, id, 'INVALID_REQUEST', 'invalid portal.close params: id is required');
    return true;
  }
  const portal = state.portals.entries.get(params.id);
  if (!portal) {
    sendRes(conn, id, { closed: false });
    return true;
  }
  state.portals.entries.delete(portal.id);
  stopPortalHttp(portal);
  sendRes(conn, id, { closed: true });
  broadcast(state, 'portal.changed', { portals: listFor(state).map(redact) });
  return true;
}
