---
title: Quick Capture
description: Send a message to any chat from any app on your Mac with a global shortcut.
---

Quick Capture opens a small composer on top of whatever you're doing. Pick a chat, or start a new chat with an agent, type, and send. You don't have to switch to Pincer's window. It's macOS only.

## Open it

Press <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd> anywhere, or choose **Go → Quick Capture…**.

The panel opens near the top of the screen your pointer is on. It works over full-screen apps and when Pincer's main window is closed. The app you were using stays in front, and focus goes back to it when the panel closes.

Pincer has to be running for the shortcut to work. It doesn't need Accessibility permission. To have it ready after you log in, turn on [Open at Login](#start-pincer-at-login).

## Pick where to send

The **To:** chip at the top shows where the message goes. By default that's the chat you last sent to from Quick Capture, or else the chat open in Pincer.

To change it, click the chip or press <kbd>⌘</kbd> <kbd>J</kbd> or <kbd>Tab</kbd>. A searchable list opens with:

- the current chat and recent chats first, then your other chats (pinned first);
- **New Chat with *agent*** for every agent on each connected gateway.

Helper runs, automations and archived chats aren't listed. With more than one gateway, each row shows which gateway it's on, and chats on a gateway that's offline can't be picked.

## Type and send

The composer works like the main [composer](../composer/):

- Paste or drag in images and files to attach them.
- Slash commands work too.

Sending to a chat you picked adds your message to it. Sending to **New Chat with *agent*** creates the chat first. Either way, Pincer's main window stays on the chat it was showing.

If the send fails, the panel stays open with your text and shows the error, so you can try again. After a failed send to a new chat, the next try goes to the chat that was already created, so you don't get a duplicate.

Closing the panel without sending keeps your draft until the next time you open it. Drafts aren't kept after you quit Pincer.

## Keys

| Action | Keys |
| --- | --- |
| Open or close Quick Capture | <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd> |
| Send | <kbd>Return</kbd> |
| Send and open the chat in Pincer | <kbd>⌘</kbd> <kbd>Return</kbd> |
| New line | <kbd>⇧</kbd> <kbd>Return</kbd> or <kbd>⌥</kbd> <kbd>Return</kbd> |
| Open the chat in Pincer without sending | <kbd>⌘</kbd> <kbd>O</kbd> |
| Choose a chat | <kbd>⌘</kbd> <kbd>J</kbd> or <kbd>Tab</kbd> |
| Send to a pinned chat | <kbd>⌘</kbd> <kbd>1</kbd>–<kbd>9</kbd> |
| Close the chat list, then the panel | <kbd>Esc</kbd> |

In the chat list, use <kbd>↑</kbd> <kbd>↓</kbd> to move and <kbd>Return</kbd> to pick. Clicking outside the panel closes it too.

## Change or turn off the shortcut

Open **Settings → General → Quick Capture**:

- **Quick Capture shortcut** turns the shortcut on or off.
- To pick a new one, click **Shortcut** and press the new combination. <kbd>Esc</kbd> cancels, and <kbd>⌫</kbd> turns the shortcut off.
- **Reset to Default** goes back to <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd>.

A shortcut needs at least one of <kbd>⌘</kbd>, <kbd>⌃</kbd> or <kbd>⌥</kbd>, except the function keys, which can be used on their own. Shortcuts macOS uses, such as <kbd>⌘</kbd> <kbd>Space</kbd>, can't be picked.

## Start Pincer at login

Turn on **Open at Login** in **Settings → General → Launch** to start Pincer when you log in, so the shortcut works right away. It's off by default and is macOS only.

If macOS needs your approval, Settings says so. Click **Open Login Items Settings…** and allow Pincer under **System Settings → General → Login Items & Extensions**.

To stop Pincer starting at login, turn **Open at Login** off, or remove Pincer in **System Settings → General → Login Items & Extensions**.
