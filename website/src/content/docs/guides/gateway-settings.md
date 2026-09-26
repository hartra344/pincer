---
title: Gateway Settings
description: View and edit your OpenClaw Gateway's configuration and plugins from Pincer.
---

Pincer can show and edit your gateway's configuration, so you don't have to hand-edit its config file.

## Opening Gateway Settings

- **macOS:** choose **Pincer → Gateway Settings…** (<kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>,</kbd>), or use the gateway's menu in the sidebar. It opens in its own window.
- **iOS:** use the gateway's menu in the sidebar. It opens as a sheet.

You can also open it from the Organize menu at the top of the sidebar, or from the [command palette](../command-palette-and-navigation/).

:::caution[Editing needs Full Management]
Settings are read-only unless this device's **Access** is set to **Full Management** on the **Connection** page, and the gateway host has approved that change. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).

[Approval History](#approval-history) is the exception. It works with the default **Chat & Approvals** access.
:::

## Pages

| Page | What's there |
| --- | --- |
| **Connection** | This device's URL, token, access level and TLS pin. **Apply** reconnects. |
| **Overview** | The gateway's version, config file and health. |
| **Approval History** | Past approval decisions from the last 30 days. |
| **Usage** | Tokens, estimated cost and rate limits. See [Usage & cost](../usage-and-cost/). |
| **Pairing Requests** | People waiting to message your agents on a channel that uses DM pairing. See [below](#pairing-requests). |
| **Gateway** | Core gateway settings. |
| **Agents & Models** | Agents, their models and defaults. |
| **Channels** | Messaging channels, such as Discord. |
| **Sessions & Messages** | How sessions and messages behave. |
| **Tools & Skills** | Tools and skills available to agents. |
| **Automation** | Scheduled and automated runs. |
| **Plugins** | Installed plugins and their settings. |
| **All Settings** | Every field, grouped by section. |
| **Raw Config** | The whole config as JSON5. |

**Connection**, **Overview**, **Approval History** and **Usage** are always there. The rest need the gateway's config.

The curated pages are built from the gateway's own schema, so they match what your gateway supports. Rarely used fields are under **Advanced**, and sections your gateway doesn't have are hidden.

**Search** in the sidebar finds any setting and jumps to it.

## Making changes

Edits from every page go into a single draft:

1. Change whatever you need, across as many pages as you like. The toolbar shows how many changes aren't saved yet.
2. Choose **Save** (<kbd>⌘</kbd> <kbd>S</kbd>). **Review Changes** lists every change.
3. Confirm. Pincer sends them together, and the gateway validates, saves and applies them.

If a value is invalid, the gateway sends back the field and the reason. Changes that need a gateway restart say so.

If someone else changed the config on the gateway in the meantime, Pincer rebases your draft on top and asks about any setting that conflicts.

### Secrets

Saved secrets are shown only as **saved**. Pincer never sends them back to the gateway unless you change them.

## Plugins

On the **Plugins** page you can:

- see installed plugins;
- **add** one from ClawHub, npm or git;
- **remove**, **enable** and **disable** plugins;
- fill in each plugin's settings and credentials.

## Raw Config

For anything the forms don't cover, **Raw Config** lets you edit the whole configuration as JSON5 and apply it in one go.

## Approval History

**Approval History** lists the gateway's decisions on commands, plugins and system changes from the last 30 days, newest first. Besides the Gateway Settings sidebar, you can open it with **Approval History…** in the Organize menu or the command palette.

It needs the `operator.approvals` scope, which both access levels include, so you don't need **Full Management**. It's read-only: answer pending approvals in the chat or from the notification. See [Exec approvals](../approvals-and-notifications/#exec-approvals).

- Filter by kind with **All**, **Commands**, **Plugins** or **System**.
- **Load More** at the bottom shows older decisions.
- **Refresh** in the toolbar reloads the list. On iOS you can also pull to refresh.
- New decisions appear at the top shortly after they're made.

Each entry shows its outcome:

| Outcome | Meaning |
| --- | --- |
| **Allowed once** | Allowed this time only. |
| **Always allowed** | Allowed, and allowed from now on. |
| **Denied** | Denied. When it wasn't a person, the reason follows, such as **Denied · Timed out**. |
| **Expired** | No one answered before it expired. |
| **Cancelled** | The request was cancelled. |
| **Pending** | Still waiting for an answer. |

Select an entry for the details:

- **Decision:** the outcome, the decision, the reason, and who decided it under **Decided by**, such as **This device**, another device, a channel, or **OpenClaw (automatic)**;
- **Times:** when it was requested, decided and set to expire;
- **ID**, with **Copy ID**;
- **Request:** the kind, the command with **Copy Command**, and the host, node, plugin, tool and severity when they apply;
- **Requested by:** the agent and chat, with **Open Chat** to jump to it.

If the gateway doesn't keep a history, the page says "Approval History Isn't Available". Update OpenClaw to see past decisions.

## Pairing Requests

When a channel account uses `dmPolicy: "pairing"`, someone new who messages it has to be let in before they can talk to your agents. **Pairing Requests** lists who's waiting, newest first, and the sidebar badge shows how many.

Each request shows:

- the sender's name or `@username`, if they set one. These come from the sender and aren't verified;
- the channel's sender id, such as "Telegram user id: 5550142". This is the part you can trust, and it's always shown;
- the channel and account the message came to;
- when they asked, when the request expires and, if they asked again, when they were last seen. On macOS, hover for the exact times.

What you can do:

- **Approve** asks you to confirm first. The sender can then DM the agent on that account. If the channel supports it, **Tell them they were approved** sends them a note. On a gateway that doesn't have a command owner yet, Full Management can also **Make them the command owner**.
- **Dismiss** removes the request without blocking the sender. They can ask again.
- Right-click (or long-press) a request to copy the sender id or the request id.

Expired requests can't be approved; dismiss them or wait for the next refresh.

:::note[Needs Full Management]
Reviewing pairing requests needs **Access → Full Management**. The gateway's pairing methods need `operator.pairing`, which Pincer doesn't ask for (see [Security & privacy](../../reference/security/#pairing-requests)); `operator.admin` covers it.
:::

There's no notification for new requests: the list refreshes when you open the page, when Pincer reconnects, and every 30 seconds while it's showing. On iOS you can also pull to refresh.

The pairing code the sender was given isn't part of the gateway's protocol, so Pincer doesn't show one. Senders you already approved aren't listed and can't be removed here. To revoke access, edit the channel's allowlist on the gateway.

## Current limits

- Gateway Settings has so far been tested against the [mock gateway](../../development/mock-gateway/) only.
- It doesn't browse the ClawHub catalog or show install progress yet.
- Lists of objects can't be edited in forms yet. Use **Raw Config** for those.
- **Pairing Requests** has no list of approved senders, can't remove them, and doesn't notify you about new requests.
