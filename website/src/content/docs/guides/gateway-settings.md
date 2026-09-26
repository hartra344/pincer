---
title: Gateway Settings
description: View and edit your OpenClaw Gateway's configuration and plugins from Pincer.
---

Pincer can show and edit your gateway's configuration, so you don't have to hand-edit its config file.

## Opening Gateway Settings

- **macOS:** choose **Pincer → Gateway Settings…** (<kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>,</kbd>), or use the gateway's menu in the sidebar. It opens in its own window.
- **iOS:** use the gateway's menu in the sidebar. It opens as a sheet.

:::caution[Editing needs Full Management]
Settings are read-only unless this device's **Access** is set to **Full Management** on the **Connection** page, and the gateway host has approved that change. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).
:::

## Pages

| Page | What's there |
| --- | --- |
| **Connection** | This device's URL, token, access level and TLS pin. **Apply** reconnects. |
| **Overview** | The gateway's version, config file and health. |
| **Approval History** | Past decisions on commands, plugins and system changes. |
| **Command Policy** | Which commands agents can run and when they ask, and what you've always allowed. See [Command Policy](../command-policy/). |
| **Gateway** | Core gateway settings. |
| **Agents & Models** | Agents, their models and defaults. |
| **Channels** | Messaging channels, such as Discord. |
| **Sessions & Messages** | How sessions and messages behave. |
| **Tools & Skills** | Tools and skills available to agents. |
| **Automation** | Scheduled and automated runs. |
| **Plugins** | Installed plugins and their settings. |
| **All Settings** | Every field, grouped by section. |
| **Raw Config** | The whole config as JSON5. |

The curated pages are built from the gateway's own schema, so they match what your gateway supports. Rarely used fields are under **Advanced**, and sections your gateway doesn't have are hidden.

**Search** in the sidebar finds any setting and jumps to it.

## Making changes

Edits from every page except **Command Policy** go into a single draft. Command Policy has its own draft and **Save** button, because it's a separate file on the gateway.

For the config draft:

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

## Current limits

- Gateway Settings has so far been tested against the [mock gateway](../../development/mock-gateway/) only.
- It doesn't browse the ClawHub catalog or show install progress yet.
- Lists of objects can't be edited in forms yet. Use **Raw Config** for those.
