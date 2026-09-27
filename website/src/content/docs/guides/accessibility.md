---
title: Accessibility
description: Using Pincer with VoiceOver, the keyboard and larger text sizes.
---

Pincer uses native controls throughout, so the system's accessibility features work in the sidebar, the transcript, the composer and Settings. This page covers what Pincer adds on top of that.

## VoiceOver

### Transcript

- Each message reads as one item: who wrote it, then the message, for example "Nova: Here's the summary…". Long messages are shortened to a readable excerpt. Replies start with the message they reply to.
- **Actions rotor:** on a message, swipe up or down (iOS) or open the actions menu with <kbd>VO</kbd> <kbd>⌘</kbd> <kbd>Space</kbd> (macOS) to **Copy**, **Reply** or **Add Reaction** without moving to the buttons in the message footer. **Add Reaction** only appears when reactions are turned on.
- Pincer says "Copied" when you copy a message or a code block.
- The **Copy**, **Reply** and **React** buttons, reaction chips, thinking and tool call headers, images, attachments and reply quotes are all buttons with their own labels. A reaction chip you've added reads as selected.
- The typing indicator reads as "Working".

### Announcements

- When the agent finishes replying in the chat you have open, VoiceOver says so, for example "Nova replied". Chats in the background don't announce.
- The [agent's avatar](../agent-avatars/#voiceover) announces when the agent starts waiting for an approval or runs into a problem.

Pincer doesn't read replies token by token while they stream.

### Sidebar

Each chat reads its title, then whether it's pinned, unread or working, then its preview. The subagent runs button reads as "Show 3 subagent runs" or "Hide subagent runs".

### Composer

The attach button reads as **Attach file** (and **Attach photos** on iOS), and Send reads as **Send**, or **Queue a follow-up** while a run is going. The [context meter](../composer/) reads as "Context window" with how full it is. Slash command suggestions are a list of buttons, with the highlighted one marked as selected.

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

On iPhone and iPad, the transcript, sidebar and composer follow your **Text Size** setting (Settings → Accessibility → Display & Text Size → Larger Text), including the larger accessibility sizes. The chat relays out as soon as you change it, without restarting Pincer.

On macOS, Pincer uses the system's standard text sizes.

## Reduce Motion

With **Reduce Motion** turned on, [agent avatars](../agent-avatars/) show still poses instead of animating.

## Languages

Pincer is in English for now. The app is being prepared for translation. If you'd like to help, see [Localization](../../development/localization/).
