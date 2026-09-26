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

## Message triggers

| Include this word | What happens |
| --- | --- |
| `tool`, `disk` | Streams a tool call. |
| `image` | Streams a tool call and attaches an image. |
| `approve` | Raises an exec approval. |
| `plan` | Walks a three-step progress card. |
| `[mock:fail-send]` | Refuses the `chat.send` with `UNAVAILABLE`, for testing failed sends. |
| `[mock:drop]` | Closes the connection. The client reconnects after its backoff. |
| `[mock:rotate-logs]` | Switches the log to the next day's file. Gateway Logs shows "Now reading …". |
| `[mock:truncate-logs]` | Empties the log file. Gateway Logs shows "Log file was rotated or truncated." |
| `[mock:log-burst]` | Writes 6,000 log lines at once. Gateway Logs skips ahead and says how much it skipped. |
| `[mock:logs-unavailable]` | The next two log reads fail with `UNAVAILABLE` "log read failed: EACCES …". |

## Config and plugins

The mock serves a small config and plugin catalog for Gateway Settings. It supports `config.get`, `config.schema`, `config.patch`, `config.set` and `config.apply`, with redacted secrets, validation issues and restart hints, plus the `plugins.*` methods. Writes need the `operator.admin` scope, so set **Access** to **Full Management**.

## Gateway logs

`logs.tail` reads an in-memory log file the way the gateway reads its real one: by byte offset, returning `{ file, cursor, size, lines, truncated, reset, skippedBytes? }`. It takes only `cursor`, `limit` (1–5000, default 500) and `maxBytes` (1–1,000,000, default 250,000) and rejects anything else with `INVALID_REQUEST`. It needs `operator.read`.

The file is called `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (nothing is written to disk). It starts with about 130 tslog-style JSON lines across every level, plus plain-text and ANSI-colored lines, and a timer adds 1–3 lines a second. Chats and approvals add lines too. Use the `[mock:*-logs]` triggers above to test rotation, truncation, falling behind and read errors.

## Selftest and live checks

The mock has its own selftest, and it is the target for Pincer's live end-to-end checks. CI runs both.

```sh
cd mock-gateway && npm ci && npm run selftest

# in another terminal, with the mock running:
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token
```

The unit tests (`swift test`) don't need the mock: they never open a socket. See [Building from source](../building/#unit-tests).

See [`mock-gateway/README.md`](https://github.com/hartra344/pincer/blob/main/mock-gateway/README.md) for everything else.
