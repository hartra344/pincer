---
title: Generated files
description: Find and download again every file and image an agent sent in a chat, without scrolling back through the transcript.
---

When an agent makes something for you, such as a PDF report, a chart, a script or a spreadsheet, it appears in the chat. **Generated Files** collects every one of them for the current chat in a single list, newest first, so you can get last week's PDF back in two clicks.

## Opening the list

- **macOS:** click the tray button in the chat's toolbar, choose **Show Generated Files** from the chat's **⋯** menu, or press <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>A</kbd>. The list opens in the inspector on the right, next to Runs and the Browser.
- **iPad:** tap the tray button in the toolbar, or choose **Show Generated Files** from the chat's menu.
- **iPhone:** choose **Show Generated Files** from the chat's menu. It opens as a sheet; drag it up for more room.

The list belongs to the chat you're looking at. In a split view or a separate chat window, it shows that chat's files.

## What's in it

- Files and images the agent sent, whether as an attachment or as a `MEDIA:` line in its reply.
- Files the Gateway still knows about from earlier in the chat, even when Pincer hasn't kept that part of the history. These come from the Gateway's artifact list and are marked **Older message**.

Files you uploaded, and screenshots or output inside tool calls, aren't listed. A file the agent sent more than once is listed once, at the latest message.

Each row shows a thumbnail or file icon, the name, the size when known, and when it was sent. Use the search field to find a file by name or type, and **All**, **Files** or **Images** to narrow the list.

## Getting a file back

Click a row's **⋯** button, or right-click (touch and hold on iPhone and iPad):

- **Open** downloads the file and shows it in Quick Look.
- **Save…** downloads the file and asks where to save it.
- **Show in Chat** scrolls the chat to the message that sent it. Files listed only by the Gateway don't have this.

Files are downloaded from the Gateway when you open or save them, so you need to be connected. If the Gateway no longer has a file, Pincer says it couldn't get it.

The **Artifacts** group in the chat's **Files** tab works the same way: click an artifact to open it, or right-click it to save it.

## Staying up to date

The list refreshes when you open it and after each run in the chat, so a file the agent just sent appears without reloading. Pincer reads the chat's cached history once and builds the list in the background, so opening it never slows the chat down.

## Try it in the demo

In **Try the Demo**, open the **Main** chat and press <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>A</kbd> to see the disk usage chart and `disk-report.sh`. The **Rate limiter design** chat has a generated design PDF; choose **Open** to view it, or **Show in Chat** to jump to the reply that sent it.
