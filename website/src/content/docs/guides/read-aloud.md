---
title: Read aloud
description: Listen to your agent's replies using your gateway's voice or the voice built into your device.
---

Pincer can read an agent's reply out loud. It uses your gateway's text-to-speech voice when there is one, and your device's built-in voice otherwise.

## Read a reply aloud

Right-click a reply (Mac) or long-press it (iPhone and iPad) and choose **Read Aloud**. While it's speaking, a **Speaking** pill appears at the bottom of the chat. Tap it, or choose **Stop Reading Aloud** from the same menu, to stop.

On a Mac, **Read Last Reply Aloud** (<kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>L</kbd>) reads the latest reply in the chat you're looking at. Press it again to stop. You can change the shortcut in [Settings → Shortcuts](../../reference/keyboard-shortcuts/#change-a-shortcut).

Only one reply speaks at a time. Starting another one stops the first.

### What gets read

Pincer reads the reply's text the way you'd say it, not the way it's typed:

- Formatting marks (headings, bold, lists, quotes and table lines) are removed.
- Code blocks, diagrams and math blocks are skipped. Short `inline code` is read as ordinary words.
- Links are read by their text, and bare web addresses and images are skipped.
- Tool calls, tool output and the agent's thinking are never read. Only the reply is.

Replies that are only code or tool calls have nothing to read, so **Read Aloud** doesn't appear for them.

## Which voice is used

Pincer decides for each reply:

1. **Gateway voice.** If your gateway supports spoken replies (OpenClaw 2026.7 or later) and has a text-to-speech provider set up, the gateway makes the audio with that provider and persona.
2. **Device voice.** Otherwise, or if the gateway can't make the audio for any reason, Pincer uses the voice built into your Mac, iPhone or iPad. You never get silence just because the gateway had a problem.

The gateway voice reads up to about 4,000 characters of a reply. The device voice reads the whole thing.

:::note
Sending text to the gateway's voice needs write access. If you connected with a read-only token, Pincer uses the device voice.
:::

## Settings

Open **Settings** and find the **Read Aloud** section. On a Mac it's on the **Conversation** tab.

- **Voice**: **Automatic** uses the gateway voice when there is one. **This Device Only** always uses the device voice, so the text of replies never goes back to the gateway to be spoken.
- **Device Voice** and **Speaking Rate** set the voice used when the device speaks. Pick **System Default** to follow your system language.
- **Read New Replies Aloud** speaks an agent's final reply when a run finishes successfully in the chat you have open. It doesn't read old messages, chats in the background or history loading in. It stays quiet while VoiceOver is running, so the two don't talk over each other.
- **Test Device Voice** plays a short sentence with your device voice and speaking rate.

## Gateway voice settings

The gateway's own speech settings are in **Gateway Settings → Voice**. They're shared by everyone using the gateway, including its channels:

- **Provider**: which text-to-speech service the gateway uses. Providers that aren't set up on the gateway are listed but can't be picked.
- **Persona**: a named voice style set up on the gateway, or **None**.
- **Speak Replies on Channels**: makes the gateway attach a spoken version to every reply it sends on your channels (Telegram, WhatsApp and so on). You don't need it for **Read Aloud** in Pincer.

The page only appears if your gateway has text-to-speech, and changing it needs write access.

## Try it in the demo

In [the demo](../../getting-started/try-the-demo/), right-click or long-press any reply and choose **Read Aloud**. The demo gateway has two providers and two personas you can switch between in **Gateway Settings → Voice**. Its "gateway voice" is a short tone, so you can tell it apart from the device voice.
