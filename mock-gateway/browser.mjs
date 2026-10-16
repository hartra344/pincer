// Mock of the Gateway's browser tool surface for the live browser panel (#974): `browser.request`
// (operator.admin) with `GET /tabs`, `POST /screencast`, `/navigate`, `/tabs/open`, `DELETE /tabs/<id>`, `/start`,
// `/act` (history.go(±1) only) and `/download`, the `/browser/screencast` WebSocket upgrade, and the assistant-media
// route that serves downloads.
// Shapes follow upstream extensions/browser/src/browser/{routes/agent.screencast.ts,screencast/{wire,upgrade}.ts}.
import crypto from 'node:crypto';
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
const CSS_SIZE = { width: 1280, height: 800 };

// Valid baseline JPEGs (192x120), generated once offline with `sips`: one per color.
const FRAMES_B64 = [
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAwKADAAQAAAABAAAAeAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAeADAAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMABAQEBAQEBgQEBgkGBgYJDAkJCQkMDwwMDAwMDxIPDw8PDw8SEhISEhISEhUVFRUVFRkZGRkZHBwcHBwcHBwcHP/bAEMBBAUFBwcHDAcHDB0UEBQdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHf/dAAQADP/aAAwDAQACEQMRAD8A+OaKKK+uPFCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//Q8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/R8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/S8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/T8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/U8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/V8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/W8Hooor9oPgQroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnOdooorxT0Aroq52uirtw3U563QKKKK7TnP/Z',
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAwKADAAQAAAABAAAAeAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAeADAAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMABAQEBAQEBgQEBgkGBgYJDAkJCQkMDwwMDAwMDxIPDw8PDw8SEhISEhISEhUVFRUVFRkZGRkZHBwcHBwcHBwcHP/bAEMBBAUFBwcHDAcHDB0UEBQdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHf/dAAQADP/aAAwDAQACEQMRAD8A+S6KKK8s+uCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//Q5eiiiviT+hArk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4j//0eXooor4k/oQK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI//9Ll6KKK+JP6ECuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiP//T5eiiiviT+hArk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4j//1OXooor4k/oQK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI6yiiiuU9oK5Ousrk61p9TixPQKKKK1OI//9Xl6KKK+JP6ECuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiOsooorlPaCuTrrK5OtafU4sT0CiiitTiP//W5eiiiviT+hArk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4jrKKKK5T2grk66yuTrWn1OLE9AooorU4j//2Q==',
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAwKADAAQAAAABAAAAeAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAeADAAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMABAQEBAQEBgQEBgkGBgYJDAkJCQkMDwwMDAwMDxIPDw8PDw8SEhISEhISEhUVFRUVFRkZGRkZHBwcHBwcHBwcHP/bAEMBBAUFBwcHDAcHDB0UEBQdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHf/dAAQADP/aAAwDAQACEQMRAD8A+TaKKK5z5sKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD//Q8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//R8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//S8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//T8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//U8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//V8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//W8vooorzT8vCusrk66ypZy1+gUUUVJynJ0UUVoeoFdZXJ11lSzlr9AoooqTlOTooorQ9QK6yuTrrKlnLX6BRRRUnKcnRRRWh6gV1lcnXWVLOWv0CiiipOU//Z',
  '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAwKADAAQAAAABAAAAeAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAeADAAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMABAQEBAQEBgQEBgkGBgYJDAkJCQkMDwwMDAwMDxIPDw8PDw8SEhISEhISEhUVFRUVFRkZGRkZHBwcHBwcHBwcHP/bAEMBBAUFBwcHDAcHDB0UEBQdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHf/dAAQADP/aAAwDAQACEQMRAD8A+Z6KKK+RPUCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//Q6iiiiv55PvArha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMT//0eoooor+eT7wK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE//9LqKKKK/nk+8CuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xP//T6iiiiv55PvArha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMT//1Ooooor+eT7wK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE7qiiivDOwK4Wu6rha7sL1ManQKKKK7jE//9XqKKKK/nk+8CuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xO6ooorwzsCuFruq4Wu7C9TGp0Ciiiu4xP//W6iiiiv55PvArha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMTuqKKK8M7Arha7quFruwvUxqdAoooruMT//2Q==',
];
export const FRAMES = FRAMES_B64.map((b64) => Buffer.from(b64, 'base64'));

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
    tabs: BROWSER_TABS.map((tab) => ({ targetId: tab.targetId, tabId: tab.tabId, history: [{ url: tab.url, title: tab.title }], index: 0 })),
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

function pushMeta(bs, tab) {
  const page = currentPage(tab);
  for (const ws of bs.sockets.get(tab.targetId) ?? []) {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ type: 'meta', url: page.url, title: page.title }));
  }
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
export function encodeFrame(url, jpeg, ts = Date.now(), scrollY = 0) {
  const header = Buffer.from(
    JSON.stringify({ url, cssWidth: CSS_SIZE.width, cssHeight: CSS_SIZE.height, scrollX: 0, scrollY, ts }),
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
    const wire = encodeFrame(url, FRAMES[0]);
    wire.writeUInt32BE(wire.length + 1000, 0);
    return wire;
  }
  const filler = Buffer.alloc(70_000, 0x20);
  const prefix = Buffer.from(`{"url":${JSON.stringify(url)},"pad":"`, 'utf8');
  const suffix = Buffer.from('"}', 'utf8');
  const header = Buffer.concat([prefix, filler.subarray(0, 70_000 - prefix.length - suffix.length), suffix]);
  const wire = Buffer.allocUnsafe(4 + header.length + FRAMES[0].length);
  wire.writeUInt32BE(header.length, 0);
  header.copy(wire, 4);
  FRAMES[0].copy(wire, 4 + header.length);
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
      ? { running: true, tabs: bs.tabs.map(tabInfo), canAutoResizeViewport: true }
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
      ws.send(JSON.stringify({ type: 'ready', targetId: grant.targetId, url: first.url, title: first.title }));
      let n = 0;
      const send = () => {
        const tab = liveTab();
        if (ws.readyState !== ws.OPEN || !tab) return;
        const { url: pageUrl } = currentPage(tab);
        const frame = hook ? malformedFrame(hook, pageUrl) : encodeFrame(pageUrl, FRAMES[(n + pageUrl.length) % FRAMES.length], Date.now(), (n % 4) * 40);
        n += 1;
        ws.send(frame, { binary: true });
      };
      send();
      const timer = setInterval(send, FRAME_INTERVAL_MS);
      timers.add(timer);
      ws.on('close', () => {
        bs.sockets.get(grant.targetId)?.delete(ws);
        clearInterval(timer);
        timers.delete(timer);
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
