import assert from 'node:assert/strict';
import http from 'node:http';
import { startServer } from '../server.mjs';
import { CLAWHUB_REGISTRY, MANAGED_SKILLS_DIR, SKILLS_METHODS, TOOLS_METHODS } from '../skills.mjs';
import { makeDevice, BASE_SCOPES, connectClient } from './helpers.mjs';

// Skills browser + effective tools, on a fresh server so installs and toggles don't leak.
export async function run() {
  const adminScopes = [...BASE_SCOPES, 'operator.admin'];
  const skillsServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const url = `ws://127.0.0.1:${skillsServer.address().port}`;
    const admin = await connectClient(url, makeDevice(), 'dev-token', true, adminScopes);
    const reader = await connectClient(url, makeDevice(), 'dev-token');
    const nobody = await connectClient(url, makeDevice(), 'dev-token', true, ['operator.approvals']);
    for (const method of [...SKILLS_METHODS, ...TOOLS_METHODS]) assert.ok(admin.hello.features.methods.includes(method), method);

    // Scopes: reads need operator.read (write implies it), install/update need operator.admin.
    for (const [method, params] of [
      ['skills.install', { name: 'github', installId: 'brew' }],
      ['skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' }],
      ['skills.update', { skillKey: 'slack', enabled: true }],
      ['skills.update', { source: 'clawhub', all: true }],
    ]) {
      const gated = await reader.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.deepEqual(gated.error.details, { code: 'MISSING_SCOPE', scope: 'operator.admin' });
    }
    for (const [method, params] of [['skills.status', {}], ['skills.search', {}], ['skills.detail', { slug: 'nas-report' }], ['tools.catalog', {}], ['tools.effective', { sessionKey: 'agent:main:main' }]]) {
      const gated = await nobody.call(method, params);
      assert.equal(gated.error.code, 'FORBIDDEN', method);
      assert.equal(gated.error.message, 'missing scope: operator.read');
    }
    nobody.ws.close();

    // skills.status: one entry per state.
    const status = await reader.send('skills.status', {});
    assert.equal(status.agentId, 'main');
    assert.equal(status.workspaceDir, '/Users/claw/.openclaw/workspace');
    assert.equal(status.managedSkillsDir, MANAGED_SKILLS_DIR);
    assert.equal(status.agentSkillFilter, undefined);
    const byName = (report) => Object.fromEntries(report.skills.map((s) => [s.name, s]));
    let skills = byName(status);
    const keys = ['name', 'description', 'source', 'bundled', 'filePath', 'baseDir', 'skillKey', 'always', 'disabled', 'blockedByAllowlist', 'blockedByAgentFilter', 'eligible', 'platformIncompatible', 'modelVisible', 'userInvocable', 'commandVisible', 'requirements', 'missing', 'configChecks', 'install'];
    for (const skill of status.skills) for (const key of keys) assert.ok(key in skill, `${skill.name}.${key}`);
    assert.equal(skills.weather.eligible, true);
    assert.equal(skills.weather.bundled, true);
    assert.equal(skills.weather.source, 'openclaw-bundled');
    assert.equal(skills.weather.modelVisible, true);
    assert.deepEqual(skills.weather.requirements, { bins: ['curl'], anyBins: [], env: [], config: [], os: [] });
    assert.equal(skills.github.eligible, false);
    assert.deepEqual(skills.github.missing.bins, ['gh']);
    assert.deepEqual(skills.github.install, [{ id: 'brew', kind: 'brew', label: 'Install GitHub CLI (brew)', bins: ['gh'] }]);
    assert.deepEqual(skills['video-frames'].install, [{ id: 'brew', kind: 'brew', label: 'Install ffmpeg (brew)', bins: ['ffmpeg'] }]);
    assert.deepEqual(skills.notion.missing.env, ['NOTION_API_KEY']);
    assert.equal(skills.notion.primaryEnv, 'NOTION_API_KEY');
    assert.deepEqual(skills['voice-call'].configChecks, [{ path: 'plugins.entries.voice-call.enabled', satisfied: false }]);
    assert.equal(skills['apple-notes'].eligible, true);
    assert.equal(skills['apt-updates'].platformIncompatible, true);
    assert.deepEqual(skills['apt-updates'].missing.os, ['linux']);
    assert.equal(skills.slack.disabled, true);
    assert.equal(skills.slack.eligible, false);
    assert.deepEqual(skills.slack.missing, { bins: [], anyBins: [], env: [], config: [], os: [] }, 'disabled but otherwise ready');
    assert.equal(skills['openai-image-gen'].blockedByAllowlist, true);
    assert.equal(skills['openai-image-gen'].eligible, false);
    assert.equal(skills.summarize.source, 'openclaw-managed');
    assert.equal(skills.summarize.bundled, false);
    assert.equal(skills.summarize.filePath, `${MANAGED_SKILLS_DIR}/summarize/SKILL.md`);
    assert.equal(skills['homelab-runbook'].source, 'openclaw-workspace');
    assert.equal(skills['homelab-runbook'].baseDir, '/Users/claw/.openclaw/workspace/skills/homelab-runbook');
    assert.equal(skills['nas-report'].clawhub.status, 'linked');
    assert.equal(skills['nas-report'].clawhub.installedVersion, '1.2.0');
    assert.equal(skills['nas-report'].clawhub.registry, CLAWHUB_REGISTRY);
    // research filters its skills: the rest are blockedByAgentFilter but still reported.
    const research = await reader.send('skills.status', { agentId: 'research' });
    assert.deepEqual(research.agentSkillFilter, ['weather', 'summarize', 'github', 'notion']);
    assert.equal(research.workspaceDir, '/Users/claw/.openclaw/workspace-research');
    assert.equal(byName(research)['homelab-runbook'].blockedByAgentFilter, true);
    assert.equal(byName(research)['homelab-runbook'].eligible, true, 'the agent filter does not change eligible');
    assert.equal(byName(research)['homelab-runbook'].modelVisible, false);
    assert.equal(byName(research).weather.blockedByAgentFilter, false);
    assert.equal((await reader.call('skills.status', { agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');
    assert.equal((await reader.call('skills.status', { sessionKey: 'agent:main:gone' })).error.message, 'Session not found.');
    assert.equal((await reader.send('skills.status', { sessionKey: 'agent:main:main' })).agentId, 'main');
    assert.match((await reader.call('skills.status', { extra: 1 })).error.message, /^invalid skills\.status params: at root: unexpected property 'extra'/);

    // skills.search / skills.detail.
    const trending = (await reader.send('skills.search', {})).results;
    assert.ok(trending.length >= 5);
    assert.ok(trending.every((r) => r.score === 0 && r.registry === CLAWHUB_REGISTRY));
    const nas = (await reader.send('skills.search', { query: 'nas' })).results;
    assert.equal(nas[0].slug, 'nas-report');
    assert.equal(nas[0].installRef, '@clawdia/nas-report');
    assert.equal(nas[0].version, '1.3.0');
    assert.equal(nas[0].ownerHandle, 'clawdia');
    const ext = (await reader.send('skills.search', { query: 'obsidian' })).results[0];
    assert.equal(ext.installOnly, true);
    assert.equal(ext.trustState, 'not-scanned-by-clawhub');
    assert.equal(ext.installRef, 'skills-sh:vaultsmith/obsidian-skills/obsidian-daily');
    assert.deepEqual((await reader.send('skills.search', { query: 'zzzz-nothing' })).results, []);
    assert.equal((await reader.send('skills.search', { query: 'a', limit: 2 })).results.length, 2);
    assert.match((await reader.call('skills.search', { limit: 0 })).error.message, /^invalid skills\.search params: at \/limit: must be >= 1/);
    assert.match((await reader.call('skills.search', { query: '' })).error.message, /at \/query: must NOT have fewer than 1 characters/);
    const detail = await reader.send('skills.detail', { slug: '@clawdia/nas-report' });
    assert.equal(detail.skill.slug, 'nas-report');
    assert.equal(detail.latestVersion.version, '1.3.0');
    assert.equal(detail.owner.handle, 'clawdia');
    assert.equal((await reader.send('skills.detail', { slug: 'home-assistant' })).skill.isOfficial, true);
    assert.match((await reader.call('skills.detail', { slug: ext.installRef })).error.message, /external skill sources are install-only/);
    const missingDetail = await reader.call('skills.detail', { slug: 'nope' });
    assert.equal(missingDetail.error.code, 'UNAVAILABLE');
    assert.match(missingDetail.error.message, /404/);

    // skills.install (gateway installer): the missing bin appears, the skill becomes eligible.
    const installed = await admin.send('skills.install', { name: 'github', installId: 'brew' });
    assert.equal(installed.ok, true);
    assert.equal(installed.message, 'Installed');
    assert.equal(installed.code, 0);
    assert.equal(byName(await reader.send('skills.status', {})).github.eligible, true);
    assert.equal((await admin.call('skills.install', { name: 'github', installId: 'apt' })).error.message, 'Installer not found: apt');
    assert.equal((await admin.call('skills.install', { name: 'nope', installId: 'brew' })).error.message, 'Skill not found: nope');
    assert.match((await admin.call('skills.install', { name: 'github' })).error.message, /must have required property 'installId'/);
    assert.match((await admin.call('skills.install', { source: 'clawhub', slug: 'x', bogus: 1 })).error.message, /unexpected property 'bogus'/);
    // ClawHub install lands in the agent's workspace, tracked.
    const ha = await admin.send('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' });
    assert.deepEqual(ha, { ok: true, message: 'Installed home-assistant@2.4.1', stdout: '', stderr: '', code: 0, slug: 'home-assistant', version: '2.4.1', targetDir: '/Users/claw/.openclaw/workspace/skills/home-assistant' });
    skills = byName(await reader.send('skills.status', {}));
    assert.equal(skills['home-assistant'].source, 'openclaw-workspace');
    assert.equal(skills['home-assistant'].clawhub.installedVersion, '2.4.1');
    assert.deepEqual(skills['home-assistant'].missing.env, ['HASS_TOKEN']);
    const again = await admin.call('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant' });
    assert.equal(again.error.code, 'UNAVAILABLE');
    assert.match(again.error.message, /already installed/);
    assert.equal((await admin.send('skills.install', { source: 'clawhub', slug: '@openclaw/home-assistant', force: true })).ok, true);
    const extInstall = await admin.send('skills.install', { source: 'clawhub', slug: ext.installRef });
    assert.match(extInstall.warning, /not scanned by ClawHub/);

    // skills.update config: toggles and write-only keys (redacted in the reply).
    assert.deepEqual(await admin.send('skills.update', { skillKey: 'slack', enabled: true }), { ok: true, skillKey: 'slack', config: { enabled: true } });
    assert.equal(byName(await reader.send('skills.status', {})).slack.eligible, true);
    const keyed = await admin.send('skills.update', { skillKey: 'notion', apiKey: '  ntn_secret  ' });
    assert.deepEqual(keyed.config, { apiKey: '__OPENCLAW_REDACTED__' });
    assert.equal(byName(await reader.send('skills.status', {})).notion.eligible, true, 'apiKey satisfies primaryEnv');
    assert.deepEqual((await admin.send('skills.update', { skillKey: 'notion', apiKey: '__OPENCLAW_REDACTED__' })).config, { apiKey: '__OPENCLAW_REDACTED__' }, 'sentinel keeps the key');
    assert.deepEqual((await admin.send('skills.update', { skillKey: 'notion', apiKey: '' })).config, {}, 'empty clears the key');
    assert.equal(byName(await reader.send('skills.status', {})).notion.eligible, false);
    const envd = await admin.send('skills.update', { skillKey: 'home-assistant', env: { HASS_TOKEN: 'abc', HASS_URL: 'http://ha.local:8123' } });
    assert.deepEqual(envd.config, { env: { HASS_TOKEN: '__OPENCLAW_REDACTED__', HASS_URL: 'http://ha.local:8123' } });
    assert.equal(byName(await reader.send('skills.status', {})).notion.disabled, false);
    assert.match((await admin.call('skills.update', { skillKey: 'slack', enabled: 'yes' })).error.message, /at \/enabled: must be boolean/);

    // skills.update ClawHub: nas-report has an update; grocery-list was edited locally.
    assert.equal((await admin.call('skills.update', { source: 'clawhub' })).error.message, 'clawhub skills.update requires "slug" or "all"');
    assert.equal((await admin.call('skills.update', { source: 'clawhub', slug: 'nas-report', all: true })).error.message, 'clawhub skills.update accepts either "slug" or "all", not both');
    const updated = await admin.send('skills.update', { source: 'clawhub', slug: 'nas-report' });
    assert.deepEqual(updated, { ok: true, skillKey: 'nas-report', config: { source: 'clawhub', results: [{ ok: true, slug: 'nas-report', previousVersion: '1.2.0', version: '1.3.0', changed: true, targetDir: '/Users/claw/.openclaw/workspace/skills/nas-report' }] } });
    assert.equal(byName(await reader.send('skills.status', {}))['nas-report'].clawhub.installedVersion, '1.3.0');
    const blocked = await admin.call('skills.update', { source: 'clawhub', slug: 'grocery-list' });
    assert.equal(blocked.error.code, 'UNAVAILABLE');
    assert.equal(blocked.error.details.results[0].code, 'force_required');
    assert.match(blocked.error.message, /Updating replaces the installed skill directory\.$/);
    const forced = await admin.send('skills.update', { source: 'clawhub', slug: 'grocery-list', force: true });
    assert.deepEqual(forced.config.results[0], { ok: true, slug: 'grocery-list', previousVersion: '0.9.0', version: '1.0.0', changed: true, targetDir: '/Users/claw/.openclaw/workspace/skills/grocery-list' });
    const all = await admin.send('skills.update', { source: 'clawhub', all: true });
    assert.equal(all.skillKey, '*');
    assert.ok(all.config.results.every((r) => r.ok));
    assert.equal(all.config.results.find((r) => r.slug === 'nas-report').changed, false);
    const untracked = await admin.call('skills.update', { source: 'clawhub', slug: 'weather' });
    assert.match(untracked.error.message, /not installed from ClawHub/);

    // tools.catalog.
    const catalog = await reader.send('tools.catalog', {});
    assert.equal(catalog.agentId, 'main');
    assert.deepEqual(catalog.profiles.map((p) => p.id), ['minimal', 'coding', 'messaging', 'full']);
    assert.deepEqual(catalog.groups.slice(0, 3).map((g) => [g.id, g.label, g.source]), [['fs', 'Files', 'core'], ['runtime', 'Runtime', 'core'], ['web', 'Web', 'core']]);
    const exec = catalog.groups.find((g) => g.id === 'runtime').tools.find((t) => t.id === 'exec');
    assert.deepEqual(exec.defaultProfiles, ['coding']);
    const pluginGroups = catalog.groups.filter((g) => g.source === 'plugin');
    assert.ok(pluginGroups.length >= 1 && pluginGroups.every((g) => g.pluginId));
    assert.equal(pluginGroups.flatMap((g) => g.tools).find((t) => t.id === 'voice_call').optional, true);
    assert.ok(!(await reader.send('tools.catalog', { agentId: 'coder', includePlugins: false })).groups.some((g) => g.source === 'plugin'));
    assert.equal((await reader.call('tools.catalog', { agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');

    // tools.effective: allowed + excluded with reasons, session overrides, notices.
    const eff = await reader.send('tools.effective', { sessionKey: 'agent:main:main' });
    assert.equal(eff.agentId, 'main');
    assert.equal(eff.profile, 'coding');
    assert.deepEqual(eff.groups.map((g) => g.source), ['core', 'plugin', 'mcp']);
    const effIds = eff.groups.flatMap((g) => g.tools.map((t) => t.id));
    assert.ok(effIds.includes('exec') && effIds.includes('read') && !effIds.includes('x_search') && !effIds.includes('browser'));
    const mcpTool = eff.groups.find((g) => g.source === 'mcp').tools[0];
    assert.equal(mcpTool.mcpServer, 'home-assistant');
    for (const tool of eff.groups.flatMap((g) => g.tools)) assert.equal(typeof tool.rawDescription, 'string');
    const access = Object.fromEntries(eff.toolAccess.tools.map((t) => [t.id, t]));
    assert.equal(eff.toolAccess.checked, 'live-session');
    assert.deepEqual(eff.toolAccess.profiles, [{ profile: 'coding', source: 'tools.profile', active: true }]);
    assert.deepEqual(access.read, { id: 'read', status: 'available', reasons: [] });
    assert.deepEqual(access.x_search, { id: 'x_search', status: 'excluded', reasons: [{ kind: 'deny', label: 'Denied by tools.deny', source: 'tools.deny' }] });
    assert.deepEqual(access.browser, { id: 'browser', status: 'excluded', reasons: [{ kind: 'profile', label: 'coding profile', source: 'tools.profile', profile: 'coding' }], alsoAllowPath: 'tools.alsoAllow' });
    assert.ok(eff.notices.some((n) => n.id === 'browser-filtered-by-profile' && n.severity === 'info'));
    assert.ok(eff.notices.some((n) => n.severity === 'warning' && n.servers?.length));
    const discord = await reader.send('tools.effective', { sessionKey: 'agent:main:discord:channel:123' });
    const discordExec = discord.groups.find((g) => g.id === 'core').tools.find((t) => t.id === 'exec');
    assert.equal(discordExec.deniedBySession, true);
    assert.equal(discord.toolAccess.tools.find((t) => t.id === 'exec').reasons[0].kind, 'session');
    assert.equal(discord.groups.find((g) => g.source === 'channel').tools[0].channelId, 'discord');
    const scout = await reader.send('tools.effective', { sessionKey: 'agent:research:main' });
    assert.deepEqual(scout.toolAccess.tools.find((t) => t.id === 'exec').reasons, [{ kind: 'allowlist', label: 'Not included in agents.entries.research.tools.allow', source: 'agents.entries.research.tools.allow' }]);
    const forge = await reader.send('tools.effective', { sessionKey: 'agent:coder:main', agentId: 'coder' });
    assert.equal(forge.profile, 'full');
    assert.equal(forge.notices, undefined);
    assert.ok(forge.toolAccess.tools.every((t) => t.status === 'available'));
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:gone' })).error.message, 'unknown session key "agent:main:gone"');
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:main', agentId: 'coder' })).error.message, 'agent id "coder" does not match session agent "main"');
    assert.equal((await reader.call('tools.effective', { sessionKey: 'agent:main:main', agentId: 'nobody' })).error.message, 'unknown agent id "nobody"');
    assert.match((await reader.call('tools.effective', {})).error.message, /^invalid tools\.effective params: at root: must have required property 'sessionKey'/);
    reader.ws.close();
    admin.ws.close();
  } finally {
    await skillsServer.close();
  }

  // MOCK_CLAWHUB_OFFLINE=1: status still works, ClawHub calls are UNAVAILABLE.
  process.env.MOCK_CLAWHUB_OFFLINE = '1';
  const offlineServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const client = await connectClient(`ws://127.0.0.1:${offlineServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    assert.ok((await client.send('skills.status', {})).skills.length > 0);
    assert.equal((await client.call('skills.search', { query: 'nas' })).error.code, 'UNAVAILABLE');
    assert.equal((await client.call('skills.install', { source: 'clawhub', slug: '@clawdia/pi-fleet' })).error.code, 'UNAVAILABLE');
    client.ws.close();
  } finally {
    delete process.env.MOCK_CLAWHUB_OFFLINE;
    await offlineServer.close();
  }

  // MOCK_NO_SKILLS=1 / MOCK_NO_TOOLS=1: an older Gateway without these methods.
  process.env.MOCK_NO_SKILLS = '1';
  process.env.MOCK_NO_TOOLS = '1';
  const legacyServer = await startServer({ host: '127.0.0.1', port: 0, pairing: 'off', mockToken: 'dev-token' });
  try {
    const legacy = await connectClient(`ws://127.0.0.1:${legacyServer.address().port}`, makeDevice(), 'dev-token', true, adminScopes);
    for (const method of [...SKILLS_METHODS, ...TOOLS_METHODS]) {
      assert.ok(!legacy.hello.features.methods.includes(method), method);
      assert.equal((await legacy.call(method, {})).error.code, 'UNKNOWN_METHOD', method);
    }
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_SKILLS;
    delete process.env.MOCK_NO_TOOLS;
    await legacyServer.close();
  }
}
