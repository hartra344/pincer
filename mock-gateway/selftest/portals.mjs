import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { PORTAL_EVENTS, PORTAL_METHODS, SECOND_PORTAL_TITLE, SEED_PORTAL_TITLE } from '../portals.mjs';
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

    // Close: gone, and a redacted portal.changed reaches every connection.
    const changed = reader.waitEvent('portal.changed');
    assert.deepEqual(await writer.send('portal.close', { id: portal.id }), { closed: true });
    const after = (await changed).portals;
    assert.deepEqual(after.map((p) => p.id), [second.id]);
    assert.ok(after.every((p) => !('url' in p)));
    assert.deepEqual((await writer.send('portal.list', {})).portals.map((p) => p.id), [second.id]);
    assert.deepEqual(await writer.send('portal.close', { id: portal.id }), { closed: false });
    await assert.rejects(fetch(portal.url), 'the portal listener stops with the portal');

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
}
