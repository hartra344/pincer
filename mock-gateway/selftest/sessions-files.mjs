import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { startServer } from '../server.mjs';
import { SESSION_FILES_METHODS, SESSION_FILES_ROOT, PREVIEW_MAX_BYTES, VOLATILE_PATH } from '../sessions-files.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

const KEY = 'agent:main:main';
const sha = (text) => crypto.createHash('sha256').update(text).digest('hex');

async function withServer(env, body) {
  for (const [k, v] of Object.entries(env)) process.env[k] = v;
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    await body({ admin, reader });
    admin.ws.close();
    reader.ws.close();
  } finally {
    for (const k of Object.keys(env)) delete process.env[k];
    await server.close();
  }
}

function invalid(res, type) {
  assert.equal(res.ok, false);
  assert.equal(res.error.code, 'INVALID_REQUEST');
  if (type) assert.equal(res.error.details?.type, type);
  return res.error;
}

export async function run() {
  await withServer({}, async ({ admin, reader }) => {
    for (const method of SESSION_FILES_METHODS) assert.ok(reader.hello.features.methods.includes(method), method);

    // Closed params.
    assert.match(invalid(await reader.call('sessions.files.list', {})).message, /must have required property 'sessionKey'/);
    assert.match(invalid(await reader.call('sessions.files.list', { sessionKey: KEY, nope: 1 })).message, /unexpected property 'nope'/);
    assert.match(invalid(await reader.call('sessions.files.get', { sessionKey: KEY, path: '' })).message, /fewer than 1/);
    // Unknown sessions: an empty list, session_file_not_found for get/set, and no artifacts.
    assert.deepEqual((await reader.send('sessions.files.list', { sessionKey: 'agent:main:ghost' })), { sessionKey: 'agent:main:ghost', files: [] });
    const ghostGet = invalid(await reader.call('sessions.files.get', { sessionKey: 'agent:main:ghost', path: 'a' }), 'session_file_not_found');
    assert.deepEqual(ghostGet.details, { type: 'session_file_not_found', path: 'a' });
    invalid(await admin.call('sessions.files.set', { sessionKey: 'agent:main:ghost', path: 'a', content: 'x', expectedHash: sha('') }), 'session_file_not_found');
    assert.deepEqual(await reader.send('artifacts.list', { sessionKey: 'agent:main:ghost' }), { artifacts: [] });

    // list: touched files, then the browser.
    const list = (await reader.send('sessions.files.list', { sessionKey: KEY }));
    assert.equal(list.sessionKey, KEY);
    assert.equal(list.root, SESSION_FILES_ROOT);
    const kinds = list.files.map((f) => f.kind);
    assert.deepEqual(kinds, [...kinds].sort((a, b) => (a === b ? 0 : a === 'modified' ? -1 : 1)));
    const legacy = list.files.find((f) => f.path === 'src/lib/legacy.ts');
    assert.deepEqual(legacy, { path: 'src/lib/legacy.ts', name: 'legacy.ts', kind: 'read', missing: true });
    const index = list.files.find((f) => f.path === 'src/index.ts');
    assert.equal(index.kind, 'modified');
    assert.equal(index.missing, false);
    assert.equal(typeof index.size, 'number');
    assert.equal(list.browser.path, '');
    assert.equal(list.browser.parentPath, undefined);
    assert.equal(list.browser.entries[0].kind, 'directory');
    const src = list.browser.entries.find((e) => e.name === 'src');
    assert.equal(src.sessionKind, 'mixed');
    assert.equal(list.browser.entries.find((e) => e.name === 'docs').sessionKind, 'read');
    assert.equal(list.browser.entries.find((e) => e.name === 'assets').sessionKind, 'read');

    const nested = (await reader.send('sessions.files.list', { sessionKey: KEY, path: 'src/lib' })).browser;
    assert.equal(nested.parentPath, 'src');
    assert.deepEqual(nested.entries.map((e) => e.name), ['format.test.ts', 'format.ts']);
    assert.equal((await reader.send('sessions.files.list', { sessionKey: KEY, path: 'src' })).browser.parentPath, '');
    assert.equal((await reader.send('sessions.files.list', { sessionKey: KEY, path: 'nope' })).browser, undefined);
    const search = (await reader.send('sessions.files.list', { sessionKey: KEY, search: ' FORMAT ' })).browser;
    assert.equal(search.search, 'FORMAT');
    assert.deepEqual(search.entries.map((e) => e.path), ['src/lib/format.test.ts', 'src/lib/format.ts']);

    // get: text, image, binary, large, missing, outside the root.
    const text = (await reader.send('sessions.files.get', { sessionKey: KEY, path: 'src/index.ts' })).file;
    assert.equal(text.previewKind, 'text');
    assert.equal(text.contentEncoding, 'utf8');
    assert.equal(text.hash, sha(text.content));
    assert.equal(text.kind, 'modified');
    const image = (await reader.send('sessions.files.get', { sessionKey: KEY, path: 'assets/logo.png' })).file;
    assert.equal(image.previewKind, 'image');
    assert.equal(image.mimeType, 'image/png');
    assert.equal(image.contentEncoding, 'base64');
    assert.equal(image.hash, undefined);
    const bin = (await reader.send('sessions.files.get', { sessionKey: KEY, path: 'assets/hosts.bin' })).file;
    assert.equal(bin.previewKind, 'unsupported');
    assert.equal(bin.content, undefined);
    const big = invalid(await reader.call('sessions.files.get', { sessionKey: KEY, path: 'logs/build.log' }), 'session_file_too_large');
    assert.equal(big.message, 'session file is too large to preview');
    assert.equal(big.details.maxPreviewBytes, PREVIEW_MAX_BYTES);
    assert.ok(big.details.size > PREVIEW_MAX_BYTES);
    const missing = invalid(await reader.call('sessions.files.get', { sessionKey: KEY, path: 'src/lib/legacy.ts' }), 'session_file_not_found');
    assert.equal(missing.message, 'session file not found');
    const outside = invalid(await reader.call('sessions.files.get', { sessionKey: KEY, path: '../secrets.txt' }), 'session_file_not_found');
    assert.equal(outside.details.reason, 'outside_session_boundary');
    const license = (await reader.send('sessions.files.get', { sessionKey: KEY, path: 'LICENSE' })).file;
    assert.equal(license.hash, undefined);

    // set: scope, params, success, conflict and the error ladder.
    const denied = await reader.call('sessions.files.set', { sessionKey: KEY, path: 'src/index.ts', content: 'x', expectedHash: text.hash });
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    assert.match(invalid(await admin.call('sessions.files.set', { sessionKey: KEY, path: 'src/index.ts', content: 'x', expectedHash: 'ABC' })).message, /at \/expectedHash: must match pattern/);
    const saved = (await admin.send('sessions.files.set', { sessionKey: KEY, path: 'src/index.ts', content: 'export {};\n', expectedHash: text.hash }));
    assert.equal(saved.file.hash, sha('export {};\n'));
    assert.equal(saved.file.kind, 'modified');
    assert.equal(saved.file.size, 11);
    const stale = invalid(await admin.call('sessions.files.set', { sessionKey: KEY, path: 'src/index.ts', content: 'y', expectedHash: text.hash }), 'session_file_conflict');
    assert.equal(stale.message, 'session file changed since it was read');
    assert.equal(stale.details.currentHash, saved.file.hash);
    const attempt = (content, path = 'src/index.ts') => admin.call('sessions.files.set', { sessionKey: KEY, path, content, expectedHash: saved.file.hash });
    assert.equal(invalid(await attempt('a\0b'), 'session_file_unsafe').message, 'session file could not be written safely');
    const tooLarge = invalid(await attempt('a'.repeat(PREVIEW_MAX_BYTES + 1)), 'session_file_too_large');
    assert.equal(tooLarge.message, 'session file content is too large');
    invalid(await attempt('x', 'LICENSE'), 'session_file_unsafe');
    invalid(await attempt('x', 'src/lib/legacy.ts'), 'session_file_not_found');
    invalid(await attempt('x', '../etc/passwd'), 'session_file_not_found');

    // The volatile file changes behind the client's back after every read.
    const v1 = (await reader.send('sessions.files.get', { sessionKey: KEY, path: VOLATILE_PATH })).file;
    const conflict = invalid(await admin.call('sessions.files.set', { sessionKey: KEY, path: VOLATILE_PATH, content: 'mine', expectedHash: v1.hash }), 'session_file_conflict');
    assert.notEqual(conflict.details.currentHash, v1.hash);

    // artifacts.list.
    assert.equal(invalid(await reader.call('artifacts.list', {}), 'artifact_query_unsupported').message, 'artifacts require sessionKey or runId');
    assert.equal(invalid(await reader.call('artifacts.list', { sessionKey: KEY, limit: 2 }), 'artifact_query_unsupported').message, 'limit and cursor require type image');
    assert.equal(invalid(await reader.call('artifacts.list', { runId: 'nope' }), 'artifact_scope_not_found').message, 'no session found for artifact query');
    assert.match(invalid(await reader.call('artifacts.list', { sessionKey: KEY, type: 'image', limit: 5 })).message, /at \/limit: must be <= 4/);
    const all = (await reader.send('artifacts.list', { sessionKey: KEY })).artifacts;
    assert.ok(all.some((a) => a.type === 'file'));
    for (const a of all) {
      assert.equal(a.source, 'session-transcript');
      assert.equal(a.image, undefined);
      assert.ok(['bytes', 'url', 'unsupported'].includes(a.download.mode));
    }
    const page1 = (await reader.send('artifacts.list', { sessionKey: KEY, type: 'image', limit: 2 }));
    assert.equal(page1.artifacts.length, 2);
    assert.ok(page1.nextCursor);
    assert.match(page1.artifacts[0].image.url, /^data:image\/png;base64,/);
    const page2 = (await reader.send('artifacts.list', { sessionKey: KEY, type: 'image', limit: 2, cursor: page1.nextCursor }));
    assert.equal(page2.artifacts.length, 1);
    assert.equal(page2.nextCursor, undefined);
    assert.equal(invalid(await reader.call('artifacts.list', { sessionKey: KEY, type: 'image', cursor: 'bogus' }), 'artifact_cursor_invalid').message,
      'Image cursor expired or belongs to another session; restart artifacts.list');
  });

  // MOCK_FILES_DRIFT: the first read of each file is followed by a change.
  await withServer({ MOCK_FILES_DRIFT: '1' }, async ({ admin }) => {
    const file = (await admin.send('sessions.files.get', { sessionKey: KEY, path: 'package.json' })).file;
    const conflict = invalid(await admin.call('sessions.files.set', { sessionKey: KEY, path: 'package.json', content: '{}', expectedHash: file.hash }), 'session_file_conflict');
    const fresh = (await admin.send('sessions.files.get', { sessionKey: KEY, path: 'package.json' })).file;
    assert.equal(fresh.hash, conflict.details.currentHash);
    await admin.send('sessions.files.set', { sessionKey: KEY, path: 'package.json', content: '{}', expectedHash: fresh.hash });
  });

  // MOCK_NO_SESSION_FILES: methods are hidden and unknown.
  await withServer({ MOCK_NO_SESSION_FILES: '1' }, async ({ reader }) => {
    for (const method of SESSION_FILES_METHODS) assert.ok(!reader.hello.features.methods.includes(method), method);
    const res = await reader.call('sessions.files.list', { sessionKey: KEY });
    assert.equal(res.ok, false);
    assert.equal(res.error.code, 'UNKNOWN_METHOD');
  });
}
