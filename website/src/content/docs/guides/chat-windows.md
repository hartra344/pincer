---
title: Chat windows
description: Open a chat in its own window on your Mac, or two chats side by side, so you can watch one while you work in another.
---

On macOS you can open any chat in its own window, or show two chats side by side in the main window. It's handy for watching a long run while you work in another chat. On iPad, side by side works in a full-width window.

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

## Two chats side by side

The main window can show a second chat to the right of the selected one:

- Right-click a chat in the sidebar and choose **Open in Split View**.
- Or choose **View → Split Right** (<kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>\</kbd>) to open the chat you visited most recently next to the current one. You can change the shortcut in [Settings → Shortcuts](../../reference/keyboard-shortcuts/#change-a-shortcut).

The left chat keeps the window's title and toolbar. The right chat has a small header with its title and agent, and buttons to **Swap Chats**, **Open in New Window** (macOS) and **Close Split View** (also <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>\</kbd>). Drag the divider to resize the two chats; Pincer remembers the split.

Both chats have their own composer, and the right chat stays loaded and live and isn't notified, just like a chat in its own window. Selecting the right-hand chat in the sidebar moves it to the left, and the chat it replaces moves to the right. Menu commands and links inside either chat act on the left chat. The split also hides on a Mac when the window is too narrow for two chats.

On iPad, **Open in Split View** is in a chat's context menu in the sidebar. The split shows while the window is wide enough for two chats, and hides when it's too narrow (for example in Slide Over), then comes back.
