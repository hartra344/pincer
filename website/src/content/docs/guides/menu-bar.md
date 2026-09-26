---
title: Menu bar
description: Quick Capture, unread chats, active runs, pending approvals and each gateway's status from the Mac menu bar.
---

Pincer can put an item in the Mac menu bar. It gives you Quick Capture and shows what needs you, what's running, what's unread and how each gateway is doing, without opening Pincer's window. It's macOS only.

## Turn it on

Open **Settings → General → Menu Bar** and turn on **Show Pincer in the menu bar**. It's off until you turn it on.

The item shows up right away, and turning the setting off removes it. You don't need to relaunch. The setting is kept on this Mac only and isn't [synced](../../reference/synced-preferences/) to your gateways.

To move the item, hold <kbd>⌘</kbd> and drag it along the menu bar. Dragging it out of the menu bar turns the setting off.

Pincer's Dock icon stays either way.

To have the menu bar item ready after you log in, turn on **Open at Login** in **Settings → General → Launch**. See [Start Pincer at login](../quick-capture/#start-pincer-at-login).

## The icon

The icon follows the menu bar's light or dark look. Next to it is the number of unread chats plus the approvals and questions waiting for you, shown as **99+** above 99. There's no number when there's nothing to show.

While an approval or question is waiting, the icon changes to a speech bubble with an exclamation mark.

## What's in the menu

| Item | What it does |
| --- | --- |
| **Quick Capture…** | Opens [Quick Capture](../quick-capture/). It shows your shortcut, such as <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd>, and works even when the shortcut is turned off. |
| **Open Pincer** | Brings Pincer's main window to the front. It opens a new one if you closed it, or restores it from the Dock if it's minimized. |
| **Needs You** | Approvals and questions waiting for your answer. |
| **Running** | Chats where the agent is replying right now. |
| **Unread** | Chats with messages you haven't read. |
| **Gateways** | Each saved gateway and its status. |
| **Settings…** | Opens Pincer's Settings window, in front of other apps. |
| **Quit Pincer** | Quits Pincer. |

The menu works with Pincer's main window closed, and it keeps up to date while Pincer runs.

## Needs You, Running and Unread

- **Needs You** lists [exec approvals](../approvals-and-notifications/) first, then agent questions. Each row shows the command or question and the chat it's in, for example *Approve: rm -rf ./build — 🛠️ Main · Forge*. Approvals that have expired and questions that were answered or have expired aren't listed. Up to 5 rows.
- **Running** lists chats with a reply in progress, newest first. Up to 5 rows.
- **Unread** lists unread chats, newest first. Up to 8 rows.

Helper (subagent) runs and archived chats aren't listed. A chat shows up only once. If it has an approval or question waiting it's under **Needs You**, otherwise under **Running** if a reply is in progress, otherwise under **Unread**. A chat with two approvals gets two rows.

When a section has more rows than fit, its last row says **N more…** and opens Pincer.

Chat rows look like notification titles: the agent's emoji, the chat's name and the agent's name, such as *🦞 home-lab · Claw*. Long names, commands and questions are cut at 40 characters. With more than one gateway, each row ends with the gateway's name, such as *— Home*.

Only gateways that are connected add rows, so you won't see chats you can't open yet. A gateway that's offline just shows its status. When nothing is waiting, running or unread on a connected gateway, the menu says **You're all caught up**.

Click a row to open that chat in Pincer's main window, on the right gateway. Approvals and questions aren't answered from the menu. The chat shows the full command, its folder and any warning, so you can decide there. You can also answer approvals from [notifications](../approvals-and-notifications/).

## Gateway status

Each saved gateway is listed in the same order as the rail, with one of these:

| Status | Meaning |
| --- | --- |
| **Connected** | Connected and healthy. |
| **Degraded** | Connected, but something on the gateway isn't working. See [Gateway health](../gateway-health/). |
| **Restarting…** | The gateway is restarting. |
| **Connecting…** | Pincer is connecting. |
| **Reconnecting…** | The connection dropped and Pincer is trying again. |
| **Waiting for approval** | The gateway has to approve this device. See [Troubleshooting](../../reference/troubleshooting/#pincer-is-waiting-for-pairing). |
| **Can't connect** | The connection failed, for example because of a bad token. |

Click a gateway to select it in Pincer's main window. If it can't connect, the window shows why.

With no gateways saved, the section says **No gateways yet**.
