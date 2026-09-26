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

## "Always allow" is missing

The gateway only offers **Always allow** for some commands. When the approval doesn't permit it, Pincer shows just **Allow once** and **Deny**.

Approval pushes on iOS always show **Always allow**, because a push doesn't say whether it's permitted. If it isn't, you get a follow-up saying "Always allow isn't available for this command." with the other two actions.

## An approval notification changed to a different message

When an answer from a notification doesn't go through, Pincer replaces the notification with a follow-up:

- **"That approval expired. Nothing was run."** You answered too late.
- **"Already allowed elsewhere."**, **"Already denied elsewhere."** or **"Already answered elsewhere."** Someone answered first.
- **"Couldn't reach *gateway* — the command is still waiting."** Pincer couldn't connect in time, so nothing was sent. Use the actions again, or open Pincer.
- **"This device can't approve commands on *gateway*. Open Pincer for details."** The device is missing the `operator.approvals` scope, or its sign-in failed. Open Pincer to see the connection error.
- **"This gateway is no longer in Pincer."** The gateway was removed.

See [Follow-up notifications](../../guides/approvals-and-notifications/#follow-up-notifications).

## iOS asks for Face ID when I tap Allow

That's expected. **Allow once** and **Always allow** need you to unlock the device. **Deny** works from the lock screen without unlocking.

## No notifications while Pincer is closed on iOS

iOS doesn't let Pincer stay connected in the background. To get notifications while it's closed, set up a [push relay](../../guides/push-notifications/), then check the status next to each gateway in **Settings → Notifications**:

| Status | What to do |
| --- | --- |
| **Waiting for APNs** | Check that notifications are allowed for Pincer in iOS Settings. |
| **Relay must be https://** | Use the relay's `https://` address. |
| **Gateway has no Web Push** | Update OpenClaw. |
| **Push off** | Turn on **Notify about replies and approvals**, and enter a relay. |
| **Not connected** | Open the gateway in Pincer, so it can subscribe. |
| An error message | Usually the phone can't reach the relay. Open `https://…/healthz` in Safari on the phone. It should show `{"ok":true}`. |

## The agent is waiting for my answer, but there's no card

Answering questions needs the `operator.questions` scope. Devices paired before Pincer asked for it need the gateway to approve a scope upgrade. The chat shows the request to approve. On the gateway host, run:

```sh
openclaw devices approve <requestId>
```

Then choose **Try Again**. Until then, you can answer in the Control UI or the channel the chat came from.

## Approval History says it isn't available

The gateway doesn't keep an approval history. Update OpenClaw.

## Pincer isn't in the share sheet

The share extension is only in Xcode-built, TestFlight and App Store builds. The `scripts/bundle-mac.sh` development bundle doesn't include it.

## Sharing to Pincer doesn't work

The **Send to Pincer** sheet says what's wrong:

- **"Add a Gateway in Pincer first, then share again."** Add a gateway in the app.
- **"Open Pincer once to finish setting up sharing, then share again."** Open Pincer, so it can move its device key where the extension can read it.
- **"Connecting…"** Pincer is still reaching the gateway. The reason follows in parentheses if it's having trouble.
- **"This device is waiting for approval on the Gateway host."** Approve the device with `openclaw devices approve`.
- **"Couldn't send: …"** The gateway's error follows.

A file larger than the gateway allows, or over 50 MB, is left out. The **Sharing** section lists anything that won't be sent. See [Share to Pincer](../../guides/sharing-to-pincer/#what-gets-sent).

## Compact Now is greyed out

Wait for the current run to finish.

## There's no context ring next to Send

The ring only appears once the gateway has reported how many tokens the chat uses, and a context limit is known. If your gateway doesn't report token usage for the chat, the ring doesn't appear.

## Include Thinking is greyed out in Find

The chat's **Gateway Reasoning** is **Off**, so there's no thinking to search. See [Thinking](../../guides/transcript/#thinking).

## Seeing what the gateway says

For a detailed log of every request and the gateway's reply, run the app with a request log:

```sh
open --env PINCER_REQUEST_LOG=/tmp/pincer.log /Applications/Pincer.app
```

Each request is logged with ✓ or the gateway's error. History and image downloads are left out.

## Still stuck?

[Open an issue on GitHub](https://github.com/hartra344/pincer/issues) with what you tried and, if you can, the relevant part of the request log. Remove any secrets first.
