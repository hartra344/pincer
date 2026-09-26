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
| **Chat & Approvals** (default) | `operator.read`, `operator.write`, `operator.approvals`, `operator.questions` |
| **Full Management** | the above, plus `operator.admin` |

`operator.admin` is only requested when you choose **Full Management**, and the gateway has to approve it separately.

`operator.questions` lets Pincer answer [agent questions](../../guides/approvals-and-notifications/#agent-questions). Devices paired before Pincer asked for it raise a one-time scope upgrade on the gateway. Until it's approved, Pincer connects without it, and you can answer questions in the Control UI or the channel instead. `operator.admin` includes it.

## Command policy

The gateway's command policy (which commands agents may run, and their allowlists) can only be read or changed with `operator.admin`, so Pincer shows it only with **Full Management**. See [Command Policy](../../guides/command-policy/).

- **Loosening asks first:** if a save would make any agent's effective policy less safe, Pincer lists each change under **Loosen command policy?** and saves only after **Save Anyway**. When the previous value isn't known, only a move to the loosest choice (or to a value Pincer doesn't recognize) counts as loosening. Stricter changes and removed entries save directly.
- **No lost updates:** every save carries the hash of the version it was based on (`baseHash`). If the file changed on the gateway in the meantime, the gateway refuses the save, and Pincer loads the latest version instead of overwriting it.
- **The socket token is never sent:** the gateway leaves the approval socket's token out of what it sends, and Pincer never includes `socket.token` in a save. The gateway keeps its own.

## Device identity

Each install creates its own **Ed25519 device key**, stored in the Keychain and marked *this device only*, so it never syncs to other devices or backups. The gateway must approve each device once.

## Secrets

Gateway tokens and passwords are stored in the **Keychain**, never in UserDefaults. In Gateway Settings, saved secrets are shown only as "saved" and are never sent back to the gateway unless you change them.

In Xcode-built, TestFlight and App Store builds, the device key, gateway secrets and device tokens are kept in a Keychain access group, `<TeamID>.chat.pincer.shared`, that only Pincer and its own extensions can read:

- the **Share extension** uses them to send as this device;
- on iOS, the **notification service extension** uses the group to read the [push](#notifications-and-push) decryption keys.

The list of saved gateways, with no secrets, is in Pincer's App Group, so the Share extension can list them. Existing Keychain items are moved into the shared group once, the first time Pincer opens after updating.

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

## Drafts

Unsent text and attachments are saved per chat, so they survive switching chats and relaunching:

- **Location:** `~/Library/Application Support/Pincer/Drafts/<gateway>/`, one folder per chat, named with a hash of the chat's key. On iOS, this is inside the app's container.
- **Protection:** files use complete file protection.
- **Cleanup:** a draft is deleted when you send it, when its chat is deleted, or when you remove its gateway.
- Drafts never leave the device.

To turn drafts off, set `PINCER_DRAFTS_DIR=off`. To use another folder, set it to a path.

## Notifications and push

- **Approval notifications show the command.** Reply and question notifications show a preview. What appears on the lock screen follows your system's notification preview settings.
- **Allowing needs you to unlock on iOS.** **Allow once** and **Always allow** ask for Face ID, Touch ID or your passcode. **Deny** doesn't, since it can only stop a command.
- **Follow-ups never show the command.**
- **Answers go only to the gateway that asked.** Pincer never tries another gateway, and it never saves an answer to send later.

With a [push relay](../../guides/push-notifications/) on iOS:

- The relay keeps no state. It seals the APNs device token into an opaque id, so the gateway never sees it.
- Notifications are end-to-end encrypted to keys for each gateway, stored in the Keychain as *this device only*. Neither the relay nor Apple can read them.
- Even decrypted, the gateway sends only a generic title and which chat or approval it's about, never message content.

## Share extension

The [Share extension](../../guides/sharing-to-pincer/) connects as the device you already paired. It never creates a device key of its own, so there's nothing new to approve.

What you share goes only to the gateway you pick, with the same transport rules as the app, and isn't stored anywhere else. On macOS the extension is sandboxed with outgoing network access only.

## Sandbox

The Xcode-built macOS app is **sandboxed**, with outgoing network access and read-only access to files you pick.

The quick `scripts/bundle-mac.sh` development bundle is only ad-hoc signed and isn't meant for everyday use.

## Synced preferences

Some personal touches, such as custom chat colors, icons and server names, sync between your devices through the gateway's user preferences. They're stored on **your** gateway, not on a third-party service. See [Synced preferences](../synced-preferences/).
