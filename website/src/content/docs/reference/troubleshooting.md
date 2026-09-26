---
title: Troubleshooting
description: Fixes for common connection, pairing and display problems in Pincer.
---

## Pincer is waiting for pairing

The first time a device connects, the gateway has to approve it. On the gateway host, run:

```sh
openclaw devices list
openclaw devices approve <requestId>
```

Pincer reconnects on its own after you approve it. If you switched a gateway to **Full Management**, it needs to be approved again for the extra access.

## "ws:// isn't allowed" for my address

Plain `ws://` only works with loopback (`127.0.0.1`), private LAN, and Tailscale addresses. For anything else, use `wss://`.

## I can't connect over Tailscale

- Check that Tailscale is running and signed in on this device.
- With **Tailscale Serve**, use `wss://<host>.<tailnet>.ts.net` with no port. Serve uses HTTPS on port 443.
- With the **tailnet IP**, use `ws://100.x.y.z:18789`, with the gateway's port.
- If Pincer warns about `ws://` with a `.ts.net` name, switch it to `wss://`.

See [Connect over Tailscale](../../getting-started/tailscale/).

## The connection fails after pinning a certificate

The fingerprint must be the SHA-256 of the gateway's current certificate, in hex. If the certificate was renewed, update the pin under **Gateway Settings → Connection**, or clear it.

## I don't see the agent's thinking

Thinking has two parts:

1. The gateway has to **save** reasoning. Turn it on with `/reasoning on`, or **Gateway Reasoning → Save & Stream** in the chat's ⋯ menu.
2. Pincer has to **show** it. Check **Thinking Steps** in the chat's ⋯ menu. **Live Only** hides it once a reply is done, and **All** keeps it.

## Gateway Settings is read-only

Editing needs **Access → Full Management** on the **Connection** page, and the gateway has to approve the change. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).

## A helper run is missing from the sidebar

Subagent (helper) runs are hidden by default. Open one with **Open run** on the tool call that started it, or turn on listing them under their parent in **Settings → Sidebar**.

## My Discord server is just called "Discord"

Pincer uses the server's slug from the gateway's Discord config when it's set. Otherwise, right-click the section header and choose **Rename Server…**.

## The Quick Capture shortcut does nothing

- Pincer has to be running. The shortcut stops working when you quit it.
- Check that **Quick Capture shortcut** is on in **Settings → General → Quick Capture**.
- If Settings says the shortcut "is used by another app", another app already registered that combination. Record a different one, or change it in the other app.
- Quick Capture is macOS only.

See [Quick Capture](../../guides/quick-capture/).

## Quick Capture won't send

- Send is turned off while the chat's gateway is offline or still connecting. The panel shows the gateway's state, and you can keep typing until it reconnects.
- With no gateway set up, the panel offers **Open Pincer** so you can add one.
- If a send fails, your text stays in the panel with the error. Press <kbd>Return</kbd> to try again.

## Images from the web don't load

Check that **Load images the agent links from the web** is on in Settings. Images from the gateway itself always load.

## Seeing what the gateway says

For a detailed log of every request and the gateway's reply, run the app with a request log:

```sh
open --env PINCER_REQUEST_LOG=/tmp/pincer.log /Applications/Pincer.app
```

Each request is logged with ✓ or the gateway's error. History and image downloads are left out.

## Still stuck?

[Open an issue on GitHub](https://github.com/hartra344/pincer/issues) with what you tried and, if you can, the relevant part of the request log. Remove any secrets first.
