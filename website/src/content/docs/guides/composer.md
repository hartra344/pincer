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
| `/reset` or `/clear` | Start the session fresh. |

The exact list depends on your gateway, its skills and its plugins.

## Quick Capture

On macOS, you can send to any chat from any app with <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd>, without switching to Pincer. See [Quick Capture](../quick-capture/).
