import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { MCP_METHODS } from '../mcp.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// MCP server management on a fresh server so seeded state and sign-ins don't leak.
export async function run() {
  const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const port = server.address().port;
    const url = `ws://127.0.0.1:${port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    for (const method of MCP_METHODS) assert.ok(admin.hello.features.methods.includes(method), method);
    assert.ok(admin.hello.features.events.includes('mcp.oauth.changed') && admin.hello.features.events.includes('mcp.status.changed'));

    for (const [method, params] of [
      ['mcp.reconnect', {}],
      ['mcp.probe', { serverName: 'github' }],
      ['mcp.oauth.start', { serverName: 'linear', redirect: 'gateway' }],
      ['mcp.oauth.complete', { attemptId: 'x', code: 'y' }],
      ['mcp.oauth.cancel', { attemptId: 'x' }],
      ['mcp.oauth.logout', { serverName: 'linear' }],
    ]) {
      const gated = await reader.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }

    // config.get: seeded servers, secrets redacted, args left alone.
    const snapshot = await reader.send('config.get', {});
    const servers = snapshot.config.mcp.servers;
    assert.deepEqual(Object.keys(servers).sort(), ['acme.docs', 'filesystem', 'github', 'home-assistant', 'linear', 'notion', 'postgres', 'sentry']);
    assert.equal(servers['home-assistant'].env.HA_TOKEN, '__OPENCLAW_REDACTED__');
    assert.equal(servers.github.headers.Authorization, '__OPENCLAW_REDACTED__');
    assert.equal(servers.filesystem.env.LOG_LEVEL, '__OPENCLAW_REDACTED__');
    assert.deepEqual(servers.postgres.args.slice(0, 2), ['mcp-server-postgres', '--dsn']);

    // mcp.status: the seed table.
    const status = await reader.send('mcp.status', {});
    assert.equal(typeof status.generatedAt, 'number');
    const by = Object.fromEntries(status.servers.map((s) => [s.name, s]));
    assert.equal(status.servers.length, 8);
    assert.deepEqual([by.filesystem.state, by.filesystem.toolCount, by.filesystem.transport], ['connected', 4, 'stdio']);
    assert.deepEqual(by['home-assistant'].tools, ['get_state', 'call_service']);
    assert.equal(by.github.toolCount, 6);
    assert.equal(by.linear.state, 'idle');
    assert.deepEqual(by.linear.auth, { mode: 'oauth-shared', state: 'requires-authorization' });
    assert.equal(by.notion.lastError.message, 'OAuth token expired');
    assert.ok(by.notion.auth.expiresAt < Date.now());
    assert.equal(by.postgres.state, 'error');
    assert.equal(by.postgres.lastError.message, 'spawn uvx ENOENT');
    assert.deepEqual([by.sentry.state, by.sentry.enabled, by.sentry.transport], ['disabled', false, 'sse']);
    assert.deepEqual((await reader.send('mcp.status', { serverNames: ['github'] })).servers.map((s) => s.name), ['github']);
    assert.deepEqual((await reader.send('mcp.oauth.status', {})).servers.map((s) => s.name), ['linear', 'notion']);

    // mcp.probe: saved servers and unsaved drafts; nothing changes in the status table.
    const probeOk = await admin.send('mcp.probe', { serverName: 'github' });
    assert.equal(probeOk.ok, true);
    assert.equal(probeOk.tools.length, 6);
    const filtered = await admin.send('mcp.probe', { serverName: 'github', server: { url: 'https://x.test/mcp', transport: 'streamable-http', toolFilter: { include: ['get_issue'] } } });
    assert.deepEqual(filtered.tools, ['get_issue']);
    const unsignedIn = await admin.send('mcp.probe', { serverName: 'linear' });
    assert.equal(unsignedIn.ok, false);
    assert.equal(unsignedIn.auth.state, 'requires-authorization');
    const broken = await admin.send('mcp.probe', { serverName: 'new', server: { command: 'nonexistent-cmd' } });
    assert.deepEqual([broken.ok, broken.diagnostics[0].message], [false, 'spawn nonexistent-cmd ENOENT']);
    const pg = await admin.send('mcp.probe', { serverName: 'postgres' });
    assert.equal(pg.diagnostics.length, 3);
    const probeStart = Date.now();
    const slowProbe = await admin.send('mcp.probe', { serverName: 'home-assistant', timeoutMs: 15000 });
    assert.ok(slowProbe.ok && Date.now() - probeStart >= 1800);
    assert.equal((await admin.send('mcp.probe', { serverName: 'home-assistant', timeoutMs: 500 })).ok, false);
    const restored = await admin.send('mcp.probe', { serverName: 'github', server: { url: 'https://api.githubcopilot.com/mcp/', transport: 'streamable-http', headers: { Authorization: '__OPENCLAW_REDACTED__' } } });
    assert.deepEqual([restored.ok, restored.resources, restored.prompts], [true, 3, 2]);
    assert.equal((await admin.call('mcp.probe', { serverName: 'nope' })).error.code, 'INVALID_REQUEST');
    assert.equal((await reader.send('mcp.status', { serverNames: ['linear'] })).servers[0].state, 'idle');

    // plugins.inspect: plugin-declared MCP servers and their auth.
    const linearPlugin = await reader.send('plugins.inspect', { pluginId: 'linear' });
    assert.deepEqual(linearPlugin.declared.mcpServers, ['linear']);
    assert.deepEqual(linearPlugin.mcpAuth, [{ serverName: 'linear', state: 'requires-authorization' }]);
    const asanaPlugin = await reader.send('plugins.inspect', { pluginId: 'asana' });
    assert.deepEqual(asanaPlugin.components.unavailable.mcpServers, ['asana-beta']);
    assert.equal(asanaPlugin.mcpAuth, undefined);

    // tools.effective: tools of connected servers plus a diagnostic for the failing one.
    const eff = await reader.send('tools.effective', { sessionKey: 'agent:main:main' });
    const mcpTools = eff.groups.find((g) => g.source === 'mcp').tools;
    assert.ok(mcpTools.some((t) => t.mcpServer === 'filesystem' && t.mcpToolName === 'read_file'));
    assert.ok(!mcpTools.some((t) => ['linear', 'postgres', 'sentry'].includes(t.mcpServer)));
    const diagnostic = eff.notices.find((n) => n.id === 'mcp-server-diagnostic:postgres');
    assert.deepEqual([diagnostic.severity, diagnostic.message, diagnostic.servers], ['warning', 'spawn uvx ENOENT', ['postgres']]);

    // Errors.
    assert.equal((await admin.call('mcp.oauth.start', { serverName: 'nope', redirect: 'gateway' })).error.message, 'unknown MCP server: nope');
    assert.equal((await admin.call('mcp.oauth.start', { serverName: 'github', redirect: 'gateway' })).error.message, 'MCP server github does not use OAuth');
    assert.equal((await admin.call('mcp.reconnect', { serverNames: ['nope'] })).error.code, 'INVALID_REQUEST');
    assert.equal((await admin.call('mcp.oauth.complete', { attemptId: 'nope', code: 'x' })).error.code, 'INVALID_REQUEST');

    // reconnect: connecting, then connected; postgres stays in error.
    const changed = admin.waitEvent('mcp.status.changed', (p) => p.servers?.includes('filesystem'));
    assert.deepEqual((await admin.send('mcp.reconnect', { serverNames: ['filesystem', 'postgres'] })).disposed, ['filesystem', 'postgres']);
    await changed;
    assert.equal((await reader.send('mcp.status', { serverNames: ['filesystem'] })).servers[0].state, 'connecting');
    await waitFor(async () => (await reader.send('mcp.status', { serverNames: ['filesystem', 'postgres'] })).servers.map((s) => s.state).join() === 'connected,error');

    // OAuth over HTTP: authorize page, callback with Allow, redirect to the return URL.
    const started = await admin.send('mcp.oauth.start', { serverName: 'linear', redirect: 'gateway', returnUrl: 'pincer://mcp-oauth/done?server=linear' });
    assert.ok(started.authorizationUrl.startsWith(`http://127.0.0.1:${port}/mcp-oauth/authorize?attempt=${started.attemptId}`));
    assert.equal(started.redirectUrl, `http://127.0.0.1:${port}/mcp-oauth/callback`);
    assert.equal((await reader.send('mcp.oauth.status', { serverNames: ['linear'] })).servers[0].state, 'pending-authorization');
    const consent = await fetch(started.authorizationUrl);
    assert.match(await consent.text(), /Authorize Pincer Mock for linear/);
    const authorized = admin.waitEvent('mcp.oauth.changed', (p) => p.serverName === 'linear' && p.state === 'authorized');
    const callback = await fetch(`${started.redirectUrl}?attempt=${started.attemptId}&code=mock-code`, { redirect: 'manual' });
    assert.equal(callback.status, 302);
    assert.equal(callback.headers.get('location'), 'pincer://mcp-oauth/done?server=linear&state=authorized');
    assert.equal((await authorized).account, 'demo@pincer.app');
    await waitFor(async () => (await reader.send('mcp.status', { serverNames: ['linear'] })).servers[0].state === 'connected');
    const linear = (await reader.send('mcp.status', { serverNames: ['linear'] })).servers[0];
    assert.deepEqual([linear.toolCount, linear.auth.state, linear.auth.account], [5, 'authorized', 'demo@pincer.app']);
    assert.equal((await fetch(`${started.redirectUrl}?attempt=${started.attemptId}&code=mock-code`)).status, 400);

    // Deny, manual complete, cancel, logout.
    const denied = await admin.send('mcp.oauth.start', { serverName: 'notion', redirect: 'gateway' });
    const denial = await fetch(`${denied.redirectUrl}?attempt=${denied.attemptId}&error=access_denied`);
    assert.equal(denial.status, 200);
    assert.equal((await reader.send('mcp.oauth.status', { serverNames: ['notion'] })).servers[0].state, 'requires-authorization');
    const manual = await admin.send('mcp.oauth.start', { serverName: 'notion', redirect: 'gateway' });
    assert.equal((await admin.call('mcp.oauth.complete', { attemptId: manual.attemptId })).error.message, 'missing authorization code');
    assert.deepEqual(await admin.send('mcp.oauth.complete', { attemptId: manual.attemptId, code: 'demo' }), { state: 'authorized', account: 'demo@pincer.app' });
    assert.deepEqual(await admin.send('mcp.oauth.cancel', { attemptId: manual.attemptId }), { cancelled: false });
    const toCancel = await admin.send('mcp.oauth.start', { serverName: 'linear', redirect: 'gateway' });
    assert.deepEqual(await admin.send('mcp.oauth.cancel', { attemptId: toCancel.attemptId }), { cancelled: true });
    assert.deepEqual(await admin.send('mcp.oauth.logout', { serverName: 'linear' }), { cleared: false });
    const relinked = await admin.send('mcp.oauth.start', { serverName: 'linear', redirect: 'gateway' });
    await admin.send('mcp.oauth.complete', { attemptId: relinked.attemptId, code: 'x' });
    assert.deepEqual(await admin.send('mcp.oauth.logout', { serverName: 'linear' }), { cleared: true });
    assert.equal((await reader.send('mcp.oauth.status', { serverNames: ['linear'] })).servers[0].state, 'requires-authorization');

    // config.patch: add, disable, delete; `disabled` and bad names are rejected.
    const patch = async (mcp) => {
      const { hash } = await admin.send('config.get', {});
      return admin.call('config.patch', { raw: JSON.stringify({ mcp: { servers: mcp } }), baseHash: hash });
    };
    assert.equal((await patch({ echo: { command: 'node', args: ['echo.js'], env: { TOKEN: 'abc' } } })).ok, true);
    assert.equal((await reader.send('mcp.status', { serverNames: ['echo'] })).servers[0].state, 'connecting');
    await waitFor(async () => (await reader.send('mcp.status', { serverNames: ['echo'] })).servers[0].state === 'connected');
    assert.deepEqual((await reader.send('mcp.status', { serverNames: ['echo'] })).servers[0].tools, ['echo', 'ping', 'time']);
    assert.equal((await reader.send('config.get', {})).config.mcp.servers.echo.env.TOKEN, '__OPENCLAW_REDACTED__');
    assert.equal((await patch({ echo: { env: { TOKEN: '__OPENCLAW_REDACTED__' }, enabled: false } })).ok, true);
    assert.equal((await reader.send('mcp.status', { serverNames: ['echo'] })).servers[0].state, 'disabled');
    assert.equal((await patch({ echo: { disabled: true } })).error.code, 'INVALID_REQUEST');
    assert.equal((await patch({ 'bad name': { command: 'x' } })).error.code, 'INVALID_REQUEST');
    assert.equal((await patch({ renamed: { env: { TOKEN: '__OPENCLAW_REDACTED__' }, command: 'x' } })).error.code, 'INVALID_REQUEST');
    assert.equal((await patch({ echo: null })).ok, true);
    assert.ok(!(await reader.send('mcp.status', {})).servers.some((s) => s.name === 'echo'));
    assert.equal((await patch({ empty: { enabled: true } })).ok, true);
    assert.equal((await reader.send('mcp.status', { serverNames: ['empty'] })).servers[0].state, 'invalid');
    await patch({ empty: null });
    admin.ws.close();
    reader.ws.close();
  } finally {
    await server.close();
  }
}

async function waitFor(check, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('timed out waiting for condition');
}
