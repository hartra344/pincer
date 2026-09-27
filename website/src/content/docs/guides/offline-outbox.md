---
title: Offline sending & retry
description: Writing messages while you're disconnected, how Pincer sends them when you reconnect, and retrying messages that failed.
---

You can keep writing when your connection drops. Messages you send while offline wait in an **outbox** and go out, in order, as soon as Pincer reconnects to that gateway. If a message can't be sent, it stays in the chat marked **Failed** so you can retry or delete it. Nothing you typed disappears.

## Sending while offline

When Pincer isn't connected to the gateway, the composer still works for text messages and [replies](../composer/#replying-to-a-message):

- A line above the composer says **Offline — messages send when you reconnect**.
- The Send button stays where it is, and <kbd>Return</kbd> still sends. Its tooltip and VoiceOver label read **Queue Message**.
- Your message appears in the chat straight away, marked **Queued**, and the composer clears as usual.

Attachments need a connection. While you're offline, the **+** button is unavailable and the composer says **Attachments need a connection**. Anything already attached stays in your [draft](../composer/#drafts) until you're back online.

## Message states

Messages that haven't reached the gateway yet show their state under your message bubble, on macOS and iOS:

| State | What it means |
| --- | --- |
| **Queued** (clock) | Waiting for a connection, or for an earlier message in the same chat. |
| **Sending…** | Pincer is sending it now. |
| **Failed — Retry** | It couldn't be sent. The reason is shown with it. |

Once the gateway has the message, the marker goes away and the message stays where it is. It isn't shown twice.

Queued and failed messages don't count as unread, don't post notifications and don't move the chat up the sidebar. That happens when they're actually sent.

## Retrying and deleting

A failed message offers **Retry** and **Delete**:

- Click or tap **Retry** or **Delete** under the message.
- Or use the message's context menu (right-click on macOS, long-press on iOS).
- With VoiceOver, the message reads, for example, "Your message. Failed to send: …", and Retry and Delete are available as actions.

Delete removes the message from Pincer only. It was never sent, so there's nothing to remove on the gateway. To change a queued message, delete it and type it again.

## Order and sending exactly once

Messages in a chat are always sent in the order you wrote them. If one fails, the messages after it in that chat wait, marked **Queued**, until you retry or delete the failed one. That way the agent never gets your messages out of order. Other chats aren't affected.

Each message is sent with the same idempotency key every time it's tried, including retries and after relaunching, so the gateway ignores copies it has already received. If Pincer quits while a message is being sent, it checks the chat's history on the next launch: if the message arrived, it's removed from the outbox; otherwise it's queued again.

## Why a message fails

| What happened | What Pincer does |
| --- | --- |
| You went offline, or the connection dropped while sending | Keeps it **Queued** and sends it automatically when you reconnect. No error is shown. |
| The gateway timed out or was temporarily unavailable while you were still connected | Marks it **Failed** with **Retry**. It isn't retried automatically. |
| The gateway rejected the message (for example, an invalid request) | Marks it **Failed** with the gateway's own message. It's never retried automatically; retrying sends it unchanged, so it usually fails again. |
| This device lost access (unpaired, token revoked, missing scope) | Marks it **Failed** with **Sign-in required**. Reconnect or pair again, then choose **Retry**. |
| The chat no longer exists on the gateway | Marks it **Failed** with **Session no longer exists**. Delete it. |

A message with attachments that fails can be retried until you quit Pincer. Attachments aren't saved in the outbox, so after a relaunch it's gone. Its text is still in the failed message until then, so you can copy it.

## Several gateways

Each gateway has its own outbox. Messages queued for one gateway are sent only when Pincer is connected to that gateway, so switching gateways never sends a message to the wrong one.

Deleting a chat in Pincer deletes its unsent messages too; the confirmation says how many. Removing a gateway deletes its outbox.

## Where the outbox is stored

The outbox is saved on your device, so queued and failed messages survive quitting Pincer and restarting your Mac, iPhone or iPad. Like drafts, it lives in Application Support, not in the [local cache](../local-cache/), so the system never clears it to free space and **Clear Cache…** doesn't touch it:

| Platform | File |
|---|---|
| macOS | `~/Library/Application Support/Pincer/Outbox/<gateway>.json` (inside the app's sandbox container for the Xcode-built app) |
| iOS and iPadOS | `Library/Application Support/Pincer/Outbox/<gateway>.json` in Pincer's app container |

Each file records its format version. A file that's damaged, or that was written by a newer Pincer (for example after going back to an earlier build), is set aside next to it (`<gateway>.corrupt.json` or `<gateway>.v<version>.json`) instead of being overwritten, and logged under subsystem `chat.pincer`, category `Outbox`, without any message content.

To keep the outbox in memory only, so it lasts until you quit Pincer, set `PINCER_OUTBOX_DIR=off`. To use another folder, set it to a path.

To see or empty it, open **Settings** (**General** tab on macOS) and find **Storage**:

- **Unsent messages** shows how many messages are queued or failed, across all gateways.
- **Clear Outbox…** asks for confirmation, then deletes every queued and failed message. Your chats and their history aren't affected.

## Trying it out

The built-in demo has a failed message you can retry. See [Try the demo](../../getting-started/try-the-demo/).
