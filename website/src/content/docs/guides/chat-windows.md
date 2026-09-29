---
title: Chat windows
description: Open a chat in its own window on your Mac, so you can watch it while you work in another.
---

On macOS you can open any chat in its own window. It's handy for watching a long run in one window while you work in another chat in the main window.

## Open a chat in a window

Do any of these:

- Right-click a chat in the sidebar and choose **Open in New Window**.
- Double-click a chat in the sidebar.
- <kbd>⌘</kbd>-click a chat in the sidebar.
- Select a chat and choose **File → Open Chat in New Window** (<kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>N</kbd>).

## What's in the window

The window shows just that chat. It has its own title and subtitle (the chat title, and the agent and model), its own toolbar (model, chat menu and runs panel), and a [composer](../composer/). The draft belongs to the chat, so it's the same one you'd see for that chat in the main window.

It uses the same Gateway connection as the main window, so it doesn't open another one.

## While a window is open

- The chat stays loaded and live. It isn't unloaded to save memory.
- Pincer doesn't show [notifications](../approvals-and-notifications/) for it while Pincer is active, just like the chat open in the main window.
- Opening the window marks the chat as read.

Clicking a subagent, run or chat link inside a chat window opens it in the main window, which comes to the front. See [Subagents & runs](../subagents-and-runs/).

## After you relaunch

Chat windows come back when Pincer relaunches, using macOS window restoration. If the chat was deleted, or its Gateway was removed, the window shows **Chat unavailable**; close it.
