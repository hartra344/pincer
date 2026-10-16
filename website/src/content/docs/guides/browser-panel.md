---
title: Browser panel
description: Watch the agent's live browser and open its portals in a panel next to the chat.
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

The Browser panel shares its slot with [Runs](../subagents-and-runs/#opening-the-runs-panel). Opening one closes the other.

- **Mac and iPad:** an inspector on the right side of the window. You can resize it.
- **iPhone:** a sheet. Tap **Done** to close it.

## Portals

A portal is a small web app the agent started on the gateway's machine and shared through the gateway, such as a dashboard or a preview. When the agent has portals open, the panel shows a tab strip: **Browser**, then one tab per portal. With no portals, there's no strip.

- **The badge:** the panel's toolbar button and its ⋯ menu item show how many portals are open. Pincer never opens the panel by itself, so the badge is how you know something is waiting.
- **Viewing:** pick a portal's tab to load it inside the panel. It loads only while its tab is showing, and Pincer keeps at most three portals loaded at a time. A portal you haven't looked at in a while reloads when you select it again.
- **Address and reload:** the address row shows the portal's address without its access token, and you can select and copy it. **Reload** loads it again.
- **Open in Browser:** opens the portal in your default browser using its access link. Pincer asks first ("Open in your browser?"), because anyone with that link can use the portal until it closes.
- **Copy Link:** in the address row's ⋯ menu. It copies the address without access, so it never includes the access token.
- **Close:** the tab's ✕, its context menu, or **Close Portal** in the address row's ⋯ menu. Pincer asks `Close "Studio clock"?` and explains that the link stops working for everyone. The agent can open a new portal if needed. The Close controls are hidden when the connection can't open portals.

**On iPhone,** open the panel from the chat's ⋯ menu: **Show Browser** shows the portal count. It opens as a sheet, and the tab strip scrolls sideways. The address row is compact: the portal's host, **Reload**, and a ⋯ menu with **Open in Browser**, **Copy Link** and **Close Portal**. Pulling down inside a page scrolls the page and doesn't close the sheet. Tap **Done** to close it.

### Only the portal's own site

The panel only shows the portal's own site. If a page in the portal links somewhere else, Pincer opens that link in your browser instead, with the access token removed. A page that redirects you away, or navigates away on its own, is blocked: a **Blocked a page outside the portal** banner shows the site's name, with an **Open in Browser** button if you want to go there yourself. Nothing opens until you choose it. Pages can't open pop-up windows, download files, or use your camera, microphone or location. Each portal keeps its cookies and storage in memory only, and they're discarded when the portal closes or you quit Pincer.

### If a portal doesn't load

- **"This portal only listens on the gateway's machine, so it may not load here":** the portal is reachable only from the gateway's own computer, and you're connected from another device. Pincer still tries to load it.
- **"This connection can't open portals":** "Pincer was connected without permission to open links. Reconnect this Gateway to fix it." The gateway didn't give this device the portal's access link, so Pincer can't show it or close it. Make sure this device's **Access** includes write access, which **Full Management** does. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).
- **A load error:** choose **Try Again**.

Portals don't need the browser plugin. If your gateway doesn't support portals, the tab strip and badge never appear.

## Privacy and performance

The picture streams only while the panel is visible. Close it and the stream stops. Pincer keeps nothing on disk: the last frame stays in memory, so reopening the panel is instant. Pincer never clicks or types in the agent's browser.

## Troubleshooting

- **"Viewing the agent's browser needs Full Management":** change this device's **Access** to **Full Management** in **Pincer Settings ▸ Gateways**, and approve it on the gateway host if asked.
- **"The agent's browser isn't running":** the agent hasn't started a browser yet, or it was closed. Ask the agent to open a page, and the panel picks it up. Also check that the browser plugin is enabled.
- **"This page is blocked":** the gateway stopped the stream because the page went somewhere its browser policy doesn't allow. Pick another page, or ask the agent to continue elsewhere.
- **"No pages open":** the browser is running with no pages. It fills in once the agent opens one.

## Try it in the demo

In [Try the Demo](../../getting-started/try-the-demo/), open any chat and press **⌥⌘B**. It shows two pages, OpenClaw Docs and a GitHub release, with a moving demo picture. The demo also has one portal, **Studio clock**: its tab appears next to **Browser**, and closing it removes it.
