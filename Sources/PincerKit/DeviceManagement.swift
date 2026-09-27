import Foundation

// MARK: Records

/// One role token of a paired device (`tokens[]` of `device.pair.list`). The Gateway redacts the
/// token itself; only its lifecycle metadata crosses the wire.
public struct DeviceTokenSummary: Hashable, Sendable {
    public let role: String
    public let scopes: [String]
    public let createdAt: Date?
    public let rotatedAt: Date?
    public let revokedAt: Date?
    public let lastUsedAt: Date?

    public var isRevoked: Bool { self.revokedAt != nil }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let role = json["role"]?.text else { return nil }
        self.role = role
        self.scopes = DeviceRecords.strings(json["scopes"])
        self.createdAt = PairingRequest.date(json["createdAtMs"])
        self.rotatedAt = PairingRequest.date(json["rotatedAtMs"])
        self.revokedAt = PairingRequest.date(json["revokedAtMs"])
        self.lastUsedAt = PairingRequest.date(json["lastUsedAtMs"])
    }
}

/// A device asking to pair with the Gateway (`device.pair.list` `pending[]`, or a
/// `device.pair.requested` event). Everything but the ids is what the device declared.
public struct PendingDeviceRequest: Identifiable, Hashable, Sendable {
    public let requestId: String
    /// hex(sha256(public key)): the device's fingerprint.
    public let deviceId: String
    public let publicKey: String?
    public let displayName: String?
    public let platform: String?
    public let deviceFamily: String?
    public let clientId: String?
    public let clientMode: String?
    public let browserOrigin: String?
    public let remoteIp: String?
    /// `role` and `roles`, without duplicates.
    public let roles: [String]
    public let scopes: [String]
    /// An already paired device asking again (new key or broader access).
    public let isRepair: Bool
    public let silent: Bool
    public let requestedAt: Date?

    public var id: String { self.requestId }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let requestId = json["requestId"]?.text, let deviceId = json["deviceId"]?.text else { return nil }
        self.requestId = requestId
        self.deviceId = deviceId
        self.publicKey = json["publicKey"]?.text
        self.displayName = json["displayName"]?.text
        self.platform = json["platform"]?.text
        self.deviceFamily = json["deviceFamily"]?.text
        self.clientId = json["clientId"]?.text
        self.clientMode = json["clientMode"]?.text
        self.browserOrigin = json["browserOrigin"]?.text
        self.remoteIp = json["remoteIp"]?.text
        self.roles = DeviceRecords.roles(json)
        self.scopes = DeviceRecords.strings(json["scopes"])
        self.isRepair = json["isRepair"]?.bool ?? false
        self.silent = json["silent"]?.bool ?? false
        self.requestedAt = PairingRequest.date(json["ts"])
    }

    /// The name the device gave, else its client id, else "Unknown device".
    public var title: String { self.displayName ?? self.clientId ?? "Unknown device" }
    public var fingerprint: String { DeviceFingerprint.format(self.deviceId) }
    /// Node-role devices can run commands for agents; approving them needs Full Management.
    public var requestsNodeRole: Bool { self.roles.contains { $0 != "operator" } }
    /// "iPhone · ios · 192.168.1.20".
    /// "iPadOS · OpenClaw app".
    public var subtitle: String {
        DeviceLabels.summary(platform: self.platform, family: self.deviceFamily, clientId: self.clientId, mode: self.clientMode)
    }
}

/// A device the Gateway trusts (`device.pair.list` `paired[]`).
public struct PairedDevice: Identifiable, Hashable, Sendable {
    public let deviceId: String
    public let publicKey: String?
    public let displayName: String?
    /// A name an operator gave it (`device.pair.rename`); shown instead of `displayName`.
    public internal(set) var operatorLabel: String?
    public let platform: String?
    public let deviceFamily: String?
    public let clientId: String?
    public let clientMode: String?
    public let remoteIp: String?
    /// How it was approved: `owner`, `silent`, `trusted-cidr`, `trusted-proxy`, `ssh-verified`, `bootstrap`.
    public let approvedVia: String?
    public let lastSeenReason: String?
    public let roles: [String]
    public let scopes: [String]
    public let tokens: [DeviceTokenSummary]
    /// The device holds a live Gateway connection right now.
    public let connected: Bool
    public let createdAt: Date?
    public let approvedAt: Date?
    public let lastSeenAt: Date?

    public var id: String { self.deviceId }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let deviceId = json["deviceId"]?.text else { return nil }
        self.deviceId = deviceId
        self.publicKey = json["publicKey"]?.text
        self.displayName = json["displayName"]?.text
        self.operatorLabel = json["operatorLabel"]?.text
        self.platform = json["platform"]?.text
        self.deviceFamily = json["deviceFamily"]?.text
        self.clientId = json["clientId"]?.text
        self.clientMode = json["clientMode"]?.text
        self.remoteIp = json["remoteIp"]?.text
        self.approvedVia = json["approvedVia"]?.text
        self.lastSeenReason = json["lastSeenReason"]?.text
        self.roles = DeviceRecords.roles(json)
        self.scopes = DeviceRecords.strings(json["scopes"])
        self.tokens = (json["tokens"]?.array ?? []).compactMap(DeviceTokenSummary.init)
        self.connected = json["connected"]?.bool ?? false
        self.createdAt = PairingRequest.date(json["createdAtMs"])
        self.approvedAt = PairingRequest.date(json["approvedAtMs"])
        self.lastSeenAt = PairingRequest.date(json["lastSeenAtMs"])
    }

    /// The operator's label, else the device's own name, else its client id, else its short fingerprint.
    public var title: String {
        self.operatorLabel ?? self.displayName ?? self.clientId ?? DeviceFingerprint.short(self.deviceId)
    }

    public var fingerprint: String { DeviceFingerprint.format(self.deviceId) }
    public var isNode: Bool { self.roles.contains("node") }

    /// "Mac · macos · 10.0.0.4".
    /// "macOS · OpenClaw CLI".
    public var subtitle: String {
        DeviceLabels.summary(platform: self.platform, family: self.deviceFamily, clientId: self.clientId, mode: self.clientMode)
    }

    /// Scopes of the live (unrevoked) tokens, else the approved `scopes`.
    public var effectiveScopes: [String] {
        var seen: Set<String> = []
        let live = self.tokens.filter { !$0.isRevoked }.flatMap(\.scopes).filter { seen.insert($0).inserted }
        return live.isEmpty ? self.scopes : live
    }

    /// Latest activity: the device's last seen time, else its newest token use.
    public var lastActive: Date? {
        ([self.lastSeenAt] + self.tokens.map(\.lastUsedAt)).compactMap(\.self).max()
    }

    /// "Approved by owner", "Approved from a trusted network"…
    public var approvedViaLabel: String? {
        switch self.approvedVia {
        case nil: nil
        case "owner": "Approved by an operator"
        case "silent": "Approved automatically (local)"
        case "trusted-cidr": "Approved from a trusted network"
        case "trusted-proxy": "Approved by a trusted proxy"
        case "ssh-verified": "Approved over SSH"
        case "bootstrap": "Approved with a setup code"
        case let other?: "Approved via \(other)"
        }
    }
}

/// A node known to the Gateway (`node.list` `nodes[]`): a device that runs commands for agents.
public struct GatewayNode: Identifiable, Hashable, Sendable {
    public let nodeId: String
    public internal(set) var displayName: String?
    public let platform: String?
    public let version: String?
    public let deviceFamily: String?
    public let modelIdentifier: String?
    public let remoteIp: String?
    /// `approved`, `pending-approval`, `pending-reapproval` or `unapproved`.
    public let approvalState: String?
    public let caps: [String]
    public let commands: [String]
    public let paired: Bool
    public let connected: Bool
    public let active: Bool
    /// Runs from the Gateway host's own install.
    public let gatewayLocal: Bool
    public let lastSeenAt: Date?
    public let approvedAt: Date?
    public let connectedAt: Date?

    public var id: String { self.nodeId }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let nodeId = json["nodeId"]?.text else { return nil }
        self.nodeId = nodeId
        self.displayName = json["displayName"]?.text
        self.platform = json["platform"]?.text
        self.version = json["version"]?.text ?? json["coreVersion"]?.text
        self.deviceFamily = json["deviceFamily"]?.text
        self.modelIdentifier = json["modelIdentifier"]?.text
        self.remoteIp = json["remoteIp"]?.text
        self.approvalState = json["approvalState"]?.text
        self.caps = DeviceRecords.strings(json["caps"])
        self.commands = DeviceRecords.strings(json["commands"])
        self.paired = json["paired"]?.bool ?? false
        self.connected = json["connected"]?.bool ?? false
        self.active = json["active"]?.bool ?? false
        self.gatewayLocal = json["gatewayLocal"]?.bool ?? false
        self.lastSeenAt = PairingRequest.date(json["lastSeenAtMs"] ?? json["lastConnectedAtMs"])
        self.approvedAt = PairingRequest.date(json["approvedAtMs"])
        self.connectedAt = PairingRequest.date(json["connectedAtMs"])
    }

    public var title: String { self.displayName ?? DeviceFingerprint.short(self.nodeId) }

    /// "mac · 2026.9.1 · 10.0.0.4".
    public var subtitle: String {
        [self.deviceFamily ?? self.platform, self.version, self.remoteIp].compactMap(\.self).joined(separator: " · ")
    }

    public var approvalLabel: String? {
        switch self.approvalState {
        case nil, "approved": nil
        case "pending-approval": "Waiting for approval"
        case "pending-reapproval": "Waiting for re-approval"
        case "unapproved": "Not approved"
        case let other?: other
        }
    }
}

/// A device id is hex(sha256(public key)), so it doubles as the key's fingerprint.
public enum DeviceFingerprint {
    /// "a1b2 c3d4 e5f6 0718 …" (groups of four, first 32 hex digits), for comparing with `openclaw devices list`.
    public static func format(_ deviceId: String) -> String {
        let hex = deviceId.lowercased()
        guard hex.count > 8 else { return hex }
        let prefix = Array(hex.prefix(32))
        let groups = stride(from: 0, to: prefix.count, by: 4).map { String(prefix[$0 ..< min($0 + 4, prefix.count)]) }
        return groups.joined(separator: " ") + (hex.count > 32 ? " …" : "")
    }

    /// The first 8 hex digits.
    public static func short(_ deviceId: String) -> String { String(deviceId.lowercased().prefix(8)) }

    /// "a1b2c3d4…9f0e": the first 8 and last 4 hex digits, for rows.
    public static func compact(_ deviceId: String) -> String {
        let hex = deviceId.lowercased()
        guard hex.count > 12 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(4))"
    }

    /// "just now", "5 min ago".
    public static func ago(_ date: Date, now: Date) -> String { PairingRequest.ago(date, now: now) }
}

/// Friendly names for the platform and client fields of pairing records.
public enum DeviceLabels {
    /// "macOS", "iPadOS", "iOS", "Android"…; nil when unknown.
    public static func platform(_ platform: String?, family: String?) -> String? {
        let raw = (platform ?? "").lowercased()
        let family = family?.lowercased() ?? ""
        switch raw {
        case "macos", "darwin", "mac": return "macOS"
        case "ios", "ipados": return family == "ipad" || raw == "ipados" ? "iPadOS" : "iOS"
        case "android": return "Android"
        case "linux": return "Linux"
        case "windows", "win32": return "Windows"
        case "": return family.isEmpty ? nil : (family == "mac" ? "macOS" : family == "ipad" ? "iPadOS" : family == "iphone" ? "iOS" : nil)
        default: return platform
        }
    }

    /// "OpenClaw CLI", "OpenClaw app", "Control UI", "Node host"; the raw client id otherwise.
    public static func client(_ clientId: String?, mode: String?) -> String? {
        guard let clientId, !clientId.isEmpty else { return nil }
        switch clientId {
        case "cli", "openclaw-cli": return "OpenClaw CLI"
        case "openclaw-ios", "openclaw-macos", "openclaw-android": return mode == "node" ? "OpenClaw node" : "OpenClaw app"
        case "openclaw-control-ui", "webchat", "webchat-ui": return "Control UI"
        case "node-host": return "Node host"
        default: return clientId
        }
    }

    static func summary(platform: String?, family: String?, clientId: String?, mode: String?) -> String {
        [Self.platform(platform, family: family), Self.client(clientId, mode: mode)].compactMap(\.self).joined(separator: " · ")
    }
}

enum DeviceRecords {
    static func strings(_ value: JSONValue?) -> [String] {
        var seen: Set<String> = []
        return (value?.array ?? []).compactMap(\.text).filter { seen.insert($0).inserted }
    }

    static func roles(_ json: JSONValue) -> [String] {
        var seen: Set<String> = []
        return ([json["role"]?.text].compactMap(\.self) + Self.strings(json["roles"])).filter { seen.insert($0).inserted }
    }
}

// MARK: Model

/// Operator devices and nodes paired with one Gateway (`device.pair.*`, `node.list`, `node.rename`,
/// `node.pair.remove`). Listing needs `operator.pairing` (Full Management covers it); approving,
/// rejecting, renaming and removing *other* devices need `operator.admin`, since the Gateway only lets
/// a device-token caller without it manage itself. Kept current by `device.pair.*` / `node.pair.*` events.
@MainActor
@Observable
public final class DeviceManagementModel {
    public struct Notice: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
    }

    public nonisolated static let listMethod = "device.pair.list"
    public nonisolated static let approveMethod = "device.pair.approve"
    public nonisolated static let rejectMethod = "device.pair.reject"
    public nonisolated static let removeMethod = "device.pair.remove"
    public nonisolated static let renameMethod = "device.pair.rename"
    public nonisolated static let nodeListMethod = "node.list"
    public nonisolated static let nodeRenameMethod = "node.rename"
    public nonisolated static let nodeRemoveMethod = "node.pair.remove"
    public nonisolated static let requestedEvent = "device.pair.requested"
    public nonisolated static let resolvedEvent = "device.pair.resolved"
    public nonisolated static let changedEvent = "device.pair.changed"
    public nonisolated static let nodeRequestedEvent = "node.pair.requested"
    public nonisolated static let nodeResolvedEvent = "node.pair.resolved"
    public nonisolated static let pairingScope = "operator.pairing"
    /// The label limit of `device.pair.rename`.
    public nonisolated static let maxLabelLength = 64

    /// Newest first.
    public private(set) var pending: [PendingDeviceRequest] = []
    /// This device first, then connected ones, then by last activity.
    public private(set) var paired: [PairedDevice] = []
    /// Connected first, then by name.
    public private(set) var nodes: [GatewayNode] = []
    public private(set) var hasLoaded = false
    public private(set) var loadState = OperationState.idle
    public private(set) var nodesLoaded = false
    public private(set) var nodesLoadState = OperationState.idle
    /// Mutations in flight or failed, by `request:`, `device:` or `node:` key.
    public private(set) var operations: [String: OperationState] = [:]
    public private(set) var notice: Notice?
    /// The device id Pincer connects with, to flag "This device" and warn before removing it.
    public let selfDeviceId: String

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private var methods: @MainActor () -> Set<String>?
    @ObservationIgnored private var scopes: @MainActor () -> [String]
    @ObservationIgnored private let allowsWritesWithoutAdmin: Bool
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nodesGeneration = 0
    /// Requests answered since the latest list was sent; its reply may predate that.
    @ObservationIgnored private var resolvedSinceList: Set<String> = []
    @ObservationIgnored private var removedSinceList: Set<String> = []
    private var rejectedMethods: Set<String> = []
    private var scopeDenied = false
    private var manageDenied = false

    /// Built in `GatewayStore.init` (the sidebar badge reads it from a view body, #119); `bind(hello:)`
    /// connects it to the store's hello once the store exists.
    init(connection: GatewayConnection, selfDeviceId: String, allowsWritesWithoutAdmin: Bool) {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { nil }
        self.scopes = { [] }
        self.selfDeviceId = selfDeviceId
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    func bind(hello: @escaping @MainActor () -> GatewayHello?) {
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
    }

    /// For checks and previews: `methods` is the advertised method list (nil or empty when unknown),
    /// `scopes` the connection's scopes, `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [GatewayConnection.adminScope] },
                selfDeviceId: String = "",
                allowsWritesWithoutAdmin: Bool = false,
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
        self.selfDeviceId = selfDeviceId
        self.allowsWritesWithoutAdmin = allowsWritesWithoutAdmin
    }

    // MARK: Capability

    /// Whether the Gateway has `method`: advertised (or the list is unknown) and not rejected.
    public func supports(_ method: String) -> Bool {
        if self.rejectedMethods.contains(method) { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(method)
    }

    public var supported: Bool { self.supports(Self.listMethod) }
    public var nodesSupported: Bool { self.supports(Self.nodeListMethod) }

    private var hasAdmin: Bool { self.scopes().contains(GatewayConnection.adminScope) }

    /// Listing needs `operator.pairing`, which `operator.admin` covers.
    public var canView: Bool {
        self.allowsWritesWithoutAdmin || self.hasAdmin || self.scopes().contains(Self.pairingScope)
    }

    /// Answering requests and removing other devices needs Full Management (`operator.admin`).
    public var canManage: Bool {
        guard !self.manageDenied else { return false }
        return self.allowsWritesWithoutAdmin || self.hasAdmin
    }

    /// The page should explain how to get access instead of listing.
    public var needsAccess: Bool { !self.canView || self.scopeDenied }

    /// Why the lists are read-only, or nil when they can be changed.
    public var readOnlyReason: String? { self.canManage ? nil : Self.readOnlyMessage }

    public var canRename: Bool { self.canManage && self.supports(Self.renameMethod) }
    public var canRenameNodes: Bool { self.canManage && self.supports(Self.nodeRenameMethod) }
    public var canRemoveNodes: Bool { self.canManage && self.supports(Self.nodeRemoveMethod) }

    public func isSelf(_ device: PairedDevice) -> Bool { !self.selfDeviceId.isEmpty && device.deviceId == self.selfDeviceId }
    public func isSelf(_ request: PendingDeviceRequest) -> Bool { !self.selfDeviceId.isEmpty && request.deviceId == self.selfDeviceId }
    public func isSelf(_ node: GatewayNode) -> Bool { !self.selfDeviceId.isEmpty && node.nodeId == self.selfDeviceId }

    /// Devices waiting for approval, for the sidebar badge.
    public var pendingCount: Int {
        guard self.supported, !self.needsAccess else { return 0 }
        return self.pending.count
    }

    public func operation(for request: PendingDeviceRequest) -> OperationState { self.operations[Self.key(request)] ?? .idle }
    public func operation(for device: PairedDevice) -> OperationState { self.operations[Self.key(device)] ?? .idle }
    public func operation(for node: GatewayNode) -> OperationState { self.operations[Self.key(node)] ?? .idle }

    public func clearNotice() { self.notice = nil }

    private static func key(_ request: PendingDeviceRequest) -> String { "request:\(request.requestId)" }
    private static func key(_ device: PairedDevice) -> String { "device:\(device.deviceId)" }
    private static func key(_ node: GatewayNode) -> String { "node:\(node.nodeId)" }

    // MARK: Loading

    /// Fetches pending and paired devices (`device.pair.list` with `{}`).
    public func load() async {
        guard self.supported, self.canView else {
            self.hasLoaded = true
            return
        }
        self.generation += 1
        let generation = self.generation
        self.resolvedSinceList = []
        self.removedSinceList = []
        self.loadState = .running
        do {
            let result = try await self.request(Self.listMethod, [:])
            guard generation == self.generation else { return }
            self.apply(result)
            self.scopeDenied = false
            self.loadState = .idle
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            guard generation == self.generation else { return }
            self.rejectedMethods.insert(Self.listMethod)
            self.pending = []
            self.paired = []
            self.loadState = .idle
        } catch let error where PairingInboxModel.isMissingScope(error) {
            guard generation == self.generation else { return }
            self.scopeDenied = true
            self.loadState = .failed(Self.needsAccessMessage)
        } catch {
            guard generation == self.generation else { return }
            self.loadState = .failed(Self.message(for: error))
        }
        self.hasLoaded = true
    }

    public func refresh() async { await self.load() }

    /// One list when Gateway Settings opens, so the sidebar badge has a count.
    public func seed() async {
        guard !self.hasLoaded, !self.loadState.isRunning, self.supported, self.canView else { return }
        await self.load()
    }

    /// Fetches the node inventory (`node.list` with `{}`).
    public func loadNodes() async {
        guard self.nodesSupported else {
            self.nodesLoaded = true
            return
        }
        self.nodesGeneration += 1
        let generation = self.nodesGeneration
        self.nodesLoadState = .running
        do {
            let result = try await self.request(Self.nodeListMethod, [:])
            guard generation == self.nodesGeneration else { return }
            let activeId = result["activeNodeId"]?.text
            var seen: Set<String> = []
            let nodes = (result["nodes"]?.array ?? []).compactMap(GatewayNode.init).filter { seen.insert($0.nodeId).inserted }
            self.nodes = Self.sorted(nodes, activeId: activeId)
            let ids = Set(self.nodes.map { Self.key($0) })
            self.operations = self.operations.filter { !$0.key.hasPrefix("node:") || ids.contains($0.key) }
            self.nodesLoadState = .idle
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            guard generation == self.nodesGeneration else { return }
            self.rejectedMethods.insert(Self.nodeListMethod)
            self.nodes = []
            self.nodesLoadState = .idle
        } catch {
            guard generation == self.nodesGeneration else { return }
            self.nodesLoadState = .failed(Self.message(for: error))
        }
        self.nodesLoaded = true
    }

    private func apply(_ result: JSONValue) {
        var seenRequests: Set<String> = []
        var pending = (result["pending"]?.array ?? []).compactMap(PendingDeviceRequest.init)
            .filter { !self.resolvedSinceList.contains($0.requestId) && seenRequests.insert($0.requestId).inserted }
        for row in self.pending where self.operations[Self.key(row)]?.isRunning == true && !seenRequests.contains(row.requestId) {
            pending.append(row)
        }
        var seenDevices: Set<String> = []
        var paired = (result["paired"]?.array ?? []).compactMap(PairedDevice.init)
            .filter { !self.removedSinceList.contains($0.deviceId) && seenDevices.insert($0.deviceId).inserted }
        for row in self.paired where self.operations[Self.key(row)]?.isRunning == true && !seenDevices.contains(row.deviceId) {
            paired.append(row)
        }
        self.pending = Self.sorted(pending)
        self.paired = self.sorted(paired)
        let keys = Set(self.pending.map { Self.key($0) } + self.paired.map { Self.key($0) })
        self.operations = self.operations.filter { $0.key.hasPrefix("node:") || keys.contains($0.key) }
    }

    static func sorted(_ requests: [PendingDeviceRequest]) -> [PendingDeviceRequest] {
        requests.sorted { ($0.requestedAt ?? .distantPast) > ($1.requestedAt ?? .distantPast) }
    }

    func sorted(_ devices: [PairedDevice]) -> [PairedDevice] {
        devices.sorted { lhs, rhs in
            let lhsSelf = self.isSelf(lhs), rhsSelf = self.isSelf(rhs)
            if lhsSelf != rhsSelf { return lhsSelf }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.deviceId < rhs.deviceId
        }
    }

    static func sorted(_ nodes: [GatewayNode], activeId: String?) -> [GatewayNode] {
        nodes.sorted { lhs, rhs in
            let lhsActive = lhs.active || lhs.nodeId == activeId, rhsActive = rhs.active || rhs.nodeId == activeId
            if lhsActive != rhsActive { return lhsActive }
            if lhs.connected != rhs.connected { return lhs.connected }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: Events

    /// `device.pair.requested` adds a request, `device.pair.resolved` drops it (and reloads to pick up
    /// the approved device), `device.pair.changed` reloads; `node.pair.*` reload the node inventory.
    func handle(event: String, payload: JSONValue) {
        guard self.canView else { return }
        switch event {
        case Self.requestedEvent:
            guard let request = PendingDeviceRequest(payload) else { return }
            self.resolvedSinceList.remove(request.requestId)
            var pending = self.pending.filter { $0.requestId != request.requestId }
            pending.append(request)
            self.pending = Self.sorted(pending)
        case Self.resolvedEvent:
            if let requestId = payload["requestId"]?.text {
                self.pending.removeAll { $0.requestId == requestId }
                self.resolvedSinceList.insert(requestId)
                self.operations[Self.key(requestId: requestId)] = nil
            }
            if self.hasLoaded, payload["decision"]?.text == "approved" { self.reloadSoon() }
        case Self.changedEvent:
            if self.hasLoaded { self.reloadSoon() }
        case Self.nodeRequestedEvent, Self.nodeResolvedEvent:
            if event == Self.nodeResolvedEvent, payload["decision"]?.text == "removed", let nodeId = payload["nodeId"]?.text {
                self.nodes.removeAll { $0.nodeId == nodeId }
            }
            if self.nodesLoaded { self.reloadNodesSoon() }
        default:
            break
        }
    }

    private static func key(requestId: String) -> String { "request:\(requestId)" }

    private func reloadSoon() { Task { await self.load() } }
    private func reloadNodesSoon() { Task { await self.loadNodes() } }

    /// The connection dropped: forget everything, including the badge.
    func reset() {
        self.generation += 1
        self.nodesGeneration += 1
        self.pending = []
        self.paired = []
        self.nodes = []
        self.hasLoaded = false
        self.nodesLoaded = false
        self.loadState = .idle
        self.nodesLoadState = .idle
        self.operations = [:]
        self.resolvedSinceList = []
        self.removedSinceList = []
        self.notice = nil
    }

    /// A reconnect may bring new scopes or a newer Gateway.
    func handleReconnect() {
        self.rejectedMethods = []
        self.scopeDenied = false
        self.manageDenied = false
    }

    // MARK: Actions

    /// Lets the device connect with the roles and scopes it asked for. True when the request is gone.
    @discardableResult
    public func approve(_ request: PendingDeviceRequest) async -> Bool {
        let key = Self.key(request)
        guard self.canManage, self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            let result = try await self.request(Self.approveMethod, ["requestId": .string(request.requestId)])
            self.dropRequest(request)
            if let device = result["device"].flatMap(PairedDevice.init) {
                self.removedSinceList.remove(device.deviceId)
                self.paired = self.sorted(self.paired.filter { $0.deviceId != device.deviceId } + [device])
            } else {
                await self.load()
            }
            return true
        } catch {
            return await self.requestFailed(request, error: error)
        }
    }

    /// Turns the device away. It can ask again. True when the request is gone.
    @discardableResult
    public func reject(_ request: PendingDeviceRequest) async -> Bool {
        let key = Self.key(request)
        guard self.canManage, self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            _ = try await self.request(Self.rejectMethod, ["requestId": .string(request.requestId)])
            self.dropRequest(request)
            return true
        } catch {
            return await self.requestFailed(request, error: error)
        }
    }

    /// Revokes the device: the Gateway forgets it and disconnects it; it has to pair again. Removing
    /// this device disconnects Pincer. True when the device is gone.
    @discardableResult
    public func remove(_ device: PairedDevice) async -> Bool {
        let key = Self.key(device)
        guard self.canManage, self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            _ = try await self.request(Self.removeMethod, ["deviceId": .string(device.deviceId)])
            self.dropDevice(device)
            return true
        } catch {
            if Self.isUnknown(error, "unknown deviceid") {
                self.dropDevice(device)
                self.notice = Notice(text: Self.staleDeviceMessage)
                await self.load()
                return true
            }
            return self.deviceFailed(key, error: error)
        }
    }

    /// Gives the device a name on this Gateway (1–64 characters). True when saved.
    @discardableResult
    public func rename(_ device: PairedDevice, to label: String) async -> Bool {
        let key = Self.key(device)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.canRename, !trimmed.isEmpty, self.operations[key]?.isRunning != true else { return false }
        guard trimmed.count <= Self.maxLabelLength else {
            self.operations[key] = .failed(Self.labelTooLongMessage)
            return false
        }
        self.operations[key] = .running
        do {
            let result = try await self.request(Self.renameMethod, ["deviceId": .string(device.deviceId), "label": .string(trimmed)])
            self.operations[key] = nil
            // The `device.pair.changed` reload can supersede the load below, so show the new name now.
            if let index = self.paired.firstIndex(where: { $0.deviceId == device.deviceId }) {
                self.paired[index].operatorLabel = result["label"]?.text ?? trimmed
            }
            await self.load()
            return true
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            self.rejectedMethods.insert(Self.renameMethod)
            self.operations[key] = .failed(Self.renameUnsupportedMessage)
            return false
        } catch {
            return self.deviceFailed(key, error: error)
        }
    }

    /// Renames a node (`node.rename`). True when saved.
    @discardableResult
    public func renameNode(_ node: GatewayNode, to name: String) async -> Bool {
        let key = Self.key(node)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.canRenameNodes, !trimmed.isEmpty, self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            let result = try await self.request(Self.nodeRenameMethod, ["nodeId": .string(node.nodeId), "displayName": .string(trimmed)])
            self.operations[key] = nil
            if let index = self.nodes.firstIndex(where: { $0.nodeId == node.nodeId }) {
                self.nodes[index].displayName = result["displayName"]?.text ?? trimmed
            }
            await self.loadNodes()
            return true
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            self.rejectedMethods.insert(Self.nodeRenameMethod)
            self.operations[key] = .failed(Self.nodeUnsupportedMessage)
            return false
        } catch {
            return self.deviceFailed(key, error: error)
        }
    }

    /// Unpairs a node (`node.pair.remove`): revokes its node role and disconnects it. True when it's gone.
    @discardableResult
    public func removeNode(_ node: GatewayNode) async -> Bool {
        let key = Self.key(node)
        guard self.canRemoveNodes, self.operations[key]?.isRunning != true else { return false }
        self.operations[key] = .running
        do {
            _ = try await self.request(Self.nodeRemoveMethod, ["nodeId": .string(node.nodeId)])
            self.nodes.removeAll { $0.nodeId == node.nodeId }
            self.operations[key] = nil
            await self.loadNodes()
            if self.hasLoaded { await self.load() }
            return true
        } catch let error where GatewayConfigClient.isUnknownMethod(error) {
            self.rejectedMethods.insert(Self.nodeRemoveMethod)
            self.operations[key] = .failed(Self.nodeUnsupportedMessage)
            return false
        } catch {
            if Self.isUnknown(error, "unknown nodeid") {
                self.nodes.removeAll { $0.nodeId == node.nodeId }
                self.operations[key] = nil
                self.notice = Notice(text: Self.staleNodeMessage)
                await self.loadNodes()
                return true
            }
            return self.deviceFailed(key, error: error)
        }
    }

    private func dropRequest(_ request: PendingDeviceRequest) {
        self.pending.removeAll { $0.requestId == request.requestId }
        self.operations[Self.key(request)] = nil
        self.resolvedSinceList.insert(request.requestId)
    }

    private func dropDevice(_ device: PairedDevice) {
        self.paired.removeAll { $0.deviceId == device.deviceId }
        self.operations[Self.key(device)] = nil
        self.removedSinceList.insert(device.deviceId)
    }

    private func requestFailed(_ request: PendingDeviceRequest, error: Error) async -> Bool {
        if Self.isUnknown(error, "unknown requestid") {
            self.dropRequest(request)
            self.notice = Notice(text: Self.staleRequestMessage)
            await self.load()
            return true
        }
        return self.deviceFailed(Self.key(request), error: error)
    }

    private func deviceFailed(_ key: String, error: Error) -> Bool {
        if PairingInboxModel.isMissingScope(error) || Self.isDenied(error) {
            self.operations[key] = nil
            if !self.allowsWritesWithoutAdmin { self.manageDenied = true }
            self.notice = Notice(text: Self.readOnlyMessage)
            return false
        }
        self.operations[key] = .failed(Self.message(for: error))
        return false
    }

    // MARK: Errors

    public nonisolated static let needsAccessTitle = "Managing devices needs Full Management"
    public nonisolated static let needsAccessMessage =
        "You can only see this device. Turn on Full Management under Connection, then approve this device on the Gateway host."
    public nonisolated static let readOnlyMessage =
        "Approving, rejecting and revoking devices needs Full Management. Turn it on under Connection."
    public nonisolated static let unsupportedMessage = "This Gateway can't manage devices."
    public nonisolated static let disconnectedMessage = "Connect to a Gateway to manage devices."
    public nonisolated static let staleRequestMessage = "This request was already handled or expired."
    public nonisolated static let staleDeviceMessage = "This device was already revoked."
    public nonisolated static let staleNodeMessage = "This node was already removed."
    public nonisolated static let labelTooLongMessage = "Names can be at most 64 characters."
    public nonisolated static let renameUnsupportedMessage = "This Gateway can't rename devices. Update OpenClaw to rename them here."
    public nonisolated static let nodeUnsupportedMessage = "This Gateway can't change nodes. Update OpenClaw to manage them here."
    public nonisolated static let revokeMessage = "This device will be disconnected and must pair again to reconnect."
    /// Shown before revoking the device Pincer itself connects with.
    public nonisolated static func selfRevokeWarning(gateway: String) -> String {
        "This is the device Pincer is using to connect. Pincer will be disconnected from \(gateway) and can't reconnect until its new pairing request is approved, from another device with Full Management or with openclaw devices approve on the Gateway host."
    }

    static func isUnknown(_ error: Error, _ needle: String) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST" else { return false }
        return message.lowercased().contains(needle)
    }

    /// The Gateway's `device pairing … denied` / `node … denied` replies: the caller may only manage itself.
    static func isDenied(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST" else { return false }
        return message.lowercased().hasSuffix(" denied")
    }

    static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(_, message, _) = error else { return error.localizedDescription }
        if PairingInboxModel.isMissingScope(error) { return Self.needsAccessMessage }
        return message
    }
}
