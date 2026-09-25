// Mock of the Gateway's config and plugin management RPCs:
// config.get / config.schema / config.patch / config.apply and plugins.list / inspect /
// setEnabled / install / uninstall. Writes need operator.admin, like the real Gateway.
import crypto from 'node:crypto';

export const REDACTED = '__OPENCLAW_REDACTED__';
export const ADMIN_SCOPE = 'operator.admin';
export const CONFIG_METHODS = [
  'config.get',
  'config.schema',
  'config.patch',
  'config.apply',
  'plugins.list',
  'plugins.inspect',
  'plugins.setEnabled',
  'plugins.install',
  'plugins.uninstall',
];
const ADMIN_METHODS = new Set(['config.patch', 'config.apply', 'config.set', 'plugins.setEnabled', 'plugins.install', 'plugins.uninstall']);
const CONFIG_PATH = '/home/mock/.openclaw/openclaw.json';

const clone = (value) => structuredClone(value);
const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

export function createConfigState() {
  return {
    config: {
      gateway: { port: 18789, bind: 'tailnet', auth: { mode: 'token', token: 'dev-token' } },
      agents: { defaults: { model: 'anthropic/claude-sonnet-4-5', thinkingDefault: 'low', timeoutSeconds: 600 } },
      channels: { discord: { enabled: true, token: 'discord-bot-secret', dmPolicy: 'pairing' } },
      tools: { allow: ['exec', 'read', 'write'] },
      plugins: {
        enabled: true,
        entries: {
          weather: { enabled: true, config: { units: 'metric' } },
          'memory-lancedb': { enabled: false, config: {} },
          browser: { enabled: false },
        },
      },
    },
    catalog: new Map([
      ['weather', { id: 'weather', name: 'Weather', description: 'Forecasts and current conditions.', version: '1.2.0', origin: 'clawhub', packageName: '@openclaw/weather', removable: true, kind: ['tool'] }],
      ['memory-lancedb', { id: 'memory-lancedb', name: 'LanceDB Memory', description: 'Long-term memory backed by LanceDB.', version: '2026.9.0', origin: 'bundled', removable: false, kind: ['memory'] }],
      ['browser', { id: 'browser', name: 'Browser', description: 'Lets agents drive a headless browser.', version: '2026.9.0', origin: 'bundled', removable: false, kind: ['tool'], needsConsent: true }],
    ]),
    generation: 1,
  };
}

function pluginSchemas(state) {
  const properties = {};
  for (const plugin of state.catalog.values()) {
    const config = plugin.id === 'weather'
      ? {
          type: 'object',
          required: ['apiKey'],
          properties: {
            apiKey: { type: 'string', minLength: 8, description: 'Key from your weather provider.' },
            units: { type: 'string', enum: ['metric', 'imperial'], default: 'metric' },
            refreshMinutes: { type: 'integer', minimum: 5, maximum: 1440 },
          },
        }
      : { type: 'object', additionalProperties: {} };
    properties[plugin.id] = { type: 'object', properties: { enabled: { type: 'boolean' }, config } };
  }
  return properties;
}

function buildSchema(state) {
  return {
    type: 'object',
    properties: {
      gateway: {
        type: 'object',
        required: ['port'],
        properties: {
          port: { type: 'integer', minimum: 1, maximum: 65535 },
          bind: { anyOf: [{ const: 'loopback' }, { const: 'lan' }, { const: 'tailnet' }, { const: 'auto' }] },
          auth: {
            type: 'object',
            properties: {
              mode: { type: 'string', enum: ['none', 'token', 'password', 'trusted-proxy'] },
              token: { anyOf: [{ type: 'string' }, { type: 'object', properties: { source: { type: 'string' }, provider: { type: 'string' }, id: { type: 'string' } } }] },
            },
          },
        },
      },
      agents: {
        type: 'object',
        properties: {
          defaults: {
            type: 'object',
            properties: {
              model: { type: 'string', minLength: 3 },
              thinkingDefault: { type: 'string', enum: ['off', 'minimal', 'low', 'medium', 'high'] },
              timeoutSeconds: { type: 'integer', minimum: 1 },
            },
          },
        },
      },
      channels: {
        type: 'object',
        properties: {
          discord: {
            type: 'object',
            properties: {
              enabled: { type: 'boolean' },
              token: { type: 'string' },
              dmPolicy: { type: 'string', enum: ['pairing', 'allowlist', 'open', 'disabled'] },
            },
          },
        },
      },
      tools: { type: 'object', properties: { allow: { type: 'array', items: { type: 'string' } } } },
      plugins: {
        type: 'object',
        properties: {
          enabled: { type: 'boolean' },
          allow: { type: 'array', items: { type: 'string' } },
          deny: { type: 'array', items: { type: 'string' } },
          entries: {
            type: 'object',
            properties: pluginSchemas(state),
            additionalProperties: { type: 'object', properties: { enabled: { type: 'boolean' }, config: { type: 'object', additionalProperties: {} } } },
          },
        },
      },
    },
  };
}

const UI_HINTS = {
  gateway: { label: 'Gateway', order: 1 },
  'gateway.port': { label: 'Port', help: 'Port the Gateway listens on.', order: 1 },
  'gateway.bind': { label: 'Bind', help: 'Which network interfaces the Gateway listens on.', order: 2 },
  'gateway.auth.token': { label: 'Token', sensitive: true },
  agents: { label: 'Agents', order: 2 },
  'agents.defaults.model': { label: 'Default model', placeholder: 'provider/model' },
  channels: { label: 'Channels', order: 3 },
  'channels.discord.token': { label: 'Bot token', sensitive: true },
  tools: { label: 'Tools', order: 4 },
  plugins: { label: 'Plugins', order: 5 },
  'plugins.entries.weather.config.apiKey': { label: 'API key', sensitive: true },
};

function sensitive(path) {
  const key = path.join('.');
  return Boolean(UI_HINTS[key]?.sensitive);
}

function redact(value, path = []) {
  if (Array.isArray(value)) return value.map((item, index) => redact(item, [...path, String(index)]));
  if (isObject(value)) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, redact(v, [...path, k])]));
  if (typeof value === 'string' && sensitive(path)) return REDACTED;
  return value;
}

function restore(value, original, path = []) {
  if (value === REDACTED) {
    if (original === undefined) throw Object.assign(new Error(`invalid config: ${path.join('.')}: redacted value has no original`), { issues: [{ path: path.join('.'), message: 'redacted value has no original' }] });
    return original;
  }
  if (Array.isArray(value)) return value.map((item, index) => restore(item, original?.[index], [...path, String(index)]));
  if (isObject(value)) return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, restore(v, isObject(original) ? original[k] : undefined, [...path, k])]));
  return value;
}

function mergePatch(target, patch) {
  if (!isObject(patch)) return clone(patch);
  const result = isObject(target) ? clone(target) : {};
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) delete result[key];
    else result[key] = mergePatch(result[key], value);
  }
  return result;
}

function validateNode(root, node, value, path, issues) {
  if (!node || value === undefined) return;
  const where = path.join('.');
  if (node.anyOf) {
    const consts = node.anyOf.filter((b) => 'const' in b).map((b) => b.const);
    if (consts.length === node.anyOf.length) {
      if (!consts.includes(value)) issues.push({ path: where, message: `must be one of ${consts.join(', ')}`, allowedValues: consts });
      return;
    }
    const branch = node.anyOf.find((b) => (b.type === 'object') === isObject(value)) ?? node.anyOf[0];
    return validateNode(root, branch, value, path, issues);
  }
  const type = node.type;
  const actual = Array.isArray(value) ? 'array' : value === null ? 'null' : typeof value;
  if (type === 'integer' && !(typeof value === 'number' && Number.isInteger(value))) return issues.push({ path: where, message: 'expected an integer' });
  if (type === 'number' && typeof value !== 'number') return issues.push({ path: where, message: 'expected a number' });
  if (['string', 'boolean', 'array', 'object'].includes(type) && actual !== type) return issues.push({ path: where, message: `expected ${type}, got ${actual}` });
  if (node.enum && !node.enum.includes(value)) issues.push({ path: where, message: `must be one of ${node.enum.join(', ')}`, allowedValues: node.enum });
  if (typeof node.minimum === 'number' && value < node.minimum) issues.push({ path: where, message: `must be >= ${node.minimum}` });
  if (typeof node.maximum === 'number' && value > node.maximum) issues.push({ path: where, message: `must be <= ${node.maximum}` });
  if (typeof node.minLength === 'number' && typeof value === 'string' && value.length < node.minLength) issues.push({ path: where, message: `must be at least ${node.minLength} characters` });
  if (type === 'array' && node.items) value.forEach((item, index) => validateNode(root, node.items, item, [...path, String(index)], issues));
  if (type === 'object') {
    for (const key of node.required ?? []) {
      if (value[key] === undefined) issues.push({ path: [...path, key].join('.'), message: 'required' });
    }
    for (const [key, child] of Object.entries(value)) {
      const childNode = node.properties?.[key] ?? (isObject(node.additionalProperties) ? node.additionalProperties : undefined);
      if (childNode) validateNode(root, childNode, child, [...path, key], issues);
      else if (node.properties && node.additionalProperties === undefined && path.length < 2) {
        issues.push({ path: [...path, key].join('.'), message: 'unknown key' });
      }
    }
  }
}

function validate(state, config) {
  const issues = [];
  const schema = buildSchema(state);
  validateNode(schema, schema, config, [], issues);
  // A plugin missing required settings shows as "needs setup" instead of invalidating the config.
  for (let i = issues.length - 1; i >= 0; i--) {
    if (/^plugins\.entries\.[^.]+\.config\./.test(issues[i].path) && issues[i].message === 'required') issues.splice(i, 1);
  }
  for (const id of Object.keys(config.plugins?.entries ?? {})) {
    if (!state.catalog.has(id)) issues.push({ path: `plugins.entries.${id}`, message: `unknown plugin "${id}"`, fixHint: 'Install the plugin first.' });
  }
  return issues;
}

function hashOf(config) {
  return crypto.createHash('sha256').update(JSON.stringify(config)).digest('hex').slice(0, 32);
}

function changedPaths(before, after, path = []) {
  if (isObject(before) && isObject(after)) {
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    return [...keys].flatMap((key) => changedPaths(before[key], after[key], [...path, key]));
  }
  return JSON.stringify(before) === JSON.stringify(after) ? [] : [path.join('.')];
}

function snapshot(state) {
  const issues = validate(state, state.config);
  const redacted = redact(state.config);
  return {
    path: CONFIG_PATH,
    exists: true,
    raw: JSON.stringify(redacted, null, 2),
    parsed: redacted,
    resolved: redacted,
    config: redacted,
    valid: issues.length === 0,
    issues,
    warnings: [],
    legacyIssues: [],
    hash: hashOf(state.config),
  };
}

function pluginEntry(state, plugin) {
  const entry = state.config.plugins?.entries?.[plugin.id] ?? {};
  const enabled = entry.enabled === true && state.config.plugins?.enabled !== false;
  let pluginState = enabled ? 'enabled' : 'disabled';
  if (enabled && plugin.id === 'weather' && !entry.config?.apiKey) pluginState = 'needs-setup';
  const { needsConsent, ...wire } = plugin;
  return {
    ...wire,
    installed: true,
    enabled,
    state: pluginState,
    runtime: { state: pluginState === 'enabled' ? 'active' : pluginState === 'needs-setup' ? 'unloaded' : 'disabled' },
  };
}

function invalidConfig(issues) {
  const lines = issues.slice(0, 3).map((issue) => `${issue.path}: ${issue.message}`);
  const more = issues.length > 3 ? ` (+${issues.length - 3} more issues)` : '';
  return { code: 'INVALID_REQUEST', message: `invalid config: ${lines.join('; ')}${more}`, details: { issues } };
}

/** Handles a config/plugin request; returns false when the method isn't one of ours. */
export function handleConfigRequest(state, conn, msg, { sendRes, sendErr, broadcast }) {
  const { id, method, params = {} } = msg;
  if (!CONFIG_METHODS.includes(method) && method !== 'config.set') return false;
  const cfg = state.configState;
  if (ADMIN_METHODS.has(method) && !(conn.scopes ?? []).includes(ADMIN_SCOPE)) {
    sendErr(conn, id, 'FORBIDDEN', `missing scope: ${ADMIN_SCOPE}`, { code: 'MISSING_SCOPE', scope: ADMIN_SCOPE });
    return true;
  }
  const fail = ({ code, message, details }) => sendErr(conn, id, code, message, details);

  const commit = (next, { partial }) => {
    const issues = validate(cfg, next);
    if (issues.length) return fail(invalidConfig(issues));
    const changed = changedPaths(cfg.config, next);
    if (!changed.length) return sendRes(conn, id, { ok: true, noop: true, changedPaths: [], path: CONFIG_PATH, config: redact(cfg.config) });
    cfg.config = next;
    const restart = changed.some((path) => path.startsWith('gateway.'));
    sendRes(conn, id, {
      ok: true,
      path: CONFIG_PATH,
      hash: hashOf(next),
      config: redact(next),
      ...(partial ? { changedPaths: changed } : {}),
      ...(restart ? { restart: { coalesced: false, delayMs: 2000 } } : {}),
    });
    if (changed.some((path) => path.startsWith('plugins.'))) {
      cfg.generation += 1;
      broadcast(state, 'plugins.changed', { generation: cfg.generation });
    }
  };

  const parseWrite = () => {
    if (hashOf(cfg.config) !== params.baseHash) {
      fail({
        code: 'INVALID_REQUEST',
        message: params.baseHash ? 'config changed since last load; re-run config.get and retry' : 'config base hash required; re-run config.get and retry',
      });
      return undefined;
    }
    try {
      return JSON.parse(params.raw);
    } catch (err) {
      fail({ code: 'INVALID_REQUEST', message: `invalid config: could not parse: ${err.message}`, details: { issues: [{ path: '', message: 'could not parse JSON' }] } });
      return undefined;
    }
  };

  switch (method) {
    case 'config.get':
      sendRes(conn, id, snapshot(cfg));
      break;
    case 'config.schema':
      sendRes(conn, id, { schema: buildSchema(cfg), uiHints: UI_HINTS, version: '2026.9.0-mock', generatedAt: new Date().toISOString() });
      break;
    case 'config.patch': {
      const patch = parseWrite();
      if (patch === undefined) break;
      try {
        const restored = restore(patch, cfg.config);
        commit(mergePatch(cfg.config, restored), { partial: true });
      } catch (err) {
        fail(invalidConfig(err.issues ?? [{ path: '', message: err.message }]));
      }
      break;
    }
    case 'config.set':
    case 'config.apply': {
      const next = parseWrite();
      if (next === undefined) break;
      try {
        commit(restore(next, cfg.config), { partial: false });
      } catch (err) {
        fail(invalidConfig(err.issues ?? [{ path: '', message: err.message }]));
      }
      break;
    }
    case 'plugins.list':
      sendRes(conn, id, {
        generation: cfg.generation,
        plugins: [...cfg.catalog.values()].map((plugin) => pluginEntry(cfg, plugin)),
        diagnostics: [],
        mutationAllowed: (conn.scopes ?? []).includes(ADMIN_SCOPE),
      });
      break;
    case 'plugins.inspect': {
      const plugin = cfg.catalog.get(params.pluginId);
      if (!plugin) return fail({ code: 'INVALID_REQUEST', message: `unknown plugin: ${params.pluginId}` }), true;
      const entry = pluginEntry(cfg, plugin);
      sendRes(conn, id, {
        ok: true,
        plugin: { id: plugin.id, name: plugin.name, version: plugin.version, description: plugin.description, origin: plugin.origin, installed: true, enabled: entry.enabled },
        credentials: plugin.id === 'weather'
          ? [{ path: ['plugins', 'entries', 'weather', 'config', 'apiKey'], label: 'Weather API key', envVars: ['WEATHER_API_KEY'], signupUrl: 'https://example.com/weather/signup', requiresCredential: true }]
          : [],
        declared: {},
        components: {},
        reviewToken: `review_${plugin.id}`,
        grants: {},
      });
      break;
    }
    case 'plugins.setEnabled': {
      const plugin = cfg.catalog.get(params.pluginId);
      if (!plugin) return fail({ code: 'INVALID_REQUEST', message: `unknown plugin: ${params.pluginId}` }), true;
      if (params.enabled && plugin.needsConsent) {
        if (params.acknowledgeCapabilities?.reviewToken !== `review_${plugin.id}`) {
          return fail({
            code: 'INVALID_REQUEST',
            message: `${plugin.name} can control a web browser and read pages it opens. Allow these capabilities?`,
            details: { capabilityConsentCode: 'PLUGIN_CAPABILITY_CONSENT_REQUIRED', pluginId: plugin.id, reviewToken: `review_${plugin.id}` },
          }), true;
        }
      }
      const entries = (cfg.config.plugins ??= {}).entries ??= {};
      entries[plugin.id] = { ...(entries[plugin.id] ?? {}), enabled: params.enabled === true };
      cfg.generation += 1;
      sendRes(conn, id, { ok: true, plugin: pluginEntry(cfg, plugin), restartRequired: false, runtime: { operationId: `op_${cfg.generation}`, generation: cfg.generation, pluginIds: [plugin.id] } });
      broadcast(state, 'plugins.changed', { generation: cfg.generation });
      break;
    }
    case 'plugins.install': {
      const spec = params.packageName ?? params.spec ?? params.pluginId ?? '';
      if (!spec || spec.includes('missing')) {
        return fail({ code: 'INVALID_REQUEST', message: `package not found: ${spec}` }), true;
      }
      if (spec.includes('unverified') && params.acknowledgeInstallPolicyWarning !== true) {
        return fail({
          code: 'INVALID_REQUEST',
          message: `${spec} isn't verified on ClawHub. Install it anyway?`,
          details: { installPolicyCode: 'install_policy_warning_acknowledgement_required' },
        }), true;
      }
      const pluginId = spec.replace(/@[^/]*$/, '').split('/').pop().replace(/^openclaw-plugin-/, '') || 'plugin';
      const name = pluginId.split('-').map((word) => word[0].toUpperCase() + word.slice(1)).join(' ');
      const plugin = { id: pluginId, name, description: `Installed from ${params.source}.`, version: '1.0.0', origin: params.source, packageName: spec, removable: true, kind: ['tool'] };
      cfg.catalog.set(pluginId, plugin);
      const entries = (cfg.config.plugins ??= {}).entries ??= {};
      entries[pluginId] = { enabled: params.enable !== false, config: {} };
      cfg.generation += 1;
      sendRes(conn, id, { ok: true, plugin: pluginEntry(cfg, plugin), restartRequired: params.source === 'git', runtime: { operationId: `op_${cfg.generation}`, generation: cfg.generation, pluginIds: [pluginId] } });
      broadcast(state, 'plugins.changed', { generation: cfg.generation });
      break;
    }
    case 'plugins.uninstall': {
      const plugin = cfg.catalog.get(params.pluginId);
      if (!plugin) return fail({ code: 'INVALID_REQUEST', message: `unknown plugin: ${params.pluginId}` }), true;
      if (!plugin.removable) return fail({ code: 'INVALID_REQUEST', message: `${plugin.name} is bundled with OpenClaw; turn it off instead.` }), true;
      cfg.catalog.delete(plugin.id);
      delete cfg.config.plugins?.entries?.[plugin.id];
      cfg.generation += 1;
      sendRes(conn, id, { ok: true, pluginId: plugin.id, restartRequired: false, removed: [`~/.openclaw/extensions/${plugin.id}`] });
      broadcast(state, 'plugins.changed', { generation: cfg.generation });
      break;
    }
    default:
      return false;
  }
  return true;
}
