# Mock OpenClaw Gateway

Standalone Node.js mock WebSocket gateway for integration-testing an OpenClaw Gateway v4 operator client.

```bash
npm install
npm start
```

Defaults: `HOST=127.0.0.1`, `PORT=18789`, `MOCK_TOKEN=dev-token`, `MOCK_PAIRING=auto`.

Pairing modes:

- `auto`: first unknown device receives `PAIRING_REQUIRED`, then is approved after about 3 seconds.
- `off`: unknown devices are accepted.
- `manual`: approve by typing the printed `requestId` on stdin.

Chat triggers: messages mentioning `tool`, `disk` or `image` stream a tool call; `approve` raises an exec approval; `plan` walks a three-step `progress_card` (`progressCard.get`/`progressCard.put`, `progressCard.changed`).

Like the Gateway, `chat.history` caps text fields at 8,000 characters, appends `...(truncated)...` and sets `__openclaw.truncated`; `chat.message.get` returns the full message. The research agent's main session opens with one capped report.

Run the full in-process self-test:

```bash
npm test --if-present
npm run selftest
```

Config and plugins (`config.mjs`):

- `config.get`, `config.schema`, `config.patch`, `config.set`, `config.apply` with redacted secrets, `baseHash` checks, validation issues, and `restart` for `gateway.*` changes. Writes need the `operator.admin` scope.
- `plugins.list`, `plugins.inspect`, `plugins.setEnabled`, `plugins.install`, `plugins.uninstall`, broadcasting `plugins.changed`.
- `weather` needs an `apiKey` (at least 8 characters); `browser` asks for capability consent before enabling; bundled plugins can't be removed.
- Install specs containing `missing` fail as not found; specs containing `unverified` require acknowledging the install policy warning.

Automations (`cron.mjs`):

- `cron.status`, `cron.list` (paging, `includeDisabled`, sorting), `cron.get`, `cron.runs`, `cron.add`, `cron.update`, `cron.remove` and `cron.run`. Writes need the `operator.admin` scope, and `cron.update` rejects a stale `expectedConfigRevision`.
- Seeded jobs: `morning-briefing` (cron, announces to Discord), `disk-check` (every 6 hours, failing) and `paper-digest` (research agent, paused), with run history.
- `cron.run` broadcasts `cron` started/finished events, posts the run into the job's chat (`agent:<agent>:cron:<id>`), and records it in the run log. A job whose message contains `fail` fails.
