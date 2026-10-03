---
title: Read aloud
description: Listen to your agent's replies using your gateway's voice or the voice built into your device.
---

Pincer can read an agent's reply out loud. It uses your gateway's text-to-speech voice when there is one, and your device's built-in voice otherwise.

## Read a reply aloud

Every agent reply has a **Listen** button (a speaker icon) in the row of buttons under it, next to Copy and Reply. Choose it to hear the reply. While that reply is speaking, the button turns into **Stop**. You can also right-click a reply (Mac) or long-press it (iPhone and iPad) and choose **Read Aloud**.

While it's speaking, a **Speaking** pill appears at the bottom of the chat. The transcript leaves room for the pill so it doesn't cover the last message. Tap it, or press <kbd>Esc</kbd>, to stop. <kbd>Esc</kbd> works even while you're typing in the message box, but it first closes menus, stops dictation and cancels an edit or reply chip. Only when none of those apply does it stop the reading.

Other ways to start and stop:

- **Command palette.** Press <kbd>⌘</kbd> <kbd>K</kbd> and run **Read Last Reply Aloud**. While something is speaking, it says **Stop Reading Aloud** instead. **Read Aloud Settings…** opens the settings, and **Gateway Voice Settings…** opens the gateway's voice page.
- **Keyboard.** <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>L</kbd> reads the latest reply in the chat you're looking at, on a Mac and on an iPad with a keyboard. Press it again to stop. You can change it in Settings → Keyboard Shortcuts (Shortcuts on a Mac). See [Change a shortcut](../../reference/keyboard-shortcuts/#change-a-shortcut).

Pincer prepares the latest readable reply in the background, so the menu command and keyboard shortcut become available once that reply is ready. If a newer message has no readable text, the command uses the most recent reply that does.

Only one reply speaks at a time. Starting another one stops the first.

### On iPhone and iPad

Speech keeps going when you switch apps or lock the screen. The Lock Screen and Control Center show what's playing, and you can stop it from there.

It stops by itself when something else needs the audio: a phone or FaceTime call, an alarm or Siri, or when you unplug your headphones.

### What gets read

Pincer reads the reply's text the way you'd say it, not the way it's typed:

- Formatting marks (headings, bold, lists, quotes and table lines) are removed.
- Code blocks, diagrams and math blocks are skipped. Short `inline code` is read as ordinary words.
- Links are read by their text, and bare web addresses and images are skipped.
- Tool calls, tool output and the agent's thinking are never read. Only the reply is.

Replies that are only code or tool calls have nothing to read, so **Read Aloud** doesn't appear for them.

Pincer checks reply text for readable content in the background, keeping transcript scrolling responsive. A newly loaded or edited reply can show **Listen** after that check finishes.

## Which voice is used

Pincer decides for each reply:

1. **Gateway voice.** If your gateway supports spoken replies (OpenClaw 2026.7 or later) and has a text-to-speech provider set up, the gateway makes the audio with that provider and persona.
2. **Device voice.** Otherwise, or if the gateway can't make the audio for any reason, Pincer uses the voice built into your Mac, iPhone or iPad. You never get silence just because the gateway had a problem.

The gateway voice reads a long reply two sentences at a time, so it starts quickly and keeps going without pauses. The next few pieces are made while the current one plays. If one piece fails or takes too long, the device voice reads the rest of the reply from that point.

:::note
Sending text to the gateway's voice needs write access. If you connected with a read-only token, Pincer uses the device voice.
:::

## Settings

Open **Settings** and find the **Read Aloud** section. On a Mac it's on the **Conversation** tab.

Device voices load in the background so you can keep scrolling and using Settings. Your selected voice stays saved while the list loads. The list refreshes when your system language or installed voices change.

- **Voice**: **Automatic** uses the gateway voice when there is one. **This Device Only** always uses the device voice, so the text of replies never goes back to the gateway to be spoken.
- **Device Voice** and **Speaking Rate** set the voice used when the device speaks. Pick **System Default** to follow your system language. If a voice you chose earlier isn't installed any more, the picker shows **System Default** instead of going blank.
- **Read New Replies Aloud** speaks an agent's final reply when a run finishes successfully in the chat you have open. It doesn't read old messages, chats in the background or history loading in. It stays quiet while VoiceOver is running, so the two don't talk over each other. If you leave the chat or start dictating before a new reply is ready to speak, that pending reply stays quiet.
- **Gateway Voice** shows what **Automatic** will do, and **Open Gateway Voice Settings…** takes you to the setup page. It reads:
  - "ElevenLabs (Eleven v4 Turbo) via *your gateway*" when the gateway voice is working.
  - "ElevenLabs can't be used (…). Gateway uses OpenAI." when the provider you picked isn't usable and the gateway would use another. Without another, it says "Using this device's voice."
  - "Not set up. Using this device's voice." or "Gateway not connected. Using this device's voice."
  - "Not used (This Device Only)" when you chose **This Device Only**.
  - "Last reply used this device's voice: …" with the reason, when the most recent reply fell back.
- **Test Device Voice** plays a short sentence with your device voice and speaking rate.

## Gateway voice settings

The gateway's own speech settings are in **Gateway Settings → Voice**. To set up a provider such as ElevenLabs, with its key, model and voice, see [Gateway voice](../gateway-voice/). The settings are shared by everyone using the gateway, including its channels:

- **Provider**: which text-to-speech service the gateway uses. Each provider shows whether it's ready or needs a key.
- **Persona**: a named voice style set up on the gateway, or **None**.
- **Speak Replies on Channels**: makes the gateway attach a spoken version to every reply it sends on your channels (Telegram, WhatsApp and so on). You don't need it for **Read Aloud** in Pincer.

The page only appears if your gateway has text-to-speech. Choosing a provider or persona needs write access, and changing keys, models and voices needs Full Management.

## Try it in the demo

In [the demo](../../getting-started/try-the-demo/), right-click or long-press any reply and choose **Read Aloud**. The demo gateway has two providers and two personas you can switch between in **Gateway Settings → Voice**. Its "gateway voice" is a short tone, so you can tell it apart from the device voice.
