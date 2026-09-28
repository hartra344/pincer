import assert from 'node:assert/strict';
import { startServer } from '../server.mjs';
import { WHATSAPP_NOT_LINKED, WHATSAPP_RELINK_FIX } from '../setup.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { port, first, agents, message, unknown, always, schema, bundled, status, one } = ctx;
  // Setup wizard: channels.status (WhatsApp not linked), skills.status (one missing CLI) and
  // WhatsApp QR login over web.login.* (admin only, not advertised).
  process.env.MOCK_WEB_LOGIN_WAIT_MS = '50';
  const setupServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const setupUrl = `ws://127.0.0.1:${setupServer.address().port}`;
    const setupAdminScopes = [...BASE_SCOPES, 'operator.admin'];
    const reader = await connectClient(setupUrl, makeDevice(), 'dev-token');
    const methods = reader.hello.features.methods;
    for (const m of ['health', 'status', 'config.schema', 'config.patch', 'channels.status', 'skills.status', 'agents.list', 'models.list', 'chat.send']) {
      assert.ok(methods.includes(m), `advertises ${m}`);
    }
    assert.ok(!methods.includes('web.login.start') && !methods.includes('web.login.wait'), 'web.login.* is not advertised');

    const channels = await reader.send('channels.status', { probe: false });
    assert.deepEqual(channels.channelOrder, ['discord', 'telegram', 'whatsapp', 'slack']);
    assert.equal(channels.channelLabels.whatsapp, 'WhatsApp');
    assert.equal(channels.channelDefaultAccountId.discord, 'default');
    assert.equal(channels.channelAccounts.discord[0].connected, true);
    assert.equal(channels.channels.discord.connected, true);
    const wa = channels.channelAccounts.whatsapp[0];
    assert.equal(wa.accountId, 'default');
    assert.equal(wa.linked, false);
    assert.equal(wa.configured, false);
    assert.equal(channels.channelAccounts.slack[0].configured, false);
    assert.deepEqual(channels.statusIssues, [{ channel: 'whatsapp', accountId: 'default', kind: 'auth', message: WHATSAPP_NOT_LINKED, fix: WHATSAPP_RELINK_FIX }]);
    const probed = await reader.send('channels.status', { probe: true, timeoutMs: 1000, channel: 'discord' });
    assert.deepEqual(probed.channelOrder, ['discord']);
    assert.ok(probed.channelAccounts.discord[0].lastProbeAt > 0);
    assert.equal((await reader.call('channels.status', { channel: 'irc' })).error.message, 'unknown channel: irc');
    assert.equal((await reader.call('channels.status', { nope: 1 })).error.code, 'INVALID_REQUEST');
    // Health agrees: WhatsApp isn't configured yet, so it isn't a problem there.
    const setupHealth = await reader.send('health');
    assert.equal(setupHealth.channels.whatsapp.configured, false);
    assert.equal(setupHealth.channels.whatsapp.accounts.default.linked, false);

    // The wizard reads the same skills.status as the Skills page (skills.mjs).
    const skills = await reader.send('skills.status', {});
    assert.equal(skills.agentId, 'main');
    assert.ok(skills.workspaceDir && skills.managedSkillsDir);
    const missing = skills.skills.filter((s) => !s.eligible && !s.disabled && !s.blockedByAllowlist && !s.blockedByAgentFilter && !s.platformIncompatible);
    assert.deepEqual(missing.map((s) => s.name), ['github', 'video-frames', 'notion', 'voice-call']);
    assert.deepEqual(missing[0].missing, { bins: ['gh'], anyBins: [], env: [], config: [], os: [] });
    assert.deepEqual(missing[0].install, [{ id: 'brew', kind: 'brew', label: 'Install GitHub CLI (brew)', bins: ['gh'] }]);
    const otherOS = skills.skills.find((s) => s.name === 'apt-updates');
    assert.equal(otherOS.platformIncompatible, true);
    assert.deepEqual(otherOS.install, []);
    assert.ok(skills.skills.filter((s) => s.eligible).length >= 3);
    for (const s of skills.skills) {
      for (const key of ['name', 'description', 'source', 'bundled', 'filePath', 'baseDir', 'skillKey', 'always', 'disabled', 'modelVisible', 'userInvocable', 'commandVisible', 'requirements', 'configChecks']) {
        assert.ok(key in s, `skill ${s.name} has ${key}`);
      }
    }
    assert.equal((await reader.send('skills.status', { agentId: 'coder' })).agentId, 'coder');
    assert.equal((await reader.call('skills.status', { agentId: 'ghost' })).error.message, 'unknown agent id "ghost"');
    assert.equal((await reader.call('skills.status', { sessionKey: 'agent:main:nope' })).error.message, 'Session not found.');

    const denied = await reader.call('web.login.start', { channel: 'whatsapp' });
    assert.equal(denied.error.code, 'FORBIDDEN');
    assert.equal(denied.error.details.code, 'MISSING_SCOPE');
    assert.equal((await reader.call('web.login.wait', {})).error.details.scope, 'operator.admin');
    reader.ws.close();

    const admin = await connectClient(setupUrl, makeDevice(), 'dev-token', true, setupAdminScopes);
    assert.equal((await admin.call('web.login.start', { channel: 'discord' })).error.message, 'web login is not supported by provider discord');
    assert.equal((await admin.call('web.login.start', { channel: 'irc' })).error.message, 'web login provider is not available');
    assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).message, 'No active WhatsApp login in progress.');
    const start = await admin.send('web.login.start', { channel: 'whatsapp', force: false, timeoutMs: 30000 });
    assert.match(start.qrDataUrl, /^data:image\/png;base64,/);
    assert.ok(start.qrDataUrl.length <= 16_384, 'QR fits the schema limit');
    const png = Buffer.from(start.qrDataUrl.split(',')[1], 'base64');
    assert.equal(png.subarray(1, 4).toString('ascii'), 'PNG');
    assert.equal(start.message, 'Scan this QR in WhatsApp → Linked Devices.');
    assert.equal(start.connected, undefined);
    const again = await admin.send('web.login.start', { channel: 'whatsapp' });
    assert.equal(again.qrDataUrl, start.qrDataUrl, 'an active QR is reused');
    assert.match(again.message, /QR already active/);
    const stillWaiting = await admin.send('web.login.wait', { channel: 'whatsapp', timeoutMs: 10, currentQrDataUrl: start.qrDataUrl });
    assert.deepEqual(stillWaiting, { connected: false, message: 'Still waiting for the QR scan. Let me know when you’ve scanned it.' });
    const refreshed = await admin.send('web.login.wait', { channel: 'whatsapp', timeoutMs: 120000, currentQrDataUrl: start.qrDataUrl });
    assert.equal(refreshed.connected, false);
    assert.match(refreshed.qrDataUrl, /^data:image\/png;base64,/);
    assert.notEqual(refreshed.qrDataUrl, start.qrDataUrl, 'the QR rotates');
    const healthEvent = admin.waitEvent('health', (p) => p.channels?.whatsapp?.connected === true, 3000);
    const linked = await admin.send('web.login.wait', { timeoutMs: 120000, currentQrDataUrl: refreshed.qrDataUrl });
    assert.deepEqual(linked, { connected: true, message: '✅ Linked! WhatsApp is ready.' });
    await healthEvent;
    const after = await admin.send('channels.status', {});
    assert.equal(after.channelAccounts.whatsapp[0].linked, true);
    assert.equal(after.channelAccounts.whatsapp[0].connected, true);
    assert.equal(after.statusIssues, undefined, 'no issues once linked');
    assert.match((await admin.send('web.login.start', { channel: 'whatsapp' })).message, /already linked/);
    const relink = await admin.send('web.login.start', { channel: 'whatsapp', force: true });
    assert.match(relink.qrDataUrl, /^data:image\/png;base64,/);
    assert.equal((await admin.send('channels.status', {})).channelAccounts.whatsapp[0].linked, false, 'force relinks');
    assert.equal((await admin.call('web.login.wait', { currentQrDataUrl: 'nope' })).error.code, 'INVALID_REQUEST');
    process.env.MOCK_WEB_LOGIN = 'link';
    try {
      assert.equal((await admin.send('web.login.wait', { channel: 'whatsapp' })).connected, true, 'MOCK_WEB_LOGIN=link links on the first wait');
    } finally {
      delete process.env.MOCK_WEB_LOGIN;
    }
    admin.ws.close();
  } finally {
    delete process.env.MOCK_WEB_LOGIN_WAIT_MS;
    await setupServer.close();
  }

}
