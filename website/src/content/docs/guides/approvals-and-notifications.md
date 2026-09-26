---
title: Approvals & notifications
description: Answering exec approvals and managing notifications in Pincer.
---

## Exec approvals

When an agent wants to run something that needs your OK, Pincer shows the request as a **banner** in the app and as an **actionable notification**. Choose:

- **Allow once:** run it this time only.
- **Always allow:** run it now, and let the gateway allow it from now on.
- **Deny:** don't run it.

You can answer from the notification without opening Pincer.

:::note
Answering approvals uses the `operator.approvals` scope, which Pincer requests with both access levels.
:::

## Notifications

- **One thread per chat:** notifications from the same chat are grouped together.
- **Reply inline:** use the reply action on a notification to answer without switching apps.
- **No double alerts:** you won't get a notification for the chat you're already looking at.
- **Helpers stay quiet:** subagent (helper) runs never send notifications or add to unread counts.

Allow notifications when Pincer asks the first time. If you missed it, turn them on in **System Settings → Notifications → Pincer** on macOS, or **Settings → Notifications → Pincer** on iOS.
