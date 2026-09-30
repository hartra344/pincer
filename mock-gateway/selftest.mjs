import { startServer } from './server.mjs';

// Ordered: the first sections share one server and later ones depend on the state they leave behind.
const SECTIONS = [
  'chat',
  'file-edits',
  'tool-cards',
  'send-hooks',
  'replies',
  'reactions',
  'webpush',
  'approvals',
  'questions',
  'config',
  'cron',
  'scope-upgrade',
  'exec-approvals',
  'context-usage',
  'approval-history',
  'logs',
  'exec-approvals-variants',
  'usage',
  'tts',
  'tts-setup',
  'tts-keys',
  'channel-pairing',
  'health',
  'setup',
  'outbox',
  'channels',
  'agents',
  'subagents',
  'devices',
  'skills',
  'mcp',
  'first-run',
  'sessions',
  'large-media',
];

const server = await startServer({ host: '127.0.0.1', port: 0, pairing: 'auto', mockToken: 'dev-token' });
try {
  const ctx = { server };
  for (const name of SECTIONS) {
    await (await import(`./selftest/${name}.mjs`)).run(ctx);
  }
  console.log('PASS');
} finally {
  await server.close();
}
