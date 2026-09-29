// A chat of upstream-shaped tool calls for the expanded tool cards (issue #324): `exec` with its
// `details` envelope (src/agents/bash-tools.exec-types.ts), a failed `exec`, an `edit`, a bundle-MCP
// `server__tool` call, `web_fetch` (src/agents/tools/web-fetch.ts) and `read`. Mirrors the demo's
// DemoGateway+ToolCards.swift.

export const TOOL_CARDS_KEY = 'agent:main:dashboard:tool-cards';
export const TOOL_CARDS_TITLE = 'Check the MCP servers';
export const TOOL_CARDS_PREVIEW = 'Era needs a sign-in; the other servers are healthy.';

export const EXEC_COMMAND = 'openclaw mcp status --verbose 2>&1 | grep -A4 "^- Era"';
export const EXEC_OUTPUT = [
  'MCP servers (4 configured)',
  '',
  '- github',
  '  transport: stdio (npx -y @modelcontextprotocol/server-github)',
  '  status: connected',
  '  tools: 26',
  '  last ping: 212 ms ago',
  '- Era',
  '  transport: streamable-http (https://mcp.era.example/v1)',
  '  status: authorization required (OAuth pending)',
  '  tools: 0',
  '  last error: 401 Unauthorized — run `openclaw mcp auth Era` to sign in',
  '- filesystem',
  '  transport: stdio (npx -y @modelcontextprotocol/server-filesystem ~/src)',
  '  status: connected',
  '  tools: 11',
  '  last ping: 187 ms ago',
  '- postgres',
  '  transport: stdio (uvx mcp-server-postgres)',
  '  status: connected',
  '  tools: 5',
  '  last ping: 341 ms ago',
  '',
  '3 connected, 1 needs attention.',
].join('\n');
export const FAILED_OUTPUT = [
  'error: Era: OAuth authorization is required but no browser session is available',
  'hint: run `openclaw mcp auth Era` from a machine with a browser',
  'openclaw: failed to refresh 1 server (exit 1)',
].join('\n');
export const ISSUES = [
  { number: 318, title: 'Tool call output shows the raw JSON envelope', state: 'open', labels: ['bug', 'ui'], author: 'alex' },
  { number: 324, title: 'Redesign expanded tool-call cards', state: 'open', labels: ['enhancement', 'ui'], author: 'alex' },
  { number: 301, title: 'Failed tool calls need a clearer error state', state: 'open', labels: ['ui'], author: 'sam' },
];
const CONFIG_PATH = 'src/mcp/servers.json';
const FETCH_URL = 'https://docs.openclaw.example/mcp/connecting';
const FETCH_TEXT = [
  '# Connecting MCP servers',
  '',
  'OpenClaw can load tools from any Model Context Protocol server. Add the server under `mcp.servers`',
  'and run `openclaw mcp status` to check it.',
  '',
  '## OAuth servers',
  '',
  'Servers that use OAuth report `authorization required` until you run `openclaw mcp auth <server>`.',
].join('\n');
const CONFIG_DIFF = [
  '  1 {', '  2   "servers": {', '  3     "Era": {', '  4       "url": "https://mcp.era.example/v1",',
  '- 5       "auth": "none"', '+ 5       "auth": "oauth"', '  6     }', '  7   }', '  8 }',
].join('\n');

export function seededToolCards({ makeMessage, textBlock, toolCallBlock }) {
  const result = (id, name, text, { isError = false, details } = {}) =>
    makeMessage('toolResult', [textBlock(text)], { extra: { toolCallId: id, toolName: name, isError, ...(details ? { details } : {}) } });
  const cwd = '/Users/alex/src/pincer';
  return [
    makeMessage('user', [textBlock('Check the MCP servers. Era looks stuck.')]),
    makeMessage('assistant', [
      textBlock('Checking the status of each server.'),
      toolCallBlock('call_seed_exec_mcp', 'exec', { command: EXEC_COMMAND, workdir: '~/src/pincer', timeoutSeconds: 30 }),
    ]),
    result('call_seed_exec_mcp', 'exec', EXEC_OUTPUT, {
      details: { status: 'completed', exitCode: 0, durationMs: 1240, cwd, aggregated: EXEC_OUTPUT },
    }),
    makeMessage('assistant', [
      textBlock("Era is waiting on OAuth. I'll try refreshing it."),
      toolCallBlock('call_seed_exec_failed', 'exec', { command: 'openclaw mcp refresh Era', workdir: '~/src/pincer' }),
    ]),
    result('call_seed_exec_failed', 'exec', FAILED_OUTPUT, {
      isError: true,
      details: { status: 'failed', exitCode: 1, durationMs: 830, cwd, aggregated: FAILED_OUTPUT },
    }),
    makeMessage('assistant', [
      textBlock('That needs an interactive sign-in. Let me look at the config; Era has no auth set.'),
      toolCallBlock('call_seed_read_config', 'read', { path: CONFIG_PATH, offset: 1, limit: 40 }),
    ]),
    result('call_seed_read_config', 'read', '{\n  "servers": {\n    "Era": {\n      "url": "https://mcp.era.example/v1",\n      "auth": "none"\n    }\n  }\n}'),
    makeMessage('assistant', [
      toolCallBlock('call_seed_edit_config', 'edit', {
        file_path: CONFIG_PATH,
        old_string: '    "url": "https://mcp.era.example/v1",\n    "auth": "none"',
        new_string: '    "url": "https://mcp.era.example/v1",\n    "auth": "oauth"',
      }),
    ]),
    result('call_seed_edit_config', 'edit', `Successfully replaced 1 block(s) in ${CONFIG_PATH}.`, {
      details: { changed: true, diff: CONFIG_DIFF },
    }),
    makeMessage('assistant', [
      textBlock('Config updated. Checking for known issues with OAuth servers.'),
      toolCallBlock('call_seed_mcp_issues', 'github__search_issues', { query: 'MCP OAuth authorization required', repo: 'hartra344/pincer', state: 'open' }),
    ]),
    result('call_seed_mcp_issues', 'github__search_issues', JSON.stringify(ISSUES, null, 2)),
    makeMessage('assistant', [toolCallBlock('call_seed_web_fetch', 'web_fetch', { url: FETCH_URL, extractMode: 'markdown' })]),
    result('call_seed_web_fetch', 'web_fetch', FETCH_TEXT, {
      details: {
        url: FETCH_URL, finalUrl: FETCH_URL, status: 200, contentType: 'text/html', title: 'Connecting MCP servers',
        tookMs: 412, truncated: false, length: FETCH_TEXT.length, rawLength: 18204, extractMode: 'markdown',
        extractor: 'readability', fetchedAt: '2026-09-29T14:40:00.000Z',
      },
    }),
    makeMessage('assistant', [textBlock(`${TOOL_CARDS_PREVIEW} Run \`openclaw mcp auth Era\` on a machine with a browser to finish the sign-in.`)]),
  ];
}
