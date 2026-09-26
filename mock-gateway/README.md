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

Gateway logs (`logs.mjs`):

- `logs.tail` (`cursor` ≥ 0, `limit` 1–5000 defaulting to 500, `maxBytes` 1–1,000,000 defaulting to 250,000) reads an in-memory log file by byte offset, like the Gateway's `readLogSlice`, and returns `{ file, cursor, size, lines, truncated, reset, skippedBytes? }`. Unknown params and bad types fail with `INVALID_REQUEST` "invalid logs.tail params: …". It needs `operator.read` (`operator.write` or `operator.admin` also work); otherwise `FORBIDDEN` with `details.code: "MISSING_SCOPE"`.
- Without a cursor it returns the tail (the last `maxBytes`, `truncated` when older lines were left out). The returned cursor ends on a complete line; a cursor in the middle of a line drops that partial line. A cursor past the end of the file resets to the tail (`reset`); one more than `maxBytes` behind fast-forwards (`reset`, `truncated` and `skippedBytes`). More than `limit` lines keeps the newest (`truncated`).
- The file is `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (a name only; nothing is written to disk), seeded with about 130 tslog-style JSON lines from the last 90 minutes across every level (including one that repeats the logger name as its first argument, a meta-object argument and a long prompt), plus a plain-text and an ANSI-colored line. A timer appends 1–3 lines a second; `chat.send` and `approve` add lines too.
- Chat triggers: `[mock:rotate-logs]` switches to the next day's file name with a fresh file; `[mock:truncate-logs]` empties the current file (the next read with a cursor gets `reset`); `[mock:log-burst]` appends 6,000 lines at once (the next read fast-forwards with `skippedBytes`); `[mock:logs-unavailable]` makes the next two reads fail with `UNAVAILABLE` "log read failed: EACCES: permission denied, open '…'".
- `MOCK_NO_LOGS=1` drops `logs.tail` from `hello-ok` and answers it with `UNKNOWN_METHOD`, like an older Gateway.
