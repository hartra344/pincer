---
title: Accessibility
description: Using Pincer with VoiceOver, the keyboard and larger text sizes.
---

Pincer uses native controls throughout, so the system's accessibility features work in the sidebar, the transcript, the composer and Settings. This page covers what Pincer adds on top of that.

## VoiceOver

### Transcript

- Each message reads as one item: who wrote it, then the message, for example "Nova: Here's the summary…". Replies start with the message they reply to.
- **Actions rotor:** on a message, swipe up or down (iOS) or press <kbd>VO</kbd> <kbd>⌘</kbd> <kbd>Space</kbd> (macOS) for **Copy message**, **Reply**, **Copy Link** and **Add Reaction**. **Add Reaction** only appears when reactions are turned on. Agent replies with thinking also offer **Copy Thinking**.
- **On iPhone and iPad**, one swipe moves one whole message. The message's other buttons, such as showing thinking or a tool call's details, opening an image or toggling a reaction, are in the same actions rotor. So are its links, as **Open** followed by the link text, for up to 10 links.
- **On the Mac**, each message is a group. Press <kbd>VO</kbd> <kbd>⇧</kbd> <kbd>↓</kbd> to step inside it and reach its text, the **Copy**, **Reply** and **React** buttons, reaction chips, thinking and tool call headers, images and attachments.
- A reaction chip you've added reads as selected. The typing indicator reads as "Working".
- [File edit cards](../file-diffs/#voiceover) have a header button that reads what changed, for example "Edited foo.swift, 3 added, 1 removed, collapsed". Their copy button reads as **Copy diff**, or **Copy file contents** for a new file, and long diffs have **Show all N lines** and **Show fewer lines** buttons.
- Pincer says "Copied" when you copy a message, a code block or a diff, or use any other copy command.

### Announcements

- When the agent finishes replying in the chat you have open, VoiceOver reads the start of the reply, for example "Nova replied: Here's the summary…". Chats in the background don't announce.
- If a run fails, the [agent's avatar](../agent-avatars/#voiceover) announces it. With avatars turned off, Pincer says "Nova: reply failed" instead.
- The avatar also announces when the agent starts waiting for an approval.
- **Find in Chat** reads its result count as it changes, for example "Result 2 of 5" or "No results".

Pincer doesn't read replies token by token while they stream.

### Sidebar

Each chat reads its title, then whether it's pinned or unread, then its preview. While a chat is running, it also says what the agent is doing, for example "Moki is working" or "Moki: 2 helper runs working". The subagent runs button reads as "Show 3 subagent runs" or "Hide subagent runs".

### Composer

- The attach button reads as **Attach files**, and on iOS the photo button reads as **Attach photos**.
- Send reads as **Send**, or **Queue a follow-up** while a run is going, and **Stop** stops it.
- The [context meter](../composer/) reads as "Context window" with how full it is. Activate it for the details and **Compact Now**.
- The model picker reads as "Model" with the current model.
- Slash command suggestions are a list of buttons, with the highlighted one marked as selected.

### Settings

Icon buttons have spoken labels, for example **Remove** followed by the item it removes, or the theme's name in Appearance. In the chat icon picker, each symbol reads as words, and the current one reads as selected.

### Gateway Health

The **Dismiss**, **Always Ignore** and **Restore** actions are in the actions rotor. See [Gateway health](../gateway-health/).

## Keyboard

On macOS, and on iPad with a keyboard, you can use Pincer without a pointer:

- **Sidebar:** on macOS, <kbd>↑</kbd> <kbd>↓</kbd> move between chats. <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>↓</kbd> jumps to the next unread chat, and <kbd>⌘</kbd> <kbd>1</kbd>…<kbd>9</kbd> opens a pinned chat.
- **Command palette:** <kbd>⌘</kbd> <kbd>K</kbd> reaches any chat, agent or setting. <kbd>↑</kbd> <kbd>↓</kbd> move, <kbd>Return</kbd> runs, <kbd>Esc</kbd> closes.
- **Composer:** <kbd>Return</kbd> sends, <kbd>⇧</kbd> <kbd>Return</kbd> adds a new line, <kbd>⌘</kbd> <kbd>.</kbd> stops a run, <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>R</kbd> replies to the last message and <kbd>Esc</kbd> cancels the reply.
- **Slash commands:** <kbd>↑</kbd> <kbd>↓</kbd> move through suggestions, <kbd>Tab</kbd> or <kbd>Return</kbd> completes, <kbd>Esc</kbd> hides them.
- **Find in Chat:** <kbd>⌘</kbd> <kbd>F</kbd>, then <kbd>⌘</kbd> <kbd>G</kbd> and <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>G</kbd> step through matches. <kbd>Esc</kbd> closes the find bar.

The full list is in [Keyboard shortcuts](../../reference/keyboard-shortcuts/).

:::note
Moving through individual messages with the arrow keys isn't supported yet. Use VoiceOver, Find in Chat or the command palette to get around a long chat.
:::

## Text size

On iPhone and iPad, the transcript, sidebar and composer follow your **Text Size** setting (Settings → Accessibility → Display & Text Size → Larger Text), including the larger accessibility sizes. The chat lays itself out again as soon as you change it, without restarting Pincer. The composer's buttons grow with the text, up to a limit so they still fit beside it.

On macOS, Pincer uses the system's standard text sizes.

## Reduce Motion

With **Reduce Motion** turned on, [agent avatars](../agent-avatars/) show still poses instead of animating.

## Languages

Pincer is in English for now. The app is being prepared for translation. If you'd like to help, see [Localization](../../development/localization/).
