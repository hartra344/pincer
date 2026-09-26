// Cron jobs ("automations"): cron.status / list / get / runs / add / update / remove / run,
// broadcasting `cron` events. Writes need operator.admin, like the real Gateway.
import crypto from 'node:crypto';
import { ADMIN_SCOPE } from './config.mjs';

export const CRON_METHODS = ['cron.status', 'cron.list', 'cron.get', 'cron.runs', 'cron.add', 'cron.update', 'cron.remove', 'cron.run'];
const ADMIN_METHODS = new Set(['cron.add', 'cron.update', 'cron.remove', 'cron.run']);
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
// How long a started run takes to finish.
export const RUN_DURATION_MS = 1200;

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

// Definition fields only, so scheduler state doesn't change the revision.
function revisionOf(job) {
  const { state, configRevision, createdAtMs, updatedAtMs, ...definition } = job;
  return crypto.createHash('sha256').update(JSON.stringify(definition)).digest('hex').slice(0, 16);
}

function matchesField(field, value, min) {
  return field.split(',').some((part) => {
    const [range, stepText] = part.split('/');
    const step = stepText ? Number(stepText) : 1;
    let lo;
    let hi;
    if (range === '*') {
      lo = min;
      hi = Infinity;
    } else if (range.includes('-')) {
      [lo, hi] = range.split('-').map(Number);
    } else {
      lo = Number(range);
      hi = stepText ? Infinity : lo;
    }
    return value >= lo && value <= hi && (value - lo) % step === 0;
  });
}

// The next minute (local time) matching a five-field cron expression, within 400 days.
export function nextCronRun(expr, fromMs) {
  const fields = expr.trim().split(/\s+/);
  if (fields.length !== 5) return undefined;
  const [minute, hour, dom, month, dow] = fields;
  const date = new Date(fromMs);
  date.setSeconds(0, 0);
  date.setMinutes(date.getMinutes() + 1);
  for (let i = 0; i < 400 * 24 * 60; i++) {
    if (
      matchesField(month, date.getMonth() + 1, 1) &&
      matchesField(dom, date.getDate(), 1) &&
      matchesField(dow, date.getDay(), 0) &&
      matchesField(hour, date.getHours(), 0) &&
      matchesField(minute, date.getMinutes(), 0)
    ) {
      return date.getTime();
    }
    date.setMinutes(date.getMinutes() + 1);
  }
  return undefined;
}

function nextRun(job, now) {
  if (!job.enabled) return undefined;
  const { schedule } = job;
  if (schedule.kind === 'every') {
    const anchor = schedule.anchorMs ?? job.createdAtMs;
    return anchor + Math.ceil((now - anchor + 1) / schedule.everyMs) * schedule.everyMs;
  }
  if (schedule.kind === 'cron') return nextCronRun(schedule.expr, now);
  if (schedule.kind === 'at') {
    const at = Date.parse(schedule.at);
    return at > now && !job.state.lastRunAtMs ? at : undefined;
  }
  return undefined;
}

function validSchedule(schedule) {
  if (!schedule || typeof schedule !== 'object') return 'schedule is required';
  if (schedule.kind === 'every') return Number.isInteger(schedule.everyMs) && schedule.everyMs >= 1 ? null : 'schedule.everyMs must be a positive integer';
  if (schedule.kind === 'cron') return nextCronRun(schedule.expr ?? '', Date.now()) ? null : `invalid cron expression: ${schedule.expr}`;
  if (schedule.kind === 'at') return Number.isFinite(Date.parse(schedule.at)) ? null : 'schedule.at must be an ISO 8601 time';
  return `unsupported schedule kind: ${schedule.kind}`;
}

function validJob(job) {
  if (!job.name?.trim()) return 'name is required';
  const schedule = validSchedule(job.schedule);
  if (schedule) return schedule;
  const kind = job.payload?.kind;
  if (job.sessionTarget === 'main' && kind !== 'systemEvent') return 'main cron jobs require payload.kind="systemEvent"';
  if (job.sessionTarget !== 'main' && kind !== 'agentTurn') return 'isolated/current/session cron jobs require payload.kind="agentTurn"';
  if (kind === 'agentTurn' && !job.payload.message?.trim()) return 'payload.message is required';
  if (kind === 'systemEvent' && !job.payload.text?.trim()) return 'payload.text is required';
  return null;
}

export function createCronState(base = Date.now()) {
  const jobs = new Map();
  const runs = [];
  function job(props, state = {}) {
    const entry = {
      id: props.id,
      agentId: props.agentId ?? 'main',
      name: props.name,
      description: props.description,
      enabled: props.enabled ?? true,
      createdAtMs: base - 30 * DAY,
      updatedAtMs: base - DAY,
      schedule: props.schedule,
      sessionTarget: props.sessionTarget ?? 'isolated',
      wakeMode: 'now',
      payload: props.payload,
      delivery: props.delivery ?? { mode: 'none' },
      state,
    };
    jobs.set(entry.id, entry);
    return entry;
  }
  function run(jobId, agoMs, props) {
    const entry = jobs.get(jobId);
    runs.push({
      ts: base - agoMs + (props.durationMs ?? 0),
      runAtMs: base - agoMs,
      jobId,
      jobName: entry.name,
      action: 'finished',
      runId: `run_seed_${runs.length + 1}`,
      sessionKey: `agent:${entry.agentId}:cron:${jobId}`,
      model: 'claude-opus-4-8',
      provider: 'anthropic',
      ...props,
    });
  }

  job({
    id: 'morning-briefing',
    name: 'Morning briefing',
    description: 'Weather, calendar and anything odd overnight.',
    schedule: { kind: 'cron', expr: '0 7 * * *', tz: 'America/New_York' },
    payload: { kind: 'agentTurn', message: 'Write my morning briefing: weather, calendar and anything odd overnight.' },
    delivery: { mode: 'announce', channel: 'discord', to: '#home-lab' },
  }, { lastRunAtMs: base - 3 * HOUR, lastRunStatus: 'ok', lastDurationMs: 41_200, lastDelivered: true, lastDeliveryStatus: 'delivered' });
  run('morning-briefing', 3 * HOUR, { status: 'ok', durationMs: 41_200, summary: 'Clear skies, two meetings, and the lab sensor is quiet.', deliveryStatus: 'delivered' });
  run('morning-briefing', 27 * HOUR, { status: 'ok', durationMs: 38_900, summary: 'Rain after 3pm; the dentist moved to Thursday.', deliveryStatus: 'delivered' });

  job({
    id: 'disk-check',
    name: 'Check disk space',
    schedule: { kind: 'every', everyMs: 6 * HOUR, anchorMs: base - 30 * DAY },
    payload: { kind: 'agentTurn', message: 'Check free space on every volume and warn me under 10%.' },
  }, {
    lastRunAtMs: base - 2 * HOUR,
    lastRunStatus: 'error',
    lastError: 'df: /Volumes/Backup: No such file or directory',
    lastDurationMs: 8_400,
    consecutiveErrors: 2,
  });
  run('disk-check', 2 * HOUR, { status: 'error', durationMs: 8_400, error: 'df: /Volumes/Backup: No such file or directory' });
  run('disk-check', 8 * HOUR, { status: 'error', durationMs: 7_900, error: 'df: /Volumes/Backup: No such file or directory' });
  run('disk-check', 14 * HOUR, { status: 'ok', durationMs: 6_100, summary: 'All volumes above 40% free.' });

  job({
    id: 'paper-digest',
    agentId: 'research',
    name: 'Weekly paper digest',
    enabled: false,
    schedule: { kind: 'cron', expr: '0 9 * * 1' },
    payload: { kind: 'agentTurn', message: 'Summarize the week’s most-cited diffusion papers.' },
  });

  const state = { jobs, runs, enabled: true, active: new Map() };
  for (const entry of jobs.values()) refresh(state, entry, base);
  return state;
}

function refresh(cron, job, now = Date.now()) {
  job.state.nextRunAtMs = nextRun(job, now);
  if (job.state.nextRunAtMs === undefined) delete job.state.nextRunAtMs;
  job.configRevision = revisionOf(job);
}

function publicJob(job) {
  return clone(job);
}

function sortedJobs(cron, params) {
  let list = [...cron.jobs.values()];
  if (!params.includeDisabled && params.enabled !== 'all' && params.enabled !== 'disabled') list = list.filter((job) => job.enabled);
  if (params.enabled === 'disabled') list = list.filter((job) => !job.enabled);
  if (params.agentId) list = list.filter((job) => job.agentId === params.agentId);
  const dir = params.sortDir === 'desc' ? -1 : 1;
  const sortBy = params.sortBy ?? 'nextRunAtMs';
  return list.sort((a, b) => {
    if (sortBy === 'name') return dir * a.name.localeCompare(b.name);
    const key = sortBy === 'updatedAtMs' ? (job) => job.updatedAtMs : (job) => job.state.nextRunAtMs ?? Number.MAX_SAFE_INTEGER;
    return dir * (key(a) - key(b));
  });
}

function page(items, params) {
  const limit = Math.min(Math.max(Number(params.limit) || 50, 1), 200);
  const offset = Math.max(Number(params.offset) || 0, 0);
  const slice = items.slice(offset, offset + limit);
  const nextOffset = offset + slice.length;
  const hasMore = nextOffset < items.length;
  return { total: items.length, offset, limit, hasMore, nextOffset: hasMore ? nextOffset : null, slice };
}

function findJob(cron, params) {
  return cron.jobs.get(params.id ?? params.jobId);
}

function jobChanged(state, broadcast, jobId, action, extra = {}) {
  broadcast(state, 'cron', { jobId, action, ...extra });
}

function startRun(state, job, { broadcast, postToSession }) {
  const cron = state.cronState;
  const runId = `run_cron_${crypto.randomBytes(4).toString('hex')}`;
  const startedAt = Date.now();
  const sessionKey = `agent:${job.agentId}:cron:${job.id}`;
  job.state.runningAtMs = startedAt;
  jobChanged(state, broadcast, job.id, 'started', { runId, runAtMs: startedAt });
  const timer = setTimeout(() => {
    cron.active.delete(runId);
    if (!cron.jobs.has(job.id)) return;
    const text = job.payload.message ?? job.payload.text ?? '';
    const failed = /fail/i.test(text);
    const summary = failed ? undefined : `Done: ${text.slice(0, 80)}`;
    const error = failed ? 'Mock failure: the task asked to fail.' : undefined;
    postToSession(state, sessionKey, {
      agentId: job.agentId,
      label: `Automation: ${job.name}`,
      userText: text,
      replyText: error ?? summary,
    });
    const durationMs = Date.now() - startedAt;
    delete job.state.runningAtMs;
    Object.assign(job.state, {
      lastRunAtMs: startedAt,
      lastRunStatus: failed ? 'error' : 'ok',
      lastDurationMs: durationMs,
      consecutiveErrors: failed ? (job.state.consecutiveErrors ?? 0) + 1 : 0,
    });
    if (failed) job.state.lastError = error;
    else delete job.state.lastError;
    if (job.schedule.kind === 'at') job.enabled = false;
    refresh(cron, job);
    cron.runs.push({
      ts: Date.now(),
      runAtMs: startedAt,
      jobId: job.id,
      jobName: job.name,
      action: 'finished',
      status: failed ? 'error' : 'ok',
      ...(error ? { error } : { summary }),
      durationMs,
      runId,
      sessionKey,
      deliveryStatus: job.delivery?.mode === 'announce' ? 'delivered' : 'not-requested',
      model: 'claude-opus-4-8',
      provider: 'anthropic',
    });
    jobChanged(state, broadcast, job.id, 'finished', { runId, status: failed ? 'error' : 'ok' });
  }, RUN_DURATION_MS);
  cron.active.set(runId, timer);
  return runId;
}

export function handleCronRequest(state, conn, msg, { sendRes, sendErr, broadcast, postToSession }) {
  const { id, method, params = {} } = msg;
  if (!CRON_METHODS.includes(method)) return false;
  const cron = state.cronState;
  if (ADMIN_METHODS.has(method) && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const invalid = (message) => sendErr(conn, id, 'INVALID_REQUEST', message);
  switch (method) {
    case 'cron.status': {
      const next = [...cron.jobs.values()].map((job) => job.state.nextRunAtMs).filter((ms) => ms !== undefined);
      sendRes(conn, id, {
        enabled: cron.enabled,
        triggersEnabled: true,
        jobs: cron.jobs.size,
        ...(next.length ? { nextWakeAtMs: Math.min(...next) } : {}),
      });
      break;
    }
    case 'cron.list': {
      const { slice, ...meta } = page(sortedJobs(cron, params), params);
      sendRes(conn, id, { jobs: slice.map(publicJob), snapshotRevision: `mock-${cron.jobs.size}`, ...meta });
      break;
    }
    case 'cron.get': {
      const job = findJob(cron, params);
      if (!job) return invalid('cron job not found'), true;
      sendRes(conn, id, publicJob(job));
      break;
    }
    case 'cron.runs': {
      const jobId = params.id ?? params.jobId;
      let entries = cron.runs.filter((run) => (params.scope === 'all' || !jobId ? true : run.jobId === jobId));
      if (params.runId) entries = entries.filter((run) => run.runId === params.runId);
      if (params.statuses?.length) entries = entries.filter((run) => params.statuses.includes(run.status));
      entries = entries.sort((a, b) => (params.sortDir === 'asc' ? a.ts - b.ts : b.ts - a.ts));
      const { slice, ...meta } = page(entries, params);
      sendRes(conn, id, { entries: clone(slice), ...meta });
      break;
    }
    case 'cron.add': {
      const now = Date.now();
      const job = {
        id: `job_${crypto.randomBytes(4).toString('hex')}`,
        agentId: params.agentId ?? 'main',
        name: params.name?.trim(),
        description: params.description,
        enabled: params.enabled ?? true,
        deleteAfterRun: params.deleteAfterRun,
        createdAtMs: now,
        updatedAtMs: now,
        schedule: params.schedule,
        sessionTarget: params.sessionTarget ?? 'isolated',
        wakeMode: params.wakeMode ?? 'now',
        payload: params.payload,
        delivery: params.delivery,
        state: {},
      };
      const problem = validJob(job);
      if (problem) return invalid(problem), true;
      cron.jobs.set(job.id, job);
      refresh(cron, job, now);
      sendRes(conn, id, publicJob(job));
      jobChanged(state, broadcast, job.id, 'added');
      break;
    }
    case 'cron.update': {
      const job = findJob(cron, params);
      if (!job) return invalid('cron job not found'), true;
      if (params.expectedConfigRevision && params.expectedConfigRevision !== job.configRevision) {
        return sendErr(conn, id, 'CONFLICT', 'cron job changed since it was loaded (config revision mismatch)'), true;
      }
      const patch = params.patch ?? {};
      const next = clone(job);
      for (const [key, value] of Object.entries(patch)) {
        if (key === 'state') continue;
        if (value === null) delete next[key];
        else if (key === 'payload' && value.kind === next.payload?.kind) next.payload = { ...next.payload, ...value };
        else if (key === 'delivery') next.delivery = { ...(value.mode === next.delivery?.mode ? next.delivery : {}), ...value };
        else next[key] = value;
      }
      const problem = validJob(next);
      if (problem) return invalid(problem), true;
      next.updatedAtMs = Date.now();
      cron.jobs.set(job.id, next);
      refresh(cron, next);
      sendRes(conn, id, publicJob(next));
      jobChanged(state, broadcast, job.id, 'updated');
      break;
    }
    case 'cron.remove': {
      const job = findJob(cron, params);
      if (!job) return invalid('cron job not found'), true;
      cron.jobs.delete(job.id);
      cron.runs = cron.runs.filter((run) => run.jobId !== job.id);
      sendRes(conn, id, { ok: true, removed: true });
      jobChanged(state, broadcast, job.id, 'removed');
      break;
    }
    case 'cron.run': {
      const job = findJob(cron, params);
      if (!job) return invalid('cron job not found'), true;
      const mode = params.mode ?? 'force';
      if (mode === 'if-enabled' && !job.enabled) return sendRes(conn, id, { ok: true, ran: false, reason: 'disabled' }), true;
      if (mode === 'due' && (job.state.nextRunAtMs ?? Infinity) > Date.now()) return sendRes(conn, id, { ok: true, ran: false, reason: 'not-due' }), true;
      if (job.state.runningAtMs) return sendRes(conn, id, { ok: true, ran: false, reason: 'already-running' }), true;
      const runId = startRun(state, job, { broadcast, postToSession });
      sendRes(conn, id, { ok: true, enqueued: true, runId });
      break;
    }
  }
  return true;
}
