---
title: Share to Pincer
description: Send text, links, images and files to any chat from the share sheet on macOS and iOS.
---

Pincer adds itself to the system share sheet, so you can send a web page, a photo or a file to an agent without copying and pasting.

## Share something

1. In any app, open the share sheet and choose **Pincer**.
2. The **Send to Pincer** sheet opens. Under **Send To**, check where it's going:
   - **Gateway**, if you have more than one;
   - **Chat**, which opens a searchable list. Pick an existing chat under **Chats** (pinned chats have a pin), or start one under **New Chat** with "New chat with *Agent*".
3. Optionally, type a message in **Note** ("Add a note (optional)").
4. Check the **Sharing** section, which lists the text, links and files that will be sent, with any warnings.
5. Choose **Send**. **Cancel** closes the sheet without sending.

Pincer remembers the last gateway and chat you shared to, and picks them next time. The first time, it uses the gateway selected in the app and, on that gateway, the default agent's main chat, or a new chat with the default agent if there isn't one.

## What you can share

- Text.
- One web link or web page.
- Up to 10 images. They're downscaled to fit the gateway's limits, like attachments in the [composer](../composer/#attachments).
- Up to 10 files.

## What gets sent

Everything goes as one message, in this order, separated by blank lines:

1. your note;
2. the shared text;
3. the links.

A link that's already in your note or the shared text isn't added again. That's common with Safari, which often shares a page's title and link together.

Some items can't be sent. The **Sharing** section tells you why:

| Message | What it means |
| --- | --- |
| "*name* is larger than the Gateway allows (*limit*)." | The file is over the gateway's attachment limit. It's left out, and the rest is sent. |
| "*name* is too large to share (over 50 MB)." | Pincer doesn't read items bigger than 50 MB. |
| "*name* is a folder; share files instead." | Share the files inside the folder. |
| "*name* can't be shared to Pincer." | The item isn't text, a link, an image or a file. |

If there's nothing left to send, the section says "Nothing to share."

## Before your first share

- **Add a gateway in Pincer first.** Otherwise the sheet says "Add a Gateway in Pincer first, then share again."
- **Open Pincer once after installing or updating.** The share extension uses the device key and secrets Pincer has already set up, and Pincer moves them where the extension can read them the first time it opens. Until then, the sheet says "Open Pincer once to finish setting up sharing, then share again."

There's nothing new to pair. The extension connects as the same device you already approved. If the gateway hasn't approved this device yet, the sheet says so and shows the device to approve with `openclaw devices approve`. See [Connect a gateway](../../getting-started/connect-a-gateway/).

## Privacy

- What you share goes only to the gateway you pick, with the same connection rules as the app (`wss://` and certificate pinning).
- It isn't stored anywhere else. Pincer only remembers which gateway and chat you picked.
- The extension never creates its own device key.
- On macOS, the extension is sandboxed with outgoing network access only.

More in [Security & privacy](../../reference/security/#share-extension).

## Current limits

- The share extension is only in Xcode-built, TestFlight and App Store builds. The `scripts/bundle-mac.sh` development bundle doesn't include it.
- It has been tested against the demo and the mock gateway, but not yet from the share sheet on a real device.
- On iOS, reaching a gateway on your local network from the extension hasn't been tested yet.

Having trouble? See [Troubleshooting](../../reference/troubleshooting/#pincer-isnt-in-the-share-sheet).
