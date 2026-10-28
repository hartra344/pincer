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
        if invoke.command == HealthSummary.command {
            if case let .failure(failure) = HealthSummary.params(invoke.paramsJSON) { return failure.result }
            return HealthSummary.result(checkHealthPayload)
        }
        if invoke.command == HealthQuery.command {
            switch HealthQuery.request(invoke.paramsJSON, now: Date(), calendar: .current) {
            case let .failure(failure): return failure.result
            case let .success(request): return HealthQuery.Fixture.result(request, now: Date(), calendar: .current)
            }
        }
        return .ok(payloadJSON: "{\"lat\":1.5,\"lon\":2.5,\"accuracyMeters\":5,\"timestamp\":\"2026-01-01T00:00:00Z\",\"isPrecise\":true}")
    }
}

private let supported = DeviceCapability.allCases.filter(\.isSupported)

/// What the iOS HealthKit reader would answer; checks run on a Mac, where Apple Health is unsupported.
let checkHealthPayload = HealthSummary.Payload(
    period: .today, startISO: "2026-10-27T04:00:00Z", endISO: "2026-10-27T19:30:00Z", timeZoneIdentifier: "America/New_York",
    stepCount: 8432, sleepDurationMinutes: 412, restingHeartRateBpm: 58.4, workoutCount: 1, workoutDurationMinutes: 42)

// MARK: Offline

@MainActor
func runDeviceModeOfflineChecks() {
    check(DeviceNodeController.approval(.failure(GatewayError.timeout("node.list")), nodeId: "me", wanted: ["location.get"]) == .unavailable,
          "a failed node.list leaves approval unknown, never Active")
    let allowed = Set(supported.flatMap(\.commands))
    check(DeviceCapability.location.commands == ["location.get"] && DeviceCapability.device.commands == ["device.info", "device.status"]
          && DeviceCapability.calendar.commands == ["calendar.events"] && DeviceCapability.contacts.commands == ["contacts.search"]
          && DeviceCapability.reminders.commands == ["reminders.list"] && DeviceCapability.motion.commands == ["motion.activity", "motion.pedometer"]
          && DeviceCapability.health.commands == ["health.summary"]
          && DeviceCapability.healthData.commands == ["pincer.health.query"],
          "capabilities map to exactly their commands")
    runHealthSummaryOfflineChecks()
    runHealthQueryOfflineChecks()
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
    await checkSupersededApprovalReplyIsDropped(gateway.deviceNode)
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

    // Apple Health (iPhone only): the demo gateway answers health.summary through the handler, with no health permission.
    gateway.deviceNode.supports = { _ in true }
    await gateway.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .health]))
    let healthActive = await waitFor("health node active", { gateway.deviceNode.status == .active })
    var healthCommands: [String] = []
    for _ in 0..<50 {
        healthCommands = DeviceRecords.strings(await selfNode()?["commands"])
        if healthCommands == ["health.summary", "location.get"] { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    check(healthActive && healthCommands == ["health.summary", "location.get"], "Apple Health declares only health.summary (\(healthCommands))")
    let summary = await gateway.demoInvokeNode(command: "health.summary", paramsJSON: #"{"period":"today"}"#)
    check(summary?["ok"]?.bool == true && summary?["payload"]?["stepCount"]?.int == 8432
          && summary?["payload"]?["restingHeartRateBpm"]?.double == 58.4 && summary?["payload"]?["period"]?.string == "today",
          "health.summary {period: today} round trip")
    let week = await gateway.demoInvokeNode(command: "health.summary", paramsJSON: #"{"period":"week"}"#)
    check(week?["ok"]?.bool == false && week?["error"]?["message"]?.string == "INVALID_REQUEST: period must be today",
          "health.summary rejects any period but today")
    await gateway.deviceNode.update(DeviceModeSettings(enabled: false, capabilities: [.location, .health]))

    // All Apple Health data (#1084): pincer.health.query through the same handler, beside health.summary.
    await gateway.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .health, .healthData]))
    let queryActive = await waitFor("health query node active", { gateway.deviceNode.status == .active })
    let wanted = ["health.summary", "location.get", "pincer.health.query"]
    var queryCommands: [String] = []
    for _ in 0..<50 {
        queryCommands = DeviceRecords.strings(await selfNode()?["commands"])
        if queryCommands == wanted { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    check(queryActive && queryCommands == wanted, "All Apple Health data declares pincer.health.query (\(queryCommands))")
    let hrv = await gateway.demoInvokeNode(
        command: "pincer.health.query", paramsJSON: #"{"mode":"statistics","type":"heartRateVariabilitySDNN","interval":"day"}"#)
    check(hrv?["ok"]?.bool == true && hrv?["payload"]?["type"]?.string == "heartRateVariabilitySDNN"
          && hrv?["payload"]?["buckets"]?.array?.compactMap { $0["average"]?.double } == HealthQuery.Fixture.hrvAverages,
          "pincer.health.query HRV statistics round trip")
    let types = await gateway.demoInvokeNode(command: "pincer.health.query", paramsJSON: #"{"mode":"types"}"#)
    check(types?["ok"]?.bool == true && (types?["payload"]?["types"]?.array?.count ?? 0) > 100
          && types?["payload"]?["excluded"]?.array?.contains("workoutRoutes") == true, "pincer.health.query lists types")
    let typo = await gateway.demoInvokeNode(command: "pincer.health.query", paramsJSON: #"{"type":"stepCount","from":"2026-10-01"}"#)
    check(typo?["ok"]?.bool == false
          && typo?["error"]?["message"]?.string?.hasPrefix(#"INVALID_REQUEST: unknown parameter "from""#) == true,
          "pincer.health.query rejects unknown params")
    let route = await gateway.demoInvokeNode(command: "pincer.health.query", paramsJSON: #"{"type":"workoutRoute"}"#)
    check(route?["error"]?["message"]?.string?.contains("workoutRoute is never shared") == true, "workout routes are never shared")
    let recovery = await waitFor("recovery chat") { gateway.sessions[DemoGateway.recoveryKey] != nil }
    check(recovery, "the demo seeds the Recovery check-in chat")
    await gateway.deviceNode.update(DeviceModeSettings(enabled: false, capabilities: [.location, .health, .healthData]))
}

@MainActor
func runHealthQueryOfflineChecks() {
    check(DeviceModePolicy.allowedCommands.contains("pincer.health.query") && !DeviceModePolicy.isForbidden("pincer.health.query")
          && ["pincer.health.write", "pincer.health.query.raw", "pincer.system.run", "health.query"].allSatisfy(DeviceModePolicy.isForbidden),
          "pincer.health.query is the only permitted pincer.* command")
    check(!DeviceCapability.healthData.isSupported && DeviceModePolicy.declaredCommands(for: [.healthData]).isEmpty
          && DeviceModePolicy.declaredCommands(for: [.location, .healthData], supported: { _ in true }) == ["location.get", "pincer.health.query"]
          && DeviceModePolicy.declaredCommands(for: [.location, .health, .healthData], supported: { _ in true })
          == ["health.summary", "location.get", "pincer.health.query"],
          "All Apple Health data is iOS only and declares only pincer.health.query")
    check(!DeviceModeSettings().capabilities.contains(.healthData) && !DeviceCapability.healthData.reportsPermission,
          "All Apple Health data is off by default and reports no permission key")
    let now = Date(timeIntervalSince1970: 1_793_203_200)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    func message(_ json: String?) -> String? {
        if case let .failure(failure) = HealthQuery.request(json, now: now, calendar: calendar) { return failure.message }
        return nil
    }
    check(message(nil) == #"INVALID_REQUEST: type is required; call with {"mode":"types"} to list types"#
          && message(#"{"type":"hrv"}"#) == #"INVALID_REQUEST: unknown type "hrv"; call with {"mode":"types"} to list types"#
          && message(#"{"type":"stepCount","to":"x"}"#)
          == #"INVALID_REQUEST: unknown parameter "to"; allowed: mode, type, startISO, endISO, interval, limit, sort"#
          && message(#"{"mode":"statistics","type":"workout"}"#)
          == "INVALID_REQUEST: statistics supports quantity and category types; use samples for workout"
          && message(#"{"type":"stepCount","limit":1001}"#) == "INVALID_REQUEST: limit must be an integer from 1 to 1000",
          "pincer.health.query params are validated with the documented errors")
    if case let .success(request) = HealthQuery.request(#"{"type":"stepCount","startISO":"2026-10-20","endISO":"2026-10-27"}"#,
                                                        now: now, calendar: calendar) {
        let stamp = HealthQuery.Stamp(timeZone: calendar.timeZone)
        check(stamp.string(request.range.start) == "2026-10-20T00:00:00-04:00"
              && stamp.string(request.range.end) == "2026-10-28T00:00:00-04:00",
              "date-only ranges cover whole local days")
    } else {
        check(false, "date-only range parses")
    }
    check(HealthQuery.resolve("HKQuantityTypeIdentifierHeartRateVariabilitySDNN") == HealthQuery.resolve("heartratevariabilitysdnn")
          && HealthQuery.resolve("workoutRoute") == .neverShared && HealthQuery.resolve("HKClinicalTypeIdentifierLabResultRecord") == .neverShared,
          "types resolve by friendly name or identifier; excluded types are never shared")
    check(HealthQuery.round(44.1234) == 44.12 && HealthQuery.round(0.000_123_456) == 0.000_123_5, "Health values round as documented")
}

@MainActor
func runHealthSummaryOfflineChecks() {
    check(DeviceModePolicy.allowedCommands.contains("health.summary") && !DeviceModePolicy.isForbidden("health.summary")
          && ["health.read", "health.samples", "health.write", "health.summaryx"].allSatisfy(DeviceModePolicy.isForbidden),
          "health.summary is the only permitted health command")
    check(!DeviceCapability.health.isSupported && DeviceModePolicy.declaredCommands(for: [.health]).isEmpty
          && DeviceModePolicy.declaredCommands(for: [.health], supported: { _ in true }) == ["health.summary"],
          "Apple Health is never declared on a Mac")
    check(!DeviceModeSettings().capabilities.contains(.health) && !DeviceCapability.health.reportsPermission,
          "Apple Health is off by default and reports no permission key")
    check(HealthSummary.params(#"{"period":"today"}"#) == .success(.init(period: .today))
          && [nil, "{}", #"{"period":"week"}"#].allSatisfy { HealthSummary.params($0) == .failure(DeviceNodeFailure(
              code: "INVALID_REQUEST", message: "INVALID_REQUEST: period must be today")) },
          "health.summary params require period today")
    let midnight = Date(timeIntervalSince1970: 1_793_059_200)
    let range = DateInterval(start: midnight, duration: 12 * 3600)
    let sleep = [DateInterval(start: midnight.addingTimeInterval(-7200), end: midnight.addingTimeInterval(6.5 * 3600)),
                 DateInterval(start: midnight.addingTimeInterval(5 * 3600), end: midnight.addingTimeInterval(7 * 3600))]
    check(abs((HealthSummary.mergedDuration(sleep, clippedTo: range) ?? 0) - 7 * 3600) < 0.001
          && HealthSummary.mergedDuration([], clippedTo: range) == nil, "sleep merges overlaps once and clips to today")
    let payload = HealthSummary.payload(
        HealthSummary.Raw(steps: 8431.6, asleep: sleep, restingHeartRate: 58.437, workoutDurations: []),
        period: .today, range: range, timeZone: .gmt)
    check(payload.stepCount == 8432 && payload.sleepDurationMinutes == 420 && payload.restingHeartRateBpm == 58.4
          && payload.workoutCount == nil && payload.workoutDurationMinutes == nil, "health.summary rounds like upstream and omits no workouts")
    if case let .ok(json) = HealthSummary.result(payload) {
        check(!json.contains("workout") && !json.contains("null"), "missing metrics are omitted, not null")
    } else {
        check(false, "health.summary payload encodes")
    }
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
    gateway.deviceNode.supports = { _ in true }
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
    await gateway.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .device, .health, .healthData]))
    let liveActive = await waitFor("live node active", timeout: 30, { gateway.deviceNode.status == .active })
    check(liveActive, "node connects (pairing approved) and becomes active (\(gateway.deviceNode.status))")
    check(profile.nodeDeviceToken?.isEmpty == false && profile.nodeDeviceToken != profile.deviceToken, "a separate node token is stored")
    let node = await selfNode()
    check(node?["connected"]?.bool == true && Set(DeviceRecords.strings(node?["commands"])) == ["location.get", "device.info", "device.status", "health.summary", "pincer.health.query"],
          "node.list shows the declared commands")
    check(!DeviceRecords.strings(node?["commands"]).contains { DeviceModePolicy.isForbidden($0) }, "no forbidden command is listed")

    let result = try? await gateway.connection.request("node.invoke", [
        "nodeId": .string(nodeId), "command": "location.get", "params": ["desiredAccuracy": "coarse"],
        "timeoutMs": 5000, "idempotencyKey": .string(UUID().uuidString),
    ], timeout: 15)
    check(result?["ok"]?.bool == true && (result?["payload"]?["lat"]?.double == 1.5 || result?["payloadJSON"]?.string?.contains("1.5") == true),
          "operator node.invoke location.get round trip")
    check(handler.handled == ["location.get"], "the handler saw only location.get")
    // The mock seeds gateway.nodes.commands.allow: ["health.summary", "pincer.health.query"], as upstream requires.
    let health = try? await gateway.connection.request("node.invoke", [
        "nodeId": .string(nodeId), "command": "health.summary", "params": ["period": "today"],
        "timeoutMs": 5000, "idempotencyKey": .string(UUID().uuidString),
    ], timeout: 15)
    let healthPayload = health?["payload"] ?? health?["payloadJSON"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    check(health?["ok"]?.bool == true && healthPayload?["stepCount"]?.int == 8432 && healthPayload?["period"]?.string == "today",
          "operator node.invoke health.summary round trip")
    check(handler.handled == ["location.get", "health.summary"], "the handler saw health.summary")
    // ...and "pincer.health.query" (#1084), which the Gateway forwards only because it's allowed.
    let query = try? await gateway.connection.request("node.invoke", [
        "nodeId": .string(nodeId), "command": "pincer.health.query",
        "params": ["mode": "statistics", "type": "heartRateVariabilitySDNN", "interval": "day"],
        "timeoutMs": 5000, "idempotencyKey": .string(UUID().uuidString),
    ], timeout: 15)
    let queryPayload = query?["payload"] ?? query?["payloadJSON"]?.string.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    check(query?["ok"]?.bool == true && queryPayload?["type"]?.string == "heartRateVariabilitySDNN"
          && queryPayload?["buckets"]?.array?.compactMap { $0["average"]?.double } == HealthQuery.Fixture.hrvAverages,
          "operator node.invoke pincer.health.query round trip")
    check(handler.handled == ["location.get", "health.summary", "pincer.health.query"], "the handler saw pincer.health.query")
    var refused = false
    do {
        let reply = try await gateway.connection.request("node.invoke", [
            "nodeId": .string(nodeId), "command": "contacts.add", "timeoutMs": 3000, "idempotencyKey": .string(UUID().uuidString)])
        refused = reply["ok"]?.bool == false
    } catch { refused = true }
    check(refused && handler.handled == ["location.get", "health.summary", "pincer.health.query"], "an undeclared command is rejected and never reaches the handler")

    await gateway.deviceNode.update(DeviceModeSettings(enabled: false, capabilities: [.location, .device]))
    check(gateway.deviceNode.status == .off, "disabling → off")
    let removed = await waitFor("node removed", timeout: 10, { profile.nodeDeviceToken == nil })
    check(removed && gateway.deviceNode.removalHint == nil,
          "with Full Management, node.pair.remove succeeds and the node token is deleted")
    let after = await selfNode()
    check(after == nil || after?["connected"]?.bool != true, "the node is gone from node.list")
    check(profile.deviceToken?.isEmpty == false, "the operator token is untouched")
}

/// A refresh replaced while its `node.list` was in flight drops the reply, so a stale "approved"
/// can't put a parked node back to Active. Leaves the node active again.
@MainActor
private func checkSupersededApprovalReplyIsDropped(_ node: DeviceNodeController) async {
    var calls = 0, released = false, staleAnswered = false
    node.approvalQueryOverride = {
        calls += 1
        guard calls == 1 else { return .pending(requestId: "req-9") }
        while !released { try? await Task.sleep(for: .milliseconds(5)) }
        staleAnswered = true
        return .approved
    }
    let event = { (name: String) in
        node.handleOperatorEvent(GatewayEvent(name: name, payload: ["nodeId": .string(DemoGateway.deviceId)], seq: nil))
    }
    event("node.pair.requested")
    _ = await waitFor("first approval query", { calls == 1 })
    event("node.pair.requested")
    let parked = await waitFor("parked", { node.status == .awaitingApproval(requestId: "req-9") })
    released = true
    _ = await waitFor("stale reply", { staleAnswered })
    try? await Task.sleep(for: .milliseconds(100))
    check(parked && node.status == .awaitingApproval(requestId: "req-9"),
          "a superseded node.list reply never puts a parked node back to Active (\(node.status))")
    node.approvalQueryOverride = nil
    event("node.pair.resolved")
    let activeAgain = await waitFor("active again", { node.status == .active })
    check(activeAgain, "the real node.list approves the node again")
}
