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

:::note
If the gateway has no durable identity for your connection, these preferences stay on the current device instead of syncing.
:::

## Kept on each device

- Appearance (light/dark, theme and color overrides)
- Thinking Steps (None, Live Only, All)
- Your display name
- Whether to load images the agent links from the web
- The transcript cache and its message search index
- Whether to show the last message under each chat, and whether to list subagent runs under their chat
- Notifications on or off (**Notify about replies and approvals**)
- The push relay URL (iOS)
- Find in Chat options (**Include Thinking** and **Include Tool Output**)
- Unsent [drafts](../../guides/composer/#drafts)
- The last gateway and chat you [shared to](../../guides/sharing-to-pincer/)
