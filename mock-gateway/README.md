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

Chat triggers: messages mentioning `tool`, `disk` or `image` stream a tool call; `approve` raises an exec approval (with `request.allowedDecisions`; `approve once-only` leaves out `allow-always`, and `approve short-lived` expires after 3 seconds). Like the Gateway, `exec.approval.resolve` answers an unknown or expired id with `INVALID_REQUEST` "approval expired or not found" (`details.reason: APPROVAL_NOT_FOUND`), an identical retry with `{ok: true}`, a different decision with "approval already resolved" (`APPROVAL_ALREADY_RESOLVED`), and `allow-always` on a once-only approval with "allow-always is unavailable for this command" (`APPROVAL_ALLOW_ALWAYS_UNAVAILABLE`, still pending); `ask` asks an `ask_user` question (`question.requested`, `question.list`, `question.resolve`, `question.resolved`; needs `operator.questions`; with `MOCK_LEGACY_PAIRING=1`, first pairings leave that scope out so the next connect needs a scope upgrade, and `swift run PincerChecks --live-scope-upgrade ws://127.0.0.1:PORT dev-token` checks Pincer's fallback) and waits for the answer before replying; `plan` walks a three-step `progress_card` (`progressCard.get`/`progressCard.put`, `progressCard.changed`). For failure tests, a message containing `[mock:fail-send]` is refused with `UNAVAILABLE`, and `[mock:drop]` closes that connection (the client reconnects after its backoff).

Context and compaction: session rows carry `totalTokens`/`contextTokens` (main 172k and coder 190k of 200k; the research main session has no limit, so clients fall back to `models.list`, whose `contextTokens` only comes with `includeDetails`, then `defaults.contextTokens`). Each run adds tokens. `sessions.compact` (needs `operator.admin`) shrinks a session to 18%, appends a compaction marker and returns `tokensBefore`/`tokensAfter`, or `compacted: false` under 4,000 tokens. Sending `/compact [instructions]` does the same as a chat run with compaction events.

Like the Gateway, `chat.history` caps text fields at 8,000 characters, appends `...(truncated)...` and sets `__openclaw.truncated`; `chat.message.get` returns the full message. The research agent's main session opens with one capped report.

Run the full in-process self-test:

```bash
npm test --if-present
npm run selftest
```

Web Push (`webpush.mjs`):

- `push.web.vapidPublicKey`, `push.web.subscribe`, `push.web.unsubscribe` and `push.web.test`, which need `operator.write`. Subscriptions are bound to the device and upserted by endpoint. Loopback `http://` endpoints are allowed for testing.
- Like the Gateway, a finished chat and exec approval requests and resolutions send an RFC 8291 `aes128gcm` push with a VAPID header and TTL, `Urgency` and `Topic` headers. The payload is `{title, body, tag, url}`, with generic text and a Control UI path (`chat/<agent>/…` or `approve/<id>`). Endpoints that answer 404 or 410 are dropped.

Config and plugins (`config.mjs`):

- `config.get`, `config.schema`, `config.patch`, `config.set`, `config.apply` with redacted secrets, `baseHash` checks, validation issues, and `restart` for `gateway.*` changes. Writes need the `operator.admin` scope.
- `plugins.list`, `plugins.inspect`, `plugins.setEnabled`, `plugins.install`, `plugins.uninstall`, broadcasting `plugins.changed`.
- `weather` needs an `apiKey` (at least 8 characters); `browser` asks for capability consent before enabling; bundled plugins can't be removed.
- Install specs containing `missing` fail as not found; specs containing `unverified` require acknowledging the install policy warning.

Automations (`cron.mjs`):

- `cron.status`, `cron.list` (paging, `includeDisabled`, sorting), `cron.get`, `cron.runs`, `cron.add`, `cron.update`, `cron.remove` and `cron.run`. Writes need the `operator.admin` scope, and `cron.update` rejects a stale `expectedConfigRevision`.
- Seeded jobs: `morning-briefing` (cron, announces to Discord), `disk-check` (every 6 hours, failing) and `paper-digest` (research agent, paused), with run history.
- `cron.run` broadcasts `cron` started/finished events, posts the run into the job's chat (`agent:<agent>:cron:<id>`), and records it in the run log. A job whose message contains `fail` fails.

Approval history (`approvals.mjs`):

- `approval.history` (`cursor`, `limit` 1–100 defaulting to 50, `kind` `exec`/`plugin`/`system-agent`) returns the terminal ledger newest first as `{ items, nextCursor? }`; `approval.get` (`{ id }`) returns `{ approval }`, including pending exec approvals with `status: "pending"`. Both need `operator.approvals`. Snapshots follow the Gateway (`presentation.kind`, no `cwd`).
- Seeded with 60 records from the last 30 days: 30 `exec`, 18 `plugin` and 12 `system-agent`, covering every status, decision and reason, device/channel/runtime/system resolvers and records without a resolver or source. Two pages at the default limit.
- Cursors are opaque and bound to their `kind`; an unknown one fails with `INVALID_REQUEST` "invalid approval.history cursor". Unknown ids fail with `INVALID_REQUEST` and `details.reason: "APPROVAL_NOT_FOUND"`.
- `exec.approval.resolve` records the decision at the top of the history, resolved by the calling device.
- `MOCK_NO_APPROVAL_HISTORY=1` drops both methods from `hello-ok` and answers them with `UNKNOWN_METHOD`, like an older Gateway.

Channel pairing (`pairing.mjs`):

- `channels.pairing.list` (`{ channel?, accountId? }`) returns `{ accounts, requests, commandOwnerConfigured, limits }` like the Gateway: two pairing-policy accounts (Telegram "Home bot", which can notify, and Discord "Family server", which can't) and three requests (Maya Chen with a username, a Discord sender with only an id, and a Telegram request that expires about 2 minutes after the mock starts). Requests expire after an hour; up to 3 pending per account. An unknown `channel` fails with `INVALID_REQUEST` "unknown pairing channel: …".
- `channels.pairing.approve` (`{ channel, accountId, requestId, notify?, bootstrapCommandOwner? }`) returns `{ requestId, senderId, notification, commandOwnerBootstrap }`; `channels.pairing.dismiss` (`{ channel, accountId, requestId }`) returns `{ requestId, senderId }`. Both remove the request. A handled or expired request fails with `INVALID_REQUEST` "pending DM access request no longer exists", an account that isn't a pairing account with "channel account does not use DM pairing: channel:account". Params are closed objects.
- Every method needs `operator.pairing` (`operator.admin` covers it); `bootstrapCommandOwner: true` also needs `operator.admin`. Missing scopes fail with `FORBIDDEN` and `details: { code: "MISSING_SCOPE", missingScope, requiredScopes }`.
- `MOCK_CHANNEL_PAIRING=off` drops the methods from `hello-ok` and answers them with `UNKNOWN_METHOD`, like an older Gateway. `MOCK_CHANNEL_PAIRING_EVERY=<seconds>` adds a new request that often. There's no pairing event; clients poll.

Health and restart (`health.mjs`):

- `hello-ok.snapshot` carries `presence`, `health`, `stateVersion` and `uptimeMs` (the mock starts about 26 hours "up").
- `health` returns a Gateway-shaped summary: Discord connected (follows `channels.discord.enabled`), Slack not configured, `heartbeatSeconds: 1800` with the main agent's heartbeat on, and empty plugin errors, failed queues and quarantined engines. `status` returns a short summary with the uptime.
- `last-heartbeat` returns an `ok-token` heartbeat from 4 minutes ago. `system-presence` returns one entry per connected client (with its `deviceId`, `instanceId` and client info) plus a `kitchen-pi` node; connects and disconnects broadcast `presence`.
- `gateway.restart.request` (`{reason?, skipDeferral?}`, needs `operator.admin`, else `MISSING_SCOPE`) answers `{status, preflight: {safe, counts, blockers, summary}}`: `deferred` while a chat run is active (it restarts once the run finishes), `coalesced` if one is already pending (`skipDeferral: true` makes the pending one go now), otherwise `scheduled`. The restart broadcasts `shutdown` `{reason, restartExpectedMs: 1500}`, aborts active runs, closes every socket with 1012, refuses new ones (close 1013) for 1.5 seconds, then accepts connections with a fresh `uptimeMs`. Sessions and config survive.
- `MOCK_NO_HEALTH=1` drops all five methods from `hello-ok`, sends an empty snapshot and answers them with `UNKNOWN_METHOD`, like an older Gateway.
