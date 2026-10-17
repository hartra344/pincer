// Mock of the Gateway's browser tool surface for the live browser panel (#974): `browser.request`
// (operator.admin) with `GET /tabs`, `POST /screencast`, `/navigate`, `/tabs/open`, `DELETE /tabs/<id>`, `/start`,
// `/act` (history.go(±1) and `resize`) and `/download`, the `/browser/screencast` WebSocket upgrade, and the assistant-media
// route that serves downloads.
// Shapes follow upstream extensions/browser/src/browser/{routes/agent.screencast.ts,screencast/{wire,upgrade}.ts}.
import crypto from 'node:crypto';
import jpegJs from 'jpeg-js';
import { WebSocketServer } from 'ws';

export const BROWSER_METHODS = ['browser.request'];

const ADMIN_SCOPE = 'operator.admin';
export const SCREENCAST_PATH = '/browser/screencast';

// Hooks for the malformed-frame cases: connect with `?case=<name>` on the upgrade URL, or mint the token with
// `POST /screencast` body `{targetId: "<name>"}` (the token then starts with `<name>-`).
export const CASE_BAD_LENGTH = 'bad-header-length'; // header length larger than the data
export const CASE_OVERSIZED_HEADER = 'oversized-header'; // header length of 70000 (> 64 KiB) with matching bytes
export const CASE_HOOKS = [CASE_BAD_LENGTH, CASE_OVERSIZED_HEADER];

export const BROWSER_TABS = [
  { targetId: 'tab-docs-0001', tabId: 't1', title: 'OpenClaw Docs', url: 'https://docs.openclaw.ai/' },
  { targetId: 'tab-release-0002', tabId: 't2', title: 'Release v2026.5 · openclaw/openclaw', url: 'https://github.com/openclaw/openclaw/releases/tag/v2026.5' },
];
const FRAME_INTERVAL_MS = 200;
// The agent browser window's size before anyone resizes it: landscape, like the real managed browser.
const DEFAULT_VIEWPORT = { width: 1230, height: 670 };
const VIEWPORT_LIMIT = 8192; // upstream ACT_MAX_VIEWPORT_DIMENSION

// Page behaviours chosen by the tab's host, so one mock covers every stream case:
//   static.example      ready, then frames only when the page repaints (navigation, resize), like upstream
//   unsupported.example the socket is closed with 4005 (SCREENCAST_UNSUPPORTED) right after ready
//   dead.example        the socket drops before `ready`, every time (a stream that never connects)
export const STATIC_HOST = 'static.example';
export const UNSUPPORTED_HOST = 'unsupported.example';
export const DEAD_HOST = 'dead.example';
const hostOf = (url) => { try { return new URL(url).hostname; } catch { return ''; } };

// Frames are painted at the page's viewport aspect (scaled so the long edge is 320 px), like upstream repaints
// at the CSS size. Vertical stripes in one of four hues, no chrome, so aspect-fit is visible at a glance.
const FRAME_HUES = [[36, 99, 235], [22, 163, 74], [217, 119, 6], [147, 51, 234]];
const frameCache = new Map();
export function frameFor(viewport, index) {
  const scale = 320 / Math.max(viewport.width, viewport.height);
  const width = Math.max(8, Math.round(viewport.width * scale));
  const height = Math.max(8, Math.round(viewport.height * scale));
  const hue = index % FRAME_HUES.length;
  const key = `${width}x${height}:${hue}`;
  let jpeg = frameCache.get(key);
  if (!jpeg) {
    const data = Buffer.alloc(width * height * 4);
    const stripe = Math.max(4, Math.round(width / 8));
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const shade = Math.floor(x / stripe) % 2 === 0 ? 1 : 0.72;
        const o = (y * width + x) * 4;
        data[o] = FRAME_HUES[hue][0] * shade;
        data[o + 1] = FRAME_HUES[hue][1] * shade;
        data[o + 2] = FRAME_HUES[hue][2] * shade;
        data[o + 3] = 255;
      }
    }
    jpeg = jpegJs.encode({ data, width, height }, 85).data;
    frameCache.set(key, jpeg);
  }
  return jpeg;
}
const DEFAULT_FRAME = () => frameFor(DEFAULT_VIEWPORT, 0);

export function browserDisabled() {
  return process.env.MOCK_NO_BROWSER === '1';
}

export function browserEvaluateDisabled() {
  return process.env.MOCK_BROWSER_EVALUATE_DISABLED === '1';
}

export function browserRetarget() {
  return process.env.MOCK_BROWSER_RETARGET === '1';
}

export const BACK_FN = '() => { history.go(-1); return true; }';
export const FORWARD_FN = '() => { history.go(1); return true; }';
export const BLOCKED_HOST = 'blocked.example';

function browserState(state) {
  state.browser ??= {
    tokens: new Map(),
    running: process.env.MOCK_BROWSER_STOPPED !== '1',
    // Per-tab history so Back and Forward move through pages.
    tabs: BROWSER_TABS.map((tab) => ({ targetId: tab.targetId, tabId: tab.tabId, history: [{ url: tab.url, title: tab.title }], index: 0, viewport: { ...DEFAULT_VIEWPORT } })),
    sockets: new Map(),
    downloads: new Map(),
    nextTab: 3,
    retargets: 0,
  };
  return state.browser;
}

const currentPage = (tab) => tab.history[tab.index];
const tabInfo = (tab) => ({ targetId: tab.targetId, tabId: tab.tabId, title: currentPage(tab).title, url: currentPage(tab).url });
const findTab = (bs, id) => bs.tabs.find((tab) => tab.targetId === id || tab.tabId === id);

const KNOWN_TITLES = new Map([
  ['https://docs.openclaw.ai/', 'OpenClaw Docs'],
  ['http://example.com/', 'Example Domain'],
  ['https://example.com/', 'Example Domain'],
]);

function titleFor(url) {
  if (KNOWN_TITLES.has(url)) return KNOWN_TITLES.get(url);
  if (url === 'about:blank') return '';
  const parsed = new URL(url);
  return `${parsed.hostname}${parsed.pathname === '/' ? '' : parsed.pathname}`;
}

/** The http, https and about:blank addresses a navigation may use; anything else is a 400. */
function parseNavigationURL(value) {
  if (typeof value !== 'string' || !value || value.length > 4096) return undefined;
  if (value === 'about:blank') return value;
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

/** Sends one fresh frame to every viewer of the tab: what CDP does when the page repaints. */
function repaint(bs, tab) {
  for (const ws of bs.sockets.get(tab.targetId) ?? []) ws.sendFrame?.();
}

function pushMeta(bs, tab) {
  const page = currentPage(tab);
  for (const ws of bs.sockets.get(tab.targetId) ?? []) {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ type: 'meta', url: page.url, title: page.title }));
  }
  repaint(bs, tab);
}

/** Moves a tab to a new page; with MOCK_BROWSER_RETARGET=1 its targetId changes and old viewers close with 4004. */
function commitNavigation(bs, tab, url) {
  const page = { url, title: titleFor(url) };
  tab.history.splice(tab.index + 1, Infinity, page);
  tab.index = tab.history.length - 1;
  if (browserRetarget()) {
    const old = tab.targetId;
    bs.retargets += 1;
    tab.targetId = `${old.replace(/-r\d+$/, '')}-r${bs.retargets}`;
    for (const ws of bs.sockets.get(old) ?? []) ws.close(4004, 'target replaced');
    bs.sockets.delete(old);
  } else {
    pushMeta(bs, tab);
  }
}

function downloadFor(bs, tab) {
  const page = currentPage(tab);
  const id = crypto.randomBytes(4).toString('hex');
  const suggestedFilename = `${(page.title || 'page').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'page'}.html`;
  const path = `/Users/alex/.openclaw/browser/downloads/${id}/${suggestedFilename}`;
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${page.title.replace(/[<&]/g, '')}</title></head><body><h1>${page.title.replace(/[<&]/g, '')}</h1><p>Saved from ${page.url.replace(/[<&"]/g, '')}</p></body></html>\n`;
  bs.downloads.set(path, { filename: suggestedFilename, body: Buffer.from(html, 'utf8') });
  return { path, suggestedFilename };
}

/**
 * The assistant-media route (`GET /__openclaw__/assistant-media?source=<path>`) serving browser downloads, behind
 * Gateway auth (`authorized(req)`). Returns false when the request isn't for this route.
 */
export function handleBrowserHttp(state, req, res, authorized) {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1');
  if (url.pathname !== '/__openclaw__/assistant-media' || browserDisabled()) return false;
  if (!authorized(req)) {
    res.writeHead(401, { 'content-type': 'text/plain' });
    res.end('unauthorized');
    return true;
  }
  const file = browserState(state).downloads.get(url.searchParams.get('source') ?? '');
  if (!file) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return true;
  }
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': file.body.length,
    'content-disposition': `attachment; filename="${file.filename}"`,
  });
  res.end(file.body);
  return true;
}

function scopeApproved(scopes, scope) {
  return scopes.includes(scope) || scopes.includes(ADMIN_SCOPE);
}

/** Upstream wire.ts: UInt32 BE header length, UTF-8 JSON header, JPEG bytes. */
export function encodeFrame(url, jpeg, ts = Date.now(), scrollY = 0, css = DEFAULT_VIEWPORT) {
  const header = Buffer.from(
    JSON.stringify({ url, cssWidth: css.width, cssHeight: css.height, scrollX: 0, scrollY, ts }),
    'utf8',
  );
  const wire = Buffer.allocUnsafe(4 + header.length + jpeg.length);
  wire.writeUInt32BE(header.length, 0);
  header.copy(wire, 4);
  jpeg.copy(wire, 4 + header.length);
  return wire;
}

function malformedFrame(kind, url) {
  if (kind === CASE_BAD_LENGTH) {
    const wire = encodeFrame(url, DEFAULT_FRAME());
    wire.writeUInt32BE(wire.length + 1000, 0);
    return wire;
  }
  const filler = Buffer.alloc(70_000, 0x20);
  const prefix = Buffer.from(`{"url":${JSON.stringify(url)},"pad":"`, 'utf8');
  const suffix = Buffer.from('"}', 'utf8');
  const header = Buffer.concat([prefix, filler.subarray(0, 70_000 - prefix.length - suffix.length), suffix]);
  const wire = Buffer.allocUnsafe(4 + header.length + DEFAULT_FRAME().length);
  wire.writeUInt32BE(header.length, 0);
  header.copy(wire, 4);
  DEFAULT_FRAME().copy(wire, 4 + header.length);
  return wire;
}

/** Handles `browser.request`; returns false when the method isn't ours. */
export function handleBrowserRequest(state, conn, msg, { sendRes, sendErr }) {
  if (msg.method !== 'browser.request' || browserDisabled()) return false;
  const { id } = msg;
  if (!scopeApproved(conn.scopes ?? [], ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const params = msg.params ?? {};
  const invalid = (message) => (sendErr(conn, id, 'INVALID_REQUEST', message), true);
  if (!['GET', 'POST', 'DELETE'].includes(params.method)) return invalid('browser.request method must be GET, POST or DELETE');
  if (typeof params.path !== 'string' || !params.path.startsWith('/')) return invalid('browser.request path must start with /');
  if (params.target !== undefined && !['host', 'node'].includes(params.target)) return invalid('browser.request target must be host or node');

  const bs = browserState(state);
  const body = params.body ?? {};
  const fail = (code, message, details) => (sendErr(conn, id, code, message, details), true);
  const notRunning = () => fail('INVALID_REQUEST', 'browser is not running; start it first');
  const blocked = () => fail('INVALID_REQUEST', 'navigation blocked by browser policy', { reason: 'navigation_blocked' });
  const tabFor = () => {
    const tab = findTab(bs, body.targetId);
    if (!tab) invalid('tab not found');
    return tab;
  };
  const urlFor = (value) => {
    const url = parseNavigationURL(value);
    if (!url) invalid('url must be http, https or about:blank');
    return url;
  };
  const route = `${params.method} ${params.path}`;

  if (route === 'GET /tabs') {
    sendRes(conn, id, bs.running
      ? { running: true, tabs: bs.tabs.map(tabInfo), canAutoResizeViewport: process.env.MOCK_BROWSER_NO_RESIZE !== '1' }
      : { running: false, tabs: [], canAutoResizeViewport: false });
    return true;
  }
  if (route === 'POST /start') {
    bs.running = true;
    sendRes(conn, id, { ok: true, running: true });
    return true;
  }
  if (route !== 'POST /screencast' && !bs.running) return notRunning();

  if (route === 'POST /navigate') {
    const tab = tabFor();
    if (!tab) return true;
    const url = urlFor(body.url);
    if (!url) return true;
    if (url.includes(BLOCKED_HOST)) return blocked();
    commitNavigation(bs, tab, url);
    sendRes(conn, id, { ok: true, targetId: tab.targetId, url });
    return true;
  }
  if (route === 'POST /tabs/open') {
    const url = urlFor(body.url);
    if (!url) return true;
    if (url.includes(BLOCKED_HOST)) return blocked();
    const n = bs.nextTab++;
    const tab = { targetId: `tab-new-${String(n).padStart(4, '0')}`, tabId: `t${n}`, history: [{ url, title: titleFor(url) }], index: 0 };
    bs.tabs.push(tab);
    sendRes(conn, id, tabInfo(tab));
    return true;
  }
  if (params.method === 'DELETE' && params.path.startsWith('/tabs/')) {
    let targetId;
    try {
      targetId = decodeURIComponent(params.path.slice('/tabs/'.length));
    } catch {
      return invalid('invalid tab id');
    }
    const tab = findTab(bs, targetId);
    if (!tab) return invalid('tab not found');
    bs.tabs.splice(bs.tabs.indexOf(tab), 1);
    for (const ws of bs.sockets.get(tab.targetId) ?? []) ws.close(4004, 'target closed');
    bs.sockets.delete(tab.targetId);
    sendRes(conn, id, { ok: true });
    return true;
  }
  if (route === 'POST /act' && body.kind === 'resize') {
    // Upstream: positive integer width and height, each up to ACT_MAX_VIEWPORT_DIMENSION; it resizes the page's viewport.
    const dims = [body.width, body.height];
    if (!dims.every((n) => Number.isInteger(n) && n > 0 && n <= VIEWPORT_LIMIT)) return invalid('resize requires positive width and height');
    if (process.env.MOCK_BROWSER_NO_RESIZE === '1') return fail('INVALID_REQUEST', 'viewport resize is not supported for this profile');
    const tab = tabFor();
    if (!tab) return true;
    tab.viewport = { width: body.width, height: body.height };
    bs.resizes = (bs.resizes ?? 0) + 1;
    repaint(bs, tab);
    sendRes(conn, id, { ok: true, targetId: tab.targetId, url: currentPage(tab).url });
    return true;
  }
  if (route === 'POST /act') {
    // Only the Control UI's history.go(±1) evaluate is supported: no other script runs.
    if (body.kind !== 'evaluate') return invalid('unsupported act kind');
    if (browserEvaluateDisabled()) {
      return fail('INVALID_REQUEST', 'act:evaluate is disabled by config (browser.evaluateEnabled=false)', { code: 'ACT_EVALUATE_DISABLED' });
    }
    const delta = body.fn === BACK_FN ? -1 : body.fn === FORWARD_FN ? 1 : 0;
    if (!delta) return invalid('unsupported evaluate function');
    const tab = tabFor();
    if (!tab) return true;
    const next = tab.index + delta;
    if (next >= 0 && next < tab.history.length) {
      tab.index = next;
      pushMeta(bs, tab);
    }
    sendRes(conn, id, { ok: true, targetId: tab.targetId, result: true });
    return true;
  }
  if (route === 'POST /download') {
    const tab = tabFor();
    if (!tab) return true;
    if (body.currentDocument !== true) return invalid('only the current document can be downloaded');
    if (body.expectedUrl !== currentPage(tab).url) return invalid('the tab navigated away from the expected url');
    sendRes(conn, id, { download: downloadFor(bs, tab) });
    return true;
  }
  if (route === 'POST /screencast') {
    const tab = findTab(bs, body.targetId);
    const hook = CASE_HOOKS.find((name) => body.targetId === name);
    if (!bs.running) return notRunning();
    if (!tab && !hook) return invalid('tab not found');
    for (const key of ['maxWidth', 'maxHeight']) {
      if (body[key] !== undefined && !(Number.isInteger(body[key]) && body[key] > 0)) return invalid(`${key} must be a positive integer`);
    }
    const target = tab ?? bs.tabs[0];
    const page = currentPage(target);
    const token = `${hook ? `${hook}-` : ''}${crypto.randomBytes(18).toString('base64url')}`;
    bs.tokens.set(token, { targetId: target.targetId });
    sendRes(conn, id, {
      token,
      wsPath: `${SCREENCAST_PATH}?token=${token}`,
      expiresAtMs: Date.now() + 30_000,
      targetId: target.targetId,
      url: page.url,
    });
    return true;
  }
  return invalid(`unsupported browser route: ${route}`);
}

function reject(socket, status, text) {
  socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  socket.destroy();
}

/**
 * Installs the `/browser/screencast` upgrade handler on `httpServer`. Other upgrades fall through to `fallback`
 * (the Gateway's main WebSocketServer). Tokens are one-time like upstream's `consumeBrowserScreencastToken`.
 */
export function attachScreencastUpgrade(httpServer, state, fallback) {
  const screencastWss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 });
  const timers = new Set();
  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    if (url.pathname !== SCREENCAST_PATH || browserDisabled()) {
      if (url.pathname === SCREENCAST_PATH) reject(socket, 404, 'Not Found');
      else fallback(req, socket, head);
      return;
    }
    const token = url.searchParams.get('token') ?? '';
    const tokens = browserState(state).tokens;
    const grant = tokens.get(token);
    tokens.delete(token);
    if (!grant) {
      reject(socket, 401, 'Unauthorized');
      return;
    }
    const hook = CASE_HOOKS.find((name) => url.searchParams.get('case') === name || token.startsWith(`${name}-`));
    const bs = browserState(state);
    const liveTab = () => findTab(bs, grant.targetId);
    if (!liveTab()) {
      reject(socket, 404, 'Not Found');
      return;
    }
    screencastWss.handleUpgrade(req, socket, head, (ws) => {
      if (!bs.sockets.has(grant.targetId)) bs.sockets.set(grant.targetId, new Set());
      bs.sockets.get(grant.targetId).add(ws);
      ws.on('error', () => ws.terminate());
      ws.on('message', (_data, binary) => {
        if (binary) ws.close(1003, 'view_only');
      });
      const first = currentPage(liveTab());
      if (hostOf(first.url) === DEAD_HOST) {
        ws.terminate();
        return;
      }
      ws.send(JSON.stringify({ type: 'ready', targetId: grant.targetId, url: first.url, title: first.title }));
      const host = hostOf(first.url);
      if (host === UNSUPPORTED_HOST) {
        ws.close(4005, 'unsupported');
        ws.on('close', () => bs.sockets.get(grant.targetId)?.delete(ws));
        return;
      }
      let n = 0;
      const send = () => {
        const tab = liveTab();
        if (ws.readyState !== ws.OPEN || !tab) return;
        const { url: pageUrl } = currentPage(tab);
        const frame = hook ? malformedFrame(hook, pageUrl) : encodeFrame(pageUrl, frameFor(tab.viewport, n + pageUrl.length), Date.now(), (n % 4) * 40, tab.viewport);
        n += 1;
        ws.send(frame, { binary: true });
      };
      ws.sendFrame = send;
      // A static page paints nothing after `ready` until something changes it.
      const timer = hostOf(currentPage(liveTab()).url) === STATIC_HOST ? undefined : setInterval(send, FRAME_INTERVAL_MS);
      if (timer) { send(); timers.add(timer); }
      ws.on('close', () => {
        bs.sockets.get(grant.targetId)?.delete(ws);
        if (timer) { clearInterval(timer); timers.delete(timer); }
      });
    });
  });
  return {
    close: () => {
      for (const timer of timers) clearInterval(timer);
      timers.clear();
      for (const ws of screencastWss.clients) ws.terminate();
      screencastWss.close();
    },
  };
}
