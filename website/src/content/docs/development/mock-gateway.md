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
| `MOCK_NO_USAGE` | off | Set to `1` to act like a gateway without usage: the five usage methods are left out of `hello-ok` and answer `UNKNOWN_METHOD`. |
| `MOCK_USAGE_FORBIDDEN` | off | Set to `1` to refuse `usage.cost` with `FORBIDDEN`, as for an operator whose role can't see every session. |
| `MOCK_CHANNEL_PAIRING` | on | Set to `off` to hide the `channels.pairing.*` methods, like an older gateway. |
| `MOCK_CHANNEL_PAIRING_EVERY` | off | Seconds between new channel pairing requests. |
| `MOCK_NO_HEALTH` | off | Set to `1` to drop the health and restart methods, like an older gateway. |
| `MOCK_FAILED_DELIVERY` | on | Set to `off` to drop the mock's one failed delivery, so Health shows Healthy. |
| `MOCK_FAILED_DELIVERY_EVERY` | off | Seconds between new failed deliveries. Each one raises the count and sends `health`, so a dismissed issue comes back. |

## Message triggers

| Include this word | What happens |
| --- | --- |
| `tool`, `disk` | Streams a tool call. |
| `image` | Streams a tool call and attaches an image. |
| `approve` | Raises an exec approval. |
| `plan` | Walks a three-step progress card. |
| `[mock:fail-send]` | Refuses the `chat.send` with `UNAVAILABLE`, for testing failed sends. |
| `[mock:drop]` | Closes the connection. The client reconnects after its backoff. |

## Config and plugins

The mock serves a small config and plugin catalog for Gateway Settings. It supports `config.get`, `config.schema`, `config.patch`, `config.set` and `config.apply`, with redacted secrets, validation issues and restart hints, plus the `plugins.*` methods. Writes need the `operator.admin` scope, so set **Access** to **Full Management**.

## Usage and cost

The mock serves 30 days of deterministic usage for its seeded chats, for the [Usage](../../guides/usage-and-cost/) page. It supports `usage.status`, `usage.cost`, `sessions.usage`, `sessions.usage.timeseries` and `sessions.usage.logs`, with the gateway's validation: `startDate` and `endDate` must come together, `agentScope: "all"` can't be combined with a `key`, and a missing or unknown `key` fails with `INVALID_REQUEST`.

The data covers the cases the page handles: one model with some unpriced requests (partial cost), one session with no pricing at all (unknown cost), a rate limit window above 90% that resets within the hour, a provider with an error, and, for ranges starting more than 31 days ago, a session that's still being counted.

## Channel pairing

The mock serves `channels.pairing.list`, `channels.pairing.approve` and `channels.pairing.dismiss` with two pairing accounts (Telegram "Home bot" and Discord "Family server") and three requests, one of which expires about 2 minutes after the mock starts. Every method needs `operator.pairing` or `operator.admin`, so set **Access** to **Full Management** to see them in Pincer. Approving or dismissing a request that's already gone fails with "pending DM access request no longer exists". `MOCK_PAIRING` is about device pairing, not these.

## Health and restart

The mock serves `health`, `status`, `last-heartbeat` and `system-presence` for the [Health page](../../guides/gateway-health/), and its hello snapshot includes presence, health and uptime. Every connected client shows up in presence, next to a `kitchen-pi` node. `health` also reports one failed delivery in the `outbound-prepared-v1` queue that stays failed, so the page shows a Degraded issue you can [dismiss](../../guides/gateway-health/#dismissing-issues).

`gateway.restart.request` needs the `operator.admin` scope. It answers `deferred` while a chat run is active, `coalesced` if a restart is already pending, and `scheduled` otherwise. The simulated restart broadcasts `shutdown` with `restartExpectedMs: 1500`, closes every socket with code 1012, refuses connections for 1.5 seconds, then comes back with a fresh uptime. Sessions and config survive.

## Selftest and live checks

The mock has its own selftest, and it is the target for Pincer's live end-to-end checks. CI runs both.

```sh
cd mock-gateway && npm ci && npm run selftest

# in another terminal, with the mock running:
PINCER_KEYCHAIN=memory swift run PincerChecks --live ws://127.0.0.1:18789 dev-token

# a gateway without usage, on another port:
MOCK_NO_USAGE=1 PORT=18790 npm start
PINCER_KEYCHAIN=memory swift run PincerChecks --live-no-usage ws://127.0.0.1:18790 dev-token
```

The unit tests (`swift test`) don't need the mock: they never open a socket. See [Building from source](../building/#unit-tests).

See [`mock-gateway/README.md`](https://github.com/hartra344/pincer/blob/main/mock-gateway/README.md) for everything else.
