---
title: Try the demo
description: Explore Pincer with a simulated gateway that runs entirely on your device.
---

Pincer has a built-in demo, so you can look around before you set up a gateway. It runs a simulated Gateway on your device with sample agents, chats, streamed replies, a chart and an exec approval. **Nothing leaves your device.**

## Open the demo

Choose **Try the Demo**:

- on the welcome screen the first time you open Pincer, or
- in the **Add Gateway** sheet (click **+** in the rail).

The demo shows up in the rail like any other gateway. You can remove it whenever you like.

## Things to try

Send a message and watch the reply stream in. A few words trigger special behavior:

| Include this word | What happens |
| --- | --- |
| `tool` or `disk` | The agent streams a tool call, shown as a card with arguments and a result. |
| `image` | The reply also includes an inline image. Click it for a Quick Look-style preview. |
| `approve` | The agent asks for an exec approval. Try **Allow once**, **Always allow** or **Deny**. |

While you're there, try:

- the **layout** menu at the top of the sidebar, to switch between *By server*, *By agent*, *By group* and *Recent*;
- typing `/` in the composer to see slash commands;
- **Thinking Steps** in the chat's ⋯ menu, to choose how much of the agent's work you see;
- **Settings → Appearance**, to try a different theme.
- **Gateway Settings → Pairing Requests**, to approve or dismiss the sample people waiting to message your agents on Telegram and Discord.

:::tip
The demo is what TestFlight testers and App Review use, so they don't need a Gateway or Tailscale.
:::

## Next

When you're ready, [connect your own gateway](../connect-a-gateway/).
