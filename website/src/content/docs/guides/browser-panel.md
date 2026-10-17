---
title: Browser panel
description: Watch the agent's live browser and browse the chat's files in a panel next to the chat.
---

The **Browser** panel shows what the agent's browser is looking at right now, so you can follow along while it works. You can move around the agent's browser, open and close its tabs and save a page. Clicking and typing into the page isn't available: the picture is view-only.

## What it shows

The panel shows a live picture of the page the agent is using. That's either the managed OpenClaw browser or your own Chrome, when the agent reaches it through the extension relay. Pincer doesn't care which: it shows whatever browser the agent used.

The panel has a page picker for choosing between open pages, the controls described below, and a status pill that reads **Live** while frames arrive.

## Controls

Navigating here steers the agent's real browser while it works. If the agent is in the middle of a task, moving it or closing its tab can change what the agent does next. The controls only appear with Full Management. Without it, you see the notice instead.

The header has one row, in this order: **Back**, **Forward**, **Reload Page**, the address field, **Open in Browser** (for `http` and `https` pages) and a ⋯ menu with **Copy URL**, **Download Page**, **New Tab…** and **Close Tab**. On iPhone the row is compact: **Back**, **Forward**, the address field and ⋯, which also holds **Reload Page**, **Open in Browser**, **Copy URL**, **Download Page**, **New Tab…** and **Close Tab**.

- **Go to an address:** click the address field (on Mac, press **⌘L** while the panel is focused), type, and press Return. Press Esc to put the current address back. While you type, the field isn't overwritten when the page changes. Addresses without `http://` or `https://` are completed: `example.com` becomes `https://example.com`, and `localhost:3000` or an IP address uses `http://`. Anything that isn't a web address, such as a search phrase, `javascript:` or an address with a user name and password, is refused with "Enter a web address".
- **Reload Page:** loads the page again in the agent's browser. While a page is loading, the header shows progress and the last picture stays on screen.
- **Back and Forward:** go through the page's history. They stay on until the gateway first refuses, because some gateways turn off the script setting these need. Then both are disabled, with "Back and Forward are turned off on this gateway". Reconnecting resets this.
- **New Tab:** ⋯ ▸ **New Tab…**, or **New Tab…** in the page picker, asks for an address and opens it as a new tab in the agent's browser. The panel switches to it.
- **Close Tab:** ⋯ ▸ **Close Tab** asks "Close this tab in the agent's browser?" and warns "The agent may be using it." After closing, the panel shows a neighbouring tab, or "No pages open".
- **Start Browser:** when the agent's browser isn't running, the panel says so and offers **Start Browser**.
- **Download Page:** saves the current page. The gateway makes a copy and Pincer fetches it, straight to a file rather than into memory. A progress indicator shows with a **Cancel** button. Cancelling stops Pincer's copy; the gateway may still have made one. When it finishes, choose where to save it: the save panel on Mac, the share sheet on iPhone and iPad. If the page changed before it could be downloaded, you'll be told. Failures show as "Couldn't download this page."
- **Blocked addresses:** if the gateway's browser policy refuses an address, a line under the row says "This address is blocked by the gateway's browser policy." Your typed address stays so you can fix it.

Errors show as a single line under the row and clear on their own after a few seconds.

## Requirements

- This device's **Access** is **Full Management** (the `operator.admin` scope). See [Access levels](../../getting-started/connect-a-gateway/#access-levels).
- The browser plugin is enabled on your gateway.

Without Full Management, the panel asks for it instead of showing the page.

## Opening it

- Click **Browser** in the chat toolbar, next to **Runs** (Runs comes first). On iPhone, use the ⋯ menu instead.
- On macOS, press **⌥⌘B**.
- Choose **Show Browser** from the chat's ⋯ menu. When the panel is open it reads **Hide Browser**.
- Click or tap a [browser page card](../tool-calls/#browser-page-previews) in the chat. The panel opens on that card's page.

The Browser panel shares its slot with [Runs](../subagents-and-runs/#opening-the-runs-panel) and [Portals](../portals/). Opening one closes the others.

Portals the agent opens have their own panel: see [Portals](../portals/).

- **Mac and iPad:** an inspector on the right side of the window. You can resize it.
- **iPhone:** a sheet. Tap **Done** to close it.

## Files

The **Files** tab, after **Browser**, shows the workspace of the chat you have open: what the agent changed, what it read and what it produced. With no chat selected it says "Select a chat to see its files". It also appears on iPhone, in the same sheet.

Turn it off with **Show Files in the workspace panel** under **Settings ▸ Appearance ▸ Workspace panel**. It's on by default. If your gateway doesn't offer file listing, the tab never appears.

### The list

- The header shows the workspace folder (select it, or use **Copy Path** in its menu), a **Search files** field, and filter chips: **All**, **N changed**, **N read** and **N artifacts**. Searching asks the gateway after a short pause and filters what's already shown at once.
- **Changed:** files the agent edited, with their path and size.
- **Read:** files the agent opened without changing them.
- **Artifacts:** things the agent produced in this chat. If the gateway left out some very large ones, a note says "Some large artifacts aren't listed."
- **Project files:** the workspace's folders. Open a folder to load it. Files the agent changed or read carry a badge. A very large folder shows "Showing the first N entries".
- A file that was deleted shows as **Deleted**, dimmed.

Groups collapse and expand, and Pincer remembers which per window. The last list for a chat shows immediately while a fresh one loads, and it refreshes when the agent finishes a run.

### Viewing a file

Open a file to see it in the tab, with **Back to Files** to return. Text shows in a scrolling monospaced view and images are shown as images. Anything else says "Pincer can't preview this file", with its size and **Copy Path**. Previews and edits are limited to 256 KiB: a larger file says "This file is too large to preview".

### Editing

Editing needs Full Management (the `operator.admin` scope). Without it, there's no **Edit** button and files are read-only. With it, text files up to 256 KiB can be edited:

1. Choose **Edit**, change the text, then **Save**. **Revert** drops your changes. Leaving with unsaved changes asks "Discard changes?", and you can **Keep Editing**.
2. If someone or something changed the file on the gateway since you opened it, you get "This file changed since you opened it". **Reload** discards your edits and shows the new version. **Overwrite…** replaces it with yours, after asking you to confirm, and the other changes to the file are lost. **Cancel** keeps you editing.
3. A file that no longer exists can't be saved: "This file no longer exists on the gateway."

Files with mixed line endings are view-only, so a save can't change them silently.

### What you can't do

You can't create, rename or delete files here. The gateway only lets operators overwrite files that already exist.

## Privacy and performance

The picture streams only while the panel is visible. While it shows a page that has a card in the chat, the card's thumbnail is refreshed from the live picture, scaled down and kept only in memory. Close it and the stream stops. Pincer keeps nothing on disk: the last frame stays in memory, so reopening the panel is instant. Pincer never clicks or types in the agent's browser.

## Troubleshooting

- **"Viewing the agent's browser needs Full Management":** change this device's **Access** to **Full Management** in **Pincer Settings ▸ Gateways**, and approve it on the gateway host if asked.
- **"The agent's browser isn't running":** the agent hasn't started a browser yet, or it was closed. Ask the agent to open a page, and the panel picks it up. Also check that the browser plugin is enabled.
- **"This page is blocked":** the gateway stopped the stream because the page went somewhere its browser policy doesn't allow. Pick another page, or ask the agent to continue elsewhere.
- **"No pages open":** the browser is running with no pages. It fills in once the agent opens one.

## Try it in the demo

In [Try the Demo](../../getting-started/try-the-demo/), open any chat and press **⌥⌘B**. It shows two pages, OpenClaw Docs and a GitHub release, with a moving demo picture.
