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
        let bookmarkShards = (0..<Self.bookmarkShardCount).map { shard in
            SyncedMap(pref: Self.bookmarksPref(shard: shard), local: \GatewayStore.[bookmarkShard: shard],
                      syncedDefaultsKey: Self.bookmarksSyncedKey(shard, self.id))
        }
        return [
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
        ] + bookmarkShards
    }

    static func pendingPrefsKey(_ id: UUID) -> String { "pincer.prefsPending.\(id.uuidString)" }
    static func queuedAvatarsKey(_ id: UUID) -> String { "pincer.avatarsQueued.\(id.uuidString)" }

    static func loadPending<T: Codable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Stores the value as JSON, or removes the key when it's empty.
    func savePending<T: Codable>(_ value: T, isEmpty: Bool, key: String) {
        if isEmpty { self.defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(value) { self.defaults.set(data, forKey: key) }
    }

    func syncedMap(_ pref: String) -> SyncedMap { self.syncedMaps.first { $0.pref == pref }! }

    /// Whether this known preference finished its first remote read and is safe to push.
    package func hasSyncedPreference(_ pref: String) -> Bool {
        guard let map = self.syncedMaps.first(where: { $0.pref == pref }) else { return false }
        return self.defaults.bool(forKey: map.syncedDefaultsKey)
    }

    /// Whether the Gateway advertised both native methods, even if a later request failed. Legacy
    /// prefs may still be the migration source on that connection.
    var advertisedNativeSessionReactions: Bool {
        guard let methods = self.hello?.methods else { return false }
        return methods.contains("session.reactions.set") && methods.contains("session.reactions.list")
    }

    /// Encoding and deterministic eviction can inspect many cached reactions, so keep that work
    /// off the main actor that owns GatewayStore.
    func fitLegacyReactionPrefs(_ entries: [String: String], preserving key: String?) async -> [String: String]? {
        await self.legacyReactionPrefsFitter(entries, key)
    }

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

    /// Returns false when the read failed.
    @discardableResult
    func pullMaps(_ maps: [SyncedMap], epoch: Int? = nil) async -> Bool {
        let fetchEpoch = epoch ?? self.connectionEpoch
        guard let fetched = await self.fetchRemoteMaps(maps.map(\.pref)) else { return false }
        if !self.isCurrent(fetchEpoch) { return true }
        for map in maps {
            if map.pref == Reactions.prefKey {
                await self.pullReactionMap(map, fetched: fetched[map.pref] ?? nil, epoch: fetchEpoch)
                guard self.isCurrent(fetchEpoch) else { return true }
            } else {
                await self.pull(map, fetched: fetched[map.pref] ?? nil)
            }
        }
        return true
    }

    /// Seconds between bootstrap pulls after the read or a first-sync write fails.
    static let bootstrapPullRetryDelays: [Double] = [2, 5, 10, 30, 30]

    /// The epoch is promoted once the bootstrap prefs read has succeeded, so avatar seeds cannot
    /// write from a connection that never saw the Gateway's existing seed map.
    enum AvatarPrefsPullAuthorization {
        static func promotedEpoch(readEpoch: Int, readSucceeded: Bool, currentEpoch: Int) -> Int? {
            guard readSucceeded, readEpoch == currentEpoch else { return nil }
            return readEpoch
        }
    }

    func finishBootstrapPrefsPull(epoch: Int, readSucceeded: Bool) {
        guard self.isCurrent(epoch) else { return }
        self.avatarPrefsPulledEpoch = Self.AvatarPrefsPullAuthorization.promotedEpoch(
            readEpoch: epoch, readSucceeded: readSucceeded, currentEpoch: self.connectionEpoch)
        self.recordAvatarSeeds()
    }

    /// Everything synced through `users.prefs`, except the group maps `loadGroups` owns, in one read.
    func pullBootstrapPrefs(epoch: Int) async {
        let prefs = Set([
            Self.serverNamesPref, Self.chatIconsPref, Self.chatColorsPref, Self.chatOrderPref,
            Self.groupIconsPref, Reactions.prefKey, Self.healthDismissalsPref, AvatarPreferences.prefKey,
        ]).union((0..<Self.bookmarkShardCount).map { Self.bookmarksPref(shard: $0) })
        let maps = self.syncedMaps.filter { prefs.contains($0.pref) }
        // A slow link can time out the first read (or its first-sync write); unsynced maps don't push,
        // so without a retry this device's changes would wait for the next reconnect. Keep the read
        // result separately: exhausting retries must not authorize automatic avatar seeds, while an
        // empty but successful profile read still protects seeds already stored on the Gateway.
        var delays = Self.bootstrapPullRetryDelays[...]
        var readSucceeded = false
        while self.isCurrent(epoch) {
            let succeeded = await self.pullMaps(maps, epoch: epoch)
            readSucceeded = readSucceeded || succeeded
            let firstSyncPending = maps.contains { !self.defaults.bool(forKey: $0.syncedDefaultsKey) }
            guard (!succeeded || firstSyncPending), self.isCurrent(epoch), let delay = delays.popFirst() else { break }
            try? await Task.sleep(for: .seconds(delay))
            guard self.isCurrent(epoch) else { return }
        }
        if self.isCurrent(epoch) { await self.retryPendingPrefs(maps) }
        let queued = self.queuedAvatarChoices
        self.queuedAvatarChoices = [:]
        for (entry, value) in queued { self.setAvatarChoice(value, for: entry) }
        guard self.isCurrent(epoch) else { return }
        self.finishBootstrapPrefsPull(epoch: epoch, readSucceeded: readSucceeded)
    }

    func pullServerNames() async { await self.pull(self.syncedMap(Self.serverNamesPref)) }
    func pullChatIcons() async { await self.pull(self.syncedMap(Self.chatIconsPref)) }
    func pullChatColors() async { await self.pull(self.syncedMap(Self.chatColorsPref)) }

    func pull(_ map: SyncedMap) async {
        let fetchEpoch = self.connectionEpoch
        guard let fetched = await self.fetchRemoteMap(map.pref) else { return }
        if map.pref == Reactions.prefKey {
            guard self.isCurrent(fetchEpoch) else { return }
            await self.pullReactionMap(map, fetched: fetched, epoch: fetchEpoch)
        } else {
            await self.pull(map, fetched: fetched)
        }
    }

    func pull(_ map: SyncedMap, fetched: [String: String]?) async {
        if map.pref == Reactions.prefKey {
            await self.pullReactionMap(map, fetched: fetched, epoch: self.connectionEpoch)
            return
        }
        let defaults = self.defaults
        if !defaults.bool(forKey: map.syncedDefaultsKey) {
            // First sync from this device: keep values already set here, remote wins on conflicts.
            var merged = self[keyPath: map.local]
            merged.merge(fetched ?? [:]) { _, remote in remote }
            merged = Self.fittingBookmarkShard(merged, pref: map.pref)
            if merged != (fetched ?? [:]) {
                guard await self.writeRemoteMap(map.pref, merged, expected: fetched) == .ok else { return }
            }
            defaults.set(true, forKey: map.syncedDefaultsKey)
            self.rejectedPrefs.removeValue(forKey: map.pref)
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

    /// Applies a reaction pull only while the connection that fetched it is still current. Fitting
    /// can suspend on a worker, so neither its RPC result nor the fetched map may outlive its epoch.
    private func pullReactionMap(_ map: SyncedMap, fetched: [String: String]?, epoch: Int) async {
        guard self.isCurrent(epoch) else { return }
        let defaults = self.defaults
        if !defaults.bool(forKey: map.syncedDefaultsKey) {
            var merged = self[keyPath: map.local]
            merged.merge(fetched ?? [:]) { _, remote in remote }
            let fullLocalReactionMap = merged
            guard let fitted = await self.fitLegacyReactionPrefs(
                merged, preserving: self.mostRecentChangedReactionKey
            ) else {
                guard self.isCurrent(epoch) else { return }
                self.rejectedPrefs[map.pref] = L("The latest reaction is too large to sync.")
                return
            }
            guard self.isCurrent(epoch) else { return }
            merged = fitted
            if merged != (fetched ?? [:]) {
                guard self.isCurrent(epoch) else { return }
                let outcome = await self.writeRemoteMap(map.pref, merged, expected: fetched)
                guard self.isCurrent(epoch) else { return }
                guard outcome == .ok else { return }
            }
            guard self.isCurrent(epoch) else { return }
            defaults.set(true, forKey: map.syncedDefaultsKey)
            self.rejectedPrefs.removeValue(forKey: map.pref)
            self.remotePrefMaps[map.pref] = merged
            var local = self.advertisedNativeSessionReactions ? fullLocalReactionMap : merged
            for (id, value) in self.pendingPrefChanges[map.pref] ?? [:] {
                if let value { local[id] = value }
                else { local.removeValue(forKey: id) }
            }
            guard self.isCurrent(epoch) else { return }
            self[keyPath: map.local] = local
            return
        }
        guard self.isCurrent(epoch) else { return }
        self.remotePrefMaps[map.pref] = fetched ?? [:]
        var local = fetched ?? [:]
        if self.advertisedNativeSessionReactions {
            local = self.reactions
            local.merge(fetched ?? [:]) { _, remote in remote }
        }
        for (id, value) in self.pendingPrefChanges[map.pref] ?? [:] { local[id] = value }
        guard self.isCurrent(epoch) else { return }
        if self[keyPath: map.local] != local { self[keyPath: map.local] = local }
    }

    func push(_ map: SyncedMap, _ id: String, _ value: String?) async {
        await self.push(map, [id: value])
    }

    /// Writes one after another per pref, so quick successive changes (toggling reactions) don't
    /// conflict with each other, and a pull in between keeps them.
    func push(_ map: SyncedMap, _ changes: [String: String?]) async {
        guard self.defaults.bool(forKey: map.syncedDefaultsKey) else {
            // A reaction can arrive while its first sync is fitting/writing the legacy map.
            // Keep it pending so that the pull cannot overwrite the optimistic value.
            if map.pref == Reactions.prefKey, !changes.isEmpty {
                var pending = self.pendingPrefChanges[map.pref] ?? [:]
                for (id, value) in changes { pending.updateValue(value, forKey: id) }
                self.pendingPrefChanges[map.pref] = pending
            }
            return
        }
        var pending = self.pendingPrefChanges[map.pref] ?? [:]
        guard !changes.isEmpty || !pending.isEmpty else { return }
        for (id, value) in changes { pending.updateValue(value, forKey: id) }
        self.pendingPrefChanges[map.pref] = pending
        let previous = self.prefPushes[map.pref]
        let task = Task {
            await previous?.value
            // Everything still pending goes out, so a later change retries an earlier failure.
            let batch = self.pendingPrefChanges[map.pref] ?? [:]
            guard !batch.isEmpty else { return }
            guard await self.write(map, batch) else { return }
            for (id, value) in batch where self.pendingPrefChanges[map.pref]?[id] == .some(value) {
                self.pendingPrefChanges[map.pref]?.removeValue(forKey: id)
            }
            if self.pendingPrefChanges[map.pref]?.isEmpty == true { self.pendingPrefChanges.removeValue(forKey: map.pref) }
            if map.pref == Reactions.prefKey, !self.advertisedNativeSessionReactions {
                // Reflect evictions locally, but layer any newer gesture that arrived while the
                // network write was in flight on top of the confirmed map.
                var local = self.remotePrefMaps[map.pref] ?? [:]
                for (id, value) in self.pendingPrefChanges[map.pref] ?? [:] {
                    if let value { local[id] = value }
                    else { local.removeValue(forKey: id) }
                }
                if self.reactions != local { self.reactions = local }
            }
        }
        self.prefPushes[map.pref] = task
        await task.value
    }

    /// Writes changes that failed earlier, after a pull has put the gateway's map in place.
    func retryPendingPrefs(_ maps: [SyncedMap]) async {
        for map in maps where !(self.pendingPrefChanges[map.pref]?.isEmpty ?? true) {
            await self.push(map, [:])
        }
    }

    /// True only when the gateway accepted the write. A conflict (another device changed the map
    /// meanwhile) is followed by a pull, since its changed event may have been taken for our echo.
    private func write(_ map: SyncedMap, _ changes: [String: String?]) async -> Bool {
        let reactionEpoch = map.pref == Reactions.prefKey ? self.connectionEpoch : nil
        var conflicted = false
        var written = false
        for _ in 0..<3 {
            if let reactionEpoch, !self.isCurrent(reactionEpoch) { return false }
            let cached = self.remotePrefMaps[map.pref]
            guard let current = cached == nil ? await self.fetchRemoteMap(map.pref) : .some(cached) else { break }
            if let reactionEpoch, !self.isCurrent(reactionEpoch) { return false }
            var next = current ?? [:]
            for (id, value) in changes { next[id] = value }
            if map.pref == Reactions.prefKey {
                guard let fitting = await self.fitLegacyReactionPrefs(next, preserving: self.mostRecentChangedReactionKey) else {
                    guard let reactionEpoch, self.isCurrent(reactionEpoch) else { return false }
                    self.rejectedPrefs[map.pref] = L("The latest reaction is too large to sync.")
                    return false
                }
                guard let reactionEpoch, self.isCurrent(reactionEpoch) else { return false }
                next = fitting
            }
            if let reactionEpoch, !self.isCurrent(reactionEpoch) { return false }
            let outcome = await self.writeRemoteMap(map.pref, next, expected: current)
            if let reactionEpoch, !self.isCurrent(reactionEpoch) { return false }
            if outcome == .ok {
                self.rejectedPrefs.removeValue(forKey: map.pref)
                self.remotePrefMaps[map.pref] = next
                written = true
                break
            }
            if let reactionEpoch, !self.isCurrent(reactionEpoch) { return false }
            self.remotePrefMaps[map.pref] = nil
            if outcome == .failed || outcome == .rejected { break }
            conflicted = true
        }
        if conflicted {
            if let reactionEpoch {
                guard self.isCurrent(reactionEpoch), let fetched = await self.fetchRemoteMap(map.pref),
                      self.isCurrent(reactionEpoch)
                else { return written }
                await self.pullReactionMap(map, fetched: fetched, epoch: reactionEpoch)
            } else {
                await self.pull(map)
            }
        }
        return written
    }

    /// Takes one expected echo of our own `users.prefs.set` for the pref; false when the change is
    /// someone else's and needs a read.
    func consumeExpectedEcho(_ pref: String) -> Bool {
        guard let count = self.expectedPrefEchoes[pref], count > 0 else { return false }
        self.expectedPrefEchoes[pref] = count - 1
        return true
    }

    enum PrefWriteOutcome { case ok, conflict, failed, rejected }

    private func writeRemoteMap(_ key: String, _ names: [String: String], expected: [String: String]?) async -> PrefWriteOutcome {
        self.expectedPrefEchoes[key, default: 0] += 1
        let outcome = await self.sendRemoteMap(key, names, expected: expected)
        if outcome != .ok { self.expectedPrefEchoes[key] = max(0, (self.expectedPrefEchoes[key] ?? 0) - 1) }
        return outcome
    }

    private func sendRemoteMap(_ key: String, _ names: [String: String], expected: [String: String]?) async -> PrefWriteOutcome {
        let entries: JSONValue = .object([key: names.isEmpty ? .null : Self.json(names)])
        func outcome(_ result: JSONValue) -> PrefWriteOutcome {
            switch result["status"]?.string {
            case "ok": .ok
            case "conflict": .conflict
            default: .failed
            }
        }
        if self.prefsSupportsExpected {
            let params: JSONValue = ["entries": entries, "expectedEntries": .object([key: expected.map(Self.json) ?? .null])]
            do {
                return outcome(try await self.connection.request("users.prefs.set", params, timeout: 15))
            } catch let GatewayError.rpc(_, message, _) where message.contains("expectedEntries") {
                // Older gateways don't accept compare-and-set; fall back to last write wins.
                self.prefsSupportsExpected = false
            } catch let GatewayError.rpc(code, message, _) where code == "INVALID_REQUEST" {
                // Too large or too many keys: retrying can't succeed, so say why instead.
                self.rejectedPrefs[key] = message
                return .rejected
            } catch {
                return .failed
            }
        }
        do {
            return outcome(try await self.connection.request("users.prefs.set", ["entries": entries], timeout: 15))
        } catch let GatewayError.rpc(code, message, _) where code == "INVALID_REQUEST" {
            // The Gateway rejected this synced map. Keep the pending local value and show why in Health.
            self.rejectedPrefs[key] = message
            return .rejected
        } catch {
            return .failed
        }
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
        if !emoji.isEmpty { self.mostRecentChangedReactionKey = key }
        Task { await self.push(self.syncedMap(Reactions.prefKey), key, value) }
    }

    /// The Gateway advertises `session.reactions.set` and `.list` (and none failed as unavailable this connection).
    public var supportsSessionReactions: Bool {
        guard !self.sessionReactionsOff, let methods = self.hello?.methods else { return false }
        return methods.contains("session.reactions.set") && methods.contains("session.reactions.list")
    }

    /// Your profile id, which the Gateway records reactions under (`users.self`); nil without a profile.
    func selfProfileId() async -> String? {
        let epoch = self.connectionEpoch
        if let cached = self.selfProfile, cached.epoch == epoch { return cached.id }
        let result = try? await self.connection.request("users.self", .object([:]), timeout: 15)
        let id = result?["profile"]?["id"]?.text
        if self.connectionEpoch == epoch { self.selfProfile = (epoch, id) }
        return id
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
            await self.bookmarkStore.removeConfirmedSessions([key])
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

    /// Every session key on the Gateway, archived included, read page by page; nil unless the whole
    /// list arrived (a failed request, a page cap or a Gateway that can't say whether more follow),
    /// so nothing is ever forgotten from a partial list.
    func completeSessionKeys() async -> Set<String>? {
        let connection = self.connection
        return await Self.completeSessionKeys(maxPages: Self.maxListPages) { params in
            guard self.state.isConnected else { throw CancellationError() }
            return try await connection.request("sessions.list", params, timeout: 30)
        }
    }

    /// The paging itself: `request` runs `sessions.list` with the given params.
    static func completeSessionKeys(maxPages: Int, limit: Int = 300,
                                    request: (JSONValue) async throws -> JSONValue) async -> Set<String>? {
        var keys = Set<String>()
        var offset = 0
        var reportedTotal = 0
        for _ in 0..<maxPages {
            var params: [String: JSONValue] = ["limit": JSONValue(limit), "archived": "all"]
            if offset > 0 { params["offset"] = JSONValue(offset) }
            guard let list = try? await request(.object(params)), let rows = list["sessions"]?.array else { return nil }
            reportedTotal = max(reportedTotal, list["totalCount"]?.int ?? 0)
            keys.formUnion(rows.compactMap(SessionRow.init).map(\.key))
            if let hasMore = list["hasMore"]?.bool {
                guard hasMore else { return keys.count >= reportedTotal ? keys : nil }
                let next = list["nextOffset"]?.int ?? offset + rows.count
                guard next > offset else { return nil }
                offset = next
            } else {
                return rows.count < limit && keys.count >= reportedTotal ? keys : nil
            }
        }
        return nil
    }

    static let maxListPages = 40

    /// Chats that dropped out of `sessions.list` (deleted while we were away, or just archived, or past
    /// the list limit). Only those the Gateway confirms gone are forgotten: a complete list no longer
    /// has them. A chat with sends still in the outbox is kept: it may not exist on the Gateway yet,
    /// and forgetting it would drop what the user queued.
    func forgetVanishedSessions(_ keys: Set<String>) async {
        guard !keys.isEmpty, self.state.isConnected, let listed = await self.completeSessionKeys() else { return }
        for key in keys.subtracting(listed) where self.isForgettable(key) {
            await self.transcriptChanged(key: key, change: .deleted)
        }
    }

    private func isForgettable(_ key: String) -> Bool {
        self.sessions[key] == nil && self.chats[key] == nil && self.outbox.entries(for: key).isEmpty
    }

    /// Once per connect: drops cached transcripts (and their search rows) of sessions deleted while the
    /// app wasn't running. The cache holds no session keys, only their digests, so a transcript is
    /// orphaned when its digest matches no session on a COMPLETE list, none in memory and none in the
    /// outbox; the search index, which does store keys, names the ones to forget in full.
    func reconcileOrphanedTranscripts(epoch: Int) async {
        guard let listed = await self.completeSessionKeys(), self.isCurrent(epoch) else { return }
        await self.forgetOrphanedBookmarks(keeping: listed)
        guard self.isCurrent(epoch) else { return }
        guard let root = self.cacheRoot else { return }
        func isLive(_ key: String) -> Bool {
            listed.contains(key) || !self.isForgettable(key)
        }
        if MessageIndex.status(gatewayId: self.id, root: root) != .unavailable {
            for key in await self.messageIndex.indexedSessionKeys() where !isLive(key) {
                guard self.isCurrent(epoch) else { return }
                await self.forgetTranscript(key)
            }
        }
        let listedDigests = Set(listed.map(TranscriptCache.digest(of:)))
        for digest in TranscriptCache.cachedDigests(gatewayId: self.id, root: root) where !listedDigests.contains(digest) {
            guard self.isCurrent(epoch) else { return }
            // A chat created, or sends queued, since the list was read may own this file.
            let inUse = Set(self.sessions.keys).union(self.chats.keys).union(self.outbox.sessionKeys)
            if inUse.contains(where: { TranscriptCache.digest(of: $0) == digest }) { continue }
            await TranscriptCache.remove(gatewayId: self.id, digest: digest, root: root)
        }
        guard self.isCurrent(epoch) else { return }
        await TranscriptCache.removeOrphanedSidecars(gatewayId: self.id, root: root)
    }

    /// Drops a chat's cached transcript and its messages from search; a refetch re-adds both.
    func forgetTranscript(_ key: String) async {
        await TranscriptCache.remove(gatewayId: self.id, sessionKey: key, root: self.cacheRoot)
        if MessageIndex.status(gatewayId: self.id, root: self.cacheRoot) != .unavailable {
            await self.messageIndex.remove(sessionKey: key)
        }
        await self.forgetSpotlight(sessionKey: key)
    }

    /// The Skills page: `skills.status` is advertised.
    public var supportsSkills: Bool { self.advertises(Skills.statusMethod) }
    /// The MCP Servers page: the config is readable (`config.get`).
    public var supportsMCPServers: Bool { self.settings.hasLoaded && self.settings.configSupported }
    /// Whether a link to the MCP Servers page can be offered before the config has loaded (`config.get` is advertised).
    public var canOpenMCPServers: Bool { self.advertises("config.get") && self.settings.configSupported }
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

    var toolsRequest: ToolsInspectorModel.Request {
        let connection = self.connection
        return { [weak self] method, params in
            let sessionKey = method == ToolsPolicy.effectiveMethod ? params["sessionKey"]?.text : nil
            let version = sessionKey.flatMap { self?.beginEffectiveMCPToolRead(sessionKey: $0) }
            do {
                let result = try await connection.request(method, params, timeout: 30)
                if let self, let sessionKey, let version {
                    await self.finishEffectiveMCPToolRead(result, sessionKey: sessionKey, version: version)
                }
                return result
            } catch {
                if let self, let sessionKey, let version {
                    self.cancelEffectiveMCPToolRead(sessionKey: sessionKey, version: version)
                }
                throw error
            }
        }
    }

    /// Resolves a transcript tool using this Gateway's latest bounded snapshot for that session.
    /// A genuinely uncached ID keeps the legacy safe-prefix fallback; a cached stale server does not.
    public func mcpServerName(forToolName toolName: String, sessionKey: String) -> String? {
        let index = self.mcpToolServerIndexes.value(for: sessionKey)
        let configured = self.settings.config["mcp"]?["servers"]?.object ?? [:]
        if let index {
            for exactID in MCPToolServerResolver.exactIDs(for: toolName) {
                if let entry = index.serversByToolID[exactID] {
                    guard case let .server(name) = entry, configured[name] != nil else { return nil }
                    return name
                }
            }
            if !index.isComplete { return nil }
        }
        let names = self.mcp.servers.map(\.name)
        return MCPToolServerResolver.resolve(toolName: toolName, effectiveIndex: nil,
                                             configuredServerNames: names)
    }

    func beginEffectiveMCPToolRead(sessionKey: String) -> UInt64? {
        guard self.mcpToolServerReadVersions[sessionKey] != nil || self.mcpToolServerReadVersions.count < 32 else { return nil }
        self.mcpToolServerReadSequence &+= 1
        self.mcpToolServerReadVersions[sessionKey] = self.mcpToolServerReadSequence
        return self.mcpToolServerReadSequence
    }

    func cancelEffectiveMCPToolRead(sessionKey: String, version: UInt64) {
        guard self.mcpToolServerReadVersions[sessionKey] == version else { return }
        self.mcpToolServerReadVersions.removeValue(forKey: sessionKey)
    }

    func finishEffectiveMCPToolRead(_ result: JSONValue, sessionKey: String, version: UInt64) async {
        let index = await Task.detached(priority: .utility) {
            MCPToolServerResolver.serverIndex(from: result)
        }.value
        guard self.mcpToolServerReadVersions[sessionKey] == version else { return }
        self.mcpToolServerReadVersions.removeValue(forKey: sessionKey)
        _ = self.mcpToolServerIndexes.insert(index, for: sessionKey, cost: index.cost)
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

    /// Forgets this device's copy of the dismissals, and any unsent pref changes and queued avatar
    /// choices, when the gateway is removed. The gateway's user prefs keep the synced values for
    /// other devices, and re-adding the gateway pulls them back.
    func forgetLocalHealthDismissals() {
        self.defaults.removeObject(forKey: "pincer.healthDismissals.\(self.id.uuidString)")
        self.defaults.removeObject(forKey: "pincer.healthDismissalsSynced.\(self.id.uuidString)")
        self.pendingPrefChanges = [:]
        self.queuedAvatarChoices = [:]
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

    /// The locally mirrored character currently shown for this agent.
    public func avatarCreature(for agentId: String) -> AvatarCreature? {
        if let queued = self.queuedAvatarChoices[agentId] {
            return queued.flatMap(AvatarCreature.init(rawValue:))
        }
        return self.avatarChoices[agentId].flatMap(AvatarCreature.init(rawValue:))
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
