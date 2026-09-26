import Foundation
import Observation

/// Top-level state: saved Gateways ("servers" in the rail) and which one is selected.
@MainActor
@Observable
public final class AppModel {
    public private(set) var gateways: [GatewayStore] = []
    public var selectedGatewayId: UUID? {
        didSet {
            // Shared so the Share extension starts on the same gateway.
            SharedContainer.defaults.set(self.selectedGatewayId?.uuidString, forKey: Self.selectedGatewayKey)
            self.updateVisible()
        }
    }
    public let notifier = Notifier.shared
    public let push = PushRegistrar.shared
    /// Counts `open(_:)` calls (from notifications), so the UI can bring the chat on screen.
    public private(set) var openRequests = 0
    /// Find in Chat to open with a chat, e.g. after picking a message search result.
    public private(set) var findRequest: FindRequest?
    /// Chats visited, for Back/Forward and the palette's recent chats.
    public private(set) var history = ChatHistory<Notifier.Target>()
    public var appIsActive = true {
        didSet {
            self.notifier.appIsActive = self.appIsActive
            if self.appIsActive, !oldValue { self.gateways.forEach { $0.reconnectIfNeeded() } }
            if !self.appIsActive, oldValue {
                let gateways = self.gateways
                Task { for gateway in gateways { await gateway.flushDrafts() } }
            }
        }
    }

    public static let selectedGatewayKey = "pincer.selectedGateway"

    public init() {
        let profiles = GatewayProfileStore.load()
        SharedContainer.shareKeychainItems(for: profiles)
        self.gateways = profiles.map(GatewayStore.init(profile:))
        let saved = (SharedContainer.defaults.string(forKey: Self.selectedGatewayKey)
            ?? UserDefaults.standard.string(forKey: Self.selectedGatewayKey)).flatMap(UUID.init(uuidString:))
        self.selectedGatewayId = self.gateways.first { $0.id == saved }?.id ?? self.gateways.first?.id
        self.notifier.onOpen = { [weak self] target in self?.open(target) }
        self.notifier.onApprovalAction = { [weak self] gatewayId, approvalId, decision in
            guard let gateway = self?.gateways.first(where: { $0.id == gatewayId }) else { return }
            Task { await gateway.resolveApproval(id: approvalId, decision: decision) }
        }
    }

    public func start() {
        guard !self.started else { return }
        self.started = true
        self.notifier.pushDelivers = { [weak self] id in self?.push.isActive(id) ?? false }
        self.notifier.isConnected = { [weak self] id in
            self?.gateways.first { $0.id == id }?.state.isConnected ?? false
        }
        self.push.onTokenChange = { [weak self] in self?.syncPush() }
        self.notifier.activate()
        for gateway in self.gateways {
            gateway.notifier = self.notifier
            gateway.start()
        }
        self.updateVisible()
    }

    @ObservationIgnored private var started = false

    /// Re-registers push on every connected gateway, e.g. after the token or a setting changed.
    public func syncPush() {
        for gateway in self.gateways {
            Task { await self.push.sync(gateway) }
        }
    }

    public var selectedGateway: GatewayStore? {
        self.gateways.first { $0.id == self.selectedGatewayId }
    }

    public var totalUnread: Int { self.gateways.reduce(0) { $0 + $1.totalUnread } }

    /// Call whenever the selected session changes so notifications for it are suppressed.
    public func updateVisible() {
        guard let gateway = self.selectedGateway, let key = gateway.selectedKey else {
            self.notifier.visible = nil
            return
        }
        let target = Notifier.Target(gatewayId: gateway.id, sessionKey: key)
        self.notifier.visible = target
        self.notifier.clear(target: target)
        self.history.visit(target)
    }

    public func open(_ target: Notifier.Target) {
        guard let gateway = self.gateways.first(where: { $0.id == target.gatewayId }) else { return }
        // Key first, so switching Gateways doesn't briefly record the other Gateway's last chat.
        gateway.selectedKey = gateway.resolveSessionKey(target.sessionKey)
        // A find request for another chat was never taken; it mustn't surface when that chat opens later.
        if let request = self.findRequest,
           request.target.gatewayId != gateway.id
           || gateway.resolveSessionKey(request.target.sessionKey) != gateway.selectedKey
        {
            self.findRequest = nil
        }
        self.selectedGatewayId = gateway.id
        self.updateVisible()
        self.openRequests += 1
    }

    /// Opens a chat with Find in Chat showing `query`, `match` (if given) selected.
    public func open(_ target: Notifier.Target, find query: String, match: TranscriptSearch.Match?) {
        self.findRequest = FindRequest(target: target, query: query, match: match)
        self.open(target)
    }

    /// The pending find request for `target`, once: it's cleared when taken.
    public func takeFindRequest(for target: Notifier.Target) -> FindRequest? {
        guard let request = self.findRequest, request.target == target else { return nil }
        self.findRequest = nil
        return request
    }

    // MARK: Navigation

    public var canGoBack: Bool { self.history.canGoBack }
    public var canGoForward: Bool { self.history.canGoForward }

    public func goBack() {
        if let target = self.history.goBack(where: self.exists) { self.open(target) }
    }

    public func goForward() {
        if let target = self.history.goForward(where: self.exists) { self.open(target) }
    }

    /// Opens the selected Gateway's `number`th pinned chat (1-based, as in ⌘1–⌘9).
    public func openPinned(_ number: Int) {
        guard let gateway = self.selectedGateway, number >= 1 else { return }
        let pinned = gateway.pinnedChats
        guard number <= pinned.count else { return }
        self.open(Notifier.Target(gatewayId: gateway.id, sessionKey: pinned[number - 1].key))
    }

    /// A visited chat can still be opened: its Gateway is saved and, once sessions are listed,
    /// the session is one of them.
    private func exists(_ target: Notifier.Target) -> Bool {
        guard let gateway = self.gateways.first(where: { $0.id == target.gatewayId }) else { return false }
        return gateway.sessions.isEmpty || gateway.sessions[target.sessionKey] != nil
    }

    // MARK: Profiles

    @discardableResult
    public func add(_ profile: GatewayProfile, secret: String?) -> GatewayStore {
        profile.secret = secret
        let store = GatewayStore(profile: profile)
        store.notifier = self.notifier
        self.gateways.append(store)
        self.persist()
        self.selectedGatewayId = store.id
        store.start()
        return store
    }

    /// Selects the built-in demo, adding it the first time.
    public func openDemo() {
        if let existing = self.gateways.first(where: { $0.profile.isDemo }) {
            self.selectedGatewayId = existing.id
        } else {
            self.add(.demo(), secret: nil)
        }
    }

    /// Replaces the connection; the device identity (and thus pairing) is kept.
    public func update(_ profile: GatewayProfile, secret: String?, credentialsChanged: Bool) {
        guard let index = self.gateways.firstIndex(where: { $0.id == profile.id }) else { return }
        self.gateways[index].stop()
        if credentialsChanged {
            profile.secret = secret
            profile.forgetDeviceToken()
        }
        let store = GatewayStore(profile: profile)
        store.notifier = self.notifier
        self.gateways[index] = store
        self.persist()
        store.start()
    }

    public func remove(_ id: UUID) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let store = self.gateways.remove(at: index)
        let push = self.push
        Task {
            await push.forget(store)
            store.stop()
        }
        store.profile.forgetCredentials()
        TranscriptCache.removeAll(gatewayId: id, permanently: true)
        self.history.prune { $0.gatewayId != id }
        DraftStore.removeAll(gatewayId: id)
        self.persist()
        if self.selectedGatewayId == id { self.selectedGatewayId = self.gateways.first?.id }
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), self.gateways.count - 1)
        guard target != index else { return }
        self.gateways.swapAt(index, target)
        self.persist()
    }

    private func persist() {
        GatewayProfileStore.save(self.gateways.map(\.profile))
    }
}

/// Find in Chat to show when a chat opens.
public struct FindRequest: Hashable, Sendable {
    public let id: UUID
    public let target: Notifier.Target
    public let query: String
    public let match: TranscriptSearch.Match?

    public init(target: Notifier.Target, query: String, match: TranscriptSearch.Match?) {
        self.id = UUID()
        self.target = target
        self.query = query
        self.match = match
    }
}
