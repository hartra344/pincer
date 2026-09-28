import assert from 'node:assert/strict';
import { connectClient } from './helpers.mjs';

export async function run(ctx) {
  const { url, device, deviceToken, sessions, always, invalid } = ctx;
  // Usage & cost: shapes and the Gateway's validation; MOCK_NO_USAGE=1 hides all five methods.
  const usage = await connectClient(url, device, deviceToken, true);
  for (const method of ['usage.status', 'usage.cost', 'sessions.usage', 'sessions.usage.timeseries', 'sessions.usage.logs']) {
    assert.ok(usage.hello.features.methods.includes(method), method);
  }
  const zone = { mode: 'specific', timeZone: 'Asia/Kolkata', utcOffset: 'UTC+5:30' };
  const status = await usage.send('usage.status', {});
  assert.ok(status.updatedAt > 0);
  assert.ok(status.providers.length >= 2);
  assert.ok(status.providers.some((p) => p.windows.some((w) => w.usedPercent >= 90 && w.resetAt - Date.now() < 3_600_000)));
  assert.ok(status.providers.some((p) => p.error));
  assert.ok(status.providers.some((p) => p.billing?.some((b) => b.type === 'budget')));
  const week = { startDate: '2000-01-01', endDate: '2000-01-07' };
  const todayKey = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const shift = (key, days) => { const [y, m, d] = key.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10); };
  const last7 = { ...zone, startDate: shift(todayKey, -6), endDate: todayKey };
  const cost = await usage.send('usage.cost', { ...last7, agentScope: 'all' });
  assert.equal(cost.days, 7);
  assert.ok(cost.daily.length > 0 && cost.daily.every((d) => d.date >= last7.startDate && d.date <= last7.endDate));
  assert.ok(cost.totals.totalTokens > 0 && cost.totals.totalCost > 0);
  const mainOnly = await usage.send('usage.cost', last7);
  assert.ok(mainOnly.totals.totalTokens < cost.totals.totalTokens, 'without agentScope only main is counted');
  // Like the Gateway, timeZone only counts with mode "specific"; +14 and -11 are always on different days.
  const today = async (params) => (await usage.send('usage.cost', { days: 1, agentScope: 'all', ...params })).daily.map((d) => d.date);
  const utcToday = new Date().toISOString().slice(0, 10);
  assert.deepEqual(await today({ timeZone: 'Pacific/Kiritimati' }), [utcToday], 'timeZone without mode is UTC');
  assert.notDeepEqual(await today({ mode: 'specific', timeZone: 'Pacific/Kiritimati' }), await today({ mode: 'specific', timeZone: 'Pacific/Pago_Pago' }));
  assert.deepEqual(await today({ mode: 'specific', timeZone: 'Nope/Zone', utcOffset: 'UTC+0' }), [utcToday], 'bad zone falls back to utcOffset');
  const empty = await usage.send('usage.cost', { ...week, agentScope: 'all' });
  assert.deepEqual(empty.daily, []);
  assert.equal(empty.totals.totalTokens, 0);
  const sessionsUsage = await usage.send('sessions.usage', { ...last7, agentScope: 'all', groupBy: 'instance', limit: 3, includeContextWeight: false });
  assert.equal(sessionsUsage.startDate, last7.startDate);
  assert.equal(sessionsUsage.endDate, last7.endDate);
  assert.equal(sessionsUsage.sessions.length, 3);
  assert.ok(sessionsUsage.aggregates.sessionCount > 3, 'aggregates cover sessions beyond the limit');
  assert.equal(sessionsUsage.totals.totalTokens, cost.totals.totalTokens);
  assert.ok(sessionsUsage.aggregates.byModel.some((m) => m.totals.missingCostEntries > 0 && m.totals.totalCost > 0), 'partial cost');
  assert.ok(sessionsUsage.aggregates.byModel.some((m) => m.totals.missingCostEntries > 0 && m.totals.totalCost === 0), 'unknown cost');
  assert.deepEqual(sessionsUsage.aggregates.byAgent.map((a) => a.agentId), ['coder', 'main', 'research']);
  assert.ok(sessionsUsage.aggregates.daily.length > 0 && sessionsUsage.aggregates.costDaily.length > 0);
  const quarter = await usage.send('sessions.usage', { ...zone, startDate: shift(todayKey, -89), endDate: todayKey, agentScope: 'all', limit: 200 });
  const computingRow = quarter.sessions.find((s) => s.computing);
  assert.equal(computingRow.usage, null);
  assert.equal(quarter.cacheStatus.status, 'partial');
  const one = await usage.send('sessions.usage', { ...last7, key: 'agent:main:main', agentId: 'main', limit: 1 });
  assert.equal(one.sessions.length, 1);
  assert.equal(one.sessions[0].key, 'agent:main:main');
  assert.ok(one.sessions[0].usage.totalTokens > 0);
  assert.ok(one.sessions[0].usage.messageCounts.total > 0);
  const quiet = await usage.send('sessions.usage', { ...last7, key: 'agent:main:cron:disk-check', limit: 1 });
  assert.equal(quiet.sessions.length, 1);
  assert.equal(quiet.sessions[0].usage.totalTokens, 0);
  const expectInvalid = async (method, params, message) => {
    const { error } = await usage.call(method, params);
    assert.equal(error?.code, 'INVALID_REQUEST', `${method} ${JSON.stringify(params)}`);
    if (message) assert.match(error.message, message);
  };
  await expectInvalid('usage.cost', { startDate: '2026-01-01' }, /startDate and endDate must be provided together/);
  await expectInvalid('sessions.usage', { endDate: '2026-01-01' }, /provided together/);
  await expectInvalid('usage.cost', { startDate: '2026-02-30', endDate: '2026-03-01' }, /invalid startDate/);
  await expectInvalid('usage.cost', { startDate: '2026-03-02', endDate: '2026-03-01' }, /must not be after/);
  await expectInvalid('usage.cost', { startDate: '2026-02-30' }, /invalid startDate/);
  await expectInvalid('usage.cost', { mode: 'specific', timeZone: 'Nope/Zone' }, /invalid timeZone/);
  await expectInvalid('usage.cost', { mode: 'specific', utcOffset: 'UTC+15' }, /invalid utcOffset/);
  await expectInvalid('usage.cost', { agentScope: 'all', agentId: 'main' }, /agentScope=all cannot be combined with agentId/);
  await expectInvalid('sessions.usage', { agentScope: 'all', key: 'agent:main:main' }, /agentScope=all cannot be combined with key or agentId/);
  await expectInvalid('sessions.usage', { key: 'agent:main:nope' }, /Invalid session key: agent:main:nope/);
  await expectInvalid('sessions.usage.timeseries', {}, /key is required for timeseries/);
  await expectInvalid('sessions.usage.logs', {}, /key is required for logs/);
  await expectInvalid('sessions.usage.timeseries', { key: 'agent:main:nope' }, /Invalid session key/);
  await expectInvalid('sessions.usage.logs', { key: 'agent:main:nope' }, /Invalid session key/);
  await expectInvalid('sessions.usage.timeseries', { key: 'agent:main:cron:disk-check' }, /No transcript found for session/);
  const series = await usage.send('sessions.usage.timeseries', { key: 'agent:main:main', agentId: 'main' });
  assert.ok(series.points.length > 0 && series.points.length <= 50);
  assert.ok(series.points.every((p, i) => i === 0 || p.cumulativeTokens >= series.points[i - 1].cumulativeTokens));
  const logs = await usage.send('sessions.usage.logs', { key: 'agent:main:main', limit: 200 });
  assert.equal(logs.logs.length, 20);
  assert.deepEqual([...new Set(logs.logs.map((l) => l.role))].sort(), ['assistant', 'tool', 'toolResult', 'user']);
  assert.equal((await usage.send('sessions.usage.logs', { key: 'agent:main:main', limit: 5 })).logs.length, 5);
  usage.ws.close();
  process.env.MOCK_USAGE_FORBIDDEN = '1';
  try {
    const restricted = await connectClient(url, device, deviceToken, true);
    assert.equal((await restricted.call('usage.cost', { agentScope: 'all' })).error.code, 'FORBIDDEN');
    restricted.ws.close();
  } finally {
    delete process.env.MOCK_USAGE_FORBIDDEN;
  }
  process.env.MOCK_NO_USAGE = '1';
  try {
    const legacy = await connectClient(url, device, deviceToken, true);
    for (const method of ['usage.status', 'usage.cost', 'sessions.usage', 'sessions.usage.timeseries', 'sessions.usage.logs']) {
      assert.ok(!legacy.hello.features.methods.includes(method), method);
      const unknown = await legacy.call(method, { key: 'agent:main:main' });
      assert.equal(unknown.error.code, 'UNKNOWN_METHOD');
    }
    assert.ok(legacy.hello.features.methods.includes('sessions.list'));
    legacy.ws.close();
  } finally {
    delete process.env.MOCK_NO_USAGE;
  }
  Object.assign(ctx, { status, one });
}
