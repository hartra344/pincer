---
title: Session manager
description: Browse every session on your OpenClaw Gateway with previews, details and run status, archive or delete them in bulk, and switch branches, rewind or recover a session.
---

The **Sessions** page lists every session on your gateway, not just the chats in your sidebar. You can preview a session, see its details and run status, archive or delete several at once, and manage a session's branches: switch between them, rewind to an earlier message, or recover a session the gateway stopped when it restarted.

## Opening Sessions

- **Gateway Settings → Sessions**. On macOS Gateway Settings opens in its own window; on iOS it opens as a sheet. See [Gateway Settings](../gateway-settings/).

If the gateway doesn't offer `sessions.list`, the page says **Session Management Isn't Available**. Update OpenClaw to manage sessions here.

## Browsing sessions

Each row shows the session's title, agent and channel, when it was last active, and its run status (**Idle**, **Queued**, **Running**, **Done**, **Failed**, **Killed** or **Timed Out**) with how long the last run took. Archived sessions are marked.

- **Filter:** choose **Active** (the default), **Archived** or **All**.
- **Search:** filter by title, key, label or agent.

Select a session to see a preview of its last few messages. Open it for **Details**: its key, agent, model, when it was created and last updated, and token counts. Previews and details load when you ask for them, so the list stays fast on gateways with hundreds of sessions.

## Archiving and deleting

Select several sessions at once: on macOS with <kbd>⌘</kbd>-click or <kbd>⇧</kbd>-click, on iOS with **Select**. The toolbar then shows how many are selected, with **Archive**, **Unarchive** and **Delete…**.

- **Archive** and **Unarchive** happen straight away. Pincer tells you how many sessions changed and lists any the gateway refused. Archived sessions leave the sidebar but aren't deleted.
- **Delete…** always asks first. Deleting removes the session and its transcript from the gateway, and it can't be undone. Pincer also removes the session's [locally cached transcript](../local-cache/).

:::caution[Some actions need Full Management]
Browsing, previews, details and branch lists need `operator.read`. Archiving, unarchiving, recovering and deleting **archived** sessions need `operator.write`. Deleting a session that isn't archived, switching branches and rewinding need `operator.admin`: set **Access** to **Full Management** on the **Connection** page, then approve this device on the gateway host. See [Access levels](../../getting-started/connect-a-gateway/#access-levels).

Without it, those actions show a **Needs Full Management** badge. To delete an active session without Full Management, archive it first.
:::

## Branches

When you edit or retry earlier messages, the gateway keeps each version of the conversation as a branch. A session's details list its branches, with a headline, message count and when each was last updated. The current branch is marked.

- **Switch** makes another branch the current one, after a confirmation.
- **Rewind…** picks one of your recent messages and rewinds the session to it, after a confirmation. The later messages stay on their own branch, so you can switch back.

After a switch or rewind, the open chat reloads from the gateway and Pincer refreshes its cached transcript.

## Recovering a session

If the gateway restarted in the middle of a run, it can mark the session as needing recovery. Those sessions show **Recover**, which asks the gateway (OpenClaw 2026.8 or later) to continue the session and tells you whether the run restarted.

## Missing features

Pincer only shows what your gateway offers. If the gateway doesn't offer previews, details, branches, rewind, recover or bulk archive, those controls are hidden, and the rest of the page still works. On older gateways without bulk archive, Pincer archives sessions one at a time.

## In the demo

The [demo](../../getting-started/try-the-demo/) has sample sessions to try everything on: active and archived ones, a running one, one with several branches and one waiting to be recovered. Archiving, deleting, switching branches, rewinding and recovering all work without a real gateway, and nothing is kept after you quit.
