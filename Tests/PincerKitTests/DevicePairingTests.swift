import CryptoKit
import Foundation
import Testing
@testable import PincerKit

/// Upstream-shaped `device.pair.list` / `node.list` rows relative to a fixed clock.
enum DeviceFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let selfId = "1d413dd6919a2b142770e9f27fddf27228163c4908dae6b43fa926739a5e2d63"
    static let otherId = "aa0a1b5c1530dc5c7ec20e0641e5ee33ecbe1c9a85dea543b1fcbb80ef1b0282"

    static func ms(_ offset: TimeInterval) -> JSONValue { .number(((now.timeIntervalSince1970 + offset) * 1000).rounded()) }

    static func pending(_ requestId: String, deviceId: String = "9f".padding(toLength: 64, withPad: "0", startingAt: 0),
                        name: String? = "Alex’s iPad", ago: TimeInterval = 120, role: String = "operator",
                        roles: [String] = ["operator"], scopes: [String] = ["operator.read", "operator.write"],
                        isRepair: Bool = false) -> JSONValue
    {
        var row: [String: JSONValue] = [
            "requestId": .string(requestId), "deviceId": .string(deviceId), "publicKey": "pk",
            "platform": "ios", "deviceFamily": "iPad", "clientId": "openclaw-ios", "clientMode": "ui",
            "role": .string(role), "roles": JSONValue(roles), "scopes": JSONValue(scopes), "remoteIp": "192.168.1.42",
            "silent": false, "isRepair": .bool(isRepair), "ts": ms(-ago),
        ]
        if let name { row["displayName"] = .string(name) }
        return .object(row)
    }

    static func paired(_ deviceId: String, name: String? = "Studio MacBook Pro", label: String? = nil,
                       clientId: String? = "cli", connected: Bool = false, seenAgo: TimeInterval? = 3600,
                       roles: [String] = ["operator"], scopes: [String] = ["operator.read"],
                       tokens: [JSONValue]? = nil) -> JSONValue
    {
        var row: [String: JSONValue] = [
            "deviceId": .string(deviceId), "publicKey": "pk", "platform": "darwin", "deviceFamily": "Mac",
            "role": .string(roles.first ?? "operator"), "roles": JSONValue(roles), "scopes": JSONValue(scopes),
            "connected": .bool(connected), "approvedVia": "owner", "createdAtMs": ms(-86400), "approvedAtMs": ms(-86400),
        ]
        if let name { row["displayName"] = .string(name) }
        if let label { row["operatorLabel"] = .string(label) }
        if let clientId { row["clientId"] = .string(clientId) }
        if let seenAgo { row["lastSeenAtMs"] = ms(-seenAgo) }
        row["tokens"] = .array(tokens ?? [["role": "operator", "scopes": JSONValue(scopes), "createdAtMs": ms(-86400)]])
        return .object(row)
    }

    static func node(_ nodeId: String, name: String?, connected: Bool = false, active: Bool = false) -> JSONValue {
        var row: [String: JSONValue] = [
            "nodeId": .string(nodeId), "platform": "darwin", "coreVersion": "2026.9.2", "caps": ["system", "system", "browser"],
            "commands": ["system.run"], "paired": true, "connected": .bool(connected), "approvalState": "approved",
            "lastConnectedAtMs": ms(-7200),
        ]
        if let name { row["displayName"] = .string(name) }
        if active { row["active"] = true }
        return .object(row)
    }

    static func list(pending: [JSONValue] = [], paired: [JSONValue] = []) -> JSONValue {
        ["pending": .array(pending), "paired": .array(paired)]
    }

    static func rpc(_ code: String, _ message: String, details: JSONValue? = nil) -> GatewayError {
        .rpc(code: code, message: message, details: details)
    }

    static let missingScope = rpc("FORBIDDEN", "missing scope: operator.pairing",
                                  details: ["code": "MISSING_SCOPE", "missingScope": "operator.pairing", "requiredScopes": ["operator.pairing"]])
}

/// A fake Gateway for `DeviceManagementModel`: records calls, answers from `results`, throws from `failures`.
@MainActor
final class ScriptedDevices {
    var calls: [(method: String, params: JSONValue)] = []
    var results: [String: JSONValue] = [:]
    var failures: [String: GatewayError] = [:]
    /// Runs inside the next `device.pair.list`, before it returns (an event racing the reply).
    var duringList: (@MainActor () -> Void)?

    init(list: JSONValue = DeviceFixtures.list()) {
        self.results[DeviceManagementModel.listMethod] = list
        self.results[DeviceManagementModel.nodeListMethod] = ["ts": 0, "nodes": []]
    }

    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        self.calls.append((method, params))
        if method == DeviceManagementModel.listMethod, let hook = self.duringList {
            self.duringList = nil
            hook()
        }
        if let failure = self.failures[method] { throw failure }
        return self.results[method] ?? [:]
    }

    var methods: [String] { self.calls.map(\.method) }
    func params(_ method: String) -> [JSONValue] { self.calls.filter { $0.method == method }.map(\.params) }
}

@MainActor
private func makeModel(_ fake: ScriptedDevices, scopes: [String] = [GatewayConnection.adminScope],
                       methods: Set<String>? = nil, selfId: String = DeviceFixtures.selfId,
                       demo: Bool = false) -> DeviceManagementModel
{
    DeviceManagementModel(methods: { methods }, scopes: { scopes }, selfDeviceId: selfId,
                          allowsWritesWithoutAdmin: demo, request: { method, params in try fake.request(method, params) })
}

@Suite("Device pairing records")
struct DeviceRecordTests {
    @Test func pendingRequestParsesUpstreamShape() throws {
        let row = DeviceFixtures.pending("r1", role: "operator", roles: ["operator", "node", "operator"],
                                         scopes: ["operator.read", "operator.read", "operator.write"], isRepair: true)
        let request = try #require(PendingDeviceRequest(row))
        #expect(request.id == "r1")
        #expect(request.roles == ["operator", "node"])
        #expect(request.scopes == ["operator.read", "operator.write"])
        #expect(request.isRepair && !request.silent)
        #expect(request.requestsNodeRole)
        #expect(request.requestedAt == DeviceFixtures.now.addingTimeInterval(-120))
        #expect(request.title == "Alex’s iPad")
        #expect(request.subtitle == "iPadOS · OpenClaw app")
        #expect(request.clientMode == "ui" && request.remoteIp == "192.168.1.42" && request.publicKey == "pk")
    }

    @Test func pendingRequestNeedsIds() {
        #expect(PendingDeviceRequest(["deviceId": "d"]) == nil)
        #expect(PendingDeviceRequest(["requestId": "r"]) == nil)
        #expect(PendingDeviceRequest("nope") == nil)
        let bare = PendingDeviceRequest(["requestId": "r", "deviceId": "d"])
        #expect(bare?.title == "Unknown device" && bare?.roles == [] && bare?.isRepair == false && bare?.requestedAt == nil)
        let clientOnly = PendingDeviceRequest(["requestId": "r", "deviceId": "d", "clientId": "cli"])
        #expect(clientOnly?.title == "cli")
        #expect(PendingDeviceRequest(DeviceFixtures.pending("r"))?.requestsNodeRole == false)
    }

    @Test func pairedDeviceTitleFallbacks() throws {
        let labelled = try #require(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId, label: "Desk")))
        #expect(labelled.title == "Desk")
        #expect(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId))?.title == "Studio MacBook Pro")
        #expect(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId, name: nil))?.title == "cli")
        #expect(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId, name: nil, clientId: nil))?.title == "aa0a1b5c")
        #expect(PairedDevice(["publicKey": "pk"]) == nil)
    }

    @Test func pairedDeviceTokensAndScopes() throws {
        let tokens: [JSONValue] = [
            ["role": "operator", "scopes": ["operator.read", "operator.admin"], "createdAtMs": DeviceFixtures.ms(-86400),
             "lastUsedAtMs": DeviceFixtures.ms(-60)],
            ["role": "node", "scopes": ["node.old"], "createdAtMs": DeviceFixtures.ms(-86400), "revokedAtMs": DeviceFixtures.ms(-600)],
            ["scopes": ["no.role"]],
        ]
        let device = try #require(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId, seenAgo: 3600, roles: ["operator", "node"],
                                                                   scopes: ["operator.read"], tokens: tokens)))
        #expect(device.tokens.map(\.role) == ["operator", "node"], "tokens without a role are dropped")
        #expect(device.tokens[1].isRevoked && !device.tokens[0].isRevoked)
        #expect(device.effectiveScopes == ["operator.read", "operator.admin"], "revoked tokens don't count")
        #expect(device.lastActive == DeviceFixtures.now.addingTimeInterval(-60), "newest of lastSeen and token use")
        #expect(device.isNode)
        #expect(device.approvedViaLabel != nil)
        #expect(device.approvedAt == DeviceFixtures.now.addingTimeInterval(-86400))
        let noTokens = try #require(PairedDevice(DeviceFixtures.paired(DeviceFixtures.otherId, scopes: ["operator.write"], tokens: [])))
        #expect(noTokens.effectiveScopes == ["operator.write"] && !noTokens.isNode && !noTokens.connected)
    }

    @Test func nodeParsesUpstreamShape() throws {
        let node = try #require(GatewayNode(DeviceFixtures.node("n1", name: "Mac mini", connected: true, active: true)))
        #expect(node.version == "2026.9.2", "coreVersion when version is missing")
        #expect(node.caps == ["system", "browser"])
        #expect(node.connected && node.active && node.paired && !node.gatewayLocal)
        #expect(node.lastSeenAt == DeviceFixtures.now.addingTimeInterval(-7200), "lastConnectedAtMs when lastSeenAtMs is missing")
        #expect(node.approvalLabel == nil)
        #expect(GatewayNode(DeviceFixtures.node("abcdef0123456789", name: nil))?.title == "abcdef01")
        #expect(GatewayNode(["nodeId": "n", "approvalState": "pending-approval"])?.approvalLabel != nil)
        #expect(GatewayNode(["displayName": "x"]) == nil)
    }

    @Test func fingerprints() {
        let id = "65b60673d6ed884bf01c2c222d82ada0740f29ac3355d6a925c81f17f47a27b8"
        #expect(DeviceFingerprint.short(id) == "65b60673")
        #expect(DeviceFingerprint.short("ABCDEF0123") == "abcdef01")
        let formatted = DeviceFingerprint.format(id)
        #expect(formatted == "65b6 0673 d6ed 884b f01c 2c22 2d82 ada0 …")
        #expect(DeviceFingerprint.format("abcd") == "abcd")
        #expect(PendingDeviceRequest(DeviceFixtures.pending("r", deviceId: id))?.fingerprint == formatted)
    }

    @Test func selfIdentityMatchesFingerprintScheme() {
        // The Gateway derives deviceId as hex(sha256(raw public key)); Pincer's identity must agree.
        let identity = Fixtures.identity()
        let raw = base64UrlDecode(Fixtures.publicKeyBase64Url)!
        let hex = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        #expect(identity.deviceId == hex)
    }
}

@Suite("Device management model")
@MainActor
struct DeviceManagementModelTests {
    @Test func loadSortsPendingAndPaired() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(
            pending: [DeviceFixtures.pending("old", ago: 900), DeviceFixtures.pending("new", ago: 60),
                      DeviceFixtures.pending("new", ago: 60), ["requestId": "broken"]],
            paired: [
                DeviceFixtures.paired("b".padding(toLength: 64, withPad: "b", startingAt: 0), name: "Offline recent", seenAgo: 60),
                DeviceFixtures.paired("c".padding(toLength: 64, withPad: "c", startingAt: 0), name: "Connected", connected: true, seenAgo: 7200),
                DeviceFixtures.paired(DeviceFixtures.selfId, name: "Me", connected: true, seenAgo: 9000),
                DeviceFixtures.paired("d".padding(toLength: 64, withPad: "d", startingAt: 0), name: "Offline old", seenAgo: 86400 * 3),
            ]))
        let model = makeModel(fake)
        #expect(!model.hasLoaded)
        await model.load()
        #expect(fake.calls.count == 1 && fake.calls[0].method == "device.pair.list" && fake.calls[0].params == [:])
        #expect(model.hasLoaded && model.loadState == .idle)
        #expect(model.pending.map(\.requestId) == ["new", "old"], "newest first, duplicates and broken rows dropped")
        #expect(model.paired.map(\.title) == ["Me", "Connected", "Offline old", "Offline recent"], "this device first, then by name")
        #expect(model.isSelf(model.paired[0]) && !model.isSelf(model.paired[1]))
        #expect(model.pendingCount == 2)
    }

    @Test func gatingByScope() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")]))
        let reader = makeModel(fake, scopes: GatewayConnection.scopes)
        #expect(!reader.canView && !reader.canManage && reader.needsAccess && reader.readOnlyReason == DeviceManagementModel.readOnlyMessage)
        await reader.load()
        #expect(fake.calls.isEmpty, "no list without operator.pairing")
        #expect(reader.pendingCount == 0)

        let pairer = makeModel(fake, scopes: GatewayConnection.scopes + [DeviceManagementModel.pairingScope])
        #expect(pairer.canView && !pairer.canManage && !pairer.needsAccess && !pairer.canRename)
        await pairer.load()
        #expect(pairer.pending.count == 1 && pairer.pendingCount == 1)
        let approved = await pairer.approve(pairer.pending[0])
        #expect(!approved && fake.params("device.pair.approve").isEmpty, "approving needs Full Management")

        let admin = makeModel(fake)
        #expect(admin.canView && admin.canManage && admin.readOnlyReason == nil && admin.canRename && admin.canRenameNodes && admin.canRemoveNodes)
        let demo = makeModel(fake, scopes: GatewayConnection.scopes + [DeviceManagementModel.pairingScope], demo: true)
        #expect(demo.canManage, "the demo manages without operator.admin")
    }

    @Test func missingScopeOnListNeedsAccess() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")]))
        fake.failures["device.pair.list"] = DeviceFixtures.missingScope
        let model = makeModel(fake, scopes: [DeviceManagementModel.pairingScope])
        await model.load()
        #expect(model.needsAccess && model.pendingCount == 0)
        #expect(model.loadState == .failed(DeviceManagementModel.needsAccessMessage))
        model.handleReconnect()
        fake.failures = [:]
        await model.load()
        #expect(!model.needsAccess && model.pendingCount == 1, "a reconnect can bring the scope")
    }

    @Test func unsupportedGateway() async {
        let advertised: Set<String> = ["sessions.list", "health"]
        let fake = ScriptedDevices()
        let model = makeModel(fake, methods: advertised)
        #expect(!model.supported && !model.nodesSupported)
        await model.load()
        await model.loadNodes()
        #expect(fake.calls.isEmpty && model.hasLoaded && model.nodesLoaded && model.pendingCount == 0)

        let rejecting = ScriptedDevices()
        rejecting.failures["device.pair.list"] = DeviceFixtures.rpc("UNKNOWN_METHOD", "unknown method: device.pair.list")
        rejecting.failures["node.list"] = DeviceFixtures.rpc("INVALID_REQUEST", "unknown method: node.list")
        let older = makeModel(rejecting)
        #expect(older.supported, "unknown method list → assume supported until rejected")
        await older.load()
        await older.loadNodes()
        #expect(!older.supported && !older.nodesSupported && older.loadState == .idle && older.nodesLoadState == .idle)
        older.handleReconnect()
        #expect(older.supported, "a reconnect may reach a newer Gateway")

        let noRename = makeModel(fake, methods: ["device.pair.list", "device.pair.approve"])
        #expect(noRename.supported && !noRename.canRename && !noRename.canRenameNodes && !noRename.canRemoveNodes)
    }

    @Test func approveSendsRequestIdAndAddsDevice() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1", deviceId: DeviceFixtures.otherId)]))
        fake.results["device.pair.approve"] = ["requestId": "r1", "device": DeviceFixtures.paired(DeviceFixtures.otherId, name: "New Mac")]
        let model = makeModel(fake)
        await model.load()
        let ok = await model.approve(model.pending[0])
        #expect(ok)
        #expect(fake.params("device.pair.approve") == [["requestId": "r1"]])
        #expect(model.pending.isEmpty && model.paired.map(\.title) == ["New Mac"] && model.pendingCount == 0)
        #expect(model.operation(for: model.paired[0]) == .idle)
    }

    @Test func approveWithoutDeviceReloads() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")]))
        fake.results["device.pair.approve"] = ["requestId": "r1"]
        let model = makeModel(fake)
        await model.load()
        fake.results["device.pair.list"] = DeviceFixtures.list(paired: [DeviceFixtures.paired(DeviceFixtures.otherId, name: "New Mac")])
        _ = await model.approve(model.pending[0])
        #expect(fake.methods == ["device.pair.list", "device.pair.approve", "device.pair.list"])
        #expect(model.pending.isEmpty && model.paired.map(\.title) == ["New Mac"])
    }

    @Test func rejectAndRemove() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")],
                                                             paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        let model = makeModel(fake)
        await model.load()
        #expect(await model.reject(model.pending[0]))
        #expect(fake.params("device.pair.reject") == [["requestId": "r1"]] && model.pending.isEmpty)
        #expect(await model.remove(model.paired[0]))
        #expect(fake.params("device.pair.remove") == [["deviceId": .string(DeviceFixtures.otherId)]] && model.paired.isEmpty)
        #expect(model.pendingCount == 0)
    }

    @Test func staleRequestIsDroppedWithNotice() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")]))
        fake.failures["device.pair.approve"] = DeviceFixtures.rpc("INVALID_REQUEST", "unknown requestId")
        let model = makeModel(fake)
        await model.load()
        let request = model.pending[0]
        fake.results["device.pair.list"] = DeviceFixtures.list()
        #expect(await model.approve(request), "already handled counts as gone")
        #expect(model.pending.isEmpty && model.notice?.text == DeviceManagementModel.staleRequestMessage)
        #expect(fake.methods.last == "device.pair.list", "reloads after a stale answer")
        model.clearNotice()
        #expect(model.notice == nil)

        let removing = ScriptedDevices(list: DeviceFixtures.list(paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        removing.failures["device.pair.remove"] = DeviceFixtures.rpc("INVALID_REQUEST", "unknown deviceId")
        let other = makeModel(removing)
        await other.load()
        let device = other.paired[0]
        removing.results["device.pair.list"] = DeviceFixtures.list()
        #expect(await other.remove(device))
        #expect(other.paired.isEmpty && other.notice?.text == DeviceManagementModel.staleDeviceMessage)
    }

    @Test func deniedTurnsReadOnly() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")],
                                                             paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        fake.failures["device.pair.approve"] = DeviceFixtures.rpc("INVALID_REQUEST", "device pairing approval denied")
        let model = makeModel(fake)
        await model.load()
        #expect(!(await model.approve(model.pending[0])))
        #expect(!model.canManage && model.notice?.text == DeviceManagementModel.readOnlyMessage)
        #expect(model.pending.count == 1 && model.operation(for: model.pending[0]) == .idle)
        #expect(!(await model.remove(model.paired[0])) && fake.params("device.pair.remove").isEmpty)
        model.handleReconnect()
        #expect(model.canManage)
    }

    @Test func otherFailuresStayOnTheRow() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        fake.failures["device.pair.remove"] = DeviceFixtures.rpc("UNAVAILABLE", "gateway busy")
        let model = makeModel(fake)
        await model.load()
        #expect(!(await model.remove(model.paired[0])))
        #expect(model.paired.count == 1 && model.operation(for: model.paired[0]) == .failed("gateway busy") && model.canManage)
    }

    @Test func renameTrimsAndValidates() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        let model = makeModel(fake)
        await model.load()
        let device = model.paired[0]
        #expect(!(await model.rename(device, to: "   ")) && fake.params("device.pair.rename").isEmpty)
        #expect(!(await model.rename(device, to: String(repeating: "x", count: 65))))
        #expect(fake.params("device.pair.rename").isEmpty && model.operation(for: device) == .failed(DeviceManagementModel.labelTooLongMessage))
        #expect(await model.rename(device, to: "  Studio  "))
        #expect(fake.params("device.pair.rename") == [["deviceId": .string(DeviceFixtures.otherId), "label": "Studio"]])
        #expect(fake.methods.last == "device.pair.list")

        fake.failures["device.pair.rename"] = DeviceFixtures.rpc("UNKNOWN_METHOD", "unknown method: device.pair.rename")
        #expect(!(await model.rename(model.paired[0], to: "Again")))
        #expect(!model.canRename && model.operation(for: model.paired[0]) == .failed(DeviceManagementModel.renameUnsupportedMessage))
    }

    @Test func eventsKeepTheListLive() async throws {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1", ago: 600)]))
        let model = makeModel(fake)
        await model.load()
        model.handle(event: "device.pair.requested", payload: DeviceFixtures.pending("r2", ago: 5))
        #expect(model.pending.map(\.requestId) == ["r2", "r1"] && model.pendingCount == 2)
        model.handle(event: "device.pair.requested", payload: DeviceFixtures.pending("r2", name: "Renamed", ago: 1))
        #expect(model.pending.map(\.title) == ["Renamed", "Alex’s iPad"], "a refreshed request replaces the old row")
        model.handle(event: "device.pair.requested", payload: ["deviceId": "no request id"])
        #expect(model.pending.count == 2)
        model.handle(event: "device.pair.resolved", payload: ["requestId": "r1", "deviceId": "d", "decision": "rejected", "ts": 1])
        #expect(model.pending.map(\.requestId) == ["r2"])
        let listsBefore = fake.params("device.pair.list").count
        model.handle(event: "device.pair.resolved", payload: ["requestId": "r2", "deviceId": "d", "decision": "approved", "ts": 1])
        #expect(model.pending.isEmpty)
        let reloaded = await devicesEventually { fake.params("device.pair.list").count > listsBefore }
        #expect(reloaded, "approved → reload to pick up the device")
        let listsAfterApprove = fake.params("device.pair.list").count
        model.handle(event: "device.pair.changed", payload: [:])
        #expect(await devicesEventually { fake.params("device.pair.list").count > listsAfterApprove }, "changed → reload")
    }

    @Test func resolvedDuringListDoesNotResurrect() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1"), DeviceFixtures.pending("r2", ago: 30)]))
        let model = makeModel(fake)
        fake.duringList = { [weak model] in
            model?.handle(event: "device.pair.resolved", payload: ["requestId": "r1", "deviceId": "d", "decision": "rejected", "ts": 1])
        }
        await model.load()
        #expect(model.pending.map(\.requestId) == ["r2"], "the list predates the resolution")
    }

    @Test func eventsIgnoredWithoutAccess() {
        let fake = ScriptedDevices()
        let model = makeModel(fake, scopes: GatewayConnection.scopes)
        model.handle(event: "device.pair.requested", payload: DeviceFixtures.pending("r1"))
        #expect(model.pending.isEmpty && model.pendingCount == 0)
    }

    @Test func resetForgetsEverything() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")],
                                                             paired: [DeviceFixtures.paired(DeviceFixtures.otherId)]))
        fake.results["node.list"] = ["ts": 0, "nodes": [DeviceFixtures.node("n1", name: "Mac mini")]]
        let model = makeModel(fake)
        await model.load()
        await model.loadNodes()
        model.reset()
        #expect(model.pending.isEmpty && model.paired.isEmpty && model.nodes.isEmpty && !model.hasLoaded && !model.nodesLoaded)
        #expect(model.pendingCount == 0 && model.notice == nil && model.loadState == .idle)
    }

    @Test func seedLoadsOnce() async {
        let fake = ScriptedDevices(list: DeviceFixtures.list(pending: [DeviceFixtures.pending("r1")]))
        let model = makeModel(fake)
        await model.seed()
        await model.seed()
        #expect(fake.params("device.pair.list").count == 1 && model.pendingCount == 1)
    }

    @Test func nodesSortRenameAndRemove() async throws {
        let fake = ScriptedDevices(list: DeviceFixtures.list(paired: [DeviceFixtures.paired("n2", name: "Pixel 9", roles: ["node", "operator"])]))
        fake.results["node.list"] = ["ts": 0, "activeNodeId": "n3", "nodes": [
            DeviceFixtures.node("n1", name: "Zed offline"), DeviceFixtures.node("n2", name: "Pixel 9"),
            DeviceFixtures.node("n4", name: "Alpha connected", connected: true), DeviceFixtures.node("n3", name: "Active one", connected: true),
            DeviceFixtures.node("n1", name: "dupe"),
        ]]
        let model = makeModel(fake)
        #expect(model.nodesSupported)
        await model.loadNodes()
        #expect(fake.params("node.list") == [[:]])
        #expect(model.nodes.map(\.nodeId) == ["n3", "n4", "n2", "n1"], "active, then connected, then by name; duplicates dropped")
        let pixel = try #require(model.nodes.first { $0.nodeId == "n2" })
        #expect(await model.renameNode(pixel, to: " Pixel "))
        #expect(fake.params("node.rename") == [["nodeId": "n2", "displayName": "Pixel"]])
        #expect(!(await model.renameNode(pixel, to: "  ")) && fake.params("node.rename").count == 1)

        await model.load()
        fake.results["node.list"] = ["ts": 0, "nodes": [DeviceFixtures.node("n1", name: "Zed offline")]]
        fake.results["device.pair.list"] = DeviceFixtures.list(paired: [DeviceFixtures.paired("n2", name: "Pixel 9", roles: ["operator"])])
        #expect(await model.removeNode(pixel))
        #expect(fake.params("node.pair.remove") == [["nodeId": "n2"]])
        #expect(model.nodes.map(\.nodeId) == ["n1"] && model.paired.first?.isNode == false, "node list and devices reloaded")

        fake.failures["node.pair.remove"] = DeviceFixtures.rpc("INVALID_REQUEST", "unknown nodeId")
        #expect(await model.removeNode(model.nodes[0]))
        #expect(model.notice?.text == DeviceManagementModel.staleNodeMessage)
    }

    @Test func nodeEventsReloadNodes() async {
        let fake = ScriptedDevices()
        fake.results["node.list"] = ["ts": 0, "nodes": [DeviceFixtures.node("n1", name: "Mac mini"), DeviceFixtures.node("n2", name: "Pixel")]]
        let model = makeModel(fake)
        await model.loadNodes()
        model.handle(event: "node.pair.resolved", payload: ["requestId": "", "nodeId": "n1", "decision": "removed", "ts": 1])
        #expect(model.nodes.map(\.nodeId) == ["n2"], "removed nodes go right away")
        #expect(await devicesEventually { fake.params("node.list").count == 2 })
    }
}

@Suite("Demo device seeds")
struct DemoDeviceSeedTests {
    private static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func seedsMatchUpstreamShapes() throws {
        let now = Date()
        let pending = DemoGateway.seedPendingDevices(now: now).compactMap(PendingDeviceRequest.init)
        let paired = DemoGateway.seedPairedDevices(now: now).compactMap(PairedDevice.init)
        let nodes = DemoGateway.seedNodes(now: now).compactMap(GatewayNode.init)
        #expect(pending.count == DemoGateway.seedPendingDevices(now: now).count && pending.count == 2)
        #expect(paired.count == DemoGateway.seedPairedDevices(now: now).count && paired.count == 3)
        #expect(nodes.count == 2)

        let ipad = try #require(pending.first { !$0.isRepair })
        #expect(ipad.title == "Alex’s iPad" && ipad.scopes == GatewayConnection.scopes && !ipad.requestsNodeRole)
        #expect(abs((ipad.requestedAt ?? .distantPast).timeIntervalSince(now) + 120) < 1)
        let upgrade = try #require(pending.first { $0.isRepair })
        #expect(upgrade.scopes.contains(GatewayConnection.adminScope))
        #expect(paired.contains { $0.deviceId == upgrade.deviceId }, "the scope upgrade comes from a paired device")

        let me = try #require(paired.first { $0.deviceId == DemoGateway.deviceId })
        #expect(me.connected && me.scopes.contains(GatewayConnection.adminScope) && me.clientId == GatewayConnection.clientId)
        #expect(Set(paired.map(\.deviceId)).count == paired.count && Set(pending.map(\.requestId)).count == pending.count)
        #expect(paired.filter { !$0.connected }.allSatisfy { $0.lastSeenAt.map { $0 < now } ?? false }, "offline devices were seen before")
        #expect(paired.map(\.title).sorted() == ["Pixel 9", "Studio MacBook Pro", me.title].sorted())
        let studio = try #require(paired.first { $0.title == "Studio MacBook Pro" })
        #expect(studio.clientId == "cli" && abs((studio.lastSeenAt ?? .distantPast).timeIntervalSince(now) + 3 * 3600) < 1)
        let pixel = try #require(paired.first { $0.title == "Pixel 9" })
        #expect(pixel.isNode && pixel.roles.contains("operator") && abs((pixel.lastSeenAt ?? .distantPast).timeIntervalSince(now) + 2 * 86400) < 1)
        #expect(paired.allSatisfy { !$0.tokens.isEmpty && $0.approvedAt != nil })

        // Every seeded key hashes to its device id, like the Gateway's (Pincer's own id is the demo's constant).
        let rows = DemoGateway.seedPendingDevices(now: now) + DemoGateway.seedPairedDevices(now: now)
        for row in rows where row["deviceId"]?.text != DemoGateway.deviceId {
            let key = try #require(row["publicKey"]?.text.flatMap(base64UrlDecode))
            #expect(key.count == 32 && Self.sha256Hex(key) == row["deviceId"]?.text, "\(row["displayName"]?.text ?? "?")")
        }

        let pairedIds = Set(paired.map(\.deviceId))
        #expect(nodes.first { $0.title == "Pixel 9" }.map { pairedIds.contains($0.nodeId) } == true, "the Pixel node is a paired device")
        #expect(nodes.filter(\.connected).map(\.title) == ["Mac mini (home)"] && nodes.contains { !$0.connected && $0.title == "Pixel 9" })
        #expect(nodes.allSatisfy { $0.version != nil && !$0.caps.isEmpty && $0.approvalState == "approved" })
    }
}

/// Polls `condition` on the main actor for up to two seconds.
@MainActor
private func devicesEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
