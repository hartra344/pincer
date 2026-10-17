---
title: Portals
description: Open the small web apps a chat's agent shared through the gateway, in their own panel next to the chat.
---

A portal is a small web app the agent started on the gateway's machine and shared through the gateway, such as a dashboard or a preview. Each chat shows only the portals of the agent running it, in a **Portals** panel of its own, separate from the [Browser panel](../browser-panel/).

## Which portals a chat shows

A chat shows a portal when either of these is true:

- **The chat's agent opened it.** The agent opened it with a successful `portal` tool call in any of its chats. That includes calls the agent made through Tool Search, which the transcript shows as `dispatch_action`, and calls from a CLI harness, named `mcp__openclaw__portal`. Pincer remembers which agent opened each portal, so the portal stays with that agent after you start a new chat or the call scrolls out of the history. Once the portal closes, it disappears.
- **One of the agent's sessions owns it.** When a chat runs on a dedicated cloud worker, the gateway knows which portals belong to that session, and Pincer asks for them. They show in that chat and in the agent's other chats.

A portal opened somewhere else, such as from the OpenClaw Control UI, doesn't show in any chat. The gateway doesn't record which agent opened most portals, so Pincer relies on the agent's own tool calls to tell. Pincer only sees a call once it has loaded the part of the chat that holds it. A portal the agent opened in a chat you haven't opened in Pincer on this device, such as a channel or scheduled session, or far back in a long chat, shows once you open that chat or scroll back to the call.

## Opening it

Pincer never opens the panel by itself.

- When the chat has portals, a **Portals** button with a count appears in the chat toolbar, next to **Browser**. Click or tap it. With no portals, there's no button.
- On macOS, press **⌥⌘P**.
- Choose **Show Portals** from the chat's ⋯ menu. When the panel is open it reads **Hide Portals**. On iPhone, this is the way to open it.

The Portals panel shares its slot with [Runs](../subagents-and-runs/#opening-the-runs-panel) and [Browser](../browser-panel/). Opening one closes the others.

- **Mac and iPad:** an inspector on the right side of the window. You can resize it.
- **iPhone:** a sheet titled **Portals**. Tap **Done** to close it.

With no portals left, the panel says "No portals" and "Portals this agent opens show here."

## Using a portal

The panel has a tab per portal.

- **Viewing:** pick a portal's tab to load it. It loads only while its tab is showing, and Pincer keeps at most three portals loaded at a time. A portal you haven't looked at in a while reloads when you select it again.
- **Address and reload:** the address row shows the portal's address without its access token, and you can select and copy it. **Reload** loads it again.
- **Open in Browser:** opens the portal in your default browser using its access link. Pincer asks first ("Open in your browser?"), because anyone with that link can use the portal until it closes.
- **Copy Link:** in the address row's ⋯ menu. It copies the address without access, so it never includes the access token.
- **Close:** the tab's ✕, its context menu, or **Close Portal** in the address row's ⋯ menu. Pincer asks `Close "Studio clock"?` and explains that the link stops working for everyone. The agent can open a new portal if needed. The Close controls are hidden when the connection can't open portals.

**On iPhone,** the tab strip scrolls sideways. The address row is compact: the portal's host, **Reload**, and a ⋯ menu with **Open in Browser**, **Copy Link** and **Close Portal**. Pulling down inside a page scrolls the page and doesn't close the sheet.

### Only the portal's own site

The panel only shows the portal's own site. If a page in the portal links somewhere else, Pincer opens that link in your browser instead, with the access token removed. A page that redirects you away, or navigates away on its own, is blocked: a **Blocked a page outside the portal** banner shows the site's name, with an **Open in Browser** button if you want to go there yourself. Nothing opens until you choose it. Pages can't open pop-up windows, download files, or use your camera, microphone or location. Each portal keeps its cookies and storage in memory only, and they're discarded when the portal closes or you quit Pincer.

## If a portal doesn't load

- **"This portal only listens on the gateway's machine, so it may not load here":** the portal is reachable only from the gateway's own computer, and you're connected from another device. Pincer still tries to load it.
- **"This connection can't open portals":** "Pincer was connected without permission to open links. Reconnect this Gateway to fix it." The gateway didn't give this device the portal's access link, so Pincer can't show it or close it. Make sure this device's **Access** includes write access, which **Full Management** does. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).
- **A load error:** choose **Try Again**.

Portals don't need the browser plugin. If your gateway doesn't support portals, the Portals button never appears.

## Try it in the demo

In [Try the Demo](../../getting-started/try-the-demo/), open a chat with the **Forge** agent. Forge opened a **Studio clock** portal in its main chat, and its **retry-fix** session runs on a cloud worker that owns a **Build dashboard** portal, so Forge's chats show both. Other agents' chats, such as **Claw** or **Scout**, have no portals and no **Portals** button. Closing a portal removes it.
