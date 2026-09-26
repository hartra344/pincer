import Foundation

// MARK: Records

/// A channel account whose DM policy is `pairing` (`channels.pairing.list` `accounts`).
public struct PairingAccount: Identifiable, Hashable, Sendable {
    public let channel: String
    public let channelLabel: String
    public let accountId: String
    public let accountLabel: String?
    public let notifySupported: Bool

    public var id: String { "\(self.channel):\(self.accountId)" }
    /// The account's label, else its id.
    public var displayName: String { self.accountLabel ?? self.accountId }
    /// "Telegram · Home bot".
    public var summary: String { "\(self.channelLabel) · \(self.displayName)" }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let channel = json["channel"]?.text, let accountId = json["accountId"]?.text else { return nil }
        self.channel = channel
        self.channelLabel = json["channelLabel"]?.text ?? ApprovalRecord.humanized(channel)
        self.accountId = accountId
        self.accountLabel = json["accountLabel"]?.text
        self.notifySupported = json["notifySupported"]?.bool ?? false
    }
}

/// Someone who messaged a pairing-policy channel account and is waiting to be let in.
/// `senderId` comes from the channel and is the identifier to trust; `metadata` (name,
/// username…) is whatever the sender set and isn't verified. `requestId` is opaque.
public struct PairingRequest: Identifiable, Hashable, Sendable {
    public let requestId: String
    public let channel: String
    public let channelLabel: String
    public let accountId: String
    public let accountLabel: String?
    public let senderId: String
    /// What the channel calls the id, e.g. "Telegram user id".
    public let senderLabel: String
    public let metadata: [String: String]
    public let createdAt: Date?
    public let lastSeenAt: Date?
    public let expiresAt: Date?
    public let notifySupported: Bool

    public var id: String { "\(self.channel):\(self.accountId):\(self.requestId)" }

    public init?(_ json: JSONValue) {
        guard json.object != nil, let requestId = json["requestId"]?.text, let channel = json["channel"]?.text,
              let accountId = json["accountId"]?.text, let senderId = json["senderId"]?.text
        else { return nil }
        self.requestId = requestId
        self.channel = channel
        self.channelLabel = json["channelLabel"]?.text ?? ApprovalRecord.humanized(channel)
        self.accountId = accountId
        self.accountLabel = json["accountLabel"]?.text
        self.senderId = senderId
        self.senderLabel = json["senderLabel"]?.text ?? "Sender ID"
        var metadata: [String: String] = [:]
        for (key, value) in json["metadata"]?.object ?? [:] {
            if let text = value.text { metadata[key] = text }
        }
        self.metadata = metadata
        self.createdAt = Self.date(json["createdAt"])
        self.lastSeenAt = Self.date(json["lastSeenAt"])
        self.expiresAt = Self.date(json["expiresAt"])
        self.notifySupported = json["notifySupported"]?.bool ?? false
    }

    /// The sender's name, else "@username", else the sender id.
    public var title: String {
        if let name = self.metadataValue("name") { return name }
        if let username = self.metadataValue("username") { return username.hasPrefix("@") ? username : "@\(username)" }
        return self.senderId
    }

    /// "Telegram user id: 4411".
    public var senderLine: String { "\(self.senderLabel): \(self.senderId)" }
    /// "Telegram · Home bot".
    public var accountLine: String { "\(self.channelLabel) · \(self.accountLabel ?? self.accountId)" }

    /// Metadata other than the name and username, with readable keys, sorted.
    public var details: [(label: String, value: String)] {
        self.metadata
            .filter { !["name", "username"].contains($0.key.lowercased()) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (Self.humanizedKey($0.key), $0.value) }
    }

    public func isExpired(at now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Whether the sender asked again well after the first request.
    public var showsLastSeen: Bool {
        guard let createdAt, let lastSeenAt else { return false }
        return lastSeenAt.timeIntervalSince(createdAt) > 60
    }

    /// "Requested 5 min ago · Expires in 55 min", "… · Expired", plus "Last seen 1 min ago" when it differs.
    public func timing(at now: Date = .now) -> String {
        var parts: [String] = []
        if let createdAt { parts.append("Requested \(Self.ago(createdAt, now: now))") }
        if self.isExpired(at: now) {
            parts.append("Expired")
        } else if let expiresAt {
            parts.append("Expires in \(Self.duration(expiresAt.timeIntervalSince(now)))")
        }
        if self.showsLastSeen, let lastSeenAt { parts.append("Last seen \(Self.ago(lastSeenAt, now: now))") }
        return parts.joined(separator: " · ")
    }

    private func metadataValue(_ key: String) -> String? {
        self.metadata.first { $0.key.lowercased() == key }?.value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        if case let .number(ms) = value { return Date(timeIntervalSince1970: ms / 1000) }
        guard let text = value.text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? "just now" : "\(Self.duration(seconds)) ago"
    }

    /// "5 min", "2 hr", "under a minute".
    public static func duration(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle = .short) -> String {
        guard seconds >= 60 else { return "under a minute" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        let minutes = (seconds / 60).rounded() * 60
        return formatter.string(from: minutes) ?? "\(Int(minutes / 60)) min"
    }

    /// `firstName` / `first_name` → "First name".
    static func humanizedKey(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for character in key {
            if character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let sentence = words.map { $0.lowercased() }.joined(separator: " ")
        guard let first = sentence.first else { return key }
        return first.uppercased() + sentence.dropFirst()
    }
}

// MARK: Model

/// Pending DM pairing requests for one Gateway (`channels.pairing.*`): senders who messaged a
/// channel account with `dmPolicy: "pairing"` and wait for someone to let them in. There is no
/// event for new requests, so the list is fetched on open, on reconnect and by polling.
@MainActor
@Observable
public final class PairingInboxModel {
    public struct Notice: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
    }

    public struct Limits: Hashable, Sendable {
        public let pendingPerAccount: Int?
        public let ttl: TimeInterval?
    }

    public nonisolated static let listMethod = "channels.pairing.list"
    public nonisolated static let approveMethod = "channels.pairing.approve"
    public nonisolated static let dismissMethod = "channels.pairing.dismiss"
    public nonisolated static let pairingScope = "operator.pairing"
    public nonisolated static let pollInterval: Duration = .seconds(30)

    public private(set) var accounts: [PairingAccount] = []
    /// Newest first.
    public private(set) var requests: [PairingRequest] = []
    public private(set) var commandOwnerConfigured = true
    public private(set) var limits: Limits?
    public private(set) var hasLoaded = false
    public private(set) var loadState = OperationState.idle
    /// Approve/dismiss in flight or failed, by request id.
    public private(set) var operations: [String: OperationState] = [:]
    /// A one-off message for the page ("Approved, but…").
    public private(set) var notice: Notice?
    /// Nil shows every channel.
    public var channelFilter: String?

    public typealias Request = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let methods: @MainActor () -> Set<String>?
    @ObservationIgnored private let scopes: @MainActor () -> [String]
    @ObservationIgnored private var generation = 0
    private var unknownMethod = false
    private var scopeDenied = false
    /// Rows approved or dismissed since the latest list was sent; its reply may predate that.
    @ObservationIgnored private var removedSinceList: Set<String> = []

    init(connection: GatewayConnection, hello: @escaping @MainActor () -> GatewayHello?) {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.methods = { hello()?.methods }
        self.scopes = { hello()?.scopes ?? [] }
    }

    /// For checks and previews: `methods` is the Gateway's advertised method list (nil or empty
    /// when unknown), `scopes` the scopes it granted, `request` answers RPCs.
    public init(methods: @escaping @MainActor () -> Set<String>? = { nil },
                scopes: @escaping @MainActor () -> [String] = { [PairingInboxModel.pairingScope] },
                request: @escaping Request)
    {
        self.request = request
        self.methods = methods
        self.scopes = scopes
    }

    // MARK: State

    /// False when the Gateway has no `channels.pairing.list`.
    public var supported: Bool {
        if self.unknownMethod { return false }
        guard let methods = self.methods(), !methods.isEmpty else { return true }
        return methods.contains(Self.listMethod)
    }

    /// Whether this connection may list and answer pairing requests: `operator.pairing`, or
    /// `operator.admin`, which covers every operator scope.
    public var canManage: Bool {
        let scopes = Set(self.scopes())
        return scopes.contains(GatewayConnection.adminScope) || scopes.contains(Self.pairingScope)
    }

    /// The page should explain how to get access instead of listing.
    public var needsAccess: Bool { !self.canManage || self.scopeDenied }

    /// "Make them the command owner" is only offered to Full Management while nobody owns commands.
    public var canBootstrapCommandOwner: Bool {
        !self.commandOwnerConfigured && self.scopes().contains(GatewayConnection.adminScope)
    }

    /// Requests that haven't expired, for the sidebar badge.
    public func pendingCount(at now: Date = .now) -> Int {
        guard self.supported, !self.needsAccess else { return 0 }
        return self.requests.count { !$0.isExpired(at: now) }
    }

    /// Distinct channels among the pairing accounts, in first-seen order.
    public var channels: [(id: String, label: String)] {
        var seen: Set<String> = []
        var channels: [(id: String, label: String)] = []
        for account in self.accounts where seen.insert(account.channel).inserted {
            channels.append((account.channel, account.channelLabel))
        }
        return channels
    }

    /// The channel filter only helps when accounts span more than one channel.
    public var showsChannelFilter: Bool { self.channels.count >= 2 }

    /// Requests for the chosen channel, newest first.
    public var visibleRequests: [PairingRequest] {
        guard self.showsChannelFilter, let filter = self.channelFilter else { return self.requests }
        return self.requests.filter { $0.channel == filter }
    }

    /// Pairing accounts on the chosen channel.
    public var visibleAccounts: [PairingAccount] {
        guard self.showsChannelFilter, let filter = self.channelFilter else { return self.accounts }
        return self.accounts.filter { $0.channel == filter }
    }

    /// The chosen channel's label, when the list is filtered.
    public var channelFilterLabel: String? {
        guard self.showsChannelFilter, let filter = self.channelFilter else { return nil }
        return self.channels.first { $0.id == filter }?.label
    }

    public func operation(for request: PairingRequest) -> OperationState { self.operations[request.id] ?? .idle }

    public func clearNotice() { self.notice = nil }

    // MARK: Loading

    /// Fetches every pending request (`channels.pairing.list` with `{}`; filtering is local).
    /// Rows with an approve or dismiss in flight are kept as they are.
    public func load() async {
        guard self.supported, self.canManage else {
            self.hasLoaded = true
            return
        }
        self.generation += 1
        let generation = self.generation
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
            self.unknownMethod = true
            self.clearList()
            self.loadState = .idle
        } catch let error where Self.isMissingScope(error) {
            guard generation == self.generation else { return }
            self.scopeDenied = true
            self.loadState = .failed(Self.missingScopeMessage)
        } catch {
            guard generation == self.generation else { return }
            self.loadState = .failed(Self.message(for: error))
        }
        self.hasLoaded = true
    }

    public func refresh() async { await self.load() }

    /// A periodic refresh: skipped while a load is already running.
    public func poll() async {
        guard !self.loadState.isRunning else { return }
        await self.load()
    }

    /// One list when Gateway Settings opens, so the sidebar badge has a count.
    public func seed() async {
        guard !self.hasLoaded, !self.loadState.isRunning, self.supported, self.canManage else { return }
        await self.load()
    }

    /// The connection dropped: forget everything, including the badge.
    func reset() {
        self.generation += 1
        self.clearList()
        self.hasLoaded = false
        self.loadState = .idle
        self.operations = [:]
        self.removedSinceList = []
        self.unknownMethod = false
        self.scopeDenied = false
        self.notice = nil
    }

    private func apply(_ result: JSONValue) {
        self.accounts = (result["accounts"]?.array ?? []).compactMap(PairingAccount.init)
        var seen: Set<String> = []
        var fresh = (result["requests"]?.array ?? []).compactMap(PairingRequest.init)
            .filter { !self.removedSinceList.contains($0.id) && seen.insert($0.id).inserted }
        let busy = self.requests.filter { self.operations[$0.id]?.isRunning == true }
        for row in busy {
            if let index = fresh.firstIndex(where: { $0.id == row.id }) { fresh[index] = row } else { fresh.append(row) }
        }
        self.requests = Self.sorted(fresh)
        let ids = Set(self.requests.map(\.id))
        self.operations = self.operations.filter { ids.contains($0.key) }
        self.commandOwnerConfigured = result["commandOwnerConfigured"]?.bool ?? true
        let limits = result["limits"]
        let ttlMs = limits?["ttlMs"]?.double
        self.limits = limits?.object == nil ? nil
            : Limits(pendingPerAccount: limits?["pendingPerAccount"]?.int, ttl: ttlMs.map { $0 / 1000 })
        if let filter = self.channelFilter, !self.channels.contains(where: { $0.id == filter }) { self.channelFilter = nil }
    }

    private func clearList() {
        self.accounts = []
        self.requests = []
        self.limits = nil
        self.commandOwnerConfigured = true
    }

    static func sorted(_ requests: [PairingRequest]) -> [PairingRequest] {
        requests.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    // MARK: Actions

    /// `channels.pairing.approve` params: `notify` only when the channel can notify, and
    /// `bootstrapCommandOwner` only when chosen and allowed.
    public nonisolated static func approveParams(_ request: PairingRequest, notify: Bool, makeCommandOwner: Bool,
                                                 canBootstrapCommandOwner: Bool) -> JSONValue
    {
        var params: [String: JSONValue] = [
            "channel": .string(request.channel), "accountId": .string(request.accountId),
            "requestId": .string(request.requestId),
        ]
        if request.notifySupported { params["notify"] = .bool(notify) }
        if makeCommandOwner, canBootstrapCommandOwner { params["bootstrapCommandOwner"] = true }
        return .object(params)
    }

    public nonisolated static func dismissParams(_ request: PairingRequest) -> JSONValue {
        [
            "channel": .string(request.channel), "accountId": .string(request.accountId),
            "requestId": .string(request.requestId),
        ]
    }

    /// Lets the sender DM the agent on this account. True when the request is gone.
    @discardableResult
    public func approve(_ request: PairingRequest, notify: Bool = true, makeCommandOwner: Bool = false) async -> Bool {
        guard self.operations[request.id]?.isRunning != true else { return false }
        guard !request.isExpired() else {
            self.notice = Notice(text: Self.expiredMessage)
            return false
        }
        let params = Self.approveParams(request, notify: notify, makeCommandOwner: makeCommandOwner,
                                        canBootstrapCommandOwner: self.canBootstrapCommandOwner)
        self.operations[request.id] = .running
        do {
            let result = try await self.request(Self.approveMethod, params)
            self.remove(request)
            var notes: [String] = []
            if result["notification"]?.text == "failed" { notes.append("Approved, but the sender couldn't be notified.") }
            switch result["commandOwnerBootstrap"]?.text {
            case "configured", "already-configured": self.commandOwnerConfigured = true
            case "unavailable": notes.append("Approved, but they couldn't be made the command owner.")
            default: break
            }
            if !notes.isEmpty { self.notice = Notice(text: notes.joined(separator: " ")) }
            return true
        } catch {
            return await self.failed(request, error: error)
        }
    }

    /// Removes the request without blocking the sender, who can ask again. True when it's gone.
    @discardableResult
    public func dismiss(_ request: PairingRequest) async -> Bool {
        guard self.operations[request.id]?.isRunning != true else { return false }
        self.operations[request.id] = .running
        do {
            _ = try await self.request(Self.dismissMethod, Self.dismissParams(request))
            self.remove(request)
            return true
        } catch {
            return await self.failed(request, error: error)
        }
    }

    private func remove(_ request: PairingRequest) {
        self.requests.removeAll { $0.id == request.id }
        self.operations[request.id] = nil
        self.removedSinceList.insert(request.id)
    }

    private func failed(_ request: PairingRequest, error: Error) async -> Bool {
        let message = Self.message(for: error)
        if Self.isStale(error) {
            self.remove(request)
            self.notice = Notice(text: Self.staleMessage)
            await self.load()
            return true
        }
        if Self.isNotPairing(error) {
            self.operations[request.id] = nil
            self.notice = Notice(text: message)
            await self.load()
            return false
        }
        self.operations[request.id] = .failed(message)
        return false
    }

    // MARK: Errors

    public nonisolated static let missingScopeMessage = "Reviewing pairing requests needs Full Management access."
    public nonisolated static let commandOwnerScopeMessage = "Making them the command owner needs Full Management access."
    public nonisolated static let staleMessage = "This request was already handled or expired."
    public nonisolated static let expiredMessage = "This request expired."

    static func isMissingScope(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, _, details) = error else { return false }
        return code == "MISSING_SCOPE" || code == "FORBIDDEN" || details?["code"]?.text == "MISSING_SCOPE"
    }

    static func isStale(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST" else { return false }
        return message.lowercased().contains("no longer exists")
    }

    static func isNotPairing(_ error: Error) -> Bool {
        guard case let GatewayError.rpc(code, message, _) = error, code == "INVALID_REQUEST" else { return false }
        return message.lowercased().contains("does not use dm pairing")
    }

    static func message(for error: Error) -> String {
        guard case let GatewayError.rpc(_, message, details) = error else { return error.localizedDescription }
        if Self.isMissingScope(error) {
            let missing = details?["missingScope"]?.text ?? details?["scope"]?.text
            return missing == GatewayConnection.adminScope ? Self.commandOwnerScopeMessage : Self.missingScopeMessage
        }
        return message
    }
}
