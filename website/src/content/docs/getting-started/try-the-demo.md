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
| `approve once-only` | An exec approval without **Always allow**, like a command the gateway won't allow for good. |
| `ask` | The agent asks you a question in a card above the composer: "What do you want removed?" |
| `plan` | The agent works through a three-step plan, shown in a card above the composer. |
| `/compact` | The chat is compacted, the same as **Compact Now**. |

While you're there, try:

- the **layout** menu at the top of the sidebar, to switch between *By server*, *By agent*, *By group* and *Recent*;
- typing `/` in the composer to see slash commands;
- **Thinking Steps** in the chat's ⋯ menu, to choose how much of the agent's work you see;
- **Settings → Appearance**, to try a different theme;
- the **context meter** next to **Send**, which shows how full each demo chat's context is;
- **Approval History…** in the Organize menu, which has sample decisions, and answering an approval in the demo adds to it;
- **Gateway Settings → Pairing Requests**, to approve or dismiss the sample people waiting to message your agents on Telegram and Discord;
- <kbd>⌘</kbd> <kbd>K</kbd>, to open the command palette.

## Try Shortcuts and Siri

Pincer's [Shortcuts & Siri](../../guides/shortcuts-and-siri/) actions work with the demo too, with no gateway or pairing needed. Open the demo once, then try:

- "What's unread in Pincer". The demo starts with three unread chats: home-lab, Forge (Forge's main chat) and Paper digest.
- "Pending approvals in Pincer". The demo starts with one, from Forge: `git push origin fix/login-timeout`. Answer it in Pincer, and Forge follows up in its main chat with "Pushed fix/login-timeout to origin." or "OK, I won't push."
- "Ask Pincer", and ask anything. Siri reads the demo agent's reply back to you.
- the same actions in the Shortcuts app, where the demo's agents and chats show up in the pickers.

If you've also added your own gateway, pick **Demo** as the action's gateway, or select the demo in Pincer first.

Actions always use the app's own demo, and start it if it isn't running yet, even in the background on iOS. So messages you send and chats you start from Shortcuts or Siri show up in Pincer. The sample data resets when Pincer relaunches.

:::tip
The demo is what TestFlight testers and App Review use, so they don't need a Gateway or Tailscale.
:::

## Next

When you're ready, [connect your own gateway](../connect-a-gateway/).
