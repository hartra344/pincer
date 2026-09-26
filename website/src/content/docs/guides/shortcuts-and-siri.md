---
title: Shortcuts & Siri
description: Ask agents, send messages and check unread chats and approvals from Shortcuts, Siri, Spotlight and the Action Button.
---

Pincer's actions show up in the Shortcuts app, Siri, and Spotlight on macOS and iOS, and in the Action Button on iPhone. Most of them run without opening the app. If Pincer is running and connected, it reuses that connection. Otherwise it connects once as the app's already approved device, the same way the Share extension does, and disconnects when the action is done.

## Actions

| Action | Opens Pincer | Returns |
| --- | --- | --- |
| **Ask Agent** | No | The reply, as text |
| **Send to Chat** | No | Nothing |
| **Start Chat with Agent** | Yes | The new chat |
| **Get Unread Chats** | No | A list of chats |
| **Get Pending Approvals** | No | A number |
| **Open Chat** | Yes | Nothing |

### Ask Agent

Sends a prompt to an agent's main chat and returns its reply. If the agent has no main chat yet, Pincer creates one.

| Parameter | Default |
| --- | --- |
| **Prompt** | Siri asks "What do you want to ask?" |
| **Agent** | The gateway's default agent |
| **Gateway** | Used only when no agent is chosen. Defaults to the [selected gateway](#more-than-one-gateway). |
| **Wait for Reply** | On |
| **Timeout (seconds)** | 60, from 5 to 300 |

With **Wait for Reply** on, the action returns the reply's plain text, and Siri reads it aloud. Siri reads about the first 500 characters, with line breaks collapsed. The full text is still passed on to the next step in your shortcut. If the reply has no text, Siri says "*Agent* replied without text."

With **Wait for Reply** off, the action returns an empty result as soon as the message is sent, and Siri says "Sent to *agent*."

If the reply takes longer than the timeout, the action fails with "Sent, but *agent* hasn't replied within *N* seconds." The message **was** delivered. The reply will show up in the chat in Pincer.

### Send to Chat

Sends a message to a chat without waiting for a reply. Siri asks "What should I send?" if there's no **Message**, and says "Sent." when it's done. **Chat** is required.

### Start Chat with Agent

Creates a new chat with an **Agent**, sends an optional first **Message** without waiting for a reply, and opens the chat in Pincer. It returns the new chat, so you can pass it to another action such as **Send to Chat**.

### Get Unread Chats

Returns the chats counted in Pincer's unread badge, most recent first. Helper runs and archived chats aren't included. Leave **Gateway** empty to check every gateway.

Siri says how many there are and names up to five, for example "3 unread chats: Research, Forge, Inbox." An agent's main chat is named after the agent, here Forge, unless you renamed it.

### Get Pending Approvals

Returns how many exec approvals are waiting for a decision. Expired approvals aren't counted. Leave **Gateway** empty to check every gateway.

Siri says "No pending approvals.", "1 pending approval: *command*", or "*N* pending approvals. First: *command*". The command is cut to its first line and about 60 characters.

This action is read-only. You can't approve or deny from Shortcuts or Siri. Answer approvals in Pincer or from their notifications. See [Approvals & notifications](../approvals-and-notifications/).

### Open Chat

Opens a **Chat** in Pincer.

## Siri phrases

These work without setting anything up.

| Action | Say |
| --- | --- |
| Ask Agent | "Ask Pincer" · "Ask *agent* in Pincer" |
| Send to Chat | "Send a message with Pincer" · "Send a message to *chat* in Pincer" |
| Get Unread Chats | "What's unread in Pincer" · "Unread chats in Pincer" |
| Get Pending Approvals | "Pending approvals in Pincer" · "What needs approval in Pincer" |
| Open Chat | "Open *chat* in Pincer" · "Open a chat in Pincer" |
| Start Chat with Agent | "Start a chat with *agent* in Pincer" · "Start a chat in Pincer" |

Phrases with an agent or chat name only work for names Siri has learned. Pincer updates them each time it loads an agent list, so open the app and connect once after installing it, and again after you add agents. Phrases without a name, such as "Ask Pincer", ask you for anything that's missing.

The same actions appear in Spotlight when you search for Pincer.

## Action Button

On an iPhone with an Action Button:

1. Open **Settings → Action Button**.
2. Swipe to **Shortcut**.
3. Tap **Choose a Shortcut**, then pick one of Pincer's actions under **Pincer**, such as **Ask Agent** or **Unread Chats**.

To give the button fixed parameters, such as always asking the same agent, make a shortcut in the Shortcuts app first and pick that instead.

## Shortcuts app

On macOS and iOS, open the Shortcuts app, create a shortcut, and search for **Pincer** in the actions list. Pick an agent, chat or gateway from the list Pincer suggests, or type to search.

- **Agents** show their emoji and name.
- **Chats** show the agent and gateway under the title. An agent's main chat is listed under the agent's name, unless you renamed it. Helper runs, automations and archived chats aren't suggested. Pinned chats come first, then the most recent.
- **Gateways** show their host under the name.

To make the list, Pincer asks each gateway for its agents and chats, and waits up to 5 seconds per gateway. Gateways that are offline are left out.

Actions chain like any other. For example, **Get Unread Chats** followed by **Repeat with Each** and **Open Chat**, or **Ask Agent** followed by **Show Result** or **Copy to Clipboard**.

## More than one gateway

- With one gateway, it's always used, and you never have to pick it.
- With several, actions that take an optional **Gateway** use the one selected in Pincer, unless you pick another. If none is selected, they use the first one.
- **Ask Agent** uses the chosen agent's gateway. **Gateway** only matters when no agent is chosen.
- **Get Unread Chats** and **Get Pending Approvals** check every gateway when **Gateway** is empty. A gateway that can't be reached is skipped. The action only fails if none of them can be reached.
- Agents show their gateway's name under their own, so two agents with the same name on different gateways can be told apart.

## In the background

**Ask Agent**, **Send to Chat**, **Get Unread Chats** and **Get Pending Approvals** run without bringing Pincer to the front. **Start Chat with Agent** and **Open Chat** open the app on the chat.

- **macOS:** if Pincer is running and connected to the gateway, actions use its connection.
- **iOS:** actions use the app's connection only while it's in the foreground. Otherwise they connect on their own, because a suspended app's connection can look open when it isn't. The [demo](#with-the-demo) is the exception.

Connecting on its own takes a moment, and the action fails with "*Gateway* isn't reachable." if the gateway doesn't answer within 10 seconds.

## With the demo

The actions also work with the built-in [demo](../../getting-started/try-the-demo/#try-shortcuts-and-siri), without a gateway or an approved device. They always use the app's own demo, starting it if needed, even in the background on iOS. So what you send or start from a shortcut shows up in Pincer. The demo's sample data resets when Pincer relaunches.

## Privacy

- **Unlock required.** Every action except **Open Chat** requires an unlocked device. They either return reply content or send messages, and a message can make an agent run commands on your machines.
- **No new access.** Actions use the device identity the gateway already approved, with the same [access level](../../getting-started/connect-a-gateway/#access-levels). They don't pair a new device.
- **Replies aren't stored.** Prompts and replies are passed to Shortcuts or Siri and are never logged or saved by the actions.
- **Names are cached.** So that saved shortcuts can show names when a gateway is offline, Pincer keeps the agent and chat names it last listed in its App Group: each agent's name and emoji, and each chat's title and agent name, up to 1,000 entries. No messages are cached.

See [Security & privacy](../../reference/security/#shortcuts-and-siri).

## Troubleshooting

See [Troubleshooting](../../reference/troubleshooting/#shortcuts-say-add-a-gateway-in-pincer-first) for what each error means.
