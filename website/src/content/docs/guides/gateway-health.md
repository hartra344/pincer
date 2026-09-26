---
title: Gateway health & restart
description: See whether your OpenClaw Gateway is healthy, who's connected, and restart it safely from Pincer.
---

The **Health** page shows how your gateway is doing and lets you restart it without a terminal.

## Opening it

Open [Gateway Settings](../gateway-settings/) and choose **Health** in the sidebar. The row gets an attention mark when the gateway is degraded (not counting dismissed issues) or needs a restart.

When something needs a look, a line at the top of the chat sidebar says so. Click or tap it to open the Health page:

| Line | Meaning |
| --- | --- |
| **Gateway degraded · N issues** | The gateway is up, but something on it isn't working. It only counts issues you haven't [dismissed](#dismissing-issues). |
| **Restart needed to apply changes** | A saved change only takes effect after a restart. |
| **Restarting Gateway…**, then **Reconnecting…** | A restart is under way. |
| **Gateway hasn't come back yet** | A minute after a restart the gateway still isn't answering. Pincer keeps trying; check the gateway host. |

A healthy gateway shows nothing there.

## What's on the page

- **Summary:** the level (**Healthy**, **Degraded**, **Down** or **Restarting**), the gateway's version, how long it has been up, and the last heartbeat with its status ("No heartbeat yet" if there hasn't been one).
- **Issues:** every reason the gateway counts as degraded, one per row:
  - a channel account that's enabled and set up but isn't running, isn't connected, or reported an error;
  - plugins that failed to load or are unavailable;
  - failed deliveries waiting in a queue;
  - a quarantined context engine;
  - a failed heartbeat, or one that's more than twice its interval late while heartbeats are on.
- **Dismissed:** issues you [dismissed](#dismissing-issues), collapsed until you open it.
- **Channels:** each channel with its status (Connected, Stopped, Error…) and its last error.
- **Connected Clients:** the apps and nodes connected to the gateway right now, with their platform, role and last activity. **This device** is marked.

The page updates live from the gateway's events and refreshes every 30 seconds while it's open. Use **Refresh** in the toolbar, or pull down on iOS, to refresh now.

If your gateway doesn't offer part of this, that section says **Unavailable on this Gateway** and the rest still works.

## Dismissing issues

Some issues are expected, like a channel account you keep set up but offline, or one old failed delivery. You can dismiss them so the gateway shows **Healthy** again.

- **Mac:** hover over the issue and click **Dismiss**, or Control-click it and choose **Dismiss**.
- **iPhone and iPad:** swipe left on the issue, or touch and hold it and choose **Dismiss**.
- **VoiceOver:** the **Dismiss**, **Always Ignore** and **Restore** actions are in the actions rotor.

A dismissed issue moves to the collapsed **Dismissed (N)** section. It doesn't count toward Degraded, the sidebar line, the Overview badge or the Settings attention mark. When every issue is dismissed, the summary shows **Healthy** and "N dismissed issues".

### Until it changes

**Dismiss** hides an issue until it changes:

| Issue | Comes back when |
| --- | --- |
| Channel account | its state changes (not running, not connected, error). A new error message alone doesn't bring it back. |
| Plugin failed to load | the error text changes |
| Failed deliveries | the count goes up. The same or a lower count stays hidden. |
| Heartbeat failed | the reason changes |
| Heartbeat late | the interval changes |
| Plugin unavailable, quarantined context engine | it clears and happens again |

Any issue also comes back if it clears up and happens again: when a device running Pincer sees a fresh result without the issue, it forgets the dismissal.

### Always Ignore

For a **channel account** or a **plugin** you can choose **Always Ignore This Account** or **Always Ignore This Plugin** from the context menu. It stays hidden whatever changes, and stays listed under **Dismissed** even while the gateway isn't reporting it, so you can restore it. Failed deliveries, context engines and heartbeats can't be always ignored, since they point to lost messages or a stalled agent.

### Restoring

Open **Dismissed**, then choose **Restore** from the context menu (swipe on iOS, or the hover button on the Mac). The issue goes back to **Issues** and counts again.

### Fixing instead

For channel, plugin and context engine issues, the context menu also has **Restart Gateway…** (with Full Management), which often fixes them. There's no way to retry or clear failed deliveries from Pincer yet: the gateway doesn't offer a method for it. That needs an upstream OpenClaw change; until then, dismiss the issue.

### Syncing

Dismissals are stored in your gateway's user preferences (`pincer.healthDismissals`, see [Synced preferences](../../reference/synced-preferences/)), so your other devices signed in as you hide the same issues. Down, Restarting and "Restart needed" can't be dismissed.

## Restarting the gateway

:::caution[Restarting needs Full Management]
**Restart Gateway…** only appears when this device's **Access** is **Full Management** on the **Connection** page. Otherwise the page shows "Restarting needs Full Management access". See [Access levels](../../getting-started/connect-a-gateway/#access-levels). In the [demo](../../getting-started/try-the-demo/), where the restart is simulated, it works with the default access.
:::

1. Choose **Restart Gateway…** and confirm. Running replies and tasks finish first; connected clients disconnect briefly.
2. If work is still running, Pincer shows **Waiting for N active tasks…**. The gateway restarts on its own once they're done, or choose **Restart Now Anyway** to ask it to skip the wait.
3. Pincer shows **Restarting…** and **Reconnecting…**, then **Gateway restarted** with the new uptime.

If the gateway hasn't come back after a minute, Pincer says **Gateway hasn't come back yet** and keeps trying to reconnect. Check the gateway host.

When a setting you saved needs a restart, Gateway Settings says "Saved. Restart the Gateway to finish applying it." and the Health page shows a banner with a **Restart Gateway…** button.

## Current limits

- Health and restart have been tested against the [demo](../../getting-started/try-the-demo/) and the [mock gateway](../../development/mock-gateway/) only, not a real gateway restart.
- **Restart Now Anyway** asks the gateway to skip waiting for active work. How quickly a real gateway restarts after that is up to the gateway.
- If a dismissed issue clears up and happens again while no device running Pincer is connected, it stays dismissed, unless it also changed (for example, more failed deliveries).
- Pincer can't retry or clear failed deliveries yet, since the gateway has no method for it.
- If the gateway shuts down without saying it will come back (for example `openclaw gateway stop`), Pincer treats it as a stop, not a restart, and shows its usual reconnecting status.
