// Mock of the Gateway's browser tool surface for the live browser panel (#974): `browser.request`
// (operator.admin) with `GET /tabs` and `POST /screencast`, and the `/browser/screencast` WebSocket upgrade.
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

function browserState(state) {
  state.browser ??= { tokens: new Map() };
  return state.browser;
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

  if (params.method === 'GET' && params.path === '/tabs') {
    sendRes(conn, id, { running: true, tabs: BROWSER_TABS.map((tab) => ({ ...tab })), canAutoResizeViewport: true });
    return true;
  }
  if (params.method === 'POST' && params.path === '/screencast') {
    const body = params.body ?? {};
    const tab = BROWSER_TABS.find((entry) => entry.targetId === body.targetId || entry.tabId === body.targetId);
    const hook = CASE_HOOKS.find((name) => body.targetId === name);
    if (!tab && !hook) return invalid('tab not found');
    for (const key of ['maxWidth', 'maxHeight']) {
      if (body[key] !== undefined && !(Number.isInteger(body[key]) && body[key] > 0)) return invalid(`${key} must be a positive integer`);
    }
    const target = tab ?? BROWSER_TABS[0];
    const token = `${hook ? `${hook}-` : ''}${crypto.randomBytes(18).toString('base64url')}`;
    browserState(state).tokens.set(token, { targetId: target.targetId, url: target.url, title: target.title });
    sendRes(conn, id, {
      token,
      wsPath: `${SCREENCAST_PATH}?token=${token}`,
      expiresAtMs: Date.now() + 30_000,
      targetId: target.targetId,
      url: target.url,
    });
    return true;
  }
  return invalid(`unsupported browser route: ${params.method} ${params.path}`);
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
    screencastWss.handleUpgrade(req, socket, head, (ws) => {
      ws.on('error', () => ws.terminate());
      ws.on('message', (_data, binary) => {
        if (binary) ws.close(1003, 'view_only');
      });
      ws.send(JSON.stringify({ type: 'ready', targetId: grant.targetId, url: grant.url, title: grant.title }));
      let n = 0;
      const send = () => {
        if (ws.readyState !== ws.OPEN) return;
        const frame = hook ? malformedFrame(hook, grant.url) : encodeFrame(grant.url, FRAMES[n % FRAMES.length], Date.now(), (n % 4) * 40);
        n += 1;
        ws.send(frame, { binary: true });
      };
      send();
      const timer = setInterval(send, FRAME_INTERVAL_MS);
      timers.add(timer);
      ws.on('close', () => {
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
