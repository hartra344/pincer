---
title: Try the demo
description: Explore Pincer with a simulated gateway that runs entirely on your device.
---

Pincer has a built-in demo, so you can look around before you set up a gateway. It runs a simulated Gateway on your device. **Nothing leaves your device.** It includes:

- three agents: **Claw** 🦞, **Scout** 🔭 and **Forge** 🛠️;
- chats sorted into groups, with three of them pinned;
- a long transcript (*Japan trip*) to scroll, page through and search;
- streamed replies with thinking and tool cards, plus an inline chart;
- exec approvals, and a sample **Approval History**;
- `ask_user` question cards and a task progress card;
- a context meter on each chat, and compaction;
- an editable command policy and sample pairing requests;
- 90 days of sample usage and cost data.

## Open the demo

Choose **Try the Demo**:

- on the welcome screen the first time you open Pincer, or
- in the **Add Gateway** sheet (click **+** in the rail).

The demo shows up in the rail like any other gateway. You can remove it whenever you like.

## Trigger words

Send a message and watch the reply stream in. A few words trigger special behavior, wherever they appear in your message:

| Include this | What happens |
| --- | --- |
| `tool` or `disk` | The agent streams a tool call, shown as a card with arguments and a result. |
| `image` | The reply also includes an inline chart. Click it for a Quick Look-style preview. |
| `approve` | The agent asks for an exec approval. Try **Allow once**, **Always allow** or **Deny**. |
| `approve once-only` | The same, but without **Always allow**, like a command the gateway won't allow for good. |
| `approve later` | The reply finishes first, then an approval arrives a few seconds later. On a Mac, switch to another app or lock the screen and answer it from the notification. |
| `ask` | The agent asks a question with a card of choices. Pick one, type your own answer, or skip it. |
| `plan` | A progress card above the composer ticks through three steps. |
| `/compact` | Compacts the chat's context and shows the divider, with the token count before and after. |

:::note
On iOS, Pincer is suspended in the background, so `approve later` can't reach you there. Send `approve` instead, then long-press the banner, or answer it from Notification Center.
:::

## Things to try

- **Approval History:** open it from [Gateway Settings](../../guides/gateway-settings/) or the command palette (<kbd>⌘</kbd> <kbd>K</kbd> → **Approval History…**) to browse past decisions of every kind.
- **Find in Chat:** press <kbd>⌘</kbd> <kbd>F</kbd> (on iOS, use the chat's ⋯ menu) and search for "onsen" in *Japan trip*.
- **Command palette:** press <kbd>⌘</kbd> <kbd>K</kbd> to jump anywhere. <kbd>⌘</kbd> <kbd>1</kbd>–<kbd>⌘</kbd> <kbd>3</kbd> open the pinned chats, and <kbd>⌘</kbd> <kbd>[</kbd> / <kbd>⌘</kbd> <kbd>]</kbd> go back and forward.
- **[Quick Capture](../../guides/quick-capture/)** (macOS): press <kbd>⌃</kbd> <kbd>⇧</kbd> <kbd>Space</kbd> from any app and send a message into a demo chat.
- **Drafts:** start typing in one chat, switch to another, and come back. Each chat keeps its own draft.
- **Context ring:** the ring by the composer shows how full a chat's context is. *Main* is orange; *Japan trip* is red, so open the ring and choose **Compact Now**.
- **Usage & Cost:** open it from the gateway menu or command palette to explore sample usage, model costs and rate limits. A chat's **Session Usage…** opens its usage history.
- **Command Policy:** open **Gateway Settings → Command Policy** (or ⌘K → **Command Policy…**) to inspect and change the demo's allowed commands and tools.
- The **layout** menu at the top of the sidebar, to switch between *By server*, *By agent*, *By group* and *Recent* (see [Organizing chats](../../guides/organizing-chats/)).
- Typing `/` in the composer to see [slash commands](../../guides/composer/#slash-commands).
- **Thinking Steps** in the chat's ⋯ menu, to choose how much of the agent's work you see.
- **Settings → Appearance**, to try a different [theme](../../guides/appearance/).
- **Gateway Settings → Pairing Requests:** review and approve or dismiss the sample people waiting to message your agents on Telegram and Discord.

See [Keyboard shortcuts](../../reference/keyboard-shortcuts/) for the rest.

## What the demo doesn't do

- **It doesn't remember.** Everything lives in memory and resets each time Pincer launches. If you answer a notification left over from a previous launch, you'll see "That approval expired. Nothing was run."
- **No push notifications.** There's no push relay, and the demo never registers for push. Notifications come from Pincer itself while it's running.
- **The Share extension has its own demo.** It runs in a separate process with its own demo instance, so it lists the demo chats and sends successfully, but the shared message won't appear in the app's demo.
- **Limited administration.** The demo simulates command policy and pairing requests, not general Gateway Settings, automations or plugins. For broader administration workflows, use the [mock gateway](../../development/mock-gateway/).

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
