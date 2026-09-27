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

[Gateway Logs](../../guides/gateway-logs/) needs only `operator.read`.
`operator.questions` lets Pincer answer [agent questions](../../guides/approvals-and-notifications/#agent-questions). Devices paired before Pincer asked for it raise a one-time scope upgrade on the gateway. Until it's approved, Pincer connects without it, and you can answer questions in the Control UI or the channel instead. `operator.admin` includes it.

### Pairing requests

Approving a [pairing request](../../guides/gateway-settings/#pairing-requests) lets that sender DM your agents on that channel account, so check the channel's sender id before you approve. The name and username come from the sender and aren't verified. **Dismiss** doesn't block anyone; to revoke access later, edit the channel's allowlist on the gateway.

The gateway's pairing methods need `operator.pairing`. Pincer never asks for it, because that scope also lets a device approve new devices and nodes. Reviewing pairing requests uses **Full Management** instead, whose `operator.admin` covers it. Making someone the command owner always needs `operator.admin`.

## Command policy

The gateway's command policy (which commands agents may run, and their allowlists) can only be read or changed with `operator.admin`, so Pincer shows it only with **Full Management**. See [Command Policy](../../guides/command-policy/).

- **Loosening asks first:** if a save would make any agent's effective policy less safe, Pincer lists each change under **Loosen command policy?** and saves only after **Save Anyway**. When the previous value isn't known, only a move to the loosest choice (or to a value Pincer doesn't recognize) counts as loosening. Stricter changes and removed entries save directly.
- **No lost updates:** every save carries the hash of the version it was based on (`baseHash`). If the file changed on the gateway in the meantime, the gateway refuses the save, and Pincer loads the latest version instead of overwriting it.
- **The socket token is never sent:** the gateway leaves the approval socket's token out of what it sends, and Pincer never includes `socket.token` in a save. The gateway keeps its own.

## Agents and workspace files

Viewing agents and reading their workspace files (`agents.list`, `agent.identity.get`, `agents.files.list`, `agents.files.get`) needs only `operator.read`. Creating, editing and deleting agents (`agents.create`, `agents.update`, `agents.delete`) and saving workspace files (`agents.files.set`) need `operator.admin`, so without **Full Management** these pages are read-only. See [Agents & workspace files](../../guides/agents/).

- **No lost updates:** every file save carries the hash of the version it was based on (`expectedHash`), or `expectedMissing` when creating a file. If the file changed on the gateway in the meantime, the gateway refuses the save and Pincer keeps your edits until you choose to reload or overwrite.
- **Deleting is explicit:** the gateway would move an agent's workspace, sessions and other data to the Trash unless told otherwise, so Pincer always sends `deleteFiles`, and sets it only when you choose **Delete and Move Files to Trash**. **Delete Agent** keeps them on the gateway host.
- **Only bootstrap files:** the gateway limits reads and writes to its own list of bootstrap files (such as `AGENTS.md` and `SOUL.md`), each up to 2 MB, inside the agent's workspace. Pincer can't read or write other files there, and checks the size before sending.

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

### Search index

[Message search](../../guides/search/) uses an index built from the cached transcripts, so it holds a copy of your messages' text:

- **Location:** `search-index.sqlite` in the same folder as the gateway's transcripts, `~/Library/Caches/Pincer/Transcripts/<gateway>/`, plus SQLite's `-wal` and `-shm` files next to it.
- **Contents:** the text of your messages and the agent's replies, with the chat, sender and date. The text is compressed to save space, not encrypted. Thinking and tool output aren't indexed.
- **Protection:** on iOS the index is opened with complete file protection, like the transcripts, so it can't be read while the device is locked.
- **Cleanup:** removing a gateway deletes its index along with its transcripts. It's derived data: if it's deleted, damaged or from an older version, Pincer rebuilds it from the transcript cache.

To turn the cache off, set `PINCER_CACHE_DIR=off`. This turns off the search index too, and nothing is written. To use another folder, set it to a path; the index moves with the transcripts.

## Gateway logs

[Gateway Logs](../../guides/gateway-logs/) keeps the lines it fetches (`logs.tail`) in memory only, up to the last 2,000 lines or 8 MB. They're never cached on disk or written to Pincer's own logs, and `PINCER_REQUEST_LOG` leaves these requests out.

The gateway redacts tokens and other secrets before it sends log lines; Pincer doesn't add redaction of its own. Lines can still contain hostnames, file paths and message content, so **Export…** reminds you to review a file before sharing it.

## Deep links and Handoff

[`pincer://` links and Handoff](../../guides/deep-links-and-handoff/) only **navigate**:

- Opening a link or a Handoff activity selects a gateway, opens a chat and can scroll to a message. It never sends a message, fills in the composer, answers an approval or pairing request, changes settings, or adds or edits a gateway. Parameters other than `gateway`, `session` and `message` are ignored.
- Links carry only the gateway ID, the gateway's URL, the session key and an optional message ID. Handoff carries the same, minus the message ID. They never carry a token, password or message text, and any user name or password in the gateway URL is removed. The URL lets another of your devices find the same gateway.
- **Links include your gateway's address**, and session keys can reveal a chat's channel, such as a Discord channel ID. If your gateway host is private, don't share links publicly.
- Handoff activities aren't indexed by Spotlight and have no web URL, so they only reach your own devices signed in to the same Apple Account.
- Notices for a missing gateway, chat or message use fixed text. Pincer doesn't display the link's contents.

## Shortcuts and Siri

[Shortcuts & Siri](../../guides/shortcuts-and-siri/) actions connect with the same device identity and access level as the app. They don't pair a new device or ask for more scopes.

- Every action except **Open Chat** requires an **unlocked device**, because they return reply content or send messages that can make an agent act.
- Prompts and replies are handed to Shortcuts or Siri and are **never logged or saved** by the actions.
- So saved shortcuts can show names while a gateway is offline, the agent and chat names Pincer last listed are kept in its **App Group**: agent names and emoji, chat titles and agent names, up to 1,000 entries. No messages are stored there.

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
