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

## Command Policy says "Needs Full Management"

The gateway shares its command policy only with devices that have `operator.admin`. Choose **Open Connection**, set **Access** to **Full Management**, choose **Apply**, then approve this device on the gateway host with `openclaw devices approve <requestId>`. The page loads once Pincer reconnects.

## "Command Policy Isn't Available"

The gateway doesn't have `exec.approvals.get`. Update OpenClaw to manage the command policy from Pincer. If only saving is missing, the page opens read-only.

## "The command policy changed on the Gateway"

Someone (or an **Always allow** answer) changed the policy file while you were editing, so your save was refused to avoid overwriting it. Pincer loads the latest version and drops your draft. Make your changes again and choose **Save**.

## "The Gateway rejected the change"

The gateway found something invalid in the policy file. Your draft is kept: fix the value named in the message, or choose **Revert**, then save again.

## Pairing Requests says it isn't available

"This Gateway doesn't support channel pairing requests" means the gateway is older than the channel pairing methods (`channels.pairing.*`). Update OpenClaw.

## Pairing Requests needs Full Management

Reviewing pairing requests needs **Access → Full Management** on the **Connection** page, and the gateway has to approve the change. Pincer doesn't ask for the narrower `operator.pairing` scope; see [Security & privacy](../security/#pairing-requests).

If the page says no channels use DM pairing, set a channel account's `dmPolicy` to `"pairing"` on the gateway.

## The sidebar says "Gateway degraded"

Something on the gateway isn't working, usually a channel that lost its connection. Click the line (or open **Gateway Settings → Health**) to see each issue and the channel's last error.

## I can't restart the gateway

**Restart Gateway…** needs **Access → Full Management**, and the gateway must offer `gateway.restart.request`. If it says **Waiting for N active tasks**, the gateway is letting running work finish first; choose **Restart Now Anyway** to skip the wait. If it says **Gateway hasn't come back yet**, the gateway process didn't come back on its own. Check the gateway host.

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

## Shortcuts say "Add a Gateway in Pincer first."

No gateway is saved yet. Open Pincer and [connect a gateway](../../getting-started/connect-a-gateway/).

If it says "Open Pincer once to finish setup.", this device hasn't created its device identity yet. Open Pincer and connect to a gateway once.

## Shortcuts say the gateway "needs this device approved"

The full message is "*Gateway* needs this device approved. Run openclaw devices approve on the Gateway host." Shortcuts use the app's device identity, so the gateway has to approve this device first. See [Pincer is waiting for pairing](#pincer-is-waiting-for-pairing).

## Shortcuts say the gateway "isn't reachable"

"*Gateway* isn't reachable." means the gateway didn't answer within 10 seconds. "Can't connect to *Gateway*: …" means it answered with an error, which follows the colon, for example "Can't connect to Home: unauthorized." Error codes in brackets, such as `[AUTH_TOKEN_MISMATCH]`, are left out so Siri doesn't read them. The same goes for "Couldn't send: …" and errors from the agent's run.

- Check that the gateway is running and that this device can reach it, for example that Tailscale is connected.
- Open Pincer and check that it connects. If it doesn't, the fixes above apply.

**Get Unread Chats** and **Get Pending Approvals** with no gateway chosen skip gateways they can't reach, and only fail if none can be reached.

## Ask Agent says "Sent, but … hasn't replied"

"Sent, but *agent* hasn't replied within *N* seconds." means the message **was** delivered, but the reply took longer than the action's **Timeout**. The reply will show up in the chat in Pincer. Don't run the shortcut again, or the agent gets the prompt twice.

For slow agents, raise **Timeout (seconds)** (up to 300), or turn off **Wait for Reply**.

If the action shows the gateway's error, or "The run failed." or "The run was stopped.", the message was delivered but the agent's run ended without a reply. "Couldn't send: …" usually means the message wasn't delivered, with the reason after the colon.

## Shortcuts say an agent or chat "isn't on" the gateway anymore

"*Name* isn't on *Gateway* anymore." means the agent or chat saved in the shortcut was removed or archived. Edit the shortcut and pick it again.

"*Gateway* isn't in Pincer anymore." (or "That Gateway isn't in Pincer anymore." when the name isn't known) means the gateway saved in the shortcut was removed from Pincer. Edit the shortcut and pick another one.

## A shortcut shows old agent or chat names

When a gateway is offline or Pincer isn't connected to it, saved shortcuts show the names Pincer last listed. Open the action's agent or chat list in the Shortcuts app, or open Pincer and connect, to refresh them.

## Siri doesn't recognize an agent or chat name

Siri learns agent and chat names when Pincer loads an agent list. Open Pincer and let it connect once after installing it, and again after adding agents. Until then, say a phrase without a name, such as "Ask Pincer", and pick from the list.

See [Shortcuts & Siri](../../guides/shortcuts-and-siri/).

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
