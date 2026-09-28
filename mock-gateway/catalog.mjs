import { DEFAULT_CONTEXT_TOKENS, DEFAULT_MODEL, clone, sendErr, sendRes } from './util.mjs';

export const commandEntry = (name, description, { aliases = [], category, source = 'native', args, acceptsArgs } = {}) => ({
  name,
  textAliases: [name, ...aliases].map((alias) => `/${alias}`),
  description,
  ...(category ? { category } : {}),
  source,
  scope: 'both',
  acceptsArgs: acceptsArgs ?? Boolean(args?.length),
  ...(args ? { args } : {}),
});

export const choices = (...values) => values.map((value) => ({ value, label: value }));

export const COMMAND_CATALOG = [
  commandEntry('help', 'Show available commands.', { category: 'status' }),
  commandEntry('status', 'Show current status.', { category: 'status' }),
  commandEntry('new', 'Start a new session.', { category: 'session', acceptsArgs: true }),
  commandEntry('reset', 'Reset the current session.', { category: 'session', acceptsArgs: true }),
  commandEntry('stop', 'Stop the current run.', { category: 'session' }),
  commandEntry('restart', 'Restart OpenClaw.', { category: 'tools' }),
  commandEntry('model', 'Show or set the model.', { category: 'options', args: [{ name: 'model', description: 'Model id', type: 'string' }] }),
  commandEntry('think', 'Set thinking level.', { aliases: ['thinking', 't'], category: 'options', args: [{ name: 'level', description: 'Thinking level', type: 'string', dynamic: true }] }),
  commandEntry('verbose', 'Toggle verbose mode.', { aliases: ['v'], category: 'options', args: [{ name: 'mode', description: 'on, off, or full', type: 'string', choices: choices('on', 'off', 'full') }] }),
  commandEntry('reasoning', 'Toggle reasoning visibility.', { aliases: ['reason'], category: 'options', args: [{ name: 'mode', description: 'on, off, or stream', type: 'string', choices: choices('on', 'off', 'stream') }] }),
  { name: 'pair', nativeName: 'pair', description: 'Native-only command', source: 'native', scope: 'native', acceptsArgs: false },
  commandEntry('weather', 'Look up the weather.', { source: 'plugin', acceptsArgs: true }),
];

// `contextTokens` (the effective cap) is only sent with `includeDetails`, like the Gateway.
export const MODEL_CATALOG = [
  { id: 'claude-opus-4-8', name: 'Claude Opus 4.8', provider: 'anthropic', available: true, contextWindow: 1_000_000, contextTokens: 200_000 },
  { id: 'claude-sonnet-5', name: 'Claude Sonnet 5', provider: 'anthropic', available: true, contextWindow: 1_000_000, contextTokens: 200_000 },
  { id: 'gpt-5.6-sol', name: 'GPT-5.6 Sol', provider: 'openai', available: true, contextWindow: 400_000 },
  { id: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash', provider: 'google', available: false, unavailableReason: 'missing-auth', contextWindow: 1_000_000 },
];

export function modelCatalog(includeDetails) {
  return MODEL_CATALOG.map(({ contextTokens, ...model }) => (includeDetails && contextTokens ? { ...model, contextTokens } : { ...model }));
}

export function rowModel(row) {
  return { provider: row.modelProvider ?? DEFAULT_MODEL.provider, model: row.model ?? DEFAULT_MODEL.model };
}

export function sessionDefaults() {
  return { model: DEFAULT_MODEL.model, modelProvider: DEFAULT_MODEL.provider, contextTokens: DEFAULT_CONTEXT_TOKENS };
}

export const CATALOG_METHODS = new Set(['models.list', 'commands.list']);

export function handleCatalogRequest(state, conn, msg) {
  if (!CATALOG_METHODS.has(msg.method)) return false;
  dispatch(state, conn, msg);
  return true;
}

function dispatch(state, conn, msg) {
  const { id, method, params = {} } = msg;
  switch (method) {
    case 'models.list': {
      if (params.agentId && !state.agents.has(params.agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      sendRes(conn, id, { models: modelCatalog(params.includeDetails === true) });
      break;
    }
    case 'commands.list': {
      if (params.agentId && !state.agents.has(params.agentId)) return sendErr(conn, id, 'INVALID_REQUEST', 'unknown agent');
      if (params.sessionKey && !state.sessions.has(params.sessionKey)) return sendErr(conn, id, 'INVALID_REQUEST', 'Session not found.');
      const commands = COMMAND_CATALOG.filter((cmd) => !params.scope || cmd.scope === 'both' || cmd.scope === params.scope)
        .map(({ args, ...cmd }) => (params.includeArgs && args ? { ...cmd, args } : cmd));
      sendRes(conn, id, { commands: clone(commands) });
      break;
    }
  }
}
