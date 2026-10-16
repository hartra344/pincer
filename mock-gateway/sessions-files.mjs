// Session workspace files and artifacts for the Files tab (#974): sessions.files.list/get/set and artifacts.list.
// Mirrors openclaw src/gateway/server-methods/{sessions-files,workspace-files,workspace-fs,session-files-errors,artifacts,
// artifacts-image-page}.ts and packages/gateway-protocol/src/schema/{sessions,artifacts}.ts:
// - scopes (core-descriptors.ts): list/get and artifacts.list need operator.read; set needs operator.admin.
// - params are closed objects; errors are INVALID_REQUEST with `details.type` (sessionFilesError / artifactError).
// - previews are capped at 256 KiB (WORKSPACE_PREVIEW_MAX_BYTES); `hash` is the SHA-256 hex of the file bytes and is the
//   sessions.files.set compare-and-swap token. Binary, read-only and over-cap files never get one.
// - set overwrites an EXISTING file only. There is no create, rename or delete.
// Hooks for tests (documented in README.md):
// - `notes/volatile.md` changes after every sessions.files.get, so a save with the hash of the last read conflicts.
// - MOCK_FILES_DRIFT=1 changes every file once, right after its first sessions.files.get.
// - changeSessionFile(state, sessionKey, path, content) rewrites a file from server-side test code.
// MOCK_NO_SESSION_FILES=1 makes the mock look like a Gateway without these methods.
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { ADMIN_SCOPE } from './config.mjs';

export const SESSION_FILES_METHODS = ['sessions.files.list', 'sessions.files.get', 'sessions.files.set', 'artifacts.list'];
export const SESSION_FILES_ROOT = '/Users/claw/.openclaw/workspace';
export const SEEDED_FILES_SESSION = 'agent:main:main';
export const VOLATILE_PATH = 'notes/volatile.md';
/** WORKSPACE_PREVIEW_MAX_BYTES. */
export const PREVIEW_MAX_BYTES = 256 * 1024;
const MAX_BROWSER_ENTRIES = 250;
const MAX_SEARCH_ENTRIES = 500;
const MAX_SEARCH_VISITED_ENTRIES = 5_000;
const SEARCH_SKIP_DIRS = new Set(['.git', '.hg', '.next', '.turbo', '.yarn', 'coverage', 'dist', 'node_modules']);
const IMAGE_MIMES = new Set(['image/avif', 'image/gif', 'image/jpeg', 'image/png', 'image/webp']);
const DEFAULT_IMAGE_PAGE = 4;

export function sessionFilesDisabled() {
  return process.env.MOCK_NO_SESSION_FILES === '1';
}

const sha256 = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex');

// --- Seed data ---

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buffer) {
  let c = 0xffffffff;
  for (const byte of buffer) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const out = Buffer.alloc(data.length + 12);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), 4 + body.length);
  return out;
}

/** A valid RGB PNG with a diagonal gradient. */
function makePng(size, [r, g, b]) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header.set([8, 2, 0, 0, 0], 8);
  const rows = Buffer.alloc((size * 3 + 1) * size);
  for (let y = 0; y < size; y++) {
    const at = y * (size * 3 + 1);
    for (let x = 0; x < size; x++) {
      const t = (x + y) / (2 * size);
      rows[at + 1 + x * 3] = Math.round(r * (1 - t) + 255 * t);
      rows[at + 2 + x * 3] = Math.round(g * (1 - t) + 255 * t);
      rows[at + 3 + x * 3] = Math.round(b * (1 - t) + 255 * t);
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', header),
    pngChunk('IDAT', zlib.deflateSync(rows)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function sniffMime(buffer) {
  if (buffer.length >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'image/jpeg';
  if (buffer.length >= 4 && buffer.subarray(0, 4).toString('ascii') === 'GIF8') return 'image/gif';
  if (buffer.length >= 12 && buffer.subarray(0, 4).toString('ascii') === 'RIFF' && buffer.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp';
  return undefined;
}

function decodeUtf8Strict(buffer) {
  if (buffer.includes(0)) return undefined;
  try {
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buffer);
  } catch {
    return undefined;
  }
}

function buildLog() {
  const lines = [];
  for (let i = 0; lines.join('\n').length < 300 * 1024; i++) {
    lines.push(`[2026-10-16T09:${String(i % 60).padStart(2, '0')}:00Z] step ${i}: compiled module ${i % 97} in ${10 + (i % 40)}ms`);
  }
  return `${lines.join('\n')}\n`;
}

function seedWorkspace(withProject) {
  const ws = { root: SESSION_FILES_ROOT, files: new Map(), touched: [] };
  const base = Date.now() - 3 * 60 * 60_000;
  const put = (path, content, minutesAgo, extra = {}) => {
    ws.files.set(path, { content: Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8'), mtimeMs: Math.floor(base + (180 - minutesAgo) * 60_000), ...extra });
  };
  put('NOTES.md', '# Notes\n\nScratch space for this chat.\n', 90);
  if (!withProject) return ws;
  put('README.md', '# Harbor\n\nA tiny status dashboard for the home lab.\n\n## Develop\n\n```sh\nnpm install\nnpm test\n```\n', 170);
  put('package.json', '{\n  "name": "harbor",\n  "version": "0.4.0",\n  "scripts": {\n    "test": "vitest run"\n  }\n}\n', 30);
  put('LICENSE', 'MIT License\n\nCopyright (c) 2026 Alex\n', 170, { readOnly: true });
  put('src/index.ts', 'import { formatUptime } from "./lib/format";\n\nexport function render(seconds: number): string {\n  return `Uptime: ${formatUptime(seconds)}`;\n}\n', 12);
  put('src/lib/format.ts', 'export function formatUptime(seconds: number): string {\n  const hours = Math.floor(seconds / 3600);\n  const minutes = Math.floor((seconds % 3600) / 60);\n  return `${hours}h ${minutes}m`;\n}\n', 9);
  put('src/lib/format.test.ts', 'import { expect, test } from "vitest";\nimport { formatUptime } from "./format";\n\ntest("formats hours and minutes", () => {\n  expect(formatUptime(3720)).toBe("1h 2m");\n});\n', 8);
  put('docs/architecture.md', '# Architecture\n\nHarbor polls each host every 30 seconds and renders one card per host.\n', 160);
  put('assets/logo.png', makePng(64, [32, 110, 200]), 150);
  put('assets/hosts.bin', Buffer.from(Array.from({ length: 2048 }, (_, i) => (i * 37 + 11) & 0xff)), 150);
  put('logs/build.log', buildLog(), 20);
  put(VOLATILE_PATH, '# Volatile\n\nThis file changes every time it is read.\n', 5);
  ws.touched = [
    { path: 'src/index.ts', kind: 'modified' },
    { path: 'src/lib/format.ts', kind: 'modified' },
    { path: 'package.json', kind: 'modified' },
    { path: VOLATILE_PATH, kind: 'modified' },
    { path: 'src/lib/format.test.ts', kind: 'modified' },
    { path: 'README.md', kind: 'read' },
    { path: 'docs/architecture.md', kind: 'read' },
    { path: 'logs/build.log', kind: 'read' },
    { path: 'assets/logo.png', kind: 'read' },
    { path: 'src/lib/legacy.ts', kind: 'read' }, // deleted since it was read
  ];
  return ws;
}

function seedArtifacts() {
  const png = (size, color) => `data:image/png;base64,${makePng(size, color).toString('base64')}`;
  const image = (n, title, size, color, seq) => ({
    id: `artifact_image_${n}`,
    type: 'image',
    title,
    mimeType: 'image/png',
    sizeBytes: makePng(size, color).length,
    sessionKey: SEEDED_FILES_SESSION,
    runId: `run-files-${n}`,
    messageSeq: seq,
    source: 'session-transcript',
    download: { mode: 'bytes' },
    image: { url: png(size, color) },
    role: 'assistant',
  });
  return [
    { id: 'artifact_file_notes', type: 'file', title: 'release-notes.md', mimeType: 'text/markdown', sizeBytes: 1842, sessionKey: SEEDED_FILES_SESSION, runId: 'run-files-1', messageSeq: 2, source: 'session-transcript', download: { mode: 'bytes' }, role: 'assistant' },
    image(1, 'uptime-chart.png', 48, [32, 110, 200], 3),
    { id: 'artifact_file_upload', type: 'file', title: 'hosts.csv', mimeType: 'text/csv', sizeBytes: 612, sessionKey: SEEDED_FILES_SESSION, messageSeq: 1, source: 'session-transcript', download: { mode: 'bytes' }, role: 'user' },
    image(2, 'status-grid.png', 40, [200, 90, 60], 5),
    image(3, 'host-map.png', 56, [60, 170, 110], 7),
  ];
}

function filesState(state) {
  state.sessionFiles ??= { workspaces: new Map(), artifacts: seedArtifacts(), cursors: new Map(), drifted: new Set(), volatileEdits: 0 };
  return state.sessionFiles;
}

function workspaceFor(state, sessionKey) {
  const fs = filesState(state);
  let ws = fs.workspaces.get(sessionKey);
  if (!ws) {
    ws = seedWorkspace(sessionKey === SEEDED_FILES_SESSION);
    fs.workspaces.set(sessionKey, ws);
  }
  return ws;
}

/** Test hook: rewrites a file as if something else on the Gateway host changed it. Returns the new hash. */
export function changeSessionFile(state, sessionKey, path, content) {
  const file = workspaceFor(state, sessionKey).files.get(path);
  if (!file) throw new Error(`no such file: ${path}`);
  file.content = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
  file.mtimeMs = Date.now();
  return sha256(file.content);
}

// --- Closed params (the gateway-protocol typebox schemas) ---

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fieldType = {
  nonEmpty: (v) => (typeof v !== 'string' ? 'must be string' : v.length ? undefined : 'must NOT have fewer than 1 characters'),
  string: (v) => (typeof v === 'string' ? undefined : 'must be string'),
  sha256: (v) => (typeof v === 'string' && /^[a-f0-9]{64}$/.test(v) ? undefined : 'must match pattern "^[a-f0-9]{64}$"'),
  assistant: (v) => (v === 'assistant' ? undefined : 'must be equal to constant'),
  image: (v) => (v === 'image' ? undefined : 'must be equal to constant'),
  limit: (v) => (!Number.isInteger(v) ? 'must be integer' : v < 1 ? 'must be >= 1' : v > 4 ? 'must be <= 4' : undefined),
  cursor: (v) => (typeof v !== 'string' ? 'must be string' : v.length < 1 ? 'must NOT have fewer than 1 characters' : v.length > 256 ? 'must NOT have more than 256 characters' : undefined),
};
const SCHEMAS = {
  'sessions.files.list': { required: ['sessionKey'], fields: { sessionKey: 'nonEmpty', agentId: 'nonEmpty', path: 'string', search: 'string' } },
  'sessions.files.get': { required: ['sessionKey', 'path'], fields: { sessionKey: 'nonEmpty', path: 'nonEmpty', agentId: 'nonEmpty' } },
  'sessions.files.set': {
    required: ['sessionKey', 'path', 'content', 'expectedHash'],
    fields: { sessionKey: 'nonEmpty', path: 'nonEmpty', agentId: 'nonEmpty', content: 'string', expectedHash: 'sha256' },
  },
  'artifacts.list': {
    required: [],
    fields: { sessionKey: 'nonEmpty', runId: 'nonEmpty', agentId: 'nonEmpty', messageRole: 'assistant', type: 'image', limit: 'limit', cursor: 'cursor' },
  },
};

export function sessionFilesParamsProblem(method, params) {
  const schema = SCHEMAS[method];
  if (!isObject(params)) return 'at root: must be object';
  for (const key of schema.required) if (!(key in params)) return `at root: must have required property '${key}'`;
  for (const [key, value] of Object.entries(params)) {
    const type = schema.fields[key];
    if (!type) return `at root: unexpected property '${key}'`;
    const problem = fieldType[type](value);
    if (problem) return `at /${key}: ${problem}`;
  }
  return undefined;
}

// --- Paths and projections ---

function normalizeRelativePath(value) {
  if (!value) return '';
  return value.replaceAll('\\', '/').split('/').filter((part) => part && part !== '.').join('/');
}

/** Root-relative path for `value`, or undefined when it resolves outside the workspace root. */
function resolveInside(root, value) {
  const absolute = value.startsWith('/') || /^[a-zA-Z]:[\\/]/.test(value);
  const parts = [];
  for (const part of normalizeRelativePath(absolute ? value.slice(root.length).replace(/^\//, '') : value).split('/')) {
    if (part === '..') {
      if (!parts.length) return undefined;
      parts.pop();
    } else if (part) {
      parts.push(part);
    }
  }
  if (absolute && value !== root && !value.startsWith(`${root}/`)) return undefined;
  return parts.join('/');
}

const baseName = (path) => path.split('/').filter(Boolean).pop() ?? path;

function fileEntry(ws, touched) {
  const base = { path: touched.path, name: baseName(touched.path), kind: touched.kind };
  const rel = resolveInside(ws.root, touched.path);
  const file = rel === undefined ? undefined : ws.files.get(rel);
  if (!file) return { ...base, missing: true };
  return { ...base, workspacePath: rel, missing: false, size: file.content.length, updatedAtMs: Math.floor(file.mtimeMs) };
}

/** Upstream populateSessionFilePreview and the inline size cap. */
function withContent(entry, file) {
  const out = { ...entry };
  const inline = file.content.length <= PREVIEW_MAX_BYTES;
  const mime = sniffMime(file.content);
  if (inline) {
    if (mime && IMAGE_MIMES.has(mime)) {
      return { ...out, mimeType: mime, contentEncoding: 'base64', previewKind: 'image', content: file.content.toString('base64') };
    }
    const text = decodeUtf8Strict(file.content);
    if (!mime && text !== undefined) {
      const withText = { ...out, mimeType: 'text/plain', contentEncoding: 'utf8', previewKind: 'text', content: text };
      if (!file.readOnly) withText.hash = sha256(file.content);
      return withText;
    }
    return { ...out, previewKind: 'unsupported', ...(mime ? { mimeType: mime } : {}) };
  }
  const prefix = file.content.subarray(0, 4100);
  if (decodeUtf8Strict(prefix) === undefined || mime) {
    return { ...out, previewKind: 'unsupported', ...(mime ? { mimeType: mime } : {}) };
  }
  return out;
}

function relevanceMap(ws) {
  const map = new Map();
  for (const touched of ws.touched) {
    const rel = resolveInside(ws.root, touched.path);
    if (rel !== undefined) map.set(rel, touched.kind);
  }
  return map;
}

function direntsOf(ws, dir) {
  const prefix = dir ? `${dir}/` : '';
  const seen = new Map();
  for (const [path, file] of ws.files) {
    if (!path.startsWith(prefix)) continue;
    const rest = path.slice(prefix.length);
    const slash = rest.indexOf('/');
    if (slash === -1) seen.set(rest, { name: rest, isFile: true, isDirectory: false, size: file.content.length, mtimeMs: file.mtimeMs });
    else {
      const name = rest.slice(0, slash);
      const prev = seen.get(name);
      seen.set(name, { name, isFile: false, isDirectory: true, mtimeMs: Math.max(prev?.mtimeMs ?? 0, file.mtimeMs) });
    }
  }
  return [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function browserEntry(path, dirent, relevance) {
  const kind = dirent.isFile ? 'file' : 'directory';
  let sessionKind = kind === 'file' ? relevance.get(path) : undefined;
  if (kind === 'directory') {
    const prefix = `${path}/`;
    for (const [filePath, fileKind] of relevance) {
      if (filePath.startsWith(prefix)) sessionKind = !sessionKind || sessionKind === fileKind ? fileKind : 'mixed';
    }
  }
  return {
    path,
    name: dirent.name,
    kind,
    ...(kind === 'file' ? { size: dirent.size } : {}),
    updatedAtMs: Math.floor(dirent.mtimeMs),
    ...(sessionKind ? { sessionKind } : {}),
  };
}

const sortEntries = (entries) => entries.toSorted((a, b) => (a.kind !== b.kind ? (a.kind === 'directory' ? -1 : 1) : a.name.localeCompare(b.name)));

function searchBrowser(ws, query, relevance) {
  const needle = query.toLowerCase();
  const entries = [];
  let visited = 0;
  let truncated = false;
  const stop = () => {
    if (entries.length >= MAX_SEARCH_ENTRIES || visited >= MAX_SEARCH_VISITED_ENTRIES) {
      truncated = true;
      return true;
    }
    return false;
  };
  const visit = (dir) => {
    if (stop()) return;
    for (const dirent of direntsOf(ws, dir)) {
      if (stop()) return;
      visited += 1;
      const path = dir ? `${dir}/${dirent.name}` : dirent.name;
      if (path.toLowerCase().includes(needle)) entries.push(browserEntry(path, dirent, relevance));
      if (dirent.isDirectory && !SEARCH_SKIP_DIRS.has(dirent.name)) visit(path);
    }
  };
  visit('');
  return { path: '', search: query, entries: sortEntries(entries), ...(truncated ? { truncated } : {}) };
}

function browserResult(ws, params) {
  const relevance = relevanceMap(ws);
  const search = params.search?.trim();
  if (search) return searchBrowser(ws, search, relevance);
  const dir = resolveInside(ws.root, normalizeRelativePath(params.path));
  if (dir === undefined) return undefined;
  const dirents = direntsOf(ws, dir);
  if (dir && !dirents.length) return undefined;
  const entries = dirents.slice(0, MAX_BROWSER_ENTRIES + 1).map((dirent) => browserEntry(dir ? `${dir}/${dirent.name}` : dirent.name, dirent, relevance));
  const parent = dir.includes('/') ? dir.slice(0, dir.lastIndexOf('/')) : '';
  return {
    path: dir,
    ...(dir ? { parentPath: parent } : {}),
    entries: sortEntries(entries.slice(0, MAX_BROWSER_ENTRIES)),
    ...(entries.length > MAX_BROWSER_ENTRIES ? { truncated: true } : {}),
  };
}

// --- Handler ---

export function handleSessionFilesRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  if (!SESSION_FILES_METHODS.includes(method) || sessionFilesDisabled()) return false;
  const params = msg.params ?? {};
  if (method === 'sessions.files.set' && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const problem = sessionFilesParamsProblem(method, params);
  if (problem) return (sendErr(conn, id, 'INVALID_REQUEST', `invalid ${method} params: ${problem}`), true);
  const fail = (type, message, details) => (sendErr(conn, id, 'INVALID_REQUEST', message, { type, ...details }), true);
  const notFound = (path, reason) => fail('session_file_not_found', 'session file not found', { path, ...(reason ? { reason } : {}) });

  if (method === 'artifacts.list') return handleArtifactsList(state, conn, id, params, { sendRes, fail });

  // Upstream resolves no entry for an unknown session: list is empty, get/set end in session_file_not_found.
  if (!state.sessions.has(params.sessionKey)) {
    if (method === 'sessions.files.list') return (sendRes(conn, id, { sessionKey: params.sessionKey, files: [] }), true);
    return notFound(params.path);
  }
  const ws = workspaceFor(state, params.sessionKey);
  const fs = filesState(state);

  if (method === 'sessions.files.list') {
    const files = ws.touched.map((touched) => fileEntry(ws, touched)).toSorted((a, b) => (a.kind !== b.kind ? (a.kind === 'modified' ? -1 : 1) : a.path.localeCompare(b.path)));
    const browser = browserResult(ws, params);
    sendRes(conn, id, { sessionKey: params.sessionKey, root: ws.root, gitCheckout: true, files, ...(browser ? { browser } : {}) });
    return true;
  }

  const rel = resolveInside(ws.root, params.path);

  if (method === 'sessions.files.get') {
    if (rel === undefined) return notFound(params.path, 'outside_session_boundary');
    const file = ws.files.get(rel);
    const touched = ws.touched.find((t) => resolveInside(ws.root, t.path) === rel);
    if (!file) return notFound(params.path);
    const entry = fileEntry(ws, { path: touched?.path ?? rel, kind: touched?.kind === 'modified' ? 'modified' : 'read' });
    const result = withContent(entry, file);
    if (typeof result.content !== 'string' && result.previewKind !== 'unsupported') {
      return fail('session_file_too_large', 'session file is too large to preview', { maxPreviewBytes: PREVIEW_MAX_BYTES, path: result.path, size: result.size });
    }
    sendRes(conn, id, { sessionKey: params.sessionKey, root: ws.root, file: result });
    // Hooks: change the file behind the client's back once it has been read.
    if (rel === VOLATILE_PATH) {
      fs.volatileEdits += 1;
      file.content = Buffer.from(`${file.content.toString('utf8').split('\n\nEdited elsewhere')[0]}\n\nEdited elsewhere ${fs.volatileEdits} time(s).\n`, 'utf8');
      file.mtimeMs = Date.now();
    } else if (process.env.MOCK_FILES_DRIFT === '1' && result.hash && !fs.drifted.has(`${params.sessionKey}\0${rel}`)) {
      fs.drifted.add(`${params.sessionKey}\0${rel}`);
      file.content = Buffer.concat([file.content, Buffer.from('\n// changed on the gateway host\n', 'utf8')]);
      file.mtimeMs = Date.now();
    }
    return true;
  }

  // sessions.files.set: the same checks, in the same order, as setSessionWorkspaceFile.
  if (params.content.includes('\0')) return fail('session_file_unsafe', 'session file could not be written safely', { path: params.path });
  const size = Buffer.byteLength(params.content, 'utf8');
  if (size > PREVIEW_MAX_BYTES) return fail('session_file_too_large', 'session file content is too large', { path: params.path, maxPreviewBytes: PREVIEW_MAX_BYTES, size });
  const file = rel === undefined ? undefined : ws.files.get(rel);
  if (!file) return notFound(params.path);
  if (file.readOnly || decodeUtf8Strict(file.content) === undefined) return fail('session_file_unsafe', 'session file could not be written safely', { path: params.path });
  const currentHash = sha256(file.content);
  if (currentHash !== params.expectedHash) return fail('session_file_conflict', 'session file changed since it was read', { path: params.path, currentHash });
  file.content = Buffer.from(params.content, 'utf8');
  file.mtimeMs = Date.now();
  sendRes(conn, id, {
    sessionKey: params.sessionKey,
    root: ws.root,
    file: { path: params.path, workspacePath: rel, name: baseName(rel), kind: 'modified', missing: false, size: file.content.length, updatedAtMs: Math.floor(file.mtimeMs), hash: sha256(file.content) },
  });
  return true;
}

function handleArtifactsList(state, conn, id, params, { sendRes, fail }) {
  const fs = filesState(state);
  if (!params.sessionKey && !params.runId) return fail('artifact_query_unsupported', 'artifacts require sessionKey or runId');
  if ((params.limit !== undefined || params.cursor !== undefined) && params.type !== 'image') {
    return fail('artifact_query_unsupported', 'limit and cursor require type image');
  }
  let sessionKey = params.sessionKey;
  // Upstream loadArtifacts resolves no scope for an unknown session and answers an empty list.
  if (sessionKey && !state.sessions.has(sessionKey)) {
    sendRes(conn, id, { artifacts: [] });
    return true;
  }
  if (!sessionKey) {
    sessionKey = fs.artifacts.find((a) => a.runId === params.runId)?.sessionKey;
    if (!sessionKey) return fail('artifact_scope_not_found', 'no session found for artifact query');
  }
  let items = fs.artifacts.filter((a) => a.sessionKey === sessionKey && (!params.runId || a.runId === params.runId));
  if (params.messageRole) items = items.filter((a) => a.role === params.messageRole);
  const strip = ({ role, image, ...summary }) => (params.type === 'image' ? { ...summary, ...(image ? { image } : {}) } : summary);
  if (params.type !== 'image') {
    sendRes(conn, id, { artifacts: items.map(strip) });
    return true;
  }
  items = items.filter((a) => a.type === 'image');
  let offset = 0;
  if (params.cursor !== undefined) {
    const cursor = fs.cursors.get(params.cursor);
    if (!cursor || cursor.sessionKey !== sessionKey) {
      return fail('artifact_cursor_invalid', 'Image cursor expired or belongs to another session; restart artifacts.list');
    }
    offset = cursor.offset;
  }
  const limit = params.limit ?? DEFAULT_IMAGE_PAGE;
  const page = items.slice(offset, offset + limit);
  const result = { artifacts: page.map(strip) };
  if (offset + limit < items.length) {
    const token = `cursor-${sessionKey.length}-${offset + limit}-${fs.cursors.size + 1}`;
    fs.cursors.set(token, { sessionKey, offset: offset + limit });
    result.nextCursor = token;
  }
  sendRes(conn, id, result);
  return true;
}
