---
title: Mock gateway
description: Run a local Node mock of the OpenClaw Gateway protocol for development and testing.
---

For quick looks, the app's built-in [demo](../../getting-started/try-the-demo/) is enough. For the full protocol, including Gateway Settings and plugins, run the Node mock in `mock-gateway/`.

## Start it

```sh
cd mock-gateway && npm install
npm start                                   # ws://127.0.0.1:18789, token "dev-token"
MOCK_TOKEN= MOCK_BACKGROUND=1 npm start     # no auth, simulated Discord traffic
```

Then add `ws://127.0.0.1:18789` in Pincer with the token `dev-token`.

## Options

| Variable | Default | Effect |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | Address to listen on. |
| `PORT` | `18789` | Port to listen on. |
| `MOCK_TOKEN` | `dev-token` | Gateway token. Set it empty for no auth. |
| `MOCK_PAIRING` | `auto` | `auto` approves new devices after about 3 seconds, `off` accepts them right away, `manual` waits for you to type the `requestId`. |
| `MOCK_BACKGROUND` | off | Set to `1` for simulated Discord traffic. |
| `MOCK_NO_LOGS` | off | Set to `1` to look like a gateway without `logs.tail`: it's left out of `hello-ok` and answers `UNKNOWN_METHOD`. |
| `MOCK_NO_USAGE` | off | Set to `1` to act like a gateway without usage: the five usage methods are left out of `hello-ok` and answer `UNKNOWN_METHOD`. |
| `MOCK_USAGE_FORBIDDEN` | off | Set to `1` to refuse `usage.cost` with `FORBIDDEN`, as for an operator whose role can't see every session. |
| `MOCK_CHANNEL_PAIRING` | on | Set to `off` to hide the `channels.pairing.*` methods, like an older gateway. |
| `MOCK_CHANNEL_PAIRING_EVERY` | off | Seconds between new channel pairing requests. |
| `MOCK_NO_SUBSCRIPTION_ID` | off | Set to `1` to reject `subscriptionId` on `sessions.messages.subscribe` and `unsubscribe` with `INVALID_REQUEST`, like a gateway before 2026.9.7. |
| `MOCK_NO_HEALTH` | off | Set to `1` to drop the health and restart methods, like an older gateway. |
| `MOCK_NO_REPLY_TO` | off | Set to `1` to refuse `chat.send` with `replyToId`, like a gateway from before replies. Pincer then quotes the original in the text. |
| `MOCK_FAILED_DELIVERY` | on | Set to `off` to drop the mock's one failed delivery, so Health shows Healthy. |
| `MOCK_FAILED_DELIVERY_EVERY` | off | Seconds between new failed deliveries. Each one raises the count and sends `health`, so a dismissed issue comes back. |
| `MOCK_LONG_CHAT` | off | Set to a number, e.g. `20000`, to seed one extra chat, **Long chat (n)**, with that many alternating user and assistant messages of mixed length (short questions, markdown sections, code blocks, long replies). It pages through `chat.history` like any chat. For testing memory and prefetch on huge transcripts. |
| `MOCK_DELAY_METHODS` | off | Holds back responses, e.g. `sessions.subscribe=800,chat.history=300` (milliseconds). The handler still runs at once, so a snapshot is taken then and events sent meanwhile arrive before the response. For testing bootstrap races. |

## Test control (`mock.control`)

Mock-only RPC, never advertised in `hello-ok` and never used by the app. Checks open a second connection and call it with `{action, …}`; its own calls aren't counted.

| Action | What it does |
| --- | --- |
| `stats` | `{total, connections}`: RPC counts per method, and the ordered method log per connection (`connect` and `mock.control` aren't counted). |
| `resetStats` | Starts the counters from zero. |
| `setDelay` | `{delays: {method: ms}}` replaces the delayed-response table (`{}` clears it). |
| `emit` | `{event, payload, subscribedOnly?}` broadcasts an event to every other connection. |
| `patchSession` | `{key, patch, reason?}` updates a session row and broadcasts `sessions.changed` with it. |
| `drop` | Closes every other connection (1012), like a network drop. |

`swift run PincerChecks --live-reconnect ws://127.0.0.1:PORT dev-token` (against a fresh mock) uses these to check the bootstrap race, overlapping reconnects, request cancellation, and prints RPC counts per launch, reconnect and finished run.

## Message triggers

| Include this word | What happens |
| --- | --- |
| `tool`, `disk` | Streams a tool call. |
| `image` | Streams a tool call and attaches an image. |
| `image huge` | Replies with one image whose `artifacts.download` payload is 26 MiB, over Pincer's 25 MiB cap, so it shows "too large" instead of loading. Still a valid PNG. Instead of the usual tool call and chart. |
| `image many` | Replies with 40 distinct 3000×2000 images (a few hundred KB each on the wire, about 24 MB decoded), for testing the image memory budget and download limit. Instead of the usual tool call and chart. |
| `patch`, `diff` | Streams an `edit` tool call shaped like upstream's (`file_path`, `old_string`, `new_string`), shown as a [file diff](../../guides/file-diffs/). |
| `approve` | Raises an exec approval. |
| `approve once-only` | Raises an approval whose `allowedDecisions` leave out `allow-always`. **Always allow** then fails with `APPROVAL_ALLOW_ALWAYS_UNAVAILABLE` and the approval stays pending. |
| `approve short-lived` | Raises an approval that expires after 3 seconds, so acting on it afterwards gets `APPROVAL_NOT_FOUND` ("That approval expired. Nothing was run."). Mock only. |
| `login`, `sign in`, `secure form` | Raises a `secure_form` question for `mail.google.com`, carrying `{requestId, origin, fields, expiresAtMs}` and expecting `question.resolve` answers as `{requestId, answers:{fieldId:value}}`. The mock never echoes the values back. |
| `plan` | Walks a three-step progress card. |
| `[mock:fail-send]` | Refuses the `chat.send` with `UNAVAILABLE`, for testing failed sends. |
| `[mock:drop]` | Closes the connection. The client reconnects after its backoff. |
| `[mock:reject-send]` | Always refuses the `chat.send` with a non-retryable `INVALID_REQUEST`. The message shows **Failed** with Delete only. |
| `[mock:unavailable-once]` | Refuses the first attempt for an idempotency key with a retryable `UNAVAILABLE` ("Previous run is still shutting down…"). Retry goes through. |
| `[mock:drop-once]` | Closes the connection before accepting the first attempt. The message stays **Queued** and is sent on reconnect. |
| `[mock:drop-after-accept]` | Accepts the first attempt, then closes the connection without answering. The message lands once, even though Pincer sends it again. |
| `[mock:rotate-logs]` | Switches the log to the next day's file. Gateway Logs shows "Now reading …". |
| `[mock:truncate-logs]` | Empties the log file. Gateway Logs shows "Log file was rotated or truncated." |
| `[mock:log-burst]` | Writes 6,000 log lines at once. Gateway Logs skips ahead and says how much it skipped. |
| `[mock:logs-unavailable]` | The next two log reads fail with `UNAVAILABLE` "log read failed: EACCES …". |

## Replies and reactions

`chat.send` takes `replyToId`, and the sent message keeps `replyToId` and a `replyToPreview` (the original's text and who wrote it), like the gateway. The **home-lab** Discord chat has a message with its Discord message id, which the agent reacted 👀 to with its `message` tool. `message.action` reacts to Discord messages (`action: "react"`) and refuses other channels and actions.

## Messages from other agents

Claw's main chat (`agent:main:main`) has a *Morning briefing* automation run and Kiko introducing herself to Claw with `sessions_send`, as `chat.history` shows them: assistant messages with `senderSession`, `senderLabel` and their `provenance`, without the model-facing prompt prefix or a model. Kiko's own main chat (`agent:kiko:main`) has the matching `sessions_send` tool calls. See [Messages from other agents](../../guides/transcript/#messages-from-other-agents).

## Config and plugins

The mock serves a small config and plugin catalog for Gateway Settings. It supports `config.get`, `config.schema`, `config.patch`, `config.set` and `config.apply`, with redacted secrets, validation issues and restart hints, plus the `plugins.*` methods. Writes need the `operator.admin` scope, so set **Access** to **Full Management**.

## Gateway logs

`logs.tail` reads an in-memory log file the way the gateway reads its real one: by byte offset, returning `{ file, cursor, size, lines, truncated, reset, skippedBytes? }`. It takes only `cursor`, `limit` (1–5000, default 500) and `maxBytes` (1–1,000,000, default 250,000) and rejects anything else with `INVALID_REQUEST`. It needs `operator.read`.

The file is called `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (nothing is written to disk). It starts with about 130 tslog-style JSON lines across every level, plus plain-text and ANSI-colored lines, and a timer adds 1–3 lines a second. Chats and approvals add lines too. Use the `[mock:*-logs]` triggers above to test rotation, truncation, falling behind and read errors.
## Usage and cost

The mock serves 30 days of deterministic usage for its seeded chats, for the [Usage](../../guides/usage-and-cost/) page. It supports `usage.status`, `usage.cost`, `sessions.usage`, `sessions.usage.timeseries` and `sessions.usage.logs`, with the gateway's validation: `startDate` and `endDate` must come together, `agentScope: "all"` can't be combined with a `key`, and a missing or unknown `key` fails with `INVALID_REQUEST`.

The data covers the cases the page handles: one model with some unpriced requests (partial cost), one session with no pricing at all (unknown cost), a rate limit window above 90% that resets within the hour, a provider with an error, and, for ranges starting more than 31 days ago, a session that's still being counted.

## Sessions

For the [Session manager](../../guides/sessions/), the mock seeds archived sessions, a run in progress, a failed run, a session interrupted by a restart and a session with three branches. It supports `sessions.preview`, `sessions.describe`, `sessions.branches.list`, `sessions.branches.switch`, `sessions.rewind`, `sessions.recover`, `sessions.delete` and `sessions.patchMany` with the gateway's scopes: `sessions.rewind` and `sessions.fork` return `editorText` and, for the seeded garden question that carries a small photo, `editorAttachments`; switching branches and rewinding need `operator.admin`, and deleting needs it unless the session is archived and the request has `archivedOnly: true`. Every change broadcasts `sessions.changed`. `MOCK_NO_SESSION_MANAGER=1` hides all of these methods; `MOCK_NO_SESSIONS_RECOVER=1` and `MOCK_NO_PATCH_MANY=1` hide just `sessions.recover` or `sessions.patchMany`, like a gateway older than 2026.8.

## Channel pairing

The mock serves `channels.pairing.list`, `channels.pairing.approve` and `channels.pairing.dismiss` with two pairing accounts (Telegram "Home bot" and Discord "Family server") and three requests, one of which expires about 2 minutes after the mock starts. Every method needs `operator.pairing` or `operator.admin`, so set **Access** to **Full Management** to see them in Pincer. Approving or dismissing a request that's already gone fails with "pending DM access request no longer exists". `MOCK_PAIRING` is about device pairing, not these.

## Health and restart

The mock serves `health`, `status`, `last-heartbeat` and `system-presence` for the [Health page](../../guides/gateway-health/), and its hello snapshot includes presence, health and uptime. Every connected client shows up in presence, next to a `kitchen-pi` node. `health` also reports one failed delivery in the `outbound-prepared-v1` queue that stays failed, so the page shows a Degraded issue you can [dismiss](../../guides/gateway-health/#dismissing-issues).

`gateway.restart.request` needs the `operator.admin` scope. It answers `deferred` while a chat run is active, `coalesced` if a restart is already pending, and `scheduled` otherwise. The simulated restart broadcasts `shutdown` with `restartExpectedMs: 1500`, closes every socket with code 1012, refuses connections for 1.5 seconds, then comes back with a fresh uptime. Sessions and config survive.

## Selftest and live checks

The mock has its own selftest, one section per domain in `mock-gateway/selftest/<domain>.mjs`, and it is the target for Pincer's live end-to-end checks. CI runs both. See [Contributing](../contributing/) for adding handlers and selftests.

```sh
cd mock-gateway && npm ci && npm run selftest

# in another terminal, with the mock running:
swift run PincerChecks --live-core ws://127.0.0.1:18789 dev-token   # and --live-extras, each against a fresh mock

# reconnect and bootstrap behaviour (#202), against a fresh mock:
swift run PincerChecks --live-reconnect ws://127.0.0.1:18789 dev-token

# a gateway without usage, on another port:
MOCK_NO_USAGE=1 PORT=18790 npm start
swift run PincerChecks --live-no-usage ws://127.0.0.1:18790 dev-token

# a gateway from before replies (rejects replyToId):
MOCK_NO_REPLY_TO=1 PORT=18791 npm start
swift run PincerChecks --live-no-reply-to ws://127.0.0.1:18791 dev-token
```

The unit tests (`swift test`) don't need the mock: they never open a socket. See [Building from source](../building/#unit-tests).

See [`mock-gateway/README.md`](https://github.com/hartra344/pincer/blob/main/mock-gateway/README.md) for everything else.
