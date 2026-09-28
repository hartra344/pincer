import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { TELEGRAM_CONFLICT, WHATSAPP_NOT_LINKED } from '../setup.mjs';
import { CHANNEL_LIFECYCLE_METHODS } from '../channels.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { port, png, started, message, invalid, enabled, again, nothing, one } = ctx;
  // Channel status and lifecycle (#31): Discord connected, Telegram degraded, WhatsApp logged out,
  // Slack disabled; channels.start/stop/logout need operator.admin and change status and health.
  process.env.MOCK_WEB_LOGIN = 'link';
  process.env.MOCK_WEB_LOGIN_WAIT_MS = '20';
  const lifecycleServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const lcUrl = `ws://127.0.0.1:${lifecycleServer.address().port}`;
    const reader = await connectClient(lcUrl, makeDevice(), 'dev-token');
    for (const m of ['channels.status', ...CHANNEL_LIFECYCLE_METHODS]) assert.ok(reader.hello.features.methods.includes(m), `advertises ${m}`);
    const account = (status, channel) => status.channelAccounts[channel][0];
    const seeded = await reader.send('channels.status', {});
    assert.deepEqual(seeded.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(seeded.channelLabels.telegram, 'Telegram');
    const discord = account(seeded, 'discord');
    assert.equal(discord.running, true);
    assert.equal(discord.connected, true);
    assert.ok(discord.lastInboundAt > 0 && discord.lastOutboundAt > 0, 'Discord has recent activity');
    const telegram = account(seeded, 'telegram');
    assert.deepEqual([telegram.enabled, telegram.configured, telegram.running, telegram.connected], [true, true, true, false]);
    assert.equal(telegram.lastError, TELEGRAM_CONFLICT);
    assert.equal(telegram.healthState, 'disconnected');
    assert.ok(telegram.reconnectAttempts > 0);
    assert.equal(seeded.channels.telegram.lastError, TELEGRAM_CONFLICT, 'channel summary carries the error');
    const whatsapp = account(seeded, 'whatsapp');
    assert.deepEqual([whatsapp.enabled, whatsapp.configured, whatsapp.linked, whatsapp.running], [true, false, false, false]);
    assert.deepEqual([account(seeded, 'slack').enabled, account(seeded, 'slack').configured], [false, false]);
    // Probing fails for the degraded account and passes for the healthy one.
    const probed = await reader.send('channels.status', { probe: true, timeoutMs: 1000 });
    assert.deepEqual(account(probed, 'telegram').probe, { ok: false, error: TELEGRAM_CONFLICT, elapsedMs: 212 });
    assert.equal(account(probed, 'discord').probe.ok, true);
    assert.ok(account(probed, 'telegram').lastProbeAt > 0);
    assert.equal(account(probed, 'whatsapp').probe, undefined, 'unconfigured accounts are not probed');
    assert.equal(account(await reader.send('channels.status', {}), 'telegram').probe, undefined, 'plain status has no probe');
    // Health agrees with channels.status.
    const seededHealth = await reader.send('health');
    assert.deepEqual(seededHealth.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(seededHealth.channels.telegram.lastError, TELEGRAM_CONFLICT);
    assert.equal(seededHealth.channels.telegram.lifecycle, 'recovering');
    assert.equal(seededHealth.channels.telegram.accounts.default.connected, false);
    // Lifecycle needs operator.admin.
    for (const method of CHANNEL_LIFECYCLE_METHODS) {
      const denied = await reader.call(method, { channel: 'telegram' });
      assert.equal(denied.error.code, 'FORBIDDEN', method);
      assert.deepEqual(denied.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }
    assert.equal(account(await reader.send('channels.status', {}), 'telegram').running, true, 'denied calls change nothing');

    const admin = await connectClient(lcUrl, makeDevice(), 'dev-token', true, [...BASE_SCOPES, 'operator.admin']);
    assert.equal((await admin.call('channels.start', {})).error.code, 'INVALID_REQUEST');
    assert.equal((await admin.call('channels.stop', { channel: 'telegram', nope: 1 })).error.code, 'INVALID_REQUEST');
    assert.equal((await admin.call('channels.start', { channel: 'irc' })).error.message, 'invalid channels.start channel');
    assert.equal((await admin.call('channels.logout', { channel: 'slack' })).error.message, 'channel slack does not support logout');
    assert.equal((await admin.call('channels.logout', { channel: 'discord' })).error.message, 'channel discord does not support logout');
    assert.equal((await admin.send('health')).channels.discord.running, true, 'an unsupported logout stops nothing');
    // Starting a running account is a no-op the Gateway reports as owned by its task.
    assert.deepEqual(await admin.send('channels.start', { channel: 'discord' }),
      { channel: 'discord', accountId: 'default', started: true, outcome: { status: 'retry', reason: 'task-owned' } });
    // Reconnect Account: stop, then start, clears Telegram's conflict.
    const stoppedEvent = admin.waitEvent('health', (p) => p.channels?.telegram?.running === false, 3000);
    assert.deepEqual(await admin.send('channels.stop', { channel: 'telegram' }), { channel: 'telegram', accountId: 'default', stopped: true });
    const stoppedHealth = await stoppedEvent;
    assert.equal(stoppedHealth.channels.telegram.lifecycle, 'stopped');
    const stopped = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([stopped.running, stopped.connected, stopped.lastError], [false, false, null]);
    assert.ok(stopped.lastStopAt > 0);
    assert.deepEqual(await admin.send('channels.stop', { channel: 'telegram', accountId: 'default' }),
      { channel: 'telegram', accountId: 'default', stopped: true }, 'stopping twice is fine');
    const startedEvent = admin.waitEvent('health', (p) => p.channels?.telegram?.connected === true, 3000);
    assert.deepEqual(await admin.send('channels.start', { channel: 'telegram' }),
      { channel: 'telegram', accountId: 'default', started: true, outcome: { status: 'handed-off' } });
    await startedEvent;
    const reconnected = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([reconnected.running, reconnected.connected, reconnected.lastError, reconnected.reconnectAttempts], [true, true, null, 0]);
    assert.equal(reconnected.healthState, 'healthy');
    // Unknown accounts: stop is a no-op, start is skipped.
    assert.deepEqual(await admin.send('channels.start', { channel: 'discord', accountId: 'ghost' }),
      { channel: 'discord', accountId: 'ghost', started: false, outcome: { status: 'skipped', reason: 'unconfigured' } });
    assert.deepEqual(await admin.send('channels.start', { channel: 'slack' }),
      { channel: 'slack', accountId: 'default', started: false, outcome: { status: 'skipped', reason: 'disabled' } });
    // WhatsApp needs a QR login before it can start; once linked, stop/start/logout work.
    assert.deepEqual(await admin.send('channels.start', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', started: false, outcome: { status: 'skipped', reason: 'unlinked' } });
    assert.match((await admin.send('web.login.start', { channel: 'whatsapp' })).qrDataUrl, /^data:image\/png;base64,/);
    assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).connected, true);
    assert.equal(account(await admin.send('channels.status', {}), 'whatsapp').connected, true);
    await admin.send('channels.stop', { channel: 'whatsapp' });
    const waStopped = account(await admin.send('channels.status', {}), 'whatsapp');
    assert.deepEqual([waStopped.linked, waStopped.running, waStopped.connected], [true, false, false]);
    assert.equal((await admin.send('channels.start', { channel: 'whatsapp' })).outcome.status, 'handed-off');
    assert.equal(account(await admin.send('channels.status', {}), 'whatsapp').running, true);
    const loggedOutEvent = admin.waitEvent('health', (p) => p.channels?.whatsapp?.linked === false, 3000);
    assert.deepEqual(await admin.send('channels.logout', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', cleared: true, loggedOut: true });
    await loggedOutEvent;
    const waOut = await admin.send('channels.status', {});
    assert.deepEqual([account(waOut, 'whatsapp').linked, account(waOut, 'whatsapp').running], [false, false]);
    assert.equal(waOut.statusIssues[0].message, WHATSAPP_NOT_LINKED, 'logged out WhatsApp needs the QR again');
    assert.deepEqual(await admin.send('channels.logout', { channel: 'whatsapp' }),
      { channel: 'whatsapp', accountId: 'default', cleared: false, loggedOut: false }, 'nothing left to clear');
    // Logging out a token channel clears its credentials: not configured, and start is skipped.
    assert.deepEqual(await admin.send('channels.logout', { channel: 'telegram' }),
      { channel: 'telegram', accountId: 'default', cleared: true, loggedOut: true });
    const tgOut = account(await admin.send('channels.status', {}), 'telegram');
    assert.deepEqual([tgOut.configured, tgOut.running, tgOut.tokenSource], [false, false, 'none']);
    assert.equal((await admin.send('channels.start', { channel: 'telegram' })).outcome.reason, 'unconfigured');
    // Discord stopped shows as stopped in health (a problem there) until started again.
    await admin.send('channels.stop', { channel: 'discord' });
    const discordStopped = await admin.send('health');
    assert.deepEqual([discordStopped.channels.discord.running, discordStopped.channels.discord.lifecycle], [false, 'stopped']);
    await admin.send('channels.start', { channel: 'discord' });
    assert.equal((await admin.send('health')).channels.discord.connected, true);
    reader.ws.close();
    admin.ws.close();
  } finally {
    delete process.env.MOCK_WEB_LOGIN;
    delete process.env.MOCK_WEB_LOGIN_WAIT_MS;
    await lifecycleServer.close();
  }
}
