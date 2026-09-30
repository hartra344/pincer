---
title: Deep links & Handoff
description: Link straight to a chat or message with pincer:// URLs, copy a link to any chat or message, and continue a chat on your other Apple devices with Handoff.
---

Every chat in Pincer has a link. Opening it brings Pincer to the front and opens that chat, on the right gateway. Handoff uses the same links to move the chat you're reading between your Mac and iPhone.

Links only **open** chats. They never send a message, fill in the composer or answer an approval. See [Security](#security).

## Copy a link to a chat

In a chat, open the **⋯** menu and choose **Copy Link to Chat**. Pincer copies the link and shows "Link copied".

Paste it anywhere you keep notes: a reminder, a note, a Shortcuts action or a message to yourself. Clicking or tapping it on a device where the same gateway is set up opens the chat.

## Copy a link to a message

Right-click a message on the Mac, or touch and hold it on iPhone and iPad, and choose **Copy Link**. Pincer copies the link and shows "Link copied". VoiceOver users find **Copy Link** in the message's actions.

Opening the link opens the chat and scrolls to the message. On the Mac it opens in your existing main window rather than a new one. Pincer loads older history if it needs to, then briefly highlights the message. A forwarded message links to its copy in this chat, not to the original.

## Link format

```
pincer://open?gateway=<gateway ID>&url=<gateway URL>&host=<gateway host>&session=<session key>&message=<message ID>
```

| Parameter | Required | What it is |
| --- | --- | --- |
| `gateway` | Yes | The gateway's ID, a UUID. Case doesn't matter. Demo links use `demo` instead. |
| `url` | No | The gateway's address, such as `wss://gateway.example.ts.net`. Pincer uses it to find the gateway on another device. Any user name or password in the address is removed. |
| `host` | No | The host name the gateway reports for itself, such as `travis-mbp.local`. It's the same whichever address a device uses, so Pincer uses it to find the gateway on another device. |
| `session` | No | The chat's session key, such as `agent:main:main`. Without it, the link just selects the gateway. |
| `message` | No | A message in the chat. Pincer scrolls to it and highlights it. |

Values are percent-encoded. Session keys contain `:` and can contain `/`, so a key like `agent:main:discord:channel/123` is written as `agent%3Amain%3Adiscord%3Achannel%2F123`. **Copy Link to Chat** and **Copy Link** do this for you.

The gateway ID is the same one [Shortcuts & Siri](../shortcuts-and-siri/) uses. A chat's Shortcuts identifier, `<gateway ID>/<session key>`, splits into the `gateway` and `session` parameters.

Parameters Pincer doesn't know are ignored, and so are links that aren't `pincer://open`.

## What happens when you open a link

| Situation | What Pincer does |
| --- | --- |
| The gateway is connected and the chat exists | Opens the chat, and scrolls to the message if there is one. |
| The gateway is saved but not connected | Opens the chat from the cache, and jumps to the message once its history loads. It doesn't send anything while the gateway reconnects. |
| The gateway isn't set up on this device | Shows your gateways and a notice: "That link points to a gateway that isn’t set up on this device." |
| The chat isn't on the gateway anymore | Opens the gateway and shows "That chat isn’t available on this gateway anymore." |
| The message can't be found | Opens the chat at the latest message and shows "Couldn’t find that message." |
| The link is broken, for example a bad gateway ID | Shows "Pincer couldn’t open that link." |

Notices appear as a banner at the top of the window and go away after 5 seconds. Click **✕** to dismiss one sooner.

A message link scrolls to the message and briefly highlights it, the same way tapping a reply's quote does. Chats opened from a link are added to [Back and Forward](../command-palette-and-navigation/#back-and-forward).

Pincer never adds a gateway from a link. Each device gives a gateway its own ID when you [connect it](../../getting-started/connect-a-gateway/), so when a link or Handoff comes from another device, Pincer looks for the same gateway among the ones saved here. Your devices don't need to use the same address: a Mac on `ws://127.0.0.1:18789` and an iPhone on `wss://travis-mbp.tail1234.ts.net` find the same gateway. Pincer tries, in order:

1. The gateway's ID, for links copied on this device.
2. The host name the gateway reports for itself. Pincer remembers it once the gateway has connected on this device.
3. The gateway's address, first exactly, then ignoring `ws`/`wss` and default ports.
4. The computer the address names, so `travis-mbp.local`, `travis-mbp` and `travis-mbp.tail1234.ts.net` count as one machine.
5. The only saved gateway that has the chat. Main chats (such as `agent:main:main`) don't count here, because every gateway has one.

If two saved gateways match equally, for example two gateways on one Mac, Pincer picks the one that has the chat, then the one you're using.

### The demo gateway

Links to [demo](../../getting-started/try-the-demo/) chats use `gateway=demo`, because the demo's ID is different on every device, so they work anywhere. Opening one adds the demo gateway if you don't have it, and opens the demo chat. It's a handy way to try links without a real gateway.

## One route for everything

Links, notifications, the **Open Chat** Shortcuts action, the [menu bar](../menu-bar/), [message search](../search/) results, [Spotlight](../search/#spotlight) results and Handoff all open chats the same way. They all behave the same way when a gateway or chat is missing.

## Handoff

While a chat is open, Pincer offers it to your other devices with Handoff:

- **Mac:** a Pincer icon appears at the end of the Dock, or in the app switcher (<kbd>⌘</kbd> <kbd>Tab</kbd>).
- **iPhone and iPad:** Pincer appears at the bottom of the app switcher.

Choose it to open the same chat, on the same gateway, on that device.

Pincer stops offering the chat when you leave it, when its gateway disconnects, or when you remove the gateway.

Handoff needs:

- Pincer installed on both devices, from the same build source (both from the App Store or TestFlight, or both built with the same Team ID);
- both devices signed in to the same Apple Account, with Bluetooth and Wi-Fi on;
- Handoff turned on: **System Settings → General → AirDrop & Handoff** on the Mac, and **Settings → General → AirPlay & Continuity** on iPhone;
- the same gateway set up on both devices, at any address. If it isn't, Pincer opens and shows the same notice as a link does.

The chat's draft and scroll position don't move over. Handoff only opens the chat.

## Security

- A link or Handoff only **navigates**. It never sends a message, puts text in the composer, allows or denies an approval or pairing request, or changes settings.
- Links never contain tokens or passwords. They contain the gateway ID, the gateway's address, the session key and the message ID. Handoff carries only the gateway ID, address, host name and session key, so it opens the chat but not a particular message.
- **Links include your gateway's address and host name.** If your gateway's hostname is private, such as a Tailscale name, don't post links publicly. Session keys can also show which channel a chat is on, for example a Discord channel ID.
- Opening a link never adds or edits a gateway. The device still needs its own approved connection.

See [Security](../../reference/security/#deep-links-and-handoff).
