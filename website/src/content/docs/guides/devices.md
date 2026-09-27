---
title: Devices & Nodes
description: Approve, reject and revoke the devices paired with your OpenClaw Gateway, and see its paired nodes, from Pincer.
---

Every app that connects to your gateway as an operator, such as Pincer on each Mac, iPhone and iPad, the Control UI or the `openclaw` CLI on another machine, is a **device** with its own key. The gateway has to approve each one before it can connect. **Devices** in [Gateway Settings](../gateway-settings/) lists the devices waiting for approval and the ones already paired, so you can manage them without running `openclaw devices` on the gateway host.

**Devices** is different from **Pairing Requests**, which lets in people who message your agents on a channel. See [Gateway Settings → Pairing Requests](../gateway-settings/#pairing-requests).

## Opening Devices

In [Gateway Settings](../gateway-settings/), choose **Devices** in the sidebar, under **Pairing Requests**. The badge on the row shows how many devices are waiting for approval. The list updates on its own when a device asks to pair or a request is resolved elsewhere, and after each change you make. **Refresh** reloads it.

## What's listed

**Pending Requests** come first, newest first, then **Paired Devices**, with the device Pincer is using at the top. Each device shows:

| | |
| --- | --- |
| **Name** | The name the device gave, or its client and platform. |
| **Platform and client** | For example *macOS · Pincer*. |
| **Fingerprint** | A short form of the device id, such as `3f9a1c2e…7b04`. Hover over it for the full id, or use **Copy Device ID**. |
| **Role and scopes** | The role (usually `operator`) and every scope it has or asks for, such as `operator.read` or `operator.admin`. |
| **Status** | **Connected** right now, **Last seen** for paired devices, or **Requested** for pending ones. |

The device Pincer itself connects with is marked **This device**. A request from a device that's already paired and wants more access, for example after you switch it to **Full Management**, is labelled **Scope upgrade**.

## Approving and rejecting

Before approving, check that you recognise the device and that the fingerprint matches the one it shows. Names come from the device and aren't verified.

- **Approve** pairs the device with the scopes it asked for. It can connect straight away.
- **Reject** turns the request down. The device can ask again the next time it connects.

## Revoking a device

**Revoke…** on a paired device removes it from the gateway. Pincer asks first. The device is disconnected and has to pair again, and be approved again, before it can reconnect.

Revoking **This device** disconnects Pincer from that gateway. Pincer warns you first, since it can't approve its own new request: you'll need to approve it from another paired device with Full Management, or run `openclaw devices approve` on the gateway host.

## Access

Managing devices needs **Access → Full Management** on the [Connection](../gateway-settings/) page, and the gateway's approval for it. The gateway's device methods (`device.pair.list`, `device.pair.approve`, `device.pair.reject`, `device.pair.remove`) need `operator.pairing`, which Pincer doesn't ask for on its own; `operator.admin` covers it. Without Full Management, the gateway only shows Pincer its own device, and the page says **Managing devices needs Full Management** with a button to open Connection. Gateways that don't support device management say so.

## The first device

Pincer can't approve its own first pairing: until a device is approved, it can't connect to see the request. So the first time you connect a gateway, approve it on the gateway host:

```sh
openclaw devices list
openclaw devices approve <requestId>
```

After that, a Mac or iPhone that's paired with **Full Management** can approve your other devices from **Devices**. See [Connect a gateway](../../getting-started/connect-a-gateway/).

## Nodes

**Nodes** in the Gateway Settings sidebar, right after **Devices**, lists the nodes paired with the gateway, such as the OpenClaw apps for macOS, iOS and Android that let agents use a device's camera, screen or location. Each shows its name, platform, version and whether it's connected, or when it was last seen (`node.list`, `node.describe`). With Full Management you can rename a node (`node.rename`). The list is read-only otherwise, and nodes can't be removed from Pincer yet.

Pincer itself is never a node. It only connects as an operator.

## In the demo

The [demo](../../getting-started/try-the-demo/) has two pending requests (a new iPad and a scope upgrade asking for `operator.admin`), three paired devices including this one, and two nodes. Approving, rejecting and revoking work, and nothing leaves the device.
