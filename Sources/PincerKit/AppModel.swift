import Foundation
import PincerPush
import Observation

public struct DictationTarget: Hashable, Sendable {
    public let sceneID: UUID
    public let gatewayID: UUID
    public let sessionKey: String

    public init(sceneID: UUID, gatewayID: UUID, sessionKey: String) {
        self.sceneID = sceneID
        self.gatewayID = gatewayID
        self.sessionKey = sessionKey
    }
}

public struct DictationToggleRequest: Equatable, Sendable {
    public var target: DictationTarget
    public var serial: Int

    public init(target: DictationTarget, serial: Int) {
        self.target = target
        self.serial = serial
    }

    /// A request only reaches its exact chat composer when that pane owns keyboard focus.
    public func matches(target: DictationTarget, paneIsActive: Bool) -> Bool {
        self.target == target && paneIsActive
    }
}

/// Top-level state: saved Gateways ("servers" in the rail) and which one is selected.
@MainActor
@Observable
public final class AppModel {
    public let locationContext: LocationContextModel
    public private(set) var gateways: [GatewayStore] = []
    public var selectedGatewayId: UUID? {
        didSet {
            // Shared so the Share extension starts on the same gateway.
            self.sharedDefaults.set(self.selectedGatewayId?.uuidString, forKey: Self.selectedGatewayKey)
            // A pending demo setup offer is only for while the demo stays selected.
            for gateway in self.gateways where gateway.profile.isDemo && gateway.id != self.selectedGatewayId {
                gateway.setup.withdrawOffer()
            }
            self.updateVisible()
        }
    }
    public let notifier = Notifier.shared
    public let push = PushRegistrar.shared
    /// The palette's request to start or stop dictation in one chat's composer.
    public var dictationToggleRequest: DictationToggleRequest?
    /// Composers currently dictating, keyed by window, Gateway, and chat for the command palette.
    public var dictationActiveTargets: Set<DictationTarget> = []
    /// Available composers, scoped like active targets so another window cannot affect the palette.
    public var dictationAvailableTargets: Set<DictationTarget> = []
    /// Counts `open(_:)` calls (from notifications), so the UI can bring the chat on screen.
    public private(set) var openRequests = 0
    /// Find in Chat to open with a chat, e.g. after picking a message search result.
    public internal(set) var findRequest: FindRequest?
    /// A message to scroll to when its chat opens, e.g. from a `pincer://` link's `message`.
    public internal(set) var messageJump: MessageJump?
    /// A passing note about a link that couldn't be followed (unknown gateway or chat).
    public var routeNotice: RouteNotice?
    /// Counts links to gateways that aren't saved, so a compact layout can show the gateway list.
    public internal(set) var gatewayListRequests = 0
    /// Chats visited, for Back/Forward and the palette's recent chats.
    public private(set) var history = ChatHistory<Notifier.Target>()
    /// Open chat windows per chat (#48), see `ChatWindowRef.swift`.
    @ObservationIgnored var windowRefCounts: [ChatWindowRef: Int] = [:]
    /// False until a scene reports `.active`, so a background launch doesn't prefetch.
    public var appIsActive = false {
        didSet {
            self.notifier.appIsActive = self.appIsActive
            self.locationContext.setActive(self.appIsActive)
            self.gateways.forEach { $0.appIsActive = self.appIsActive }
            if self.appIsActive, !oldValue { self.gateways.forEach { $0.reconnectIfNeeded() } }
            if !self.appIsActive, oldValue {
                let gateways = self.gateways
                Task { for gateway in gateways { await gateway.flushDrafts() } }
            }
        }
    }

    public static let selectedGatewayKey = "pincer.selectedGateway"

    /// Whether the main window shows its selected chat to the user right now: the scene is active
    /// and focused and, on iPhone, the chat is pushed. Set by the main window; chats shown there
    /// are marked read as messages arrive (#374).
    public var mainChatVisible = false {
        didSet { if self.mainChatVisible != oldValue { self.updateVisible() } }
    }

    /// The app's model. Created on first use, by the scene or, when iOS launches Pincer in the
    /// background for a notification action, by `Notifier` before any scene exists.
    public static let shared = AppModel()

    /// Saved gateways and the selected one (shared with the Share extension).
    @ObservationIgnored private let sharedDefaults: UserDefaults
    /// Per-gateway preferences, and where lists saved before the App Group existed are read from.
    @ObservationIgnored private let localDefaults: UserDefaults
    /// The first-run wizard: fills the window with no gateways, and "Add Gateway…" opens it.
    @ObservationIgnored public let firstRun: FirstRunModel

    public convenience init() {
        let storage = Self.storage(appGroupId: SharedContainer.appGroupId, namespace: DevNamespace.current)
        self.init(sharedDefaults: storage.shared, localDefaults: storage.local)
    }

    /// Where saved gateways and per-gateway preferences live. A namespaced build without an App Group
    /// keeps both in one dev suite, so it never reads (or copies profiles from) the shared `.standard`.
    nonisolated static func storage(appGroupId: String?, namespace: String?) -> (shared: UserDefaults, local: UserDefaults) {
        if appGroupId == nil, let suite = SharedContainer.devSuiteName(namespace: namespace).flatMap(UserDefaults.init(suiteName:)) {
            return (suite, suite)
        }
        return (appGroupId.flatMap(UserDefaults.init(suiteName:)) ?? .standard, .standard)
    }

    /// Keeps every preference in `defaults`, e.g. a scratch suite for checks.
    /// `firstRunEnvironment` stands in for the first-run wizard's network checks.
    public convenience init(defaults: UserDefaults, firstRunEnvironment: FirstRunModel.Environment = .live) {
        self.init(sharedDefaults: defaults, localDefaults: defaults, firstRunEnvironment: firstRunEnvironment)
    }

    private init(sharedDefaults: UserDefaults, localDefaults: UserDefaults, firstRunEnvironment: FirstRunModel.Environment = .live) {
        self.sharedDefaults = sharedDefaults
        self.localDefaults = localDefaults
        let locationContext = LocationContextModel(defaults: localDefaults)
        self.locationContext = locationContext
        let profiles = GatewayProfileStore.load(from: sharedDefaults, legacy: localDefaults)
        SharedContainer.shareKeychainItems(for: profiles, defaults: sharedDefaults)
        // One Keychain read at launch, however many Gateways there are.
        let identity = profiles.isEmpty ? nil : DeviceIdentity.loadOrCreate()
        self.identity = identity
        self.gateways = profiles.map {
            let store = GatewayStore(profile: $0, defaults: localDefaults, identity: identity!)
            store.locationContext = locationContext
            store.appIsActive = false
            return store
        }
        self.firstRun = FirstRunModel(defaults: localDefaults, environment: firstRunEnvironment, hasGateways: !profiles.isEmpty)
        let saved = (sharedDefaults.string(forKey: Self.selectedGatewayKey)
            ?? localDefaults.string(forKey: Self.selectedGatewayKey)).flatMap(UUID.init(uuidString:))
        self.selectedGatewayId = self.gateways.first { $0.id == saved }?.id ?? self.gateways.first?.id
        self.notifier.onOpen = { [weak self] target in
            guard let self else { return }
            self.open(self.route(for: target), verifySession: false)
        }
        self.notifier.approvalResolver = { [weak self] gatewayId, approvalId, decision in
            await self?.respondToApproval(gatewayId: gatewayId, approvalId: approvalId, decision: decision) ?? .unknownGateway
        }
        self.firstRun.app = self
        self.notifier.gatewayLookup = { [weak self] id in self?.gateways.first { $0.id == id } }
        self.notifier.pushDelivers = { [weak self] id in self?.push.isActive(id) ?? false }
        self.notifier.isConnected = { [weak self] id in
            self?.gateways.first { $0.id == id }?.state.isConnected ?? false
        }
    }

    /// Answers an approval on exactly the gateway the notification came from. Works before
    /// `start()` (a background launch has no scene): only that gateway is connected then.
    public func respondToApproval(gatewayId: UUID, approvalId: String, decision: String) async -> ApprovalOutcome {
        guard let gateway = self.gateways.first(where: { $0.id == gatewayId }) else { return .unknownGateway }
        if !self.started {
            gateway.notifier = self.notifier
            gateway.start()
        }
        return await gateway.resolveApproval(id: approvalId, decision: decision)
    }

    public func start() {
        guard !self.started else { return }
        self.started = true
        self.push.onTokenChange = { [weak self] in self?.syncPush() }
        self.notifier.activate()
        for gateway in self.gateways {
            gateway.notifier = self.notifier
            gateway.start()
        }
        self.updateVisible()
    }

    @ObservationIgnored private var started = false
    /// The device identity, read from the Keychain once and shared by every Gateway.
    @ObservationIgnored private var identity: DeviceIdentity?

    private func deviceIdentity() -> DeviceIdentity {
        if let identity { return identity }
        let loaded = DeviceIdentity.loadOrCreate()
        self.identity = loaded
        return loaded
    }

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
        for gateway in self.gateways {
            let shown = gateway.id == self.selectedGatewayId && self.mainChatVisible ? gateway.selectedKey : nil
            gateway.setVisibleChat(shown, viewer: GatewayStore.mainViewer)
        }
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
        if !target.sessionKey.isEmpty { gateway.selectedKey = gateway.resolveSessionKey(target.sessionKey) }
        // A find request for another chat was never taken; it mustn't surface when that chat opens later.
        if let request = self.findRequest,
           request.target.gatewayId != gateway.id
           || gateway.resolveSessionKey(request.target.sessionKey) != gateway.selectedKey
        {
            self.findRequest = nil
        }
        if let jump = self.messageJump,
           jump.target.gatewayId != gateway.id
           || gateway.resolveSessionKey(jump.target.sessionKey) != gateway.selectedKey
        {
            self.messageJump = nil
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
        let store = GatewayStore(profile: profile, defaults: self.localDefaults, identity: self.deviceIdentity())
        store.locationContext = self.locationContext
        store.notifier = self.notifier
        store.appIsActive = self.appIsActive
        store.wireBookmarkSync()
        self.gateways.append(store)
        self.persist()
        self.selectedGatewayId = store.id
        store.start()
        self.firstRun.gatewayAdded(store.id)
        return store
    }

    /// Selects the built-in demo, adding it the first time. Try the Demo lands straight in its chat
    /// list: its setup wizard is never offered on its own, only from the gateway menu and ⌘K (#175).
    public func openDemo() {
        if let existing = self.gateways.first(where: { $0.profile.isDemo }) {
            self.selectedGatewayId = existing.id
            existing.setup.withdrawOffer()
            DemoBookmarks.seed(into: BookmarkStore.shared(gatewayId: existing.id))
        } else {
            let demo = self.add(.demo(), secret: nil)
            demo.setup.withdrawOffer()
            DemoBookmarks.seed(into: BookmarkStore.shared(gatewayId: demo.id))
        }
    }

    /// Replaces the connection; the device identity (and thus pairing) is kept.
    public func update(_ profile: GatewayProfile, secret: String?, credentialsChanged: Bool) {
        guard let index = self.gateways.firstIndex(where: { $0.id == profile.id }) else { return }
        let old = self.gateways[index]
        old.stop()
        // The new store reads the outbox this one leaves behind.
        old.retireOutbox()
        if credentialsChanged {
            profile.secret = secret
            profile.forgetDeviceToken()
        }
        let store = GatewayStore(profile: profile, defaults: self.localDefaults, identity: self.deviceIdentity())
        store.locationContext = self.locationContext
        store.notifier = self.notifier
        store.appIsActive = self.appIsActive
        store.outboxRoot = old.outboxRoot
        self.gateways[index] = store
        self.persist()
        store.start()
    }

    public func remove(_ id: UUID) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let store = self.gateways.remove(at: index)
        SpotlightCenter.shared.forgetGateway(id)
        let push = self.push
        Task {
            await push.forget(store)
            store.stop()
            // A prefs pull that was in flight may have written them back.
            store.forgetLocalHealthDismissals()
            store.forgetLocalBookmarks()
            ReactionStore(gatewayId: id.uuidString, defaults: self.localDefaults).removeAll()
        }
        store.profile.forgetCredentials()
        TranscriptCache.removeAll(gatewayId: id, permanently: true)
        self.history.prune { $0.gatewayId != id }
        DraftStore.removeAll(gatewayId: id)
        store.forgetLocalBookmarks()
        ReactionStore(gatewayId: id.uuidString, defaults: self.localDefaults).removeAll()
        store.retireOutbox(save: false)
        store.outbox = Outbox()
        OutboxStore.remove(gatewayId: id, root: store.outboxRoot)
        OutboxAttachmentStore.removeAll(gatewayId: id, root: store.outboxRoot)
        store.forgetLocalHealthDismissals()
        store.forgetGatewayHost()
        self.persist()
        if self.selectedGatewayId == id { self.selectedGatewayId = self.gateways.first?.id }
        self.firstRun.showIfNoGateways()
    }

    /// Deletes every Gateway's cached transcripts and search indexes (Settings' Clear Cache), then
    /// refills them from what's open and from the Gateways. Nothing on the Gateways changes.
    public func clearTranscriptCache() async {
        await Task.detached(priority: .userInitiated) { TranscriptCache.removeEverything() }.value
        for gateway in self.gateways { await gateway.cacheCleared() }
        await self.spotlightCacheCleared()
    }

    /// Unsent messages (queued or failed) across every Gateway.
    public var unsentCount: Int { self.gateways.reduce(0) { $0 + $1.unsentCount } }

    /// Attachment bytes kept on disk for unsent messages, across every Gateway.
    public var outboxAttachmentBytes: Int { self.gateways.reduce(0) { $0 + $1.outboxAttachmentBytes } }

    /// Discards every Gateway's unsent messages (Settings → Storage).
    public func discardUnsentMessages() {
        for gateway in self.gateways { gateway.discardOutbox() }
    }

    public func move(_ id: UUID, by offset: Int) {
        guard let index = self.gateways.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), self.gateways.count - 1)
        guard target != index else { return }
        self.gateways.swapAt(index, target)
        self.persist()
    }

    /// Writes every Gateway's unsent messages to disk now, on this thread: the app is quitting,
    /// and a write still queued might not get to run.
    public func saveOutboxesNow() {
        for store in self.gateways { store.saveOutboxNow() }
    }

    /// Waits for queued outbox writes to land, inside a background task on iOS so a suspended
    /// app doesn't leave the last one unwritten.
    public func flushOutboxWrites() async {
        let end = self.notifier.beginBackgroundActivity("Save unsent messages") {}
        defer { end() }
        for store in self.gateways { await OutboxStore.flushWrites(gatewayId: store.id, root: store.outboxRoot) }
    }

    private func persist() {
        GatewayProfileStore.save(self.gateways.map(\.profile), to: self.sharedDefaults)
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
