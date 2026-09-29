import Foundation
import PincerKit

// Device pairing and nodes (#30): records and the model against a fake request, then the demo and
// a (mock) Gateway end to end.

/// Records requests and answers them from `handler`.
@MainActor
final class FakeDeviceGateway {
    var calls: [(method: String, params: JSONValue)] = []
    var handler: (String, JSONValue) throws -> JSONValue = { _, _ in [:] }
    var methods: [String] { self.calls.map(\.method) }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        self.calls.append((method, params))
        return try self.handler(method, params)
    }
}

private let checkSelfId = String(repeating: "a", count: 64)
private let checkOtherId = String(repeating: "b", count: 64)

private func pendingRow(_ requestId: String, deviceId: String, name: String, ageMs: Double, isRepair: Bool = false) -> JSONValue {
    let now = Date().timeIntervalSince1970 * 1000
    return ["requestId": .string(requestId), "deviceId": .string(deviceId), "displayName": .string(name), "platform": "darwin",
            "clientId": "cli", "role": "operator", "roles": ["operator"], "scopes": ["operator.read", "operator.write"],
            "isRepair": .bool(isRepair), "ts": .number(now - ageMs)]
}

private func pairedRow(_ deviceId: String, name: String, connected: Bool = false, roles: [String] = ["operator"]) -> JSONValue {
    let now = Date().timeIntervalSince1970 * 1000
    return ["deviceId": .string(deviceId), "displayName": .string(name), "platform": "darwin", "roles": JSONValue(roles),
            "scopes": ["operator.read"], "connected": .bool(connected), "approvedAtMs": .number(now - 86_400_000),
            "tokens": [["role": "operator", "scopes": ["operator.read"], "createdAtMs": .number(now - 86_400_000)]]]
}

@MainActor
func checkDeviceManagement() async {
    print("Device pairing")
    check(DeviceFingerprint.short(checkSelfId.uppercased()) == "aaaaaaaa", "short fingerprint is 8 lowercase hex digits")
    check(DeviceFingerprint.format(checkOtherId).hasPrefix("bbbb bbbb ") && DeviceFingerprint.format(checkOtherId).hasSuffix(" …"),
          "fingerprints are grouped by four (\(DeviceFingerprint.format(checkOtherId)))")
    let request = PendingDeviceRequest(pendingRow("r1", deviceId: checkOtherId, name: "Laptop", ageMs: 60_000))
    check(request?.title == "Laptop" && request?.requestsNodeRole == false && request?.scopes == ["operator.read", "operator.write"],
          "pending request parses the upstream shape")
    check(PendingDeviceRequest(["deviceId": .string(checkOtherId)]) == nil, "a request needs a requestId")
    let device = PairedDevice(pairedRow(checkOtherId, name: "Laptop", roles: ["node", "operator"]))
    check(device?.isNode == true && device?.tokens.first?.role == "operator" && device?.approvedAt != nil, "paired device parses tokens and roles")
    let node = GatewayNode(["nodeId": .string(checkOtherId), "displayName": "Mac mini", "coreVersion": "2026.9.2", "caps": ["canvas"],
                            "paired": true, "connected": true])
    check(node?.title == "Mac mini" && node?.version == "2026.9.2" && node?.caps == ["canvas"] && node?.connected == true,
          "node parses (version falls back to coreVersion)")
    check(GatewayNode(["displayName": "No id"]) == nil, "a node needs a nodeId")

    // Model: listing, gating, actions.
    let fake = FakeDeviceGateway()
    var scopes = [GatewayConnection.adminScope]
    var pending: [JSONValue] = [pendingRow("old", deviceId: checkOtherId, name: "Old", ageMs: 600_000),
                                pendingRow("new", deviceId: checkOtherId, name: "New", ageMs: 1000)]
    var paired: [JSONValue] = [pairedRow(checkOtherId, name: "Other"), pairedRow(checkSelfId, name: "Me", connected: true)]
    fake.handler = { method, params in
        switch method {
        case DeviceManagementModel.listMethod: return ["pending": .array(pending), "paired": .array(paired)]
        case DeviceManagementModel.approveMethod:
            let id = params["requestId"]?.text
            guard pending.contains(where: { $0["requestId"]?.text == id }) else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown requestId", details: nil) }
            pending.removeAll { $0["requestId"]?.text == id }
            return ["requestId": .string(id ?? ""), "device": pairedRow(String(repeating: "c", count: 64), name: "Approved")]
        case DeviceManagementModel.rejectMethod:
            pending.removeAll { $0["requestId"]?.text == params["requestId"]?.text }
            return ["requestId": params["requestId"] ?? .null, "deviceId": .string(checkOtherId)]
        case DeviceManagementModel.removeMethod:
            let id = params["deviceId"]?.text
            guard paired.contains(where: { $0["deviceId"]?.text == id }) else { throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown deviceId", details: nil) }
            paired.removeAll { $0["deviceId"]?.text == id }
            return ["deviceId": .string(id ?? "")]
        case DeviceManagementModel.renameMethod: return ["deviceId": params["deviceId"] ?? .null, "label": params["label"] ?? .null]
        default: throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
    }
    let model = DeviceManagementModel(scopes: { scopes }, selfDeviceId: checkSelfId, request: fake.request)
    check(model.supported && model.canView && model.canManage && model.readOnlyReason == nil && model.pendingCount == 0,
          "admin can view and manage; no badge before loading")
    await model.seed()
    await model.seed()
    check(fake.methods == [DeviceManagementModel.listMethod], "seed lists once (\(fake.methods))")
    check(model.pending.map(\.requestId) == ["new", "old"] && model.pendingCount == 2, "pending newest first, badge counts them")
    check(model.paired.first.map(model.isSelf) == true && model.paired.map(\.title) == ["Me", "Other"], "this device listed first")
    let approved = await model.approve(model.pending[0])
    check(approved && model.pending.map(\.requestId) == ["old"] && model.paired.contains { $0.title == "Approved" },
          "approve drops the request and adds the device")
    check(fake.calls.last?.params == ["requestId": "new"], "approve sends only requestId")
    let stale = PendingDeviceRequest(pendingRow("new", deviceId: checkOtherId, name: "New", ageMs: 1000))!
    let staleHandled = await model.approve(stale)
    check(staleHandled && model.notice?.text == DeviceManagementModel.staleRequestMessage, "stale request → already handled notice")
    model.clearNotice()
    let rejected = await model.reject(model.pending[0])
    check(rejected && model.pending.isEmpty && model.pendingCount == 0, "reject clears the badge")
    let other = model.paired.first { $0.deviceId == checkOtherId }!
    let tooLong = await model.rename(other, to: String(repeating: "x", count: 65))
    check(!tooLong && model.operation(for: other) == .failed(DeviceManagementModel.labelTooLongMessage)
          && fake.methods.last != DeviceManagementModel.renameMethod, "labels over 64 characters aren't sent")
    let renamed = await model.rename(other, to: "  Work laptop  ")
    check(renamed && fake.calls.last { $0.method == DeviceManagementModel.renameMethod }?.params == ["deviceId": .string(checkOtherId), "label": "Work laptop"],
          "rename trims the label")
    let removed = await model.remove(other)
    check(removed && !model.paired.contains { $0.deviceId == checkOtherId }, "remove drops the device")
    let removedAgain = await model.remove(other)
    check(removedAgain && model.notice?.text == DeviceManagementModel.staleDeviceMessage, "removing a removed device → notice")

    // Without operator.admin: view with operator.pairing, nothing without it.
    scopes = ["operator.read", DeviceManagementModel.pairingScope]
    check(model.canView && !model.canManage && model.readOnlyReason == DeviceManagementModel.readOnlyMessage && !model.canRename,
          "operator.pairing views read-only")
    let blocked = await model.remove(model.paired[0])
    check(!blocked && fake.methods.last != DeviceManagementModel.removeMethod, "read-only sends no changes")
    scopes = GatewayConnection.scopes
    check(!model.canView && model.needsAccess && model.pendingCount == 0, "without operator.pairing → needs access, no badge")

    // A gateway without device pairing.
    let old = DeviceManagementModel(methods: { ["health", "status"] }, request: fake.request)
    let before = fake.calls.count
    await old.load()
    await old.loadNodes()
    check(!old.supported && !old.nodesSupported && old.hasLoaded && old.nodesLoaded && fake.calls.count == before && old.pendingCount == 0,
          "unadvertised methods aren't called")
    let rejecting = DeviceManagementModel(request: { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) })
    await rejecting.load()
    check(!rejecting.supported && rejecting.loadState == .idle && rejecting.pendingCount == 0, "UNKNOWN_METHOD → unsupported")
    let denied = DeviceManagementModel(request: { _, _ in
        throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.pairing",
                               details: ["code": "MISSING_SCOPE", "missingScope": "operator.pairing"])
    })
    await denied.load()
    check(denied.needsAccess && denied.pendingCount == 0, "missing scope on list → needs access")
}

// MARK: Demo

@MainActor
func runDemoDevices(_ gateway: GatewayStore) async {
    print("Devices (demo)")
    let devices = gateway.devices
    check(devices.supported && devices.nodesSupported && devices.canView && devices.canManage && devices.canRename
          && devices.canRenameNodes && devices.canRemoveNodes, "demo manages devices without admin")
    await devices.load()
    check(devices.loadState == .idle && devices.pendingCount == 2, "two pending requests in the demo (\(devices.pendingCount))")
    let ipad = devices.pending.first { !$0.isRepair }
    let upgrade = devices.pending.first { $0.isRepair }
    check(devices.pending.first == ipad && ipad?.title.contains("iPad") == true && ipad?.requestsNodeRole == false,
          "the newest request is a new iPad (\(devices.pending.map(\.title)))")
    check(upgrade?.scopes.contains(GatewayConnection.adminScope) == true
          && devices.paired.contains { $0.deviceId == upgrade?.deviceId }, "a paired device asks for Full Management")
    let me = devices.paired.first
    check(me.map(devices.isSelf) == true && me?.connected == true, "this device listed first and connected")
    check(devices.paired.count == 3 && devices.paired.map(\.title).dropFirst().sorted() == ["Pixel 9", "Studio MacBook Pro"]
          && devices.paired.contains { $0.isNode }, "this device, the Studio CLI and the Pixel (\(devices.paired.map(\.title)))")
    check(devices.paired.first { $0.title == "Studio MacBook Pro" }?.connected == false
          && devices.paired.first { $0.title == "Pixel 9" }?.lastActive.map { $0 < Date().addingTimeInterval(-86_400) } == true,
          "offline devices show when they were last seen")
    check(devices.paired.allSatisfy { $0.fingerprint.hasSuffix(" …") && !$0.effectiveScopes.isEmpty || $0.isNode },
          "operator devices show scopes and a fingerprint")
    if let ipad {
        let approved = await devices.approve(ipad)
        check(approved && devices.paired.contains { $0.deviceId == ipad.deviceId } && devices.pendingCount == 1, "approve the iPad")
        let again = await devices.approve(ipad)
        check(again && devices.notice?.text == DeviceManagementModel.staleRequestMessage, "approving it again → already handled")
        devices.clearNotice()
    }
    if let upgrade {
        let rejected = await devices.reject(upgrade)
        check(rejected && devices.pendingCount == 0, "reject the scope upgrade")
    }
    if let cli = devices.paired.first(where: { $0.clientId == "cli" && !devices.isSelf($0) }) {
        let renamed = await devices.rename(cli, to: "Build Mac")
        let updated = await waitFor("rename") { devices.paired.first { $0.deviceId == cli.deviceId }?.title == "Build Mac" }
        check(renamed && updated, "rename a device")
        let removed = await devices.remove(devices.paired.first { $0.deviceId == cli.deviceId } ?? cli)
        check(removed && !devices.paired.contains { $0.deviceId == cli.deviceId }, "remove a device")
    } else {
        check(false, "demo has a CLI device")
    }
    await devices.loadNodes()
    check(devices.nodesLoadState == .idle && devices.nodes.count == 2 && devices.nodes.first?.connected == true,
          "two nodes, the connected one first (\(devices.nodes.map(\.title)))")
    if let offline = devices.nodes.first(where: { !$0.connected }) {
        let renamed = await devices.renameNode(offline, to: "Alex’s Pixel")
        check(renamed && devices.nodes.contains { $0.nodeId == offline.nodeId && $0.title == "Alex’s Pixel" }, "rename a node")
        let removed = await devices.removeNode(offline)
        check(removed && !devices.nodes.contains { $0.nodeId == offline.nodeId } && devices.nodes.count == 1, "unpair a node")
        let device = devices.paired.first { $0.deviceId == offline.nodeId }
        check(device == nil || device?.isNode == false, "its device row loses the node role")
    }
    check(devices.paired.first.map(devices.isSelf) == true, "this device is still paired")
}

// MARK: Live

/// Against the mock's seeded devices: `admin` has Full Management; a standard store can't list.
/// Leaves this device paired so later checks keep their connection.
@MainActor
func runLiveDevices(profile: GatewayProfile, gateway: GatewayStore, admin: GatewayStore) async {
    print("Devices (live)")
    let adminReady = await agentsReady(admin, "admin")
    check(adminReady, "admin connected before device checks")
    let devices = admin.devices
    guard admin.hello?.methods.contains(DeviceManagementModel.listMethod) == true else {
        // MOCK_DEVICE_PAIRING=off
        await devices.load()
        check(!devices.supported && devices.pendingCount == 0, "gateway without device.pair.list → unsupported")
        return
    }
    let readerProfile = GatewayProfile(name: "Devices reader", url: profile.url, authMode: .token)
    readerProfile.secret = profile.secret
    let readerStore = GatewayStore(profile: readerProfile)
    readerStore.start()
    await agentsReady(readerStore, "devices reader")
    defer { readerStore.stop() }
    await readerStore.devices.load()
    check(readerStore.devices.needsAccess && readerStore.devices.pendingCount == 0 && readerStore.devices.paired.isEmpty,
          "without operator.pairing → needs access")

    await devices.load()
    if devices.loadState != .idle {
        await agentsReady(admin, "admin")
        await devices.load()
    }
    check(devices.loadState == .idle && devices.canManage, "device.pair.list with Full Management (\(devices.loadState))")
    let seeded = devices.pending.filter { ["pair_ipad", "pair_studio_admin"].contains($0.requestId) }
    check(seeded.map(\.requestId) == ["pair_ipad", "pair_studio_admin"], "seeded requests, newest first (\(devices.pending.map(\.requestId)))")
    check(devices.pendingCount == devices.pending.count && devices.pendingCount >= 2, "badge counts pending requests")
    let titles = devices.paired.map(\.title)
    check(["Studio MacBook Pro", "Pixel 9", "Mac mini (home)"].allSatisfy(titles.contains), "seeded devices listed (\(titles))")
    let me = devices.paired.first { devices.isSelf($0) }
    check(me?.connected == true && devices.paired.first == me, "this device listed first and connected")
    check(me?.effectiveScopes.contains(GatewayConnection.adminScope) == true, "this device holds Full Management (\(me?.effectiveScopes ?? []))")
    check(devices.paired.first { $0.title == "Mac mini (home)" }?.isNode == true, "node host listed as a node")

    if let ipad = seeded.first(where: { $0.requestId == "pair_ipad" }) {
        check(ipad.title == "Alex's iPad" && ipad.platform == "ipados" && !ipad.isRepair && ipad.requestedAt != nil, "iPad request presentation")
        let approved = await devices.approve(ipad)
        check(approved && devices.operation(for: ipad) == .idle && !devices.pending.contains { $0.requestId == "pair_ipad" }
              && devices.paired.contains { $0.deviceId == ipad.deviceId }, "device.pair.approve")
        let again = await devices.approve(ipad)
        check(again && devices.notice?.text == DeviceManagementModel.staleRequestMessage, "stale approve → already handled")
        devices.clearNotice()
    }
    if let upgrade = seeded.first(where: { $0.requestId == "pair_studio_admin" }) {
        check(upgrade.isRepair && upgrade.scopes.contains(GatewayConnection.adminScope), "scope upgrade asks for operator.admin")
        let rejected = await devices.reject(upgrade)
        check(rejected && !devices.pending.contains { $0.requestId == "pair_studio_admin" }, "device.pair.reject")
    }
    if let studio = devices.paired.first(where: { $0.title == "Studio MacBook Pro" }) {
        let tooLong = await devices.rename(studio, to: String(repeating: "x", count: 65))
        check(!tooLong && devices.operation(for: studio) == .failed(DeviceManagementModel.labelTooLongMessage), "long label refused locally")
        let renamed = await devices.rename(studio, to: "  Build Mac  ")
        let shown = await waitFor("renamed") { devices.paired.first { $0.deviceId == studio.deviceId }?.title == "Build Mac" }
        check(renamed && shown, "device.pair.rename (\(devices.paired.map(\.title)))")
        let removed = await devices.remove(studio)
        check(removed && !devices.paired.contains { $0.deviceId == studio.deviceId }, "device.pair.remove")
        await devices.load()
        check(!devices.paired.contains { $0.deviceId == studio.deviceId }, "removed device stays gone after a reload")
        let again = await devices.remove(studio)
        check(again && devices.notice?.text == DeviceManagementModel.staleDeviceMessage, "stale remove → already removed")
        devices.clearNotice()
    } else {
        check(false, "mock seeded the Studio MacBook Pro")
    }

    await devices.loadNodes()
    let nodeTitles = devices.nodes.map(\.title)
    check(devices.nodesLoadState == .idle && nodeTitles.first == "Mac mini (home)" && nodeTitles.contains("Pixel 9"),
          "node.list, connected node first (\(nodeTitles))")
    check(devices.nodes.first?.caps.contains("canvas") == true && devices.nodes.first?.connected == true, "node caps and status")
    if let pixel = devices.nodes.first(where: { $0.title == "Pixel 9" }) {
        let renamed = await devices.renameNode(pixel, to: "Alex's Pixel")
        check(renamed && devices.nodes.contains { $0.nodeId == pixel.nodeId && $0.title == "Alex's Pixel" }, "node.rename")
        let removed = await devices.removeNode(pixel)
        check(removed && !devices.nodes.contains { $0.nodeId == pixel.nodeId }, "node.pair.remove")
        let row = await waitFor("pixel row") { devices.paired.first { $0.deviceId == pixel.nodeId }?.isNode == false }
        check(row, "the phone stays paired as an operator (\(devices.paired.first { $0.deviceId == pixel.nodeId }?.roles ?? []))")
        let again = await devices.removeNode(pixel)
        check(again && devices.notice?.text == DeviceManagementModel.staleNodeMessage, "stale node remove → already removed")
        devices.clearNotice()
    }
    let stillConnected = await agentsReady(admin, "admin")
    check(stillConnected, "admin still connected after device checks")
}
