import Foundation
@testable import PincerKit

// Opt-in device mode (#1030): the policy and settings offline, then the demo and a (mock) Gateway
// end to end. Pincer is an operator by default; the node surface only ever declares allowlisted commands.

final class CheckNodeHandler: DeviceNodeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    var handled: [String] { self.lock.withLock { self.commands } }

    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: caps.map { ($0.rawValue, true) })
    }

    func requestAccess(for cap: DeviceCapability) async -> Bool { true }

    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        self.lock.withLock { self.commands.append(invoke.command) }
        return .ok(payloadJSON: "{\"lat\":1.5,\"lon\":2.5,\"accuracyMeters\":5,\"timestamp\":\"2026-01-01T00:00:00Z\",\"isPrecise\":true}")
    }
}

private let supported = DeviceCapability.allCases.filter(\.isSupported)

// MARK: Offline

@MainActor
func runDeviceModeOfflineChecks() {
    check(DeviceNodeController.approval(.failure(GatewayError.timeout("node.list")), nodeId: "me", wanted: ["location.get"]) == .unavailable,
          "a failed node.list leaves approval unknown, never Active")
    let allowed = Set(supported.flatMap(\.commands))
    check(DeviceCapability.location.commands == ["location.get"] && DeviceCapability.device.commands == ["device.info", "device.status"]
          && DeviceCapability.calendar.commands == ["calendar.events"] && DeviceCapability.contacts.commands == ["contacts.search"]
          && DeviceCapability.reminders.commands == ["reminders.list"] && DeviceCapability.motion.commands == ["motion.activity", "motion.pedometer"],
          "capabilities map to exactly their commands")
    let forbidden = ["camera.snap", "camera.clip", "screen.record", "system.run", "system.notify", "device.apps", "photos.latest",
                     "contacts.add", "calendar.add", "reminders.add", "sms.send", "health.read", "browser.proxy", "computer.click",
                     "files.read", "talk.ptt.start", "canvas.present", "chat.push", "watch.notify"]
    check(forbidden.allSatisfy(DeviceModePolicy.isForbidden) && forbidden.allSatisfy { !DeviceModePolicy.allowedCommands.contains($0) },
          "forbidden families are denied and never allowlisted")
    let all = DeviceModePolicy.declaredCommands(for: Set(DeviceCapability.allCases))
    check(Set(all) == allowed && all == all.sorted() && all.allSatisfy { !DeviceModePolicy.isForbidden($0) },
          "all capabilities declare only the allowlist, sorted (\(all.count) commands)")
    let upstreamIOS = ["location.get", "contacts.add", "calendar.add", "reminders.add", "device.apps", "photos.latest", "system.notify"]
    check(upstreamIOS.filter { all.contains($0) } == ["location.get"], "upstream iOS write commands are never declared")
    check(upstreamIOS.dropFirst().allSatisfy { command in
        (try? GatewayConnection.validate(.node(caps: [], commands: [command], permissions: [:]))) == nil
    }, "a node surface carrying a forbidden command refuses to connect")
    let settings = DeviceModeSettings()
    check(!settings.enabled && settings.capabilities == [.location] && settings.declaredCommands.isEmpty, "device mode is off by default, location only")
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = UUID()
    let saved = DeviceModeSettings(enabled: true, capabilities: [.location, .calendar, .reminders])
    saved.save(gatewayId: id, defaults: defaults)
    check(DeviceModeSettings.load(gatewayId: id, defaults: defaults) == saved
          && DeviceModeSettings.load(gatewayId: UUID(), defaults: defaults) == DeviceModeSettings(), "settings persist per gateway")
    let identity = DeviceIdentity.loadOrCreate()
    let node = try? GatewayConnection.connectParams(
        identity: identity, authMode: .token, deviceToken: "node-tok", secret: "operator-secret", scopes: ["operator.read"],
        nonce: "n", signedAt: 1, instanceId: "i",
        surface: .node(caps: ["location"], commands: ["location.get"], permissions: ["location": true]))
    check(node?["role"]?.string == "node" && node?["scopes"] == [] && node?["client"]?["mode"]?.string == "node"
          && node?["commands"] == ["location.get"] && node?["caps"] == ["location"] && node?["permissions"]?["location"]?.bool == true
          && node?["auth"] == ["token": "node-tok"], "node connect: role node, no scopes, node token")
    let op = try? GatewayConnection.connectParams(
        identity: identity, authMode: .token, deviceToken: nil, secret: "s", scopes: ["operator.read"], nonce: "n", signedAt: 1, instanceId: "i")
    check(op?["role"]?.string == "operator" && op?["client"]?["mode"]?.string == "ui" && op?["commands"] == [], "operator connect unchanged")
}

// MARK: Demo

@MainActor
func runDemoDeviceModeChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    let handler = CheckNodeHandler()
    gateway.deviceNode.handler = handler
    gateway.start()
    defer { gateway.stop() }
    guard await waitFor("device mode demo connects", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "demo connects for device mode"); return
    }
    let selfId = DemoGateway.deviceId
    func selfNode() async -> JSONValue? {
        let result = try? await gateway.connection.request("node.list", [:])
        return result?["nodes"]?.array?.first { $0["nodeId"]?.text == selfId }
    }
    check(gateway.deviceNode.status == .off && !gateway.deviceNode.settings.enabled, "device mode starts off")
    let neverAttached = await selfNode()
    check(neverAttached?["connected"]?.bool != true, "no node is attached while off")

    await gateway.deviceNode.update(DeviceModeSettings(enabled: true))
    let nodeActive = await waitFor("device node active", { gateway.deviceNode.status == .active })
    check(nodeActive, "enabling → active (\(gateway.deviceNode.status))")
    var node = await selfNode()
    check(node?["connected"]?.bool == true && DeviceRecords.strings(node?["commands"]) == ["location.get"],
          "node.list shows this device with its declared commands")
    let ok = await gateway.demoInvokeNode(command: "location.get")
    check(ok?["ok"]?.bool == true && ok?["payload"]?["lat"]?.double == 1.5 && handler.handled == ["location.get"],
          "location.get round trip reaches the handler")
    let recorded = await waitFor("last invoke", { gateway.deviceNode.lastInvoke?.command == "location.get" && gateway.deviceNode.lastInvoke?.ok == true })
    check(recorded, "last request is recorded")
    for command in ["device.info", "contacts.add", "system.run", "camera.snap"] {
        let rejected = await gateway.demoInvokeNode(command: command)
        check(rejected?["ok"]?.bool == false && rejected?["error"]?["code"]?.string == "INVALID_REQUEST", "undeclared \(command) → INVALID_REQUEST")
    }
    check(handler.handled == ["location.get"], "undeclared commands never reach the handler")

    await gateway.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .device]))
    let reconnected = await waitFor("surface change", {
        gateway.deviceNode.status == .active
    })
    check(reconnected, "changing capabilities re-connects")
    var commandsNow: [String] = []
    for _ in 0..<50 {
        commandsNow = DeviceRecords.strings(await selfNode()?["commands"])
        if commandsNow == ["device.info", "device.status", "location.get"] { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    check(commandsNow == ["device.info", "device.status", "location.get"], "node.list follows the new surface (\(commandsNow))")
    let info = await gateway.demoInvokeNode(command: "device.info")
    check(info?["ok"]?.bool == true, "newly declared device.info is answered")

    await gateway.deviceNode.update(DeviceModeSettings(enabled: false, capabilities: [.location, .device]))
    check(gateway.deviceNode.status == .off, "disabling → off")
    node = await selfNode()
    check(node == nil || node?["connected"]?.bool == false, "the node is no longer connected")
    let gone = await gateway.demoInvokeNode(command: "location.get")
    check(gone?["ok"]?.bool == false, "no invoke is answered after disabling")
    // The demo's operator holds no operator.admin: no node.pair.remove, a hint instead.
    check(gateway.deviceNode.removalHint != nil, "without Full Management, turning off explains how to remove the node role")
}

// MARK: Live

@MainActor
func runLiveDeviceModeChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Device mode check", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    let handler = CheckNodeHandler()
    gateway.deviceNode.handler = handler
    gateway.start()
    defer { gateway.stop(); profile.forgetCredentials() }
    guard await waitFor("device mode live connects", { gateway.state.isConnected && gateway.hello != nil }),
          gateway.hello?.methods.contains("node.invoke") == true
    else {
        check(gateway.hello?.methods.contains("node.invoke") != true, "live gateway without node.invoke (MOCK_NODES=off) skips device mode")
        return
    }
    let nodeId = DeviceIdentity.loadOrCreate().deviceId
    func selfNode() async -> JSONValue? {
        let result = try? await gateway.connection.request("node.list", [:])
        return result?["nodes"]?.array?.first { $0["nodeId"]?.text == nodeId }
    }
    await gateway.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .device]))
    let liveActive = await waitFor("live node active", timeout: 30, { gateway.deviceNode.status == .active })
    check(liveActive, "node connects (pairing approved) and becomes active (\(gateway.deviceNode.status))")
    check(profile.nodeDeviceToken?.isEmpty == false && profile.nodeDeviceToken != profile.deviceToken, "a separate node token is stored")
    let node = await selfNode()
    check(node?["connected"]?.bool == true && Set(DeviceRecords.strings(node?["commands"])) == ["location.get", "device.info", "device.status"],
          "node.list shows the declared commands")
    check(!DeviceRecords.strings(node?["commands"]).contains { DeviceModePolicy.isForbidden($0) }, "no forbidden command is listed")

    let result = try? await gateway.connection.request("node.invoke", [
        "nodeId": .string(nodeId), "command": "location.get", "params": ["desiredAccuracy": "coarse"],
        "timeoutMs": 5000, "idempotencyKey": .string(UUID().uuidString),
    ], timeout: 15)
    check(result?["ok"]?.bool == true && (result?["payload"]?["lat"]?.double == 1.5 || result?["payloadJSON"]?.string?.contains("1.5") == true),
          "operator node.invoke location.get round trip")
    check(handler.handled == ["location.get"], "the handler saw only location.get")
    var refused = false
    do {
        let reply = try await gateway.connection.request("node.invoke", [
            "nodeId": .string(nodeId), "command": "contacts.add", "timeoutMs": 3000, "idempotencyKey": .string(UUID().uuidString)])
        refused = reply["ok"]?.bool == false
    } catch { refused = true }
    check(refused && handler.handled == ["location.get"], "an undeclared command is rejected and never reaches the handler")

    await gateway.deviceNode.update(DeviceModeSettings(enabled: false, capabilities: [.location, .device]))
    check(gateway.deviceNode.status == .off, "disabling → off")
    let removed = await waitFor("node removed", timeout: 10, { profile.nodeDeviceToken == nil })
    check(removed && gateway.deviceNode.removalHint == nil,
          "with Full Management, node.pair.remove succeeds and the node token is deleted")
    let after = await selfNode()
    check(after == nil || after?["connected"]?.bool != true, "the node is gone from node.list")
    check(profile.deviceToken?.isEmpty == false, "the operator token is untouched")
}
