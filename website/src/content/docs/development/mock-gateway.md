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
| `MOCK_CHANNEL_PAIRING` | on | Set to `off` to hide the `channels.pairing.*` methods, like an older gateway. |
| `MOCK_CHANNEL_PAIRING_EVERY` | off | Seconds between new channel pairing requests. |

## Message triggers

| Include this word | What happens |
| --- | --- |
| `tool`, `disk` | Streams a tool call. |
| `image` | Streams a tool call and attaches an image. |
| `approve` | Raises an exec approval. |
| `plan` | Walks a three-step progress card. |

## Config and plugins

The mock serves a small config and plugin catalog for Gateway Settings. It supports `config.get`, `config.schema`, `config.patch`, `config.set` and `config.apply`, with redacted secrets, validation issues and restart hints, plus the `plugins.*` methods. Writes need the `operator.admin` scope, so set **Access** to **Full Management**.

## Channel pairing

The mock serves `channels.pairing.list`, `channels.pairing.approve` and `channels.pairing.dismiss` with two pairing accounts (Telegram "Home bot" and Discord "Family server") and three requests, one of which expires about 2 minutes after the mock starts. Every method needs `operator.pairing` or `operator.admin`, so set **Access** to **Full Management** to see them in Pincer. Approving or dismissing a request that's already gone fails with "pending DM access request no longer exists". `MOCK_PAIRING` is about device pairing, not these.

See [`mock-gateway/README.md`](https://github.com/hartra344/pincer/blob/main/mock-gateway/README.md) for everything else.
