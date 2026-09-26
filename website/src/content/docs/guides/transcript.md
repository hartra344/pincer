---
title: Transcript, thinking & tools
description: Streaming replies, thinking, tool cards, images, models and message details in Pincer.
---

The transcript is where you read what your agents are doing. It's built with native views, not a web page, so it stays fast even in long chats.

## Streaming replies

Replies stream in as the agent writes them. Markdown is fully supported, including tables and code blocks with a **Copy** button.

Every message ends with a **Copy** button and its details: the model that wrote it and the full date and time it was sent.

## Thinking

OpenClaw only stores the agent's reasoning when the session's reasoning level is **on**. You can set it from:

- the hint above the composer;
- the chat's ⋯ menu: **Gateway Reasoning → Save & Stream**;
- the chat itself, by sending `/reasoning on`.

| Gateway Reasoning | Effect |
| --- | --- |
| **Save & Stream** | Reasoning streams live and is saved in the history. |
| **Stream Only** | Reasoning streams live but isn't saved. |
| **Off** | No reasoning. This also hides reasoning text in the transcript. |

### Thinking steps

How much of the agent's thinking steps (reasoning and tool calls) you see is a separate choice, set per device under **Thinking Steps** in the chat's ⋯ menu or in Settings:

- **None:** only replies.
- **Live Only** (default): thinking and tool calls show while the agent works, then hide once the reply is done.
- **All:** every turn keeps its thinking and tool calls, folded into one collapsible *Thinking* item once the turn finishes.

**Copy Thinking** stays in a reply's context menu whichever you pick.

## Tool cards

Each tool call is shown as a card with its arguments and result. When a tool call starts a helper (subagent) run, the card has an **Open run** button that takes you to it.

## Images

Pincer shows images inline, with a Quick Look-style preview and sharing. This covers:

- attachments on messages;
- the agent's `MEDIA:` lines, the same as the web UI. Local files are fetched through the gateway's `assistant-media` route;
- public `https` images the agent links to. These are downloaded directly, **without** any credentials or cookies.

To stop Pincer from loading images from the web, turn off **Load images the agent links from the web** in Settings.

## Your messages

Messages from you appear under **your own name**, even when you sent them through Discord. A small **via Discord** tag shows where they came from. Set your name in Settings. It defaults to your macOS full name.

## Models

The chat toolbar shows the session's model. Pick another from the list the gateway offers, or go back to the agent's default, and new messages use it.

Each reply's footer shows the model the gateway recorded for it, so earlier replies keep their original model after you switch.

## Find in Chat

**Find in Chat** (<kbd>⌘</kbd> <kbd>F</kbd>) opens a find bar at the top of the chat. It highlights every match and shows where you are, such as "3 of 12". <kbd>⌘</kbd> <kbd>G</kbd> and <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>G</kbd> (or <kbd>Return</kbd>) step through the matches, scrolling to each one. Its options menu can also search thinking and tool input and output, which expand when you land on a match in them.

To search every chat at once, use [Search messages](../search/) (<kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>F</kbd>). Opening one of its results opens that chat with Find in Chat already showing your query and the message you picked selected. Every search result is also a match in Find, though Find matches inside words too.

## History and caching

The full history of every chat loads in the background, so scrolling up never waits for the network. After connecting, Pincer caches every chat, most recently active first, and skips chats that haven't changed. Opening a chat shows the cached transcript right away, then fetches only what's new.

[Search messages](../search/) covers everything in this cache. The cache location and how to turn it off are described in [Security & privacy](../../reference/security/#local-cache).
