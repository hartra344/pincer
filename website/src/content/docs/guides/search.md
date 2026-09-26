---
title: Search messages
description: Search the text of every cached chat on a gateway, and jump straight to the message.
---

Message search looks through the text of every chat Pincer has cached for the selected gateway, including older history you haven't scrolled to. Picking a result opens the chat with [Find in Chat](../transcript/#find-in-chat) on that exact message.

## Opening message search

There are three ways in:

- **⇧⌘F**, or **Go → Search Messages…**, opens the search straight away. It's available on macOS and on iPad with a keyboard, whenever a gateway is selected.
- In the **⌘K** command palette, type at least two characters and choose **Search Messages for “…”**. It's listed right after the chats that match, or first when no chat name matches, so pressing <kbd>Return</kbd> on a query that doesn't name a chat searches messages.
- In the sidebar, type in **Find a chat**. A **Search messages for “…”** row appears above the chat list and opens the search with what you typed. This is the way in by touch, on iPhone and iPad.

## What matches

- **Case and accents are ignored.** `cafe` finds "Café", and `CAFE` finds "café".
- **Each word matches from its start.** `tok` finds "Tokyo", but `kyo` doesn't.
- **Several words must appear together, as a phrase.** `japan trip` finds "Japan trip" but not "trip to Japan".
- **Queries need at least two characters.** Punctuation on its own finds nothing.

Only the text of your messages and the agent's replies is searched, as the transcript shows it. Thinking, tool calls and their output, attachment names, link targets and messages that haven't finished sending or streaming are left out.

## What's searched

- **The selected gateway only.** Switch gateways to search another one.
- **Chats in the sidebar.** Helper (subagent) runs never show up, even when the sidebar lists them. Archived chats show up only while **Show Archived** (in the Organize menu) is on.
- **Cached history only.** Pincer caches every chat in the background after connecting (see [History and caching](../transcript/#history-and-caching)). The cache keeps up to the latest 20,000 messages of each chat, so anything older isn't searched.

New messages become searchable as soon as they're cached, whether you sent them or they arrived. A message that changes is searched with its new text.

## Results

Results are grouped by chat, and the chat with the newest match comes first. Each group has:

- a heading with the chat's title, plus **· Archived** for an archived chat;
- up to **3** matching messages, newest first. Each shows who sent it ("You", "via Discord" or the agent's name), when (the time today, the weekday for the past six days, otherwise the date) and a couple of lines of text around the match, highlighted the same way Find in Chat does;
- **More matches in *chat*…** when the chat has more than 3 matches. It opens the chat with Find in Chat on its newest match.

Results cover up to **30** chats. A very common word may leave out chats whose matches are all older.

## Keyboard

| Action | Shortcut |
| --- | --- |
| Move between results | <kbd>↑</kbd> <kbd>↓</kbd> |
| Open the selected result | <kbd>Return</kbd> |
| Back to the palette (when you came from ⌘K), otherwise close | <kbd>Esc</kbd> |
| Back to the palette, when the field is empty | <kbd>⌫</kbd> |

The arrow keys skip chat headings and wrap around at the ends. You can also click or tap a result, and pointing at a result selects it.

## Jumping to a message

Opening a result closes the search and opens the chat, even if it isn't loaded yet. Find in Chat opens with your query filled in and that message's match selected, scrolled into view and highlighted, with every other match in the chat highlighted too. The find bar shows where you are, such as "3 of 12", and <kbd>⌘</kbd> <kbd>G</kbd>, <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>G</kbd> or <kbd>Return</kbd> step through the matches. Find's own options (thinking and tool output) stay as you left them.

If that message is no longer in the chat, the newest match is selected instead. If nothing matches any more, the find bar says **No results**.

## What you might see

| Message | Meaning |
| --- | --- |
| **Indexing chats… n of m — results may be incomplete** | Pincer is still adding cached chats to the search index, for example the first time after an update. Results so far are shown, and the search runs again when indexing finishes. |
| **Type at least 2 characters.** | The query is too short. |
| **No messages match “…”.** | Nothing in the cached chats matches. Check the [matching rules](#what-matches). |
| **Connect to *gateway* to search messages.** | Pincer hasn't received the gateway's chat list yet. Search works once it connects. |
| **Message search needs the transcript cache, which is turned off.** | `PINCER_CACHE_DIR=off` is set. Search only covers cached chats. |
| **Message search is unavailable right now.** | The search index couldn't be read. Pincer rebuilds it on its own; try again shortly. |

The search index is stored next to the transcript cache. See [Security & privacy](../../reference/security/#local-cache).
