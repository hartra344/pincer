import Foundation
import Observation

extension GatewayStore {
    // MARK: Synced preferences

    /// Server names and chat icons you set live in your gateway user preferences, so every device
    /// signed in as you shows the same ones. The local copy keeps them instant and works offline.
    static let serverNamesPref = "pincer.serverNames"
    /// SF Symbol names by session key. Kept in prefs because `sessions.patch` only accepts
    /// emoji, OpenClaw glyph ids or SVG for a session's `icon`.
    static let chatIconsPref = "pincer.chatIcons"
    /// Custom "#RRGGBB" colors by session key. Kept in prefs because `sessions.patch` only accepts
    /// OpenClaw's named colors for a session's `color`.
    static let chatColorsPref = "pincer.chatColors"
    /// Group names to display positions, for gateways without the `sessions.groups.*` catalog.
    static let groupsPref = "pincer.groups"
    /// Session keys to positions within their group, so chats can be arranged by hand.
    static let chatOrderPref = "pincer.chatOrder"
    /// SF Symbol names by group name. The gateway's group catalog has no icon field.
    static let groupIconsPref = "pincer.groupIcons"
    /// Gateway Health issues dismissed until they change (`until:<fingerprint>`) or always ignored
    /// (`always`), by issue id.
    static let healthDismissalsPref = "pincer.healthDismissals"

    struct SyncedMap {
        let pref: String
        let local: ReferenceWritableKeyPath<GatewayStore, [String: String]>
        let syncedDefaultsKey: String
    }

    var syncedMaps: [SyncedMap] {
        [
            SyncedMap(pref: Self.serverNamesPref, local: \.serverNameOverrides,
                      syncedDefaultsKey: "pincer.serverNamesSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatIconsPref, local: \.chatIcons,
                      syncedDefaultsKey: "pincer.chatIconsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatColorsPref, local: \.chatColors,
                      syncedDefaultsKey: "pincer.chatColorsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.groupsPref, local: \.groupPositions,
                      syncedDefaultsKey: "pincer.groupsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.chatOrderPref, local: \.chatPositions,
                      syncedDefaultsKey: "pincer.chatOrderSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.groupIconsPref, local: \.groupIcons,
                      syncedDefaultsKey: "pincer.groupIconsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Reactions.prefKey, local: \.reactions,
                      syncedDefaultsKey: "pincer.reactionsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: Self.healthDismissalsPref, local: \.healthDismissals,
                      syncedDefaultsKey: "pincer.healthDismissalsSynced.\(self.id.uuidString)"),
            SyncedMap(pref: AvatarPreferences.prefKey, local: \.avatarChoices,
                      syncedDefaultsKey: "pincer.avatarsSynced.\(self.id.uuidString)"),
        ]
    }

    func syncedMap(_ pref: String) -> SyncedMap { self.syncedMaps.first { $0.pref == pref }! }

    private static func names(from value: JSONValue?) -> [String: String] {
        (value?.object ?? [:]).compactMapValues { $0.string?.nilIfEmpty }
    }

    private static func json(_ names: [String: String]) -> JSONValue {
        .object(names.mapValues(JSONValue.string))
    }

    /// Reads a map from the gateway; `nil` when this connection has no user profile to store it.
    private func fetchRemoteMap(_ pref: String) async -> [String: String]?? {
        guard let result = try? await self.connection.request(
            "users.prefs.get", ["keys": [.string(pref)]], timeout: 15),
            result["status"]?.string == "ok"
        else { return nil }
        let value = result["entries"]?[pref]
        return .some(value == nil || value == .null ? nil : Self.names(from: value))
    }

    /// Reads several maps with one `users.prefs.get`; nil when there's no user profile or the read failed.
    private func fetchRemoteMaps(_ prefs: [String]) async -> [String: [String: String]?]? {
        guard let result = try? await self.connection.request(
            "users.prefs.get", ["keys": .array(prefs.map(JSONValue.string))], timeout: 15),
            result["status"]?.string == "ok"
        else { return nil }
        var maps: [String: [String: String]?] = [:]
        for pref in prefs {
            let value = result["entries"]?[pref]
            maps[pref] = (value == nil || value == .null) ? .some(nil) : .some(Self.names(from: value))
        }
        return maps
    }

    func pullMaps(_ maps: [SyncedMap], epoch: Int? = nil) async {
        guard let fetched = await self.fetchRemoteMaps(maps.map(\.pref)) else { return }
        if let epoch, !self.isCurrent(epoch) { return }
        for map in maps { await self.pull(map, fetched: fetched[map.pref] ?? nil) }
    }

    /// Everything synced through `users.prefs`, except the group maps `loadGroups` owns, in one read.
    func pullBootstrapPrefs(epoch: Int) async {
        let prefs: Set<String> = [
            Self.serverNamesPref, Self.chatIconsPref, Self.chatColorsPref, Self.chatOrderPref,
            Self.groupIconsPref, Reactions.prefKey, Self.healthDismissalsPref, AvatarPreferences.prefKey,
        ]
        await self.pullMaps(self.syncedMaps.filter { prefs.contains($0.pref) }, epoch: epoch)
        let queued = self.queuedAvatarChoices
        self.queuedAvatarChoices = [:]
        for (entry, value) in queued { self.setAvatarChoice(value, for: entry) }
        guard self.isCurrent(epoch) else { return }
        self.avatarPrefsPulledEpoch = epoch
        self.recordAvatarSeeds()
    }

    func pullServerNames() async { await self.pull(self.syncedMap(Self.serverNamesPref)) }
    func pullChatIcons() async { await self.pull(self.syncedMap(Self.chatIconsPref)) }
    func pullChatColors() async { await self.pull(self.syncedMap(Self.chatColorsPref)) }

    func pull(_ map: SyncedMap) async {
        guard let fetched = await self.fetchRemoteMap(map.pref) else { return }
        await self.pull(map, fetched: fetched)
    }

    func pull(_ map: SyncedMap, fetched: [String: String]?) async {
        let defaults = self.defaults
        if !defaults.bool(forKey: map.syncedDefaultsKey) {
            // First sync from this device: keep values already set here, remote wins on conflicts.
            var merged = self[keyPath: map.local]
            merged.merge(fetched ?? [:]) { _, remote in remote }
            if merged != (fetched ?? [:]) {
                guard await self.writeRemoteMap(map.pref, merged, expected: fetched) else { return }
            }
            defaults.set(true, forKey: map.syncedDefaultsKey)
            self.remotePrefMaps[map.pref] = merged
            self[keyPath: map.local] = merged
            return
        }
        self.remotePrefMaps[map.pref] = fetched ?? [:]
        // Local changes still being written win over what the gateway had a moment ago.
        var local = fetched ?? [:]
        for (id, value) in self.pendingPrefChanges[map.pref] ?? [:] { local[id] = value }
        if self[keyPath: map.local] != local { self[keyPath: map.local] = local }
    }

    func push(_ map: SyncedMap, _ id: String, _ value: String?) async {
        await self.push(map, [id: value])
    }

    /// Writes one after another per pref, so quick successive changes (toggling reactions) don't
    /// conflict with each other, and a pull in between keeps them.
    func push(_ map: SyncedMap, _ changes: [String: String?]) async {
        guard !changes.isEmpty, self.defaults.bool(forKey: map.syncedDefaultsKey) else { return }
        var pending = self.pendingPrefChanges[map.pref] ?? [:]
        for (id, value) in changes { pending.updateValue(value, forKey: id) }
        self.pendingPrefChanges[map.pref] = pending
        let previous = self.prefPushes[map.pref]
        let task = Task {
            await previous?.value
            await self.write(map, changes)
            for (id, value) in changes where self.pendingPrefChanges[map.pref]?[id] == .some(value) {
                self.pendingPrefChanges[map.pref]?.removeValue(forKey: id)
            }
        }
        self.prefPushes[map.pref] = task
        await task.value
    }

    private func write(_ map: SyncedMap, _ changes: [String: String?]) async {
        // Optimistic write; on a conflict (another device changed it at the same time) re-read and retry.
        for _ in 0..<3 {
            let cached = self.remotePrefMaps[map.pref]
            guard let current = cached == nil ? await self.fetchRemoteMap(map.pref) : .some(cached) else { return }
            var next = current ?? [:]
            for (id, value) in changes { next[id] = value }
            if await self.writeRemoteMap(map.pref, next, expected: current) {
                self.remotePrefMaps[map.pref] = next
                return
            }
            self.remotePrefMaps[map.pref] = nil
        }
    }

    func consumeOwnWrite(_ pref: String) -> Bool {
        guard let at = self.ownPrefWrites.removeValue(forKey: pref) else { return false }
        return ContinuousClock.now - at < .seconds(3)
    }

    private func writeRemoteMap(_ key: String, _ names: [String: String], expected: [String: String]?) async -> Bool {
        self.ownPrefWrites[key] = .now
        let ok = await self.sendRemoteMap(key, names, expected: expected)
        if !ok { self.ownPrefWrites.removeValue(forKey: key) }
        return ok
    }

    private func sendRemoteMap(_ key: String, _ names: [String: String], expected: [String: String]?) async -> Bool {
        let entries: JSONValue = .object([key: names.isEmpty ? .null : Self.json(names)])
        if self.prefsSupportsExpected {
            let params: JSONValue = ["entries": entries, "expectedEntries": .object([key: expected.map(Self.json) ?? .null])]
            do {
                let result = try await self.connection.request("users.prefs.set", params, timeout: 15)
                return result["status"]?.string == "ok"
            } catch let GatewayError.rpc(_, message, _) where message.contains("expectedEntries") {
                // Older gateways don't accept compare-and-set; fall back to last write wins.
                self.prefsSupportsExpected = false
            } catch {
                return false
            }
        }
        guard let result = try? await self.connection.request("users.prefs.set", ["entries": entries], timeout: 15) else { return false }
        return result["status"]?.string == "ok"
    }

    // MARK: Reactions

    /// Your emoji on one message, in the order added.
    public func myReactions(sessionKey: String, messageId: String) -> [String] {
        Reactions.decode(self.reactions[Reactions.prefEntryKey(sessionKey: sessionKey, messageId: messageId)])
    }

    /// Replaces your emoji on one message on every device; an empty list deletes the entry.
    func setReactions(_ emoji: [String], sessionKey: String, messageId: String) {
        let key = Reactions.prefEntryKey(sessionKey: sessionKey, messageId: messageId)
        let value = Reactions.encode(emoji)
        guard self.reactions[key] != value else { return }
        self.reactions[key] = value
        Task { await self.push(self.syncedMap(Reactions.prefKey), key, value) }
    }

    /// Whether reactions can be mirrored to bridged channels. Unlike older methods, `message.action`
    /// is only tried when the Gateway advertises it.
    public var supportsMessageAction: Bool {
        self.hello?.methods.contains("message.action") ?? false
    }

    /// Whether the Gateway advertises `method` (false before hello).
    public func advertises(_ method: String) -> Bool {
        self.hello?.methods.contains(method) ?? false
    }

    /// The Sessions page: `sessions.list` is advertised (or the Gateway doesn't list its methods).
    public var supportsSessionManager: Bool {
        guard let methods = self.hello?.methods, !methods.isEmpty else { return self.hello != nil }
        return methods.contains(SessionManager.listMethod)
    }

    /// A session's history changed on the Gateway (rewind, branch switch, recovery) or it was deleted:
    /// its cached transcript is dropped, and an open chat reloads from scratch. A rewind's cut message
    /// goes back into an empty composer. Deduplicated per key while one is under way (the RPC reply
    /// and its `sessions.changed` both land here).
    func transcriptChanged(key: String, change: SessionTranscriptChange) async {
        if case let .changed(text?) = change, !text.isEmpty {
            if let chat = self.chats[key] {
                if chat.draft.text.isEmpty { chat.draft.text = text }
            } else if await DraftStore.load(gatewayId: self.id, sessionKey: key) == nil {
                await DraftStore.save(ComposerDraft(text: text), gatewayId: self.id, sessionKey: key)
            }
        }
        guard self.invalidatingTranscripts.insert(key).inserted else { return }
        defer { self.invalidatingTranscripts.remove(key) }
        await self.cancelHeadlessFill(key)
        if change == .deleted {
            self.chats.removeValue(forKey: key)?.stopCaching()
            self.residency.forget(key)
            self.setSession(nil, for: key)
            self.outbox.removeSession(key)
            if self.selectedKey == key { self.selectedKey = self.defaultSessionKey }
            await self.forgetTranscript(key)
        } else if let chat = self.chats[key], !chat.isDehydrated {
            // The whole cache entry goes (messages and tool details) before the refetch can save.
            await chat.reloadAfterHistoryChange { await self.forgetTranscript(key) }
        } else {
            await self.forgetTranscript(key)
        }
    }

    /// Chats that dropped out of `sessions.list` (deleted while we were away, or just archived, or past
    /// the list limit). Only those the Gateway confirms gone are forgotten: an unfiltered list that
    /// wasn't cut at its limit no longer has them. A chat with sends still in the outbox is kept: it may
    /// not exist on the Gateway yet, and forgetting it would drop what the user queued.
    func forgetVanishedSessions(_ keys: Set<String>) async {
        guard !keys.isEmpty, self.state.isConnected else { return }
        let params: [String: JSONValue] = ["limit": 300, "archived": "all"]
        guard let list = try? await self.connection.request("sessions.list", .object(params), timeout: 30),
              let rows = list["sessions"]?.array,
              rows.count < 300
        else { return }
        let listed = Set(rows.compactMap(SessionRow.init).map(\.key))
        for key in keys.subtracting(listed) where self.sessions[key] == nil && self.outbox.entries(for: key).isEmpty {
            await self.transcriptChanged(key: key, change: .deleted)
        }
    }

    /// Drops a chat's cached transcript and its messages from search; a refetch re-adds both.
    private func forgetTranscript(_ key: String) async {
        await TranscriptCache.remove(gatewayId: self.id, sessionKey: key, root: self.cacheRoot)
        if MessageIndex.status(gatewayId: self.id, root: self.cacheRoot) != .unavailable {
            await self.messageIndex.remove(sessionKey: key)
        }
    }

    /// The Skills page: `skills.status` is advertised.
    public var supportsSkills: Bool { self.advertises(Skills.statusMethod) }
    /// The MCP Servers page: the config is readable (`config.get`).
    public var supportsMCPServers: Bool { self.settings.hasLoaded && self.settings.configSupported }
    /// The chat's Tools & Policy inspector: `tools.effective` is advertised.
    public var supportsToolsEffective: Bool { self.advertises(ToolsPolicy.effectiveMethod) }
    /// An agent's Tools inspector: `tools.catalog` is advertised.
    public var supportsToolsCatalog: Bool { self.advertises(ToolsPolicy.catalogMethod) }

    /// A new inspector for one chat. Create it outside `body` (e.g. in `.task`).
    public func toolsInspector(sessionKey: String) -> ToolsInspectorModel {
        let agentId = self.sessions[sessionKey]?.agentId ?? SessionKey.agentId(from: sessionKey)
        return ToolsInspectorModel(scope: .session(key: sessionKey, agentId: agentId),
                                   methods: { [weak self] in self?.hello?.methods }, request: self.toolsRequest)
    }

    /// A new inspector for one agent, using its most recent chat (if any) for live policy.
    public func toolsInspector(agentId: String) -> ToolsInspectorModel {
        let chats = self.sessions.values.filter { $0.agentId == agentId && !$0.isArchived }
        let session = chats.first(where: \.isMain) ?? chats.max { $0.activityMs < $1.activityMs }
        return ToolsInspectorModel(scope: .agent(agentId, sessionKey: session?.key),
                                   methods: { [weak self] in self?.hello?.methods }, request: self.toolsRequest)
    }

    private var toolsRequest: ToolsInspectorModel.Request {
        let connection = self.connection
        return { method, params in try await connection.request(method, params, timeout: 30) }
    }

    /// `message.action` calls the built-in demo received, oldest first (for checks; empty for real Gateways).
    public func demoRecordedActions() async -> [JSONValue] {
        await self.connection.demoRecordedActions()
    }

    // MARK: Health dismissals

    /// Saves and syncs dismissals the health model changed. A no-op, with no write to the observable
    /// `healthDismissals` and no `users.prefs` push, when they're already in place.
    func applyHealthDismissals(_ changes: [String: String?]) {
        let effective = changes.filter { self.healthDismissals[$0.key] != $0.value }
        guard !effective.isEmpty else { return }
        var next = self.healthDismissals
        for (id, value) in effective { next[id] = value }
        self.healthDismissals = next
        self.healthDismissalPushes += 1
        Task { await self.push(self.syncedMap(Self.healthDismissalsPref), effective) }
    }

    /// Forgets this device's copy of the dismissals when the gateway is removed. The gateway's
    /// user prefs keep them for other devices, and re-adding the gateway pulls them back.
    func forgetLocalHealthDismissals() {
        self.defaults.removeObject(forKey: "pincer.healthDismissals.\(self.id.uuidString)")
        self.defaults.removeObject(forKey: "pincer.healthDismissalsSynced.\(self.id.uuidString)")
    }

    // MARK: Avatars

    /// Sets (or with `nil`, clears back to Auto) an agent's character on every device.
    public func setAvatarCreature(_ creature: AvatarCreature?, for agentId: String) {
        self.setAvatarChoice(creature?.rawValue, for: agentId)
    }

    /// Sets Pixel or Plush on every device.
    public func setAvatarRenderStyle(_ style: AvatarRenderStyle) {
        self.setAvatarChoice(style.rawValue, for: AvatarPreferences.renderStyleEntry)
    }

    /// The identity seed this Gateway first saw for the agent, so renaming it keeps its pet.
    public func avatarSeed(for agent: AgentSummary) -> String {
        self.avatarChoices[AvatarPreferences.seedEntry(for: agent.id)]
            ?? AvatarStyle.identitySeed(name: agent.name, agentId: agent.id)
    }

    /// Records the seed of every agent without one, in one push. Never overwrites a seed. Before this
    /// device's first sync they're only kept here: the first sync's merge writes them in its one
    /// write, with the Gateway's older seeds winning. After that it waits for this connection's
    /// prefs pull, so another device's older seed wins.
    func recordAvatarSeeds() {
        let firstSyncPending = !self.defaults.bool(forKey: self.syncedMap(AvatarPreferences.prefKey).syncedDefaultsKey)
        guard firstSyncPending || self.avatarPrefsPulledEpoch == self.connectionEpoch else { return }
        var added: [String: String?] = [:]
        for agent in self.agents {
            let entry = AvatarPreferences.seedEntry(for: agent.id)
            if self.avatarChoices[entry] == nil {
                added[entry] = AvatarStyle.identitySeed(name: agent.name, agentId: agent.id)
            }
        }
        guard !added.isEmpty else { return }
        for (entry, value) in added { self.avatarChoices[entry] = value }
        guard !firstSyncPending else { return }
        let map = self.syncedMap(AvatarPreferences.prefKey)
        Task { await self.push(map, added) }
    }

    /// Drops a deleted agent's seed and character here and on the Gateway.
    func clearAvatarChoices(for agentId: String) {
        self.queuedAvatarChoices.removeValue(forKey: agentId)
        var removed: [String: String?] = [:]
        for entry in [AvatarPreferences.seedEntry(for: agentId), agentId] where self.avatarChoices[entry] != nil {
            self.avatarChoices[entry] = nil
            removed[entry] = .some(nil)
        }
        guard !removed.isEmpty else { return }
        let map = self.syncedMap(AvatarPreferences.prefKey)
        Task { await self.push(map, removed) }
    }

    private func setAvatarChoice(_ value: String?, for entry: String) {
        guard self.state.isConnected else {
            self.queuedAvatarChoices[entry] = .some(value)
            return
        }
        // A choice made now beats one queued while offline and not yet replayed.
        self.queuedAvatarChoices.removeValue(forKey: entry)
        guard self.avatarChoices[entry] != value else { return }
        self.avatarChoices[entry] = value
        Task { await self.push(self.syncedMap(AvatarPreferences.prefKey), entry, value) }
    }
}
