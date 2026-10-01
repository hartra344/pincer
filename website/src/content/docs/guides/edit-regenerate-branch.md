---
title: Edit, regenerate and branch
description: Change a message and resend it, get a fresh answer, or fork a chat from any point.
---

Right-click (macOS) or long-press (iOS) a message in the transcript to see these actions. VoiceOver exposes them as custom actions. An action only appears when the chat can do it.

## Branch from Here

On any message, **Branch from Here** opens a new chat forked at that point. The original chat is untouched.

- On one of your messages, the new chat starts just before it and your message text is put back in the new chat's composer, ready to send or change.
- On an assistant reply, the new chat continues right after that reply with an empty composer.

## Edit & Resend

On one of your messages, **Edit & Resend** puts its text in the composer with an **Editing message** chip. Nothing changes until you press Send. Cancel (the chip's button, or Esc) restores your previous draft.

When you send, the chat rewinds to before that message and your edited text is sent as a new message. The earlier path isn't lost: it stays as a branch you can see in the [Session Manager](../sessions/).

If the original message had images, they're kept and sent again with the edited text.

## Regenerate

On the last assistant reply, **Regenerate** rewinds to the message before it and sends that message again unchanged, for a fresh answer. Any images on that message are sent again too. It isn't offered while a reply is streaming.

## Switching between branches

When a chat has more than one path, an inline **‹ 2 / 3 ›** switcher sits in the footer of the message where the branches fork. Use the arrows to step to the previous or next path, or click the label for a menu that lists every branch (with its message count and a checkmark on the current one); the transcript reloads to show it. The switcher is hidden while a reply is streaming. Nothing is deleted by switching, and you can still manage every branch in the [Session Manager](../sessions/). Switching needs Full Management (admin) access.

## The header branch menu

Whenever a chat has more than one branch, a branch icon appears in the chat header: in the toolbar on iPhone, iPad and Mac, and in each pane header in split view. Hover it for a tooltip such as "Branch 2 of 3" (VoiceOver reads the same). Click it to list every branch with its message count and a checkmark on the current one, then pick one to switch, without scrolling back to the fork point. Switching needs Full Management access and isn't possible while a reply streams; the menu then shows why.

:::note
The Gateway only reports where each branch ends, not where it forks. Pincer puts the switcher on the message your latest Edit & Resend or Regenerate sent (remembered until the app quits), otherwise on the last message you sent on the current branch. After relaunching, or on another device, it may sit lower than the real fork point.
:::

## What you need

- **Branch from Here** needs write access to the Gateway.
- **Edit & Resend** and **Regenerate** aren't available while a reply is streaming. They rewind the chat, which is an admin operation, so they need Full Management (admin) access.
- **Switching branches** also needs Full Management (admin) access.

## Try it in the Demo

The [Demo](../../getting-started/try-the-demo/) has a chat with several turns, so all three actions are available without a Gateway.
