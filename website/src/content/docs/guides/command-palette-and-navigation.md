---
title: Command palette & navigation
description: Jump to any chat or run a command with ⌘K, go back and forward, and open pinned chats with ⌘1–9.
---

The command palette finds any chat on any gateway and runs common commands, without leaving the keyboard. Back and Forward retrace the chats you've visited, like a browser.

## Open the palette

Press <kbd>⌘</kbd> <kbd>K</kbd>, or choose **Go → Command Palette…**. Press it again to close it.

- **macOS:** the **Go** menu is in the menu bar. The palette opens in the window you're using.
- **iOS:** there's no on-screen button. The palette opens with <kbd>⌘</kbd> <kbd>K</kbd> on a hardware keyboard, such as on an iPad.

Type to search. The field says "Jump to a chat or run a command…".

## What you can do

Before you type, results are grouped into sections:

| Section | What's there |
| --- | --- |
| **Chats** | Chats on every gateway. Recently visited chats come first, then the selected gateway's chats in sidebar order, then other gateways'. Each shows its agent and origin, plus the gateway name if you have more than one. Pinned chats show their <kbd>⌘</kbd> number. |
| **New Chat** | "New Chat with *Agent*" for each agent on the selected gateway, while it's connected. The default agent is marked **Default agent**. |
| **Commands** | The commands below, plus "Switch to *Gateway*" for each other saved gateway. |

Helper (subagent) runs and archived chats aren't listed.

### Commands

| Command | What it does |
| --- | --- |
| **Change Model…** | Opens a list of the agent's models. It shows the current model, and it's disabled if the chat's model can't be changed. |
| **Pin Chat** / **Unpin Chat** | Pins or unpins the current chat. |
| **Show Thinking Steps** / **Hide Thinking Steps** | Switches [Thinking Steps](../transcript/#thinking-steps) between **None** and the default, **Live Only**. |
| **Go Back** / **Go Forward** | Same as <kbd>⌘</kbd> <kbd>[</kbd> and <kbd>⌘</kbd> <kbd>]</kbd>. |
| **Next Unread Chat** | Jumps to the next chat with unread messages. Enabled only when something is unread. |
| **Open Settings…** | Opens Settings: a window on macOS, a sheet on iOS. |
| **Gateway Settings…** | Opens [Gateway Settings](../gateway-settings/) for the selected gateway. |
| **Automations…** | Opens the selected gateway's automations. |
| **Approval History…** | Opens [Approval History](../gateway-settings/#approval-history) for the selected gateway. |

### Searching messages

Once you've typed at least 2 characters, the palette also offers **Search Messages for “*query*”**, right after the matching chats, or first when no chat matches. Choose it, or press <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>F</kbd> (**Go → Search Messages…**), to search the text of every cached chat on the selected gateway. See [Search messages](../search/).

### Choosing a model

**Change Model…** opens a second page with "Choose a model…" in the field:

- **Default (*model*)** goes back to the agent's default;
- each model the agent can use follows, with its provider. The current one is marked **Current**;
- models that aren't available, or can't be picked by hand, are greyed out.

## Matching

Search is forgiving:

- Every word you type has to match, but it can match the title, the subtitle or hidden keywords.
- Letters can match in order, not only as a whole word. `jptr` finds "Japan trip", and `nwcr` finds "New Chat with Research".
- Case and accents don't matter.
- Keywords include agent, gateway, channel and category names. Commands also match common synonyms: "audit" or "log" finds **Approval History…**, "cron" finds **Automations…**, and "preferences" finds **Open Settings…**.

If nothing matches, the palette shows "No matches".

## Keys

| Action | Keys |
| --- | --- |
| Move through results | <kbd>↑</kbd> <kbd>↓</kbd> |
| Run the selected result | <kbd>Return</kbd> |
| Back to commands from the models or messages page | <kbd>Esc</kbd>, or <kbd>Delete</kbd> in an empty field |
| Close the palette | <kbd>Esc</kbd> |

The selection wraps from the last result to the first. Clicking outside the palette also closes it.

## Back and Forward

**Go → Back** (<kbd>⌘</kbd> <kbd>[</kbd>) and **Go → Forward** (<kbd>⌘</kbd> <kbd>]</kbd>) work like a browser's history, across all your gateways:

- Opening a new chat clears Forward.
- Chats that no longer exist are skipped.
- Removing a gateway drops its chats from the history.
- Back goes up to 50 chats.
- The history isn't saved, so it starts fresh each time you open Pincer.

Back and Forward are greyed out when there's nowhere to go. On iOS there are no toolbar buttons for them. Use the keys on a hardware keyboard, or **Go Back** and **Go Forward** in the palette.

## Pinned chats ⌘1–9

<kbd>⌘</kbd> <kbd>1</kbd> to <kbd>⌘</kbd> <kbd>9</kbd> open the selected gateway's first nine pinned chats, in the order the sidebar shows them. Archived chats are skipped.

On macOS they're also listed under **Go → Pinned Chats**, which appears when the selected gateway has pinned chats. To pin a chat, see [Per-chat actions](../organizing-chats/#per-chat-actions).

See [Keyboard shortcuts](../../reference/keyboard-shortcuts/) for the full list.
