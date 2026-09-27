---
title: Devices & Nodes
description: Approve, reject, rename and revoke the devices, and see the nodes, paired with your OpenClaw Gateway, from Pincer.
---

Every app that connects to your gateway, such as Pincer on each Mac, iPhone and iPad, the Control UI, the `openclaw` CLI on another machine, or a node app, is a **device** with its own key. The gateway has to approve each one before it can connect. **Devices** in [Gateway Settings](../gateway-settings/) lists the devices waiting for approval and the ones already paired, so you can manage them without running `openclaw devices` on the gateway host.

**Devices** is different from **Pairing Requests**, which lets in people who message your agents on a channel. See [Gateway Settings → Pairing Requests](../gateway-settings/#pairing-requests).

## Opening Devices

In [Gateway Settings](../gateway-settings/), choose **Devices** in the sidebar, under **Pairing Requests**. The badge on the row shows how many devices are waiting for approval. The list updates on its own when a device asks to pair or a request is answered elsewhere (`device.pair.requested`, `device.pair.resolved`), and after each change you make. **Refresh** reloads it.

## What's listed

**Pending Requests** comes first, newest first, then **Paired Devices**, with the device Pincer is using at the top. Each device shows:

| | |
| --- | --- |
| **Name** | The name the device gave, or its client and platform. |
| **Platform and client** | For example *macOS · Pincer*. |
| **Fingerprint** | A short form of the device id. Hover over it for the full id, or use **Copy Device ID** in the context menu. |
| **Role and scopes** | The role (`operator` or `node`) and the scopes it has or asks for, such as `operator.read` or `operator.admin`. |
| **Status** | **Connected**, **Last seen** for paired devices, or **Requested** for waiting ones. |

The device Pincer itself connects with is tagged **This Mac**, **This iPhone** or **This iPad**. A request from a device that's already paired and asks for more access, for example after you switch it to **Full Management**, is tagged **Scope upgrade**. A request that asks for the `node` role says so, since approving it lets agents run commands on that device.

## Approving and rejecting

Only approve devices you recognize, and compare the fingerprint with the one the device shows while it waits. Names come from the device and aren't verified.

- **Approve** pairs the device with the role and scopes it asked for. It can connect straight away.
- **Reject** turns the request down. The device can ask again.

## Renaming and revoking

From a paired device's **Actions** menu (or its context menu):

- **Rename…** changes the name every operator of the gateway sees (`device.pair.rename`, on gateways that support it).
- **Revoke…** asks first, then removes the device from the gateway and disconnects it (`device.pair.remove`). To use it again, it has to pair again.

Revoking the device Pincer is using (**Revoke This Device…**) disconnects Pincer from that gateway. Pincer warns you first, since it can't approve its own new request: approve it from another device paired with Full Management, or run `openclaw devices approve` on the gateway host.

## Access

Managing devices needs **Access → Full Management** on the [Connection](../gateway-settings/) page, and the gateway's approval for it. The gateway's device methods need `operator.pairing`, which Pincer doesn't ask for on its own; `operator.admin` covers it. Without Full Management, the gateway only shows Pincer its own device, and the page says **Managing devices needs Full Management** with a button to open Connection. Gateways that don't support device pairing say so.

## The first device

Pincer can't approve its own first pairing: until a device is approved, it can't connect to see the request. So the first time you connect a gateway, approve it on the gateway host:

```sh
openclaw devices list
openclaw devices approve <requestId>
```

After that, a Mac, iPhone or iPad paired with **Full Management** can approve your other devices from **Devices**. See [Connect a gateway](../../getting-started/connect-a-gateway/).

## Nodes

**Nodes**, right after **Devices** in the sidebar, lists the nodes known to the gateway: Macs, phones and servers that run commands for your agents, such as the OpenClaw apps for macOS, iOS and Android (`node.list`). Each shows its name, platform, version, whether it's connected, or when it was last seen, and tags such as **Gateway Host**. With Full Management you can **Rename…** a node (`node.rename`). Nodes can't be removed from Pincer yet. New nodes are approved on the **Devices** page.

Pincer itself is never a node. It only connects as an operator.

## In the demo

The [demo](../../getting-started/try-the-demo/) has pending device requests, a few paired devices including this one, and two nodes. Approving, rejecting, renaming and revoking work, and nothing leaves the device.
