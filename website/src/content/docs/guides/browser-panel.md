---
title: Browser panel
description: Watch the agent's live browser in a panel next to the chat, view-only.
---

The **Browser** panel shows what the agent's browser is looking at right now, so you can follow along while it works. It's view-only for now: you can watch, but you can't click, type or navigate. Controls are coming.

## What it shows

The panel shows a live picture of the page the agent is using. That's either the managed OpenClaw browser or your own Chrome, when the agent reaches it through the extension relay. Pincer doesn't care which: it shows whatever browser the agent used.

The panel has a page picker for choosing between open pages, the page's address (read-only, and you can select and copy it), an **Open in Browser** button for `http` and `https` pages, and a status pill that reads **Live** while frames arrive.

## Requirements

- This device's **Access** is **Full Management** (the `operator.admin` scope). See [Access levels](../../getting-started/connect-a-gateway/#access-levels).
- The browser plugin is enabled on your gateway.

Without Full Management, the panel asks for it instead of showing the page.

## Opening it

- Click **Browser** in the chat toolbar, next to **Runs** (Runs comes first). On iPhone, use the ⋯ menu instead.
- On macOS, press **⌥⌘B**.
- Choose **Show Browser** from the chat's ⋯ menu. When the panel is open it reads **Hide Browser**.
- Click or tap a [browser page card](../tool-calls/#browser-page-previews) in the chat. The panel opens on that card's page.

The Browser panel shares its slot with [Runs](../subagents-and-runs/#opening-the-runs-panel). Opening one closes the other.

- **Mac and iPad:** an inspector on the right side of the window. You can resize it.
- **iPhone:** a sheet. Tap **Done** to close it.

## Privacy and performance

The picture streams only while the panel is visible. Close it and the stream stops. Pincer keeps nothing on disk: the last frame stays in memory, so reopening the panel is instant. Pincer never sends input to the page.

## Troubleshooting

- **"Viewing the agent's browser needs Full Management":** change this device's **Access** to **Full Management** in **Pincer Settings ▸ Gateways**, and approve it on the gateway host if asked.
- **"The agent's browser isn't running":** the agent hasn't started a browser yet, or it was closed. Ask the agent to open a page, and the panel picks it up. Also check that the browser plugin is enabled.
- **"This page is blocked":** the gateway stopped the stream because the page went somewhere its browser policy doesn't allow. Pick another page, or ask the agent to continue elsewhere.
- **"No pages open":** the browser is running with no pages. It fills in once the agent opens one.

## Try it in the demo

In [Try the Demo](../../getting-started/try-the-demo/), open any chat and press **⌥⌘B**. It shows two pages, OpenClaw Docs and a GitHub release, with a moving demo picture.
