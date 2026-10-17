import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { CLOCK_SESSION_KEY, OWNED_ENVIRONMENT_ID, OWNED_SESSION_KEY, PORTAL_EVENTS, PORTAL_METHODS, SECOND_PORTAL_TITLE, SEED_PORTAL_TITLE, SESSION_PORTAL_METHODS } from '../portals.mjs';
import { makeDevice, connectClient } from './helpers.mjs';

// Portals on a fresh server so the seeded portal and its HTTP listener don't leak.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${server.address().port}`;
    const writer = await connectClient(url, makeDevice(), 'dev-token');
    const reader = await connectClient(url, makeDevice(), 'dev-token', true, ['operator.read']);
    for (const method of PORTAL_METHODS) assert.ok(writer.hello.features.methods.includes(method), method);
    for (const event of PORTAL_EVENTS) assert.ok(writer.hello.features.events.includes(event), event);
    assert.ok(!writer.hello.features.methods.includes('portal.open'), 'Pincer never opens portals');

    const { portals } = await writer.send('portal.list', {});
    assert.equal(portals.length, 2);
    const [portal, second] = portals;
    assert.equal(second.title, SECOND_PORTAL_TITLE);
    assert.notEqual(second.listenPort, portal.listenPort);
    assert.notEqual(second.tokenQuery, portal.tokenQuery);
    assert.equal(second.exposure.kind, 'non-loopback');
    assert.equal(portal.title, SEED_PORTAL_TITLE);
    assert.equal(typeof portal.id, 'string');
    assert.equal(typeof portal.port, 'number');
    assert.equal(typeof portal.listenPort, 'number');
    assert.equal(typeof portal.createdAtMs, 'number');
    assert.deepEqual(portal.exposure, { kind: 'non-loopback', browserReachability: 'unverified' });
    assert.equal(portal.path, '/');
    assert.ok(portal.description);
    assert.equal(portal.publicUrl, `http://127.0.0.1:${portal.listenPort}/`);
    assert.match(portal.tokenQuery, /^openclaw_portal=.+/);
    assert.equal(portal.url, `${portal.publicUrl}?${portal.tokenQuery}`);
    assert.ok(!portal.publicUrl.includes('openclaw_portal'));

    // Read-only connections get the same summary without url/tokenQuery.
    const redacted = (await reader.send('portal.list', {})).portals[0];
    assert.equal(redacted.id, portal.id);
    assert.equal(redacted.publicUrl, portal.publicUrl);
    assert.ok(!('url' in redacted) && !('tokenQuery' in redacted));
    const gated = await reader.call('portal.close', { id: portal.id });
    assert.equal(gated.error.code, 'FORBIDDEN');
    assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.write' });

    // Token → cookie → 200; no token or a wrong token → 401.
    const withToken = await fetch(portal.url);
    assert.equal(withToken.status, 200);
    assert.match(await withToken.text(), /Studio clock/);
    const cookie = withToken.headers.get('set-cookie');
    assert.match(cookie, new RegExp(`^openclaw_portal_${portal.listenPort}=[^;]+; HttpOnly; SameSite=Lax; Path=/$`));
    const viaCookie = await fetch(portal.publicUrl, { headers: { cookie: cookie.split(';')[0] } });
    assert.equal(viaCookie.status, 200);
    assert.equal(viaCookie.headers.get('set-cookie'), null);
    assert.equal((await fetch(portal.publicUrl)).status, 401);
    assert.equal((await fetch(`${portal.publicUrl}?openclaw_portal=wrong`)).status, 401);

    // A portal's cookie never opens another portal, even renamed to the other's cookie name.
    const firstCookie = cookie.split(';')[0];
    assert.equal((await fetch(second.publicUrl, { headers: { cookie: firstCookie } })).status, 401);
    const renamed = `openclaw_portal_${second.listenPort}=${firstCookie.split('=')[1]}`;
    assert.equal((await fetch(second.publicUrl, { headers: { cookie: renamed } })).status, 401);
    assert.equal((await fetch(second.url)).status, 200);

    // /redirect-out 302s to example.com, behind the same token/cookie check.
    const out = await fetch(`${portal.publicUrl}redirect-out`, { redirect: 'manual', headers: { cookie: firstCookie } });
    assert.equal(out.status, 302);
    assert.equal(out.headers.get('location'), 'http://example.com/');
    assert.equal((await fetch(`${portal.url.replace('/?', '/redirect-out?')}`, { redirect: 'manual' })).status, 302);
    assert.equal((await fetch(`${portal.publicUrl}redirect-out`, { redirect: 'manual' })).status, 401);

    // Scoping (#1029): the clock is attributed by a `portal` tool call in one chat; the dashboard is owned by a session.
    for (const method of SESSION_PORTAL_METHODS) assert.ok(writer.hello.features.methods.includes(method), method);
    const history = (await writer.send('chat.history', { sessionKey: CLOCK_SESSION_KEY })).messages;
    const call = history.flatMap((m) => (Array.isArray(m.content) ? m.content : [])).find((b) => b.type === 'toolCall' && b.name === 'dispatch_action');
    assert.equal(call.arguments.id, 'openclaw:core:portal');
    assert.equal(call.arguments.args.action, 'open');
    const opened = history.find((m) => m.role === 'toolResult' && m.toolName === 'dispatch_action');
    const envelope = JSON.parse(opened.content[0].text);
    assert.equal(envelope.tool.name, 'portal');
    assert.match(envelope.result.content[0].text, /^Portal route allocated at /);
    assert.equal(JSON.parse(envelope.result.content[1].text).id, portal.id);
    assert.equal(opened.details, undefined);
    assert.ok(history.some((m) => m.role === 'custom' && m.customType === 'openclaw.nested-tool.v1'));
    const other = (await writer.send('chat.history', { sessionKey: 'agent:main:main' })).messages;
    assert.ok(!JSON.stringify(other).includes('"portal"'), 'another agent never opened a portal');
    assert.deepEqual(await writer.send('environments.session.status', { sessionKey: 'agent:main:main' }), { attachment: null });
    const status = await writer.send('environments.session.status', { sessionKey: OWNED_SESSION_KEY });
    assert.equal(status.attachment.environmentId, OWNED_ENVIRONMENT_ID);
    assert.equal(status.closed, false);
    const ownedList = (await writer.send('portal.session.list', { sessionKey: OWNED_SESSION_KEY, environmentId: OWNED_ENVIRONMENT_ID })).portals;
    assert.deepEqual(ownedList.map((p) => p.id), [second.id]);
    assert.ok(ownedList[0].url, 'the owner list is unredacted for a writer');
    await assert.rejects(writer.send('portal.session.list', { sessionKey: 'agent:main:main', environmentId: OWNED_ENVIRONMENT_ID }));
    assert.deepEqual(await writer.send('portal.session.close', { id: second.id, sessionKey: CLOCK_SESSION_KEY, environmentId: OWNED_ENVIRONMENT_ID }).catch(() => 'rejected'), 'rejected');
    assert.equal((await reader.call('portal.session.close', { id: second.id, sessionKey: OWNED_SESSION_KEY, environmentId: OWNED_ENVIRONMENT_ID })).ok, false);

    // Close: gone, and a redacted portal.changed reaches every connection.
    const changed = reader.waitEvent('portal.changed');
    assert.deepEqual(await writer.send('portal.close', { id: portal.id }), { closed: true });
    const after = (await changed).portals;
    assert.deepEqual(after.map((p) => p.id), [second.id]);
    assert.ok(after.every((p) => !('url' in p)));
    assert.deepEqual((await writer.send('portal.list', {})).portals.map((p) => p.id), [second.id]);
    assert.deepEqual(await writer.send('portal.close', { id: portal.id }), { closed: false });
    await assert.rejects(fetch(portal.url), 'the portal listener stops with the portal');
    const ownedChanged = reader.waitEvent('portal.changed');
    assert.deepEqual(await writer.send('portal.session.close', { id: second.id, sessionKey: OWNED_SESSION_KEY, environmentId: OWNED_ENVIRONMENT_ID }), { closed: true });
    assert.deepEqual((await ownedChanged).portals, []);
    assert.deepEqual((await writer.send('portal.session.list', { sessionKey: OWNED_SESSION_KEY, environmentId: OWNED_ENVIRONMENT_ID })).portals, []);

    writer.ws.close();
    reader.ws.close();
  } finally {
    await server.close();
  }

  // MOCK_PORTAL_LOOPBACK=1: the first portal reports loopback-only.
  process.env.MOCK_PORTAL_LOOPBACK = '1';
  const loop = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${loop.address().port}`, makeDevice(), 'dev-token');
    const kinds = (await client.send('portal.list', {})).portals.map((p) => p.exposure.kind);
    assert.deepEqual(kinds, ['loopback-only', 'non-loopback']);
    client.ws.close();
  } finally {
    delete process.env.MOCK_PORTAL_LOOPBACK;
    await loop.close();
  }

  // MOCK_NO_PORTALS=1 hides the methods like an older Gateway.
  process.env.MOCK_NO_PORTALS = '1';
  const off = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${off.address().port}`, makeDevice(), 'dev-token');
    for (const method of PORTAL_METHODS) assert.ok(!client.hello.features.methods.includes(method), method);
    client.ws.close();
  } finally {
    delete process.env.MOCK_NO_PORTALS;
    await off.close();
  }

  // MOCK_NO_SESSION_PORTALS=1 drops the 2026.9 session methods but keeps portal.list/portal.close.
  process.env.MOCK_NO_SESSION_PORTALS = '1';
  const legacy = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${legacy.address().port}`, makeDevice(), 'dev-token');
    for (const method of SESSION_PORTAL_METHODS) assert.ok(!client.hello.features.methods.includes(method), method);
    for (const method of PORTAL_METHODS) assert.ok(client.hello.features.methods.includes(method), method);
    client.ws.close();
  } finally {
    delete process.env.MOCK_NO_SESSION_PORTALS;
    await legacy.close();
  }
}
