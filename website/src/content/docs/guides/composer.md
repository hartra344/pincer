---
title: Composer & slash commands
description: Sending messages, attachments, stopping runs and using slash commands in Pincer.
---

## Sending messages

| Action | Keys |
| --- | --- |
| Send | <kbd>Return</kbd> |
| New line | <kbd>⇧</kbd> <kbd>Return</kbd> or <kbd>⌥</kbd> <kbd>Return</kbd> |
| Stop the current run | <kbd>⌘</kbd> <kbd>.</kbd> |

## Attachments

Paste, drag in, or pick images and files with the **+** button. Images are downscaled to fit the gateway's limits before they're sent.

To send something from another app, use the share sheet. See [Share to Pincer](../sharing-to-pincer/).

## Drafts

Each chat keeps what you haven't sent yet, both the text and any attachments, when you switch to another chat or quit Pincer. Come back and it's still there.

- Drafts are saved a moment after you stop typing.
- A draft is deleted when you send it, when its chat is deleted, or when you remove its gateway.
- Drafts stay on this device. They don't sync.

Where drafts are stored, and how to turn them off, is in [Security & privacy](../../reference/security/#drafts).

## Context meter

A small ring next to **Send** shows how full the chat's context window is. It appears once the gateway has reported how many tokens the chat uses, and a limit is known.

- The ring turns **orange** at 85% and **red** at 95%, and shows the percentage inside from 85%.
- Hover over it for the numbers, such as "Context: 172k / 200k tokens (86%)".
- A "~" means the number is an estimate from before the last run. It doesn't change color.

Click the ring for details:

- **Context Window** (or **Prompt Budget**, when the session has one): tokens used, the limit and the percentage;
- a hint when it's filling up. At 95% the agent will compact on its own soon;
- **Last run:** tokens in and out;
- **Instructions (optional)** and **Compact Now**.

### Compact Now

**Compact Now** summarizes older messages to free up room, like OpenClaw does on its own when the context is full. Add instructions to tell it what to keep. When it's done, Pincer shows the result, such as "Compacted 172k → 31k tokens."

**Compact Now** is greyed out while the agent is working. Wait for the current run to finish.

With **Full Management** and no instructions, Pincer asks the gateway to compact the session directly. Otherwise it sends `/compact`, or `/compact` followed by your instructions, as a message. Either way it stays the same chat. See [Compaction](../organizing-chats/#compaction).

## Slash commands

Type `/` to see the commands the gateway offers for this chat: built-ins, skills and plugins. After you pick one, Pincer suggests its arguments too:

- listed choices, such as `/verbose on`;
- the agent's models, for `/model`;
- the session's thinking levels, for `/think`.

| Action | Keys |
| --- | --- |
| Move through suggestions | <kbd>↑</kbd> <kbd>↓</kbd> |
| Complete | <kbd>Tab</kbd> or <kbd>Return</kbd> |
| Hide suggestions | <kbd>Esc</kbd> |
| Send a complete command | <kbd>Return</kbd> |

A few notes:

- `/clear` is sent as `/reset`, like the Control UI.
- Gateways that don't support `commands.list` get a built-in list of common commands.

### Handy commands

| Command | What it does |
| --- | --- |
| `/reasoning on` | Save and stream the agent's reasoning for this session. |
| `/model` | Switch the session's model. |
| `/think` | Set the session's thinking level. |
| `/compact` | Summarize older messages to free up context. Add instructions after it to say what to keep. |
| `/reset` or `/clear` | Start the session fresh. |

The exact list depends on your gateway, its skills and its plugins.

## Quick Capture

On macOS, you can send to any chat from any app with <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd>, without switching to Pincer. See [Quick Capture](../quick-capture/).
