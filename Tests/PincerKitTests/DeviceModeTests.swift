import Foundation
import Testing
@testable import PincerKit

/// Fake device handler: records what reached it.
final class FakeNodeHandler: DeviceNodeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _handled: [String] = []
    var reply: DeviceNodeResult = .ok(payloadJSON: "{\"lat\":1.5,\"lon\":2.5}")
    var handled: [String] { self.lock.withLock { self._handled } }

    func permissions(for caps: Set<DeviceCapability>) async -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: caps.map { ($0.rawValue, true) })
    }

    func requestAccess(for cap: DeviceCapability) async -> Bool { true }

    func handle(_ invoke: DeviceNodeInvoke) async -> DeviceNodeResult {
        self.lock.withLock { self._handled.append(invoke.command) }
        return self.reply
    }
}

@Suite("Device mode policy")
struct DeviceModePolicyTests {
    @Test func capabilityCommandMap() {
        #expect(DeviceCapability.location.commands == ["location.get"])
        #expect(DeviceCapability.device.commands == ["device.info", "device.status"])
        #expect(DeviceCapability.calendar.commands == ["calendar.events"])
        #expect(DeviceCapability.contacts.commands == ["contacts.search"])
        #expect(DeviceCapability.reminders.commands == ["reminders.list"])
        #expect(DeviceCapability.motion.commands == ["motion.activity", "motion.pedometer"])
        #expect(Set(DeviceCapability.allCases.map(\.rawValue)) == ["location", "device", "calendar", "contacts", "reminders", "motion"])
        #expect(DeviceModePolicy.allowedCommands.count == DeviceCapability.allCases.flatMap(\.commands).count)
    }

    @Test func forbiddenFamiliesAreNeverDeclarable() {
        let forbidden = [
            "camera.snap", "camera.list", "camera.clip", "screen.record", "screen.snapshot", "system.run", "system.run.prepare",
            "system.notify", "system.which", "device.apps", "photos.latest", "contacts.add", "calendar.add", "reminders.add",
            "sms.send", "sms.search", "health.read", "health.steps", "browser.proxy", "computer.click", "files.read", "file.write",
            "talk.ptt.start", "canvas.present", "chat.push", "watch.status", "watch.notify", "CAMERA.snap", " system.run ",
        ]
        for command in forbidden {
            #expect(DeviceModePolicy.isForbidden(command), "\(command) must be forbidden")
            #expect(!DeviceModePolicy.allowedCommands.contains(command), "\(command) must not be allowed")
        }
        let everything = DeviceModePolicy.declaredCommands(for: Set(DeviceCapability.allCases))
        #expect(everything.allSatisfy { !DeviceModePolicy.isForbidden($0) })
        #expect(Set(everything) == Set(DeviceCapability.allCases.filter(\.isSupported).flatMap(\.commands)))
        #expect(!DeviceModePolicy.allowedCommands.contains { DeviceModePolicy.isForbidden($0) })
    }

    @Test func declaredCommandsAreSortedAndScoped() {
        #expect(DeviceModePolicy.declaredCommands(for: []) == [])
        #expect(DeviceModePolicy.declaredCommands(for: [.location]) == ["location.get"])
        let motion = DeviceCapability.motion.isSupported ? ["motion.activity", "motion.pedometer"] : []
        #expect(DeviceModePolicy.declaredCommands(for: [.motion, .device]) == ["device.info", "device.status"] + motion)
    }

    @Test func settingsDefaultOffWithLocationOnly() {
        let settings = DeviceModeSettings()
        #expect(!settings.enabled && settings.capabilities == [.location])
        #expect(settings.declaredCommands == [])
        #expect(DeviceModeSettings(enabled: true).declaredCommands == ["location.get"])
    }

    @Test func settingsPersistPerGateway() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let a = UUID(), b = UUID()
        #expect(DeviceModeSettings.load(gatewayId: a, defaults: scratch.defaults) == DeviceModeSettings())
        let saved = DeviceModeSettings(enabled: true, capabilities: [.location, .calendar, .reminders])
        saved.save(gatewayId: a, defaults: scratch.defaults)
        #expect(DeviceModeSettings.load(gatewayId: a, defaults: scratch.defaults) == saved)
        #expect(DeviceModeSettings.load(gatewayId: b, defaults: scratch.defaults) == DeviceModeSettings())
        #expect(scratch.defaults.data(forKey: "pincer.deviceMode.\(a.uuidString)") != nil)
    }
}

@Suite("Device mode connect")
struct DeviceModeConnectTests {
    let identity = Fixtures.identity()

    func params(_ surface: GatewayConnection.Surface, deviceToken: String? = nil, secret: String? = nil) throws -> JSONValue {
        .object(try GatewayConnection.connectParams(
            identity: self.identity, authMode: .token, deviceToken: deviceToken, secret: secret,
            scopes: ["operator.read"], nonce: "n1", signedAt: 1_700_000_000_000, instanceId: "i1", surface: surface))
    }

    func node(commands: [String] = ["device.info", "location.get"]) -> GatewayConnection.Surface {
        .node(caps: ["device", "location"], commands: commands, permissions: ["location": true, "device": true])
    }

    @Test func nodeFrameShape() throws {
        let params = try self.params(self.node())
        #expect(params["role"]?.string == "node")
        #expect(params["scopes"] == [])
        #expect(params["client"]?["mode"]?.string == "node")
        #expect(params["client"]?["id"]?.string == GatewayConnection.clientId)
        #expect(params["caps"] == ["device", "location"])
        #expect(params["commands"] == ["device.info", "location.get"])
        #expect(params["permissions"]?["location"]?.bool == true && params["permissions"]?["device"]?.bool == true)
        #expect(params["device"]?["id"]?.string == Fixtures.deviceId)
    }

    @Test func nodeSignatureCoversRoleAndModeAndNodeToken() throws {
        let params = try self.params(self.node(), deviceToken: "node-tok", secret: "shared-operator")
        #expect(params["auth"] == ["token": "node-tok"])
        let device = try #require(params["device"])
        let signatureText = try #require(device["signature"]?.string)
        let signature = try #require(base64UrlDecode(signatureText))
        let payload = DeviceAuthPayload.v2(
            deviceId: Fixtures.deviceId, clientId: GatewayConnection.clientId, clientMode: "node", role: "node", scopes: [],
            signedAtMs: 1_700_000_000_000, token: "node-tok", nonce: "n1")
        #expect(self.identity.privateKey.publicKey.isValidSignature(signature, for: Data(payload.utf8)))
        let operatorPayload = DeviceAuthPayload.v2(
            deviceId: Fixtures.deviceId, clientId: GatewayConnection.clientId, clientMode: "ui", role: "operator",
            scopes: ["operator.read"], signedAtMs: 1_700_000_000_000, token: "node-tok", nonce: "n1")
        #expect(!self.identity.privateKey.publicKey.isValidSignature(signature, for: Data(operatorPayload.utf8)))
    }

    @Test func operatorFrameUnchanged() throws {
        let params = try self.params(.operatorClient, secret: "s")
        #expect(params["role"]?.string == "operator")
        #expect(params["scopes"] == ["operator.read"])
        #expect(params["client"]?["mode"]?.string == "ui")
        #expect(params["caps"] == ["tool-events"] && params["commands"] == [])
        #expect(params["permissions"] == [:])
    }

    @Test func forbiddenSurfaceRefused() {
        for command in ["system.run", "camera.snap", "screen.record", "system.notify", "contacts.add", "device.apps", "photos.latest", "made.up"] {
            #expect(throws: (any Error).self, "\(command)") { _ = try self.params(self.node(commands: ["location.get", command])) }
            #expect(throws: (any Error).self) { try GatewayConnection.validate(self.node(commands: [command])) }
        }
        #expect(throws: Never.self) { try GatewayConnection.validate(self.node()) }
        #expect(throws: Never.self) { try GatewayConnection.validate(.operatorClient) }
    }

    @Test func nodeTokenIsSeparateFromOperatorToken() {
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .token)
        defer { profile.forgetCredentials() }
        profile.deviceToken = "operator-tok"
        profile.nodeDeviceToken = "node-tok"
        #expect(profile.deviceToken == "operator-tok" && profile.nodeDeviceToken == "node-tok")
        profile.nodeDeviceToken = nil
        #expect(profile.deviceToken == "operator-tok" && profile.nodeDeviceToken == nil)
        profile.nodeDeviceToken = "node-tok"
        profile.forgetCredentials()
        #expect(profile.deviceToken == nil && profile.nodeDeviceToken == nil)
    }
}

@Suite("Device node dispatch")
struct DeviceNodeDispatchTests {
    func invoke(_ command: String, params: String? = nil) -> DeviceNodeInvoke {
        DeviceNodeInvoke(id: "req-1", nodeId: "node-1", command: command, paramsJSON: params, timeoutMs: 5000)
    }

    @Test func parsesInvokeRequest() throws {
        let payload = Fixtures.json(#"{"id":"r","nodeId":"n","command":"location.get","paramsJSON":"{\"a\":1}","timeoutMs":3000}"#)
        let parsed = try #require(DeviceNodeController.invoke(from: payload))
        #expect(parsed == DeviceNodeInvoke(id: "r", nodeId: "n", command: "location.get", paramsJSON: "{\"a\":1}", timeoutMs: 3000))
        #expect(DeviceNodeController.invoke(from: Fixtures.json(#"{"id":"r"}"#)) == nil)
    }

    @Test func declaredCommandReachesHandler() async {
        let handler = FakeNodeHandler()
        let result = await DeviceNodeController.result(for: self.invoke("location.get"), declared: ["location.get"], handler: handler)
        #expect(result == .ok(payloadJSON: "{\"lat\":1.5,\"lon\":2.5}"))
        #expect(handler.handled == ["location.get"])
        let params = DeviceNodeController.resultParams(invoke: self.invoke("location.get"), result: result)
        #expect(params["id"]?.string == "req-1" && params["nodeId"]?.string == "node-1" && params["ok"]?.bool == true)
        #expect(params["payloadJSON"]?.string == "{\"lat\":1.5,\"lon\":2.5}")
        #expect(absent(params["error"]))
    }

    @Test func undeclaredCommandIsInvalidRequestAndNeverReachesHandler() async {
        let handler = FakeNodeHandler()
        for command in ["device.info", "system.run", "camera.snap", "made.up"] {
            let result = await DeviceNodeController.result(for: self.invoke(command), declared: ["location.get"], handler: handler)
            guard case let .failure(code, message) = result else { Issue.record("\(command) should fail"); continue }
            #expect(code == "INVALID_REQUEST" && message.contains("unknown command"))
        }
        // Even if a forbidden command somehow sat in the declared set, it is refused.
        let forced = await DeviceNodeController.result(for: self.invoke("system.run"), declared: ["system.run"], handler: handler)
        #expect(forced == .failure(code: "INVALID_REQUEST", message: "INVALID_REQUEST: unknown command"))
        #expect(handler.handled.isEmpty)
    }

    @Test func handlerFailureEncodesErrorWithoutDetails() async {
        let handler = FakeNodeHandler()
        handler.reply = .failure(code: "UNAVAILABLE", message: "LOCATION_PERMISSION_REQUIRED: grant Location permission")
        let result = await DeviceNodeController.result(for: self.invoke("location.get"), declared: ["location.get"], handler: handler)
        let params = DeviceNodeController.resultParams(invoke: self.invoke("location.get"), result: result)
        #expect(params["ok"]?.bool == false)
        #expect(params["error"]?["code"]?.string == "UNAVAILABLE")
        #expect(params["error"]?["message"]?.string == "LOCATION_PERMISSION_REQUIRED: grant Location permission")
        #expect(absent(params["error"]?["details"]) && absent(params["payloadJSON"]))
        #expect(params["error"]?.object?.keys.sorted() == ["code", "message"])
    }

    @Test func missingHandlerIsUnavailable() async {
        let result = await DeviceNodeController.result(for: self.invoke("location.get"), declared: ["location.get"], handler: nil)
        guard case let .failure(code, _) = result else { Issue.record("expected failure"); return }
        #expect(code == "UNAVAILABLE")
    }
}

@Suite("Device mode surface")
struct DeviceModeSurfaceTests {
    /// What upstream's iOS app declares by default, write commands and all.
    static let upstreamIOS = [
        "location.get", "device.info", "device.status", "device.apps", "contacts.search", "contacts.add", "calendar.events",
        "calendar.add", "reminders.list", "reminders.add", "photos.latest", "motion.activity", "motion.pedometer",
        "camera.snap", "system.notify", "chat.push", "watch.status",
    ]

    @Test func writeCommandsAreNeverDeclaredEvenThoughUpstreamDoes() {
        let all = Set(DeviceCapability.allCases)
        let declared = Set(DeviceModePolicy.declaredCommands(for: all))
        for command in ["contacts.add", "calendar.add", "reminders.add", "device.apps", "photos.latest"] {
            #expect(!declared.contains(command), "\(command)")
            #expect(DeviceModePolicy.isForbidden(command))
        }
        #expect(declared.isSubset(of: Set(Self.upstreamIOS)))
        let surviving = Self.upstreamIOS.filter { DeviceModePolicy.allowedCommands.contains($0) && !DeviceModePolicy.isForbidden($0) }
        #expect(declared.isSubset(of: Set(surviving)))
        #expect(!declared.contains { $0.hasSuffix(".add") })
        // A node surface carrying any of them is refused.
        for command in Self.upstreamIOS where !DeviceModePolicy.allowedCommands.contains(command) {
            #expect(throws: (any Error).self, "\(command)") {
                try GatewayConnection.validate(.node(caps: [], commands: [command], permissions: [:]))
            }
        }
    }

    @Test func settingsNeverDeclareForbiddenEvenWhenEnabledWithAllCaps() {
        let settings = DeviceModeSettings(enabled: true, capabilities: Set(DeviceCapability.allCases))
        #expect(settings.declaredCommands.allSatisfy { DeviceModePolicy.allowedCommands.contains($0) && !DeviceModePolicy.isForbidden($0) })
        #expect(!settings.declaredCommands.contains("contacts.add"))
    }

    @Test func unsupportedCapabilityIsNeverDeclared() {
        #if os(macOS)
        #expect(!DeviceCapability.motion.isSupported)
        #expect(DeviceModePolicy.declaredCommands(for: [.motion]) == [])
        #expect(DeviceModeSettings(enabled: true, capabilities: [.motion, .location]).declaredCommands == ["location.get"])
        #endif
        #expect(DeviceCapability.location.isSupported)
    }
}

extension DemoGateway {
    func testSetSelfNode(pendingRequestId: String?, commands: [String]) {
        guard let index = self.demoNodes.firstIndex(where: { $0["nodeId"]?.text == Self.deviceId }),
              var node = self.demoNodes[index].object else { return }
        node["commands"] = JSONValue(commands)
        node["pendingRequestId"] = pendingRequestId.map { .string($0) } ?? nil
        self.demoNodes[index] = .object(node)
    }
}

@MainActor
@Suite("Device node controller (demo)")
struct DeviceNodeControllerDemoTests {
    func store() -> (GatewayStore, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let store = GatewayStore(profile: .demo(), defaults: scratch.defaults)
        store.cacheRoot = nil
        store.deviceNode.handler = FakeNodeHandler()
        return (store, scratch)
    }

    @Test func approvalComesFromNodeList() async throws {
        let (store, scratch) = self.store()
        defer { store.stop(); scratch.remove() }
        store.start()
        #expect(await eventually(timeout: .seconds(10)) { store.state.isConnected })
        await store.deviceNode.update(DeviceModeSettings(enabled: true))
        #expect(await eventually(timeout: .seconds(10)) { store.deviceNode.status == .active })
        let demo = try #require(store.connection.demo)

        // The Gateway parks the surface: pendingRequestId set → awaiting approval with that id.
        await demo.testSetSelfNode(pendingRequestId: "req-9", commands: [])
        store.deviceNode.handleOperatorEvent(GatewayEvent(name: "node.pair.requested", payload: ["nodeId": .string(DemoGateway.deviceId)], seq: nil))
        #expect(await eventually(timeout: .seconds(5)) { store.deviceNode.status == .awaitingApproval(requestId: "req-9") })

        // Approved: no pending id and declared ⊆ approved commands → active.
        await demo.testSetSelfNode(pendingRequestId: nil, commands: ["location.get"])
        store.deviceNode.handleOperatorEvent(GatewayEvent(name: "node.pair.resolved", payload: ["nodeId": .string(DemoGateway.deviceId)], seq: nil))
        #expect(await eventually(timeout: .seconds(5)) { store.deviceNode.status == .active })

        // Commands not yet a superset of the declared set → still awaiting (no pending id).
        await store.deviceNode.update(DeviceModeSettings(enabled: true, capabilities: [.location, .device]))
        await demo.testSetSelfNode(pendingRequestId: nil, commands: ["location.get"])
        store.deviceNode.handleOperatorEvent(GatewayEvent(name: "node.pair.requested", payload: ["nodeId": .string(DemoGateway.deviceId)], seq: nil))
        #expect(await eventually(timeout: .seconds(5)) { store.deviceNode.status == .awaitingApproval(requestId: nil) })
        // Events for other nodes are ignored.
        let before = store.deviceNode.status
        store.deviceNode.handleOperatorEvent(GatewayEvent(name: "node.pair.resolved", payload: ["nodeId": "someone-else"], seq: nil))
        #expect(store.deviceNode.status == before)
    }

    @Test func disableWithoutAdminSetsHintAndKeepsNodeToken() async throws {
        let (store, scratch) = self.store()
        defer { store.stop(); store.profile.forgetCredentials(); scratch.remove() }
        store.start()
        #expect(await eventually(timeout: .seconds(10)) { store.state.isConnected })
        store.profile.nodeDeviceToken = "node-tok"
        await store.deviceNode.update(DeviceModeSettings(enabled: true))
        #expect(await eventually(timeout: .seconds(10)) { store.deviceNode.status == .active })
        store.profile.nodeDeviceToken = "node-tok"
        let demo = try #require(store.connection.demo)
        let before = await demo.demoNodes.count
        await store.deviceNode.update(DeviceModeSettings(enabled: false))
        #expect(store.deviceNode.status == .off)
        // Demo hello carries no operator.admin: no node.pair.remove call, a hint instead, token kept.
        #expect(store.deviceNode.removalHint != nil)
        #expect(store.profile.nodeDeviceToken == "node-tok")
        #expect(await demo.demoNodes.count == before)
        #expect(await demo.demoNodes.first { $0["nodeId"]?.text == DemoGateway.deviceId }?["connected"]?.bool == false)
        #expect(DeviceModeSettings.load(gatewayId: store.profile.id, defaults: scratch.defaults).enabled == false)
    }

    @Test func demoInvokeRoundTripAndUndeclaredRejected() async throws {
        let (store, scratch) = self.store()
        defer { store.stop(); scratch.remove() }
        store.start()
        #expect(await eventually(timeout: .seconds(10)) { store.state.isConnected })
        await store.deviceNode.update(DeviceModeSettings(enabled: true))
        #expect(await eventually(timeout: .seconds(10)) { store.deviceNode.status == .active })
        let ok = await store.demoInvokeNode(command: "location.get")
        #expect(ok?["ok"]?.bool == true && ok?["payload"]?["lat"]?.double == 1.5)
        for command in ["contacts.add", "system.run", "device.info"] {
            let rejected = await store.demoInvokeNode(command: command)
            #expect(rejected?["ok"]?.bool == false && rejected?["error"]?["code"]?.string == "INVALID_REQUEST", "\(command)")
        }
        #expect((store.deviceNode.lastInvoke?.command) == "location.get")
    }
}

@MainActor
@Suite("Device node approval")
struct DeviceNodeApprovalTests {
    private func list(_ node: JSONValue) -> Result<JSONValue, Error> { .success(.object(["nodes": .array([node])])) }

    @Test func failedNodeListIsUnknownNotApproved() {
        let timeout = DeviceNodeController.approval(.failure(GatewayError.timeout("node.list")), nodeId: "me", wanted: ["location.get"])
        #expect(timeout == .unavailable)
        let rpc = DeviceNodeController.approval(.failure(GatewayError.rpc(code: "INTERNAL", message: "boom", details: nil)), nodeId: "me", wanted: ["location.get"])
        #expect(rpc == .unavailable)
    }

    @Test func approvalFollowsTheSelfRow() {
        let wanted: Set<String> = ["location.get"]
        let approved = self.list(.object(["nodeId": .string("me"), "commands": .array([.string("location.get")])]))
        #expect(DeviceNodeController.approval(approved, nodeId: "me", wanted: wanted) == .approved)
        let parked = self.list(.object(["nodeId": .string("me"), "pendingRequestId": .string("r1"),
                                        "commands": .array([.string("location.get")])]))
        #expect(DeviceNodeController.approval(parked, nodeId: "me", wanted: wanted) == .pending(requestId: "r1"))
        let older = self.list(.object(["nodeId": .string("me"), "commands": .array([])]))
        #expect(DeviceNodeController.approval(older, nodeId: "me", wanted: wanted) == .pending(requestId: nil))
        #expect(DeviceNodeController.approval(approved, nodeId: "other", wanted: wanted) == .pending(requestId: nil))
    }
}
