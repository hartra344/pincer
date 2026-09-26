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

## Command policy

The gateway's command policy (which commands agents may run, and their allowlists) can only be read or changed with `operator.admin`, so Pincer shows it only with **Full Management**. See [Command Policy](../../guides/command-policy/).

- **Loosening asks first:** if a save would make any agent's effective policy less safe, Pincer lists each change under **Loosen command policy?** and saves only after **Save Anyway**. When the previous value isn't known, only a move to the loosest choice (or to a value Pincer doesn't recognize) counts as loosening. Stricter changes and removed entries save directly.
- **No lost updates:** every save carries the hash of the version it was based on (`baseHash`). If the file changed on the gateway in the meantime, the gateway refuses the save, and Pincer loads the latest version instead of overwriting it.
- **The socket token is never sent:** the gateway leaves the approval socket's token out of what it sends, and Pincer never includes `socket.token` in a save. The gateway keeps its own.

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

To turn the cache off, set `PINCER_CACHE_DIR=off`. To use another folder, set it to a path.

## Sandbox

The Xcode-built macOS app is **sandboxed**, with outgoing network access and read-only access to files you pick.

The quick `scripts/bundle-mac.sh` development bundle is only ad-hoc signed and isn't meant for everyday use.

## Synced preferences

Some personal touches, such as custom chat colors, icons and server names, sync between your devices through the gateway's user preferences. They're stored on **your** gateway, not on a third-party service. See [Synced preferences](../synced-preferences/).
