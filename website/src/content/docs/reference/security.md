---
title: Security & privacy
description: How Pincer handles identity, secrets, transport, images and local data.
---

Pincer is designed to be safe to run on machines where the official OpenClaw app isn't allowed.

## A pure client

Pincer connects to a Gateway you already run and speaks the Gateway WebSocket protocol (v4) in the **`operator`** role.

- It **never** bundles, launches or embeds a Gateway.
- It **never** registers as a node, so it exposes **no** camera, screen, shell or `system.run` capabilities.

## Scopes

| Access level | Scopes requested |
| --- | --- |
| **Chat & Approvals** (default) | `operator.read`, `operator.write`, `operator.approvals` |
| **Full Management** | the above, plus `operator.admin` |

`operator.admin` is only requested when you choose **Full Management**, and the gateway has to approve it separately.

## Device identity

Each install creates its own **Ed25519 device key**, stored in the Keychain and marked *this device only*, so it never syncs to other devices or backups. The gateway must approve each device once.

## Secrets

Gateway tokens and passwords are stored in the **Keychain**, never in UserDefaults. In Gateway Settings, saved secrets are shown only as "saved" and are never sent back to the gateway unless you change them.

## Transport

- `wss://` is **required** for anything other than loopback, private LAN or Tailscale addresses.
- You can **pin** the gateway's TLS certificate by its SHA-256 fingerprint.

## Images

Images are fetched only from the gateway itself: inline, through `artifacts.download`, or from the gateway's own host.

The one exception is public `https` images the agent links to. These are downloaded directly with **no credentials or cookies**, and you can turn this off in Settings with **Load images the agent links from the web**.

## Local cache

Transcripts are cached so chats open instantly:

- **Location:** `~/Library/Caches/Pincer/Transcripts/<gateway>/`, one file per chat.
- **Size:** up to 20,000 messages per chat.
- **Protection:** files use complete file protection.
- **Cleanup:** removing a gateway deletes its cache.

### Search index

[Message search](../../guides/search/) uses an index built from the cached transcripts, so it holds a copy of your messages' text:

- **Location:** `search-index.sqlite` in the same folder as the gateway's transcripts, `~/Library/Caches/Pincer/Transcripts/<gateway>/`, plus SQLite's `-wal` and `-shm` files next to it.
- **Contents:** the text of your messages and the agent's replies, with the chat, sender and date. The text is compressed to save space, not encrypted. Thinking and tool output aren't indexed.
- **Protection:** on iOS the index is opened with complete file protection, like the transcripts, so it can't be read while the device is locked.
- **Cleanup:** removing a gateway deletes its index along with its transcripts. It's derived data: if it's deleted, damaged or from an older version, Pincer rebuilds it from the transcript cache.

To turn the cache off, set `PINCER_CACHE_DIR=off`. This turns off the search index too, and nothing is written. To use another folder, set it to a path; the index moves with the transcripts.

## Sandbox

The Xcode-built macOS app is **sandboxed**, with outgoing network access and read-only access to files you pick.

The quick `scripts/bundle-mac.sh` development bundle is only ad-hoc signed and isn't meant for everyday use.

## Synced preferences

Some personal touches, such as custom chat colors, icons and server names, sync between your devices through the gateway's user preferences. They're stored on **your** gateway, not on a third-party service. See [Synced preferences](../synced-preferences/).
