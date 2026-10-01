---
title: Synced preferences
description: Which Pincer preferences sync between devices, and where they're stored.
---

Pincer has no server of its own. Anything that syncs between your devices is stored on **your gateway**, either in OpenClaw's own session data or in the gateway's per-user preferences (`users.prefs`).

## Stored in OpenClaw session data

These use the gateway's own features, so other OpenClaw clients see them too:

| What | Where |
| --- | --- |
| Pin, rename, archive, reasoning level | the session itself (`sessions.patch`) |
| Named chat colors | the session itself (`sessions.patch`) |
| Groups, their order and names | the group catalog (`sessions.groups.*`) |

## Stored in `users.prefs`

These are Pincer extras that OpenClaw's session data can't hold:

| Key | What it stores |
| --- | --- |
| `pincer.serverNames` | Names you gave Discord servers with **Rename Server…** |
| `pincer.chatIcons` | SF Symbol icons picked with **Change Icon…** |
| `pincer.chatColors` | Custom chat colors. These win over the named color. |
| `pincer.groupIcons` | Group header icons |
| `pincer.chatOrder` | The order of chats within a group. This wins over pinning and activity. |
| `pincer.groups` | Groups, on gateways without the group catalog |
| `pincer.reactions` | Your [reactions](../../guides/transcript/#reactions), keyed by `<session key>\|<message id>`, with that message's emoji in the order you added them, separated by spaces |
| `pincer.healthDismissals` | Gateway Health issues you dismissed or always ignore |
| `pincer.bookmarks.0` … `pincer.bookmarks.7` | Your [bookmarks](../../guides/export-and-bookmarks/#bookmark-a-message), keyed by session key and message id, each with the start of the message, its role and when you added it. They're spread over eight keys because the gateway limits each preference to 4 KB. Room for about 100–150; once it's full, a new bookmark removes an older one. |
| `pincer.avatars` | [Avatar](../../guides/agent-avatars/#settings) characters picked for each agent, keyed by agent id, the **Style** (`pixel` or `plush`) under `@style`, and under `seed@<agentId>` the identity the agent's pet was first picked from, so a rename keeps the pet |

:::note
If the gateway has no durable identity for your connection, these preferences stay on the current device instead of syncing.
:::

Removing a gateway from Pincer clears this device's copy of `pincer.healthDismissals` and the bookmarks, and any changes not yet saved to the gateway. The gateway keeps them for your other devices, and adding the gateway again brings them back.

## How syncing works

- Each entry (one chat's icon, one bookmark, one reaction) syncs on its own. If two devices change different entries at the same time, both changes are kept. If they change the same entry, the last one saved wins.
- A change shows up on your device right away. If the gateway is offline or the save fails, Pincer keeps the change on this device, even across a restart, and saves it again when the gateway is back. It never reverts to the gateway's older value in the meantime. If the gateway refuses a change as too large, Pincer stops retrying it on its own; for bookmarks, the Bookmarks list says so.
- When another device changes a preference, the gateway tells Pincer, and Pincer reads just that preference again.
- The first time a device syncs with a gateway, what's already on the device is merged with what the gateway has. Where both have the same entry, the gateway's wins. That's how bookmarks you saved before syncing existed move to the gateway. It also means a device that hasn't synced yet can bring back a bookmark you removed on another device.

## Kept on each device

- Appearance (light/dark, theme and color overrides)
- Whether avatars are animated (**Animated avatars**)
- Thinking Steps (None, Live Only, All)
- Your display name
- Whether to load images the agent links from the web
- The transcript cache and its message search index
- Whether to show the last message under each chat, and whether to list subagent runs under their chat
- Notifications on or off (**Notify about replies and approvals**)
- Open at Login (macOS). macOS keeps this in Login Items & Extensions, so it's set separately on each Mac.
- The push relay URL (iOS)
- Find in Chat options (**Include Thinking** and **Include Tool Output**)
- Recent reaction emoji, for the quick reactions
- Unsent [drafts](../../guides/composer/#drafts)
- The last gateway and chat you [shared to](../../guides/sharing-to-pincer/)
- Whether to show Pincer in the [menu bar](../../guides/menu-bar/) (macOS)
