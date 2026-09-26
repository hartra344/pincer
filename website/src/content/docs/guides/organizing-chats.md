---
title: Organizing chats
description: Sidebar layouts, servers, groups, pins, icons and colors in Pincer.
---

The sidebar keeps your chats organized by server, channel and agent. This page covers how it's laid out and how to arrange it.

## Layouts

Pick a layout from the menu at the top of the sidebar:

| Layout | How chats are grouped |
| --- | --- |
| **By server** (default) | Each Discord server gets a section with its `#channels`. Automations get their own section, and everything else is grouped under its agent. |
| **By agent** | One section per agent. |
| **By group** | One section per group you've made. |
| **Recent** | One list, most recently active first. |

### The Organize menu

This menu, called **Organize**, also has:

- **Show Archived**, to list archived chats;
- **New Group…**, in *By group* and *By server*;
- **Automations…**;
- **Approval History…**, to see [past approval decisions](../gateway-settings/#approval-history);
- **Gateway Settings…** (<kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>,</kbd>);
- **Edit Connection…**, which opens the **Connection** page of Gateway Settings;
- **Reconnect**.

### Discord server names

Server names come from your gateway's Discord config (`channels.discord.guilds.<id>.slug`) when it's set. Otherwise the section is just called **Discord**.

To name a server yourself, right-click its header and choose **Rename Server…**. The name syncs to your other devices through the gateway.

:::note
Discord doesn't send its categories to the gateway. To recreate them, use [groups](#groups).
:::

## Groups

Groups are your own folders for chats. They sync through the gateway, so they're the same on every device.

- **Create a group:** choose **New Group…** from the Organize menu or a group header's menu, or right-click a chat and choose **Move to Group → New Group…**.
- **Move chats:** drag a chat onto a group (or onto **Ungrouped**). Drop it between two chats to put it at that spot. In *By server*, dropping a grouped chat on its own server or agent takes it back out of the group.
- **Reorder groups:** drag a group header, or use **Move Up** and **Move Down** in its menu.
- **Icon:** **Change Icon…** on a group's header picks an SF Symbol.
- **Delete:** **Delete Group…** removes the group and leaves its chats ungrouped.

Empty groups stay until you delete them, so you can set them up ahead of time.

## Per-chat actions

Right-click a chat (or long-press on iOS) for:

- **Pin**, to keep it at the top;
- **Rename**;
- **Move to Group**;
- **Color**, from OpenClaw's named colors, or **Custom…** for any color;
- **Change Icon…**, to pick an SF Symbol tinted with the chat's color, or **Reset Icon**;
- **Reasoning level**;
- **Archive**.

Custom colors and icons sync to your other devices. See [Synced preferences](../../reference/synced-preferences/).

## New chats, forks and branches

Chats you start with **New Chat** (<kbd>⌘</kbd> <kbd>N</kbd>) are listed on their own, like in the Control UI. Only forks and branches nest under their parent.

## Helper (subagent) runs

Subagent runs stay out of the sidebar by default. A spinner on the parent chat shows when helpers are working, and you open one from the **Open run** button on the tool call that started it.

If you'd rather see them, **Settings → Sidebar** can list them under their parent, behind a ✨ count chip. Helper runs never add to unread counts or send notifications.

## Compaction

When a chat's context is compacted, it stays the same chat. You'll see a "Compacting context…" line while it runs, then a divider in the same thread.

To see how full the context is, or to compact it yourself, use the [context meter](../composer/#context-meter) next to **Send**.

## Finding your way

- **Search** at the top of the sidebar filters chats by name.
- **Unread dots** and the **Dock badge** show what's new.
- **Next Unread Chat** (<kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>↓</kbd>) jumps to the next chat with unread messages.
- The **command palette** (<kbd>⌘</kbd> <kbd>K</kbd>) finds any chat on any gateway by typing a few letters.
- **Back** (<kbd>⌘</kbd> <kbd>[</kbd>) and **Forward** (<kbd>⌘</kbd> <kbd>]</kbd>) retrace the chats you've visited.
- <kbd>⌘</kbd> <kbd>1</kbd> to <kbd>⌘</kbd> <kbd>9</kbd> open your first nine pinned chats.

See [Command palette & navigation](../command-palette-and-navigation/).
