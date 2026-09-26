---
title: Try the demo
description: Explore Pincer with a simulated gateway that runs entirely on your device.
---

Pincer has a built-in demo, so you can look around before you set up a gateway. It runs a simulated Gateway on your device with sample agents, chats, streamed replies, a chart, an exec approval, a sample approval history, an editable command policy, sample usage and cost data and a live gateway log. **Nothing leaves your device.**

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
- **Usage & Cost…** in the gateway's menu, to see the [usage dashboard](../../guides/usage-and-cost/);
- **Settings → Appearance**, to try a different theme;
- **Organize → Gateway Logs…**, to watch the simulated gateway's log grow. Send a message or trigger an approval and it shows up there. Try the level buttons, search, **Pause** and **Export…**;
- the **context meter** next to **Send**, which shows how full each demo chat's context is;
- **Approval History…** in the Organize menu, which has sample decisions, and answering an approval in the demo adds to it;
- **Gateway Settings → Command Policy** (or ⌘K → "Command Policy…"), to see which commands each agent may run. **Recently allowed** lists allowed commands such as `/usr/bin/git`, `/usr/bin/rg` and `/opt/homebrew/bin/npm`; open an agent to change its settings, or remove an allowed command or tool. Changes are saved to the demo gateway only;
- **Gateway Settings → Pairing Requests**, to approve or dismiss the sample people waiting to message your agents on Telegram and Discord;
- **Gateway Settings → Health**: Telegram has lost its connection, so the gateway shows **Degraded**, with its channels, last heartbeat and the three clients connected (this device, a Control UI and a node). **Restart Gateway…** simulates a safe restart: nothing real restarts, your chats are still there afterwards, and Telegram reconnects, so the gateway comes back **Healthy**. Start a reply first to see the restart wait for it, then try **Restart Now Anyway**. It works with the demo's default access, since nothing real restarts;
- <kbd>⌘</kbd> <kbd>K</kbd>, to open the command palette.

## Try Shortcuts and Siri

Pincer's [Shortcuts & Siri](../../guides/shortcuts-and-siri/) actions work with the demo too, with no gateway or pairing needed. Open the demo once, then try:

- "What's unread in Pincer". The demo starts with three unread chats: home-lab, Forge (Forge's main chat) and Paper digest.
- "Pending approvals in Pincer". The demo starts with one, from Forge: `git push origin fix/login-timeout`. Answer it in Pincer, and Forge follows up in its main chat with "Pushed fix/login-timeout to origin." or "OK, I won't push."
- "Ask Pincer", and ask anything. Siri reads the demo agent's reply back to you.
- the same actions in the Shortcuts app, where the demo's agents and chats show up in the pickers.

If you've also added your own gateway, pick **Demo** as the action's gateway, or select the demo in Pincer first.

Actions always use the app's own demo, and start it if it isn't running yet, even in the background on iOS. So messages you send and chats you start from Shortcuts or Siri show up in Pincer. The sample data resets when Pincer relaunches.

## Sample usage and cost

The demo comes with 90 days of made-up usage, busiest in the last month, so the [Usage](../../guides/usage-and-cost/) page has something to show. Open it with **Usage & Cost…** in the gateway's menu or the command palette.

- **Dashboard:** daily spend that varies from day to day and drops on weekends, across three agents (Claw, Scout and Forge) and five models from Anthropic, OpenAI, Google and a local Ollama model. Each chat's usage is billed to the model shown in its toolbar. `gpt-5.6-sol` has some unpriced requests every few days, so its cost is marked partial (*). The Ollama model has no pricing at all, so its session's cost shows as **—**.
- **Rate limits:** Claude's 5-hour window is at 92% (red) and resets within the hour, next to weekly windows. OpenAI has a daily request window, a credit balance and a monthly budget that matches the demo's OpenAI spend. Gemini shows a sign-in error, and Ollama says local models aren't metered.
- **Session drill-down:** choose **Session Usage…** from a demo chat's ⋯ menu, or double-click (macOS) or tap (iOS) a session on the dashboard, for its totals, a usage-over-time chart and a log of user, assistant, tool call and tool result entries that follows that chat's conversation.

:::tip
The demo is what TestFlight testers and App Review use, so they don't need a Gateway or Tailscale.
:::

## Next

When you're ready, [connect your own gateway](../connect-a-gateway/).
