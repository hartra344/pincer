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

## Regenerate

On the last assistant reply, **Regenerate** rewinds to the message before it and sends that message again unchanged, for a fresh answer. It isn't offered while a reply is streaming.

## Switching between branches

When a chat has more than one path, a **Branch 1 of 2** control with previous and next arrows appears above the composer. Use the arrows to step to the previous or next path, or click the label for a menu that lists every branch (with its message count and a checkmark on the current one); the transcript reloads to show it. The switcher is hidden while a reply is streaming. Nothing is deleted by switching, and you can still manage every branch in the [Session Manager](../sessions/). Switching needs Full Management (admin) access.

## What you need

- **Branch from Here** needs write access to the Gateway.
- **Edit & Resend** and **Regenerate** aren't available while a reply is streaming. They rewind the chat, which is an admin operation, so they need Full Management (admin) access.
- **Switching branches** also needs Full Management (admin) access.

## Try it in the Demo

The [Demo](../../getting-started/try-the-demo/) has a chat with several turns, so all three actions are available without a Gateway.
