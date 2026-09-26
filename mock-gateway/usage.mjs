// Usage & cost: usage.status (provider quotas), usage.cost (daily totals), sessions.usage (per-session
// rows + aggregates), sessions.usage.timeseries and sessions.usage.logs (one session, whole history).
// Shapes follow the Gateway's UsageSummary / CostUsageSummary / SessionsUsageResult and the validation
// in server-methods-usage.ts. Data is deterministic: 30 days of activity for the seeded chats.
// MOCK_NO_USAGE=1 makes the mock look like a Gateway without these methods;
// MOCK_USAGE_FORBIDDEN=1 answers usage.cost with FORBIDDEN, as for a restricted operator.

export const USAGE_METHODS = ['usage.status', 'usage.cost', 'sessions.usage', 'sessions.usage.timeseries', 'sessions.usage.logs'];

export function usageDisabled() {
  return process.env.MOCK_NO_USAGE === '1';
}

function usageForbidden() {
  return process.env.MOCK_USAGE_FORBIDDEN === '1';
}

const DAY_MS = 86_400_000;
const HISTORY_DAYS = 30;

// USD per million input, output, cache-read and cache-write tokens; null when unpriced.
const MODELS = {
  opus: { provider: 'anthropic', model: 'claude-opus-4-8', prices: [15, 75, 1.5, 18.75] },
  sonnet: { provider: 'anthropic', model: 'claude-sonnet-5', prices: [3, 15, 0.3, 3.75] },
  // Every 4th day some requests come back without pricing.
  sol: { provider: 'openai', model: 'gpt-5.6-sol', prices: [1.25, 10, 0.125, 0], unpricedEvery: 4 },
  flash: { provider: 'google', model: 'gemini-3.8-flash', prices: [0.3, 2.5, 0.03, 0] },
  local: { provider: 'ollama', model: 'qwen3-coder', prices: null },
};

export const USAGE_SESSIONS = [
  { key: 'agent:main:main', agentId: 'main', channel: 'webchat', models: [[MODELS.opus, 1]], daily: 900_000, days: [0, 30] },
  { key: 'agent:main:discord:channel:123', agentId: 'main', label: 'home-lab', channel: 'discord', models: [[MODELS.sonnet, 1]], daily: 250_000, days: [0, 30] },
  { key: 'agent:main:dashboard:trip', agentId: 'main', label: 'Japan trip', channel: 'webchat', models: [[MODELS.sol, 1]], daily: 400_000, days: [0, 18] },
  { key: 'agent:research:main', agentId: 'research', channel: 'webchat', models: [[MODELS.flash, 1]], daily: 150_000, days: [0, 30] },
  { key: 'agent:research:dashboard:papers', agentId: 'research', label: 'Paper digest', channel: 'webchat', models: [[MODELS.sonnet, 1]], daily: 600_000, days: [1, 30] },
  // Entirely unpriced.
  { key: 'agent:research:subagent:abc', agentId: 'research', label: 'Summarize arXiv 2401.x', channel: 'webchat', models: [[MODELS.local, 1]], daily: 300_000, days: [2, 12] },
  { key: 'agent:coder:main', agentId: 'coder', channel: 'webchat', models: [[MODELS.sol, 0.6], [MODELS.opus, 0.4]], daily: 1_200_000, days: [0, 30] },
];

// A range longer than this reports the discord chat as still being computed (usage: null).
const COMPUTING_KEY = 'agent:main:discord:channel:123';
const COMPUTING_AFTER_DAYS = 31;

function zeroTotals() {
  return {
    input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    totalCost: 0, inputCost: 0, outputCost: 0, cacheReadCost: 0, cacheWriteCost: 0, missingCostEntries: 0,
  };
}

function addTotals(sum, t) {
  for (const k of Object.keys(zeroTotals())) sum[k] += t[k] ?? 0;
  if (t.missingCostByModel) {
    sum.missingCostByModel ??= {};
    for (const [ref, n] of Object.entries(t.missingCostByModel)) sum.missingCostByModel[ref] = (sum.missingCostByModel[ref] ?? 0) + n;
  }
  return sum;
}

function sumTotals(records) {
  return records.reduce((sum, r) => addTotals(sum, r.totals), zeroTotals());
}

function zeroMessages() {
  return { total: 0, user: 0, assistant: 0, toolCalls: 0, toolResults: 0, errors: 0 };
}

function sumMessages(records) {
  const m = zeroMessages();
  for (const r of records) for (const k of Object.keys(m)) m[k] += r.messages[k];
  return m;
}

// YYYY-MM-DD of `ms` in `timeZone`.
function dayKey(ms, timeZone) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date(ms));
  const get = (type) => parts.find((p) => p.type === type).value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

function shiftKey(key, days) {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

function validKey(key) {
  if (typeof key !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(key)) return false;
  return shiftKey(key, 0) === key;
}

function daysBetween(start, end) {
  return Math.round((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / DAY_MS);
}

function validTimeZone(zone) {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}

function records(now, timeZone) {
  const today = dayKey(now, timeZone);
  const out = [];
  USAGE_SESSIONS.forEach((session, index) => {
    for (let offset = session.days[0]; offset < session.days[1]; offset++) {
      const date = shiftKey(today, -offset);
      const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
      const weekend = weekday === 0 || weekday === 6;
      const wave = 1 + 0.35 * Math.sin((offset + index * 3) / 2.7);
      const base = session.daily * (weekend ? 0.3 : 1) * wave;
      const timestamp = now - offset * DAY_MS - (index + 1) * 420_000;
      for (const [model, share] of session.models) {
        const tokens = Math.floor(base * share);
        if (tokens <= 0) continue;
        const entries = Math.max(1, Math.floor(tokens / 40_000));
        const totals = zeroTotals();
        totals.input = Math.floor((tokens * 18) / 100);
        totals.output = Math.floor((tokens * 6) / 100);
        totals.cacheWrite = Math.floor((tokens * 6) / 100);
        totals.cacheRead = tokens - totals.input - totals.output - totals.cacheWrite;
        totals.totalTokens = tokens;
        const ref = `${model.provider}/${model.model}`;
        if (model.prices) {
          let priced = 1;
          if (model.unpricedEvery && offset % model.unpricedEvery === 1) {
            const missing = Math.max(1, Math.floor(entries / 3));
            totals.missingCostEntries = missing;
            totals.missingCostByModel = { [ref]: missing };
            priced = 1 - missing / (entries + missing);
          }
          const [pi, po, pr, pw] = model.prices;
          totals.inputCost = (totals.input * pi) / 1e6 * priced;
          totals.outputCost = (totals.output * po) / 1e6 * priced;
          totals.cacheReadCost = (totals.cacheRead * pr) / 1e6 * priced;
          totals.cacheWriteCost = (totals.cacheWrite * pw) / 1e6 * priced;
          totals.totalCost = totals.inputCost + totals.outputCost + totals.cacheReadCost + totals.cacheWriteCost;
        } else {
          totals.missingCostEntries = entries;
          totals.missingCostByModel = { [ref]: entries };
        }
        const user = Math.max(1, Math.floor((entries + 2) / 3));
        const messages = {
          total: user + entries, user, assistant: entries,
          toolCalls: Math.floor(entries / 2), toolResults: Math.floor(entries / 2), errors: offset % 7 === 3 ? 1 : 0,
        };
        out.push({ session: index, model, offset, date, timestamp, totals, entries, messages });
      }
    }
  });
  return out;
}

// Mirrors resolveDateInterpretation: timeZone/utcOffset only count with mode "specific"; without it
// days are UTC. A bad zone falls back to a valid offset (whole hours only here; otherwise UTC).
function resolveZone(params) {
  if (params.mode !== 'specific') return { timeZone: 'UTC' };
  const offset = typeof params.utcOffset === 'string' ? /^UTC([+-])(\d{1,2})(?::([0-5]\d))?$/.exec(params.utcOffset.trim()) : null;
  const minutes = offset ? (offset[1] === '+' ? 1 : -1) * (Number(offset[2]) * 60 + Number(offset[3] ?? 0)) : undefined;
  const validOffset = minutes !== undefined && minutes >= -720 && minutes <= 840;
  const offsetZone = validOffset ? (minutes % 60 === 0 ? (minutes === 0 ? 'UTC' : `Etc/GMT${minutes > 0 ? '-' : '+'}${Math.abs(minutes / 60)}`) : 'UTC') : undefined;
  if (params.timeZone !== undefined && params.timeZone !== null) {
    if (typeof params.timeZone === 'string' && params.timeZone.trim() && validTimeZone(params.timeZone.trim())) return { timeZone: params.timeZone.trim() };
    if (offsetZone) return { timeZone: offsetZone };
    return { error: 'invalid timeZone: expected a valid IANA time zone' };
  }
  if (offsetZone) return { timeZone: offsetZone };
  if (params.utcOffset != null && (typeof params.utcOffset !== 'string' || params.utcOffset.trim() !== '')) {
    return { error: 'invalid utcOffset: expected UTC-12:00 through UTC+14:00' };
  }
  return { timeZone: 'UTC' };
}

// Mirrors usage-date-range.ts: explicit dates together (inclusive), else the last `days` (30).
function resolveRange(params, now) {
  const zone = resolveZone(params);
  if (zone.error) return zone;
  const { timeZone } = zone;
  const given = (value) => value !== undefined && value !== null && !(typeof value === 'string' && value.trim() === '');
  for (const field of ['startDate', 'endDate']) {
    if (given(params[field]) && !validKey(params[field])) return { error: `invalid ${field}: expected a valid YYYY-MM-DD calendar date` };
  }
  const hasStart = given(params.startDate);
  if (hasStart !== given(params.endDate)) return { error: 'startDate and endDate must be provided together' };
  if (hasStart) {
    if (params.startDate > params.endDate) return { error: 'startDate must not be after endDate' };
    return { start: params.startDate, end: params.endDate, timeZone };
  }
  const days = Number.isInteger(params.days) && params.days > 0 ? params.days : 30;
  const end = dayKey(now, timeZone);
  return { start: shiftKey(end, -(days - 1)), end, timeZone };
}

function withDate(date, totals) {
  return { date, ...totals };
}

function modelBuckets(recs, byProvider) {
  const groups = new Map();
  for (const r of recs) {
    const id = byProvider ? r.model.provider : `${r.model.provider}/${r.model.model}`;
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(r);
  }
  return [...groups.values()]
    .map((group) => {
      const bucket = { provider: group[0].model.provider, count: group.reduce((n, r) => n + r.entries, 0), totals: sumTotals(group) };
      if (!byProvider) bucket.model = group[0].model.model;
      return bucket;
    })
    .sort((a, b) => b.totals.totalTokens - a.totals.totalTokens);
}

function keyedBuckets(recs, field, keyOf) {
  const groups = new Map();
  for (const r of recs) {
    const key = keyOf(r);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  return [...groups.keys()].sort().map((key) => ({ [field]: key, totals: sumTotals(groups.get(key)) }));
}

function sessionSummary(recs) {
  const summary = sumTotals(recs);
  if (recs.length) {
    summary.firstActivity = Math.min(...recs.map((r) => r.timestamp));
    summary.lastActivity = Math.max(...recs.map((r) => r.timestamp));
    summary.durationMs = recs.length * 23 * 60_000;
  }
  summary.activityDates = [...new Set(recs.map((r) => r.date))].sort();
  const messageCounts = sumMessages(recs);
  summary.messageCounts = messageCounts;
  summary.toolUsage = { totalCalls: messageCounts.toolCalls, uniqueTools: 3, tools: [] };
  summary.modelUsage = modelBuckets(recs, false);
  return summary;
}

function statusSummary(now) {
  return {
    updatedAt: now,
    providers: [
      {
        provider: 'anthropic', displayName: 'Claude', plan: 'Max', accountEmail: 'claw@example.com',
        windows: [
          { label: '5-hour', usedPercent: 92, resetAt: now + 38 * 60_000 },
          { label: 'Weekly', usedPercent: 61, resetAt: now + 3 * DAY_MS + 4 * 3_600_000 },
          { label: 'Weekly', groupLabel: 'Opus', usedPercent: 78, resetAt: now + 3 * DAY_MS + 4 * 3_600_000 },
        ],
      },
      {
        provider: 'openai', displayName: 'OpenAI', plan: 'Pro',
        windows: [{ label: 'Daily requests', usedPercent: 34, resetAt: now + 7 * 3_600_000 + 12 * 60_000 }],
        billing: [
          { type: 'balance', label: 'Credit balance', amount: 42.5, unit: 'USD' },
          { type: 'budget', label: 'Monthly budget', used: 128.4, limit: 200, unit: 'USD', period: 'month' },
        ],
      },
      { provider: 'google', displayName: 'Gemini', windows: [], error: 'Sign-in expired. Run `openclaw models auth google` to reconnect.' },
      { provider: 'ollama', displayName: 'Ollama', windows: [], summary: "Local models aren't metered." },
    ],
  };
}

const LOG_SCRIPT = [
  ['user', 'Can you check disk usage and show me a quick status?'],
  ['assistant', 'Checking the volumes now.'],
  ['tool', 'exec: df -h'],
  ['toolResult', 'Filesystem      Size  Used Avail Use% Mounted on\n/dev/disk3s1   926G  411G  490G  46% /'],
  ['assistant', "The root volume is 46% full, so there's plenty of room."],
  ['user', 'Great. Anything else worth cleaning up?'],
  ['tool', 'exec: du -sh ~/Library/Caches'],
  ['toolResult', '7.4G\t/Users/claw/Library/Caches'],
  ['assistant', "Caches take 7.4 GB. I can clear the largest ones if you'd like, but nothing is urgent."],
  ['user', "Leave them for now. Summarize today's research queue instead."],
];

export function handleUsageRequest(state, conn, msg, { sendRes, sendErr }) {
  const { id, method } = msg;
  if (!USAGE_METHODS.includes(method) || usageDisabled()) return false;
  const params = msg.params && typeof msg.params === 'object' && !Array.isArray(msg.params) ? msg.params : {};
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  const now = Date.now();
  const text = (value) => (typeof value === 'string' && value.trim() ? value.trim() : undefined);

  // timeseries/logs: one known session, whole history.
  const sessionFor = (detail) => {
    const key = text(params.key);
    if (!key) return invalid(`key is required for ${detail}`), null;
    if (!state.sessions.has(key)) return invalid(`Invalid session key: ${key}`), null;
    return { key, index: USAGE_SESSIONS.findIndex((s) => s.key === key) };
  };

  switch (method) {
    case 'usage.status': {
      sendRes(conn, id, statusSummary(now));
      return true;
    }
    case 'usage.cost': {
      const range = resolveRange(params, now);
      if (range.error) return invalid(range.error), true;
      if (usageForbidden()) {
        sendErr(conn, id, 'FORBIDDEN', 'Aggregate usage includes sessions hidden by your operator role; ask an administrator to review Gateway-wide usage.');
        return true;
      }
      const agentId = text(params.agentId);
      if (params.agentScope === 'all' && agentId) return invalid('agentScope=all cannot be combined with agentId'), true;
      const agent = params.agentScope === 'all' ? null : agentId ?? 'main';
      const recs = records(now, range.timeZone).filter(
        (r) => r.date >= range.start && r.date <= range.end && (!agent || USAGE_SESSIONS[r.session].agentId === agent),
      );
      const byDate = new Map();
      for (const r of recs) {
        if (!byDate.has(r.date)) byDate.set(r.date, []);
        byDate.get(r.date).push(r);
      }
      const dates = [...byDate.keys()].sort();
      sendRes(conn, id, {
        updatedAt: now,
        days: daysBetween(range.start, range.end) + 1,
        daily: dates.map((date) => withDate(date, sumTotals(byDate.get(date)))),
        totals: sumTotals(recs),
      });
      return true;
    }
    case 'sessions.usage': {
      const range = resolveRange(params, now);
      if (range.error) return invalid(range.error), true;
      const key = text(params.key);
      const agentId = text(params.agentId);
      const all = params.agentScope === 'all';
      if (all && (key || agentId)) return invalid('agentScope=all cannot be combined with key or agentId'), true;
      if (key && !state.sessions.has(key)) return invalid(`Invalid session key: ${key}`), true;
      const limit = Number.isFinite(params.limit) ? Math.max(1, Math.min(1000, Math.floor(params.limit))) : 50;
      const agent = all ? null : agentId ?? (key ? key.split(':')[1] : 'main');
      const longRange = daysBetween(range.start, dayKey(now, range.timeZone)) + 1 > COMPUTING_AFTER_DAYS;
      const computing = !key && longRange ? COMPUTING_KEY : null;

      const inRange = records(now, range.timeZone).filter((r) => r.date >= range.start && r.date <= range.end);
      const bySession = new Map();
      for (const r of inRange) {
        if (!bySession.has(r.session)) bySession.set(r.session, []);
        bySession.get(r.session).push(r);
      }
      // A specific chat without seeded usage still gets its (empty) row, as on the Gateway.
      const known = key && !USAGE_SESSIONS.some((s) => s.key === key)
        ? [{ key, agentId: key.split(':')[1] ?? 'main', channel: state.sessions.get(key)?.channel ?? 'webchat', models: [[MODELS.opus, 1]] }]
        : [];
      const matched = [...USAGE_SESSIONS, ...known]
        .map((session, index) => ({ session, index, recs: bySession.get(index) ?? [] }))
        .filter(({ session, recs }) => (key ? session.key === key : recs.length > 0) && (!agent || session.agentId === agent))
        .sort((a, b) => {
          const l = sumTotals(a.recs);
          const r = sumTotals(b.recs);
          return l.totalCost === r.totalCost ? r.totalTokens - l.totalTokens : r.totalCost - l.totalCost;
        });
      const counted = matched.filter(({ session }) => session.key !== computing).flatMap(({ recs }) => recs);

      const sessions = matched.slice(0, limit).map(({ session, index, recs }) => {
        const chat = state.sessions.get(session.key);
        const [model] = session.models[0];
        const row = {
          key: session.key, sessionId: chat?.sessionId ?? `mock-${index}`, scope: 'instance',
          updatedAt: recs.length ? Math.max(...recs.map((r) => r.timestamp)) : chat?.updatedAt ?? now - DAY_MS,
          agentId: session.agentId, channel: session.channel, modelProvider: model.provider, model: model.model,
        };
        if (session.label) row.label = session.label;
        if (session.key === computing) {
          row.usage = null;
          row.computing = true;
        } else {
          row.usage = sessionSummary(recs);
        }
        return row;
      });

      const byDate = new Map();
      for (const r of counted) {
        if (!byDate.has(r.date)) byDate.set(r.date, []);
        byDate.get(r.date).push(r);
      }
      const dates = [...byDate.keys()].sort();
      const messages = sumMessages(counted);
      const result = {
        updatedAt: now,
        startDate: range.start,
        endDate: range.end,
        sessions,
        totals: sumTotals(counted),
        aggregates: {
          sessionCount: matched.length,
          messages,
          tools: { totalCalls: messages.toolCalls, uniqueTools: 6, tools: [{ name: 'exec', count: Math.floor(messages.toolCalls / 2) }] },
          byModel: modelBuckets(counted, false),
          byProvider: modelBuckets(counted, true),
          byAgent: keyedBuckets(counted, 'agentId', (r) => USAGE_SESSIONS[r.session].agentId),
          byChannel: keyedBuckets(counted, 'channel', (r) => USAGE_SESSIONS[r.session].channel),
          daily: dates.map((date) => {
            const day = byDate.get(date);
            const totals = sumTotals(day);
            const m = sumMessages(day);
            return { date, tokens: totals.totalTokens, cost: totals.totalCost, messages: m.total, toolCalls: m.toolCalls, errors: m.errors };
          }),
          costDaily: dates.map((date) => withDate(date, sumTotals(byDate.get(date)))),
        },
      };
      if (computing) result.cacheStatus = { status: 'partial', cachedFiles: 6, pendingFiles: 1, staleFiles: 0 };
      sendRes(conn, id, result);
      return true;
    }
    case 'sessions.usage.timeseries': {
      const found = sessionFor('timeseries');
      if (!found) return true;
      const recs = found.index < 0 ? [] : records(now, 'UTC').filter((r) => r.session === found.index).sort((a, b) => a.timestamp - b.timestamp);
      if (!recs.length) return invalid(`No transcript found for session: ${found.key}`), true;
      const points = [];
      let cumulativeTokens = 0;
      let cumulativeCost = 0;
      for (const r of recs) {
        for (const half of [0, 1]) {
          const tokens = half === 0 ? Math.floor(r.totals.totalTokens / 2) : r.totals.totalTokens - Math.floor(r.totals.totalTokens / 2);
          const cost = r.totals.totalCost / 2;
          cumulativeTokens += tokens;
          cumulativeCost += cost;
          points.push({
            timestamp: r.timestamp - (1 - half) * 2_700_000,
            input: Math.floor(r.totals.input / 2), output: Math.floor(r.totals.output / 2),
            cacheRead: Math.floor(r.totals.cacheRead / 2), cacheWrite: Math.floor(r.totals.cacheWrite / 2),
            totalTokens: tokens, cost, cumulativeTokens, cumulativeCost,
          });
        }
      }
      sendRes(conn, id, { sessionId: state.sessions.get(found.key)?.sessionId ?? `mock-${found.index}`, points: points.slice(-50) });
      return true;
    }
    case 'sessions.usage.logs': {
      const found = sessionFor('logs');
      if (!found) return true;
      const limit = Number.isFinite(params.limit) ? Math.max(1, Math.min(1000, Math.floor(params.limit))) : 200;
      if (found.index < 0) return sendRes(conn, id, { logs: [] }), true;
      const recs = records(now, 'UTC').filter((r) => r.session === found.index);
      const last = recs.length ? Math.max(...recs.map((r) => r.timestamp)) : now;
      const totals = sumTotals(recs);
      const perToken = totals.totalTokens ? totals.totalCost / totals.totalTokens : 0;
      const unpriced = USAGE_SESSIONS[found.index].models.every(([m]) => !m.prices);
      const logs = [];
      for (let step = 0; step < 20; step++) {
        const [role, content] = LOG_SCRIPT[step % LOG_SCRIPT.length];
        const entry = { timestamp: last - (19 - step) * 95_000, role, content };
        if (role === 'assistant') {
          entry.tokens = 8_000 + ((step * 3_137) % 21_000);
          if (!unpriced) entry.cost = entry.tokens * perToken;
        }
        logs.push(entry);
      }
      sendRes(conn, id, { logs: logs.slice(-limit) });
      return true;
    }
  }
  return false;
}
