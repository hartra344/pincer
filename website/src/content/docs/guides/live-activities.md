---
title: Live Activities & Dynamic Island (iOS)
description: Follow a running agent turn from the Lock Screen and the Dynamic Island on iPhone, with what the agent is doing, how long it has run, and when it needs your approval.
---

When an agent takes a while to answer, Pincer on iPhone shows the turn as a **Live Activity**: a card on the Lock Screen and in the Dynamic Island, so you can put the phone down and still see what's going on.

The card shows:

- **Who and where:** the agent's name and emoji, and the chat's title.
- **What it's doing:** *Thinking*, *Running exec* (the tool's name), *Replying*, or *Tidying up its memory* while it compacts the context.
- **Waiting for you:** *Waiting for your approval* in orange when a command needs your OK. Open Pincer to [answer it](../approvals-and-notifications/).
- **How long:** a timer that counts up from when the turn began, with no battery cost from Pincer.
- **How it ended:** *Finished*, *Something went wrong* or *Stopped*. A finished card stays on the Lock Screen for a few seconds, then goes. A stopped one goes at once.

Tap the card to open the chat.

## When you get one

- Only turns that run for **a few seconds**. Quick replies never flash a card.
- One card per running chat, for the chats you started or watch in Pincer. Helper (subagent) runs, archived chats, and automations or slash commands you've hidden from the sidebar don't get one.
- Cards are updated by Pincer itself, so they follow the turn for as long as iOS keeps Pincer running. If iOS suspends Pincer, the timer keeps counting but the status stops changing until you open Pincer again. For alerts while Pincer is closed, see [notifications while closed](../push-notifications/).
- iOS only lets an app start a Live Activity while it's in the foreground. A turn that begins while Pincer is in the background gets no card.

## Turning it off

Live Activities are on by default. To turn them off:

- In Pincer, **Settings → Notifications → Show running chats on the Lock Screen**. Cards on screen end right away.
- Or in iOS, **Settings → Pincer → Live Activities**.

Live Activities are iOS only. On macOS, the sidebar and the chat's avatar show a running chat.

:::note
Pincer is a pure operator client. The card is drawn from what your Gateway already tells Pincer about the turn: nothing is sent to Apple or to a server, and it holds no chat text.
:::

## Try it in the demo

The demo's replies finish in a couple of seconds, too fast for a card. In **Try the Demo**, send a message with the word "ask" in any chat. The agent asks you a question and waits, so the turn keeps running and the Lock Screen shows *Running ask_user* until you answer or skip. Send "ask me something and approve this" instead, and the card turns to *Waiting for your approval*. Nothing is executed.
