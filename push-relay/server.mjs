import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRelay, loadEnvFile } from './relay.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const env = { ...loadEnvFile(process.env.RELAY_ENV_FILE ?? path.join(here, '.env')), ...process.env };

for (const name of ['RELAY_SECRET', 'APNS_KEY_ID', 'APNS_TEAM_ID']) {
  if (!env[name]) {
    console.error(`${name} is required (see README.md)`);
    process.exit(64);
  }
}
// A relative APNS_KEY_FILE is relative to this folder, so the .p8 can sit next to .env.
const key = env.APNS_KEY ?? (env.APNS_KEY_FILE ? fs.readFileSync(path.resolve(here, env.APNS_KEY_FILE), 'utf8') : undefined);
if (!key) {
  console.error('APNS_KEY or APNS_KEY_FILE is required (see README.md)');
  process.exit(64);
}

const relay = createRelay({
  secret: env.RELAY_SECRET,
  keyId: env.APNS_KEY_ID,
  teamId: env.APNS_TEAM_ID,
  key,
  topics: (env.APNS_TOPICS ?? 'chat.pincer.ios').split(',').map((s) => s.trim()).filter(Boolean),
  origins: {
    ...(env.APNS_PRODUCTION_ORIGIN ? { production: env.APNS_PRODUCTION_ORIGIN } : {}),
    ...(env.APNS_SANDBOX_ORIGIN ? { sandbox: env.APNS_SANDBOX_ORIGIN } : {}),
  },
});
const port = Number(env.PORT ?? 8787);
const host = env.HOST ?? '127.0.0.1';
relay.listen(port, host, () => console.log(`Pincer push relay on http://${host}:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => relay.close(() => process.exit(0)));
