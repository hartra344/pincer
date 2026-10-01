import CryptoKit
import Foundation
import os
import PincerPush
import Synchronization

/// On-disk copy of each chat's committed transcript. Reopening a chat is instant (even offline) and
/// older history — which doesn't change — never has to be refetched; only the newest page is.
public enum TranscriptCache {
    public struct Snapshot: Codable, Sendable {
        public var version = Self.currentVersion
        public var items: [ChatItem]
        /// The transcript reaches back to the first message (no older history on the Gateway).
        public var complete: Bool
        /// Session activity when saved; an unchanged session needs no background refresh.
        public var activityMs: Double?
        /// The transcript was cut at `maxItems` (the newest kept, older history dropped), so it's
        /// as complete as it will get even though `complete` is false.
        public var retained: Bool
        /// Old caches may lack sender attribution for already-projected assistant messages.
        /// This stays set until the bounded authoritative history scan succeeds.
        public var forwardedSenderRefreshPending: Bool
        /// A one-write instruction used only after that scan completes; never serialized.
        var forwardedSenderRefreshCompleted = false

        public static let currentVersion = 10

        public init(version: Int = Self.currentVersion, items: [ChatItem], complete: Bool, activityMs: Double? = nil,
                    retained: Bool = false, forwardedSenderRefreshPending: Bool = false)
        {
            self.version = version
            self.items = items
            self.complete = complete
            self.activityMs = activityMs
            self.retained = retained
            self.forwardedSenderRefreshPending = forwardedSenderRefreshPending
            self.forwardedSenderRefreshCompleted = false
        }

        private enum CodingKeys: String, CodingKey {
            case version, items, complete, activityMs, retained, forwardedSenderRefreshPending
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decode(Int.self, forKey: .version)
            self.items = try c.decode([ChatItem].self, forKey: .items)
            self.complete = try c.decode(Bool.self, forKey: .complete)
            self.activityMs = try c.decodeIfPresent(Double.self, forKey: .activityMs)
            self.retained = try c.decodeIfPresent(Bool.self, forKey: .retained) ?? false
            self.forwardedSenderRefreshPending = try c.decodeIfPresent(Bool.self, forKey: .forwardedSenderRefreshPending)
                ?? (self.version < Self.currentVersion)
            self.forwardedSenderRefreshCompleted = false
        }

        /// Whether a transcript of `committedCount` items is cut at `maxItems` when saved.
        public static func isRetained(committedCount: Int) -> Bool {
            committedCount > TranscriptCache.maxItems
        }
    }

    /// Written next to each transcript so freshness checks don't decode the whole thing.
    struct Meta: Codable, Sendable {
        var complete: Bool
        var activityMs: Double?
        /// The transcript's `Snapshot.version`; a sidecar without one (written before it was
        /// recorded) or for another version never vouches for freshness.
        var version: Int?
        /// `Snapshot.retained`; nil in a sidecar written before v8.
        var retained: Bool?
        var forwardedSenderRefreshPending: Bool? = nil
    }

    /// What `loadWithOutcome` found on disk. Anything but `missing`, `loaded`, `migrated` and
    /// `unavailable` means the file was unusable and has been removed, so the chat is refetched
    /// from the Gateway.
    public enum LoadOutcome: Equatable, Sendable {
        /// No cached transcript.
        case missing
        /// A transcript of the current version.
        case loaded
        /// An older transcript brought up to date by the migration chain.
        case migrated(from: Int)
        /// Older than `oldestMigratableVersion`; deleted.
        case outdated(version: Int)
        /// Written by a newer app; deleted (its saves would overwrite it anyway).
        case future(version: Int)
        /// Empty, truncated, not JSON or not a transcript; moved to the Quarantine folder.
        case corrupt(String)
        /// The transcript exists but couldn't be read right now (locked with the device, permission
        /// or I/O trouble that may pass). Nothing was deleted or quarantined; a save would replace
        /// the older cached history, so callers hold theirs until a later load succeeds.
        case unavailable(String)

        /// The file couldn't be used and was removed.
        public var discarded: Bool {
            switch self {
            case .missing, .loaded, .migrated, .unavailable: false
            case .outdated, .future, .corrupt: true
            }
        }
    }

    static let logger = Logger(subsystem: "chat.pincer", category: "TranscriptCache")

    // MARK: Versions and migrations
    //
    // Adding a migration
    // ------------------
    // When `Snapshot`'s on-disk shape changes (or what's cached must be rebuilt differently):
    //  1. Bump `Snapshot.currentVersion` (this also rebuilds every Gateway's message search
    //     index, whose `user_version` includes it).
    //  2. If a transcript of the previous version can be turned into the new one without the
    //     Gateway, add `migrations[old] = { json in ... }`: it gets the decoded JSON object of a
    //     version-`old` snapshot and edits it in place into a version-`old + 1` one (`version`
    //     is set for you). Steps chain, so v3 runs `migrations[3]` then `migrations[4]`. Throw
    //     when a file can't be migrated; it's then discarded as outdated. A migrated transcript
    //     is saved back at the current version, so each file is migrated once.
    //     If it can't (the old files lack data only the Gateway has), raise
    //     `oldestMigratableVersion` to the new version instead: older files are deleted and
    //     refetched.
    //  3. Add a test in Tests/PincerKitTests/TranscriptCacheVersioningTests.swift decoding a
    //     literal old-version file through `decode(_:)`.
    //
    // History
    //  - v5 (#116, replies and reactions) added `replyToId`, `replyToPreview`, `channelMessageId`,
    //    `transportChannel` and `conversationRef` to `ChatItem`. A v4 file would decode (they're
    //    optional) but its messages would silently lack reply quotes and the channel ids agent
    //    reactions point at, and older history is never refetched once cached. So v4 isn't
    //    migratable: it's discarded and refetched, and `oldestMigratableVersion` is 5.
    //  - v6 (#168) follows #154 (file edit diffs), which added the optional `ChatItem.toolDetails`
    //    without a bump. A v5 file cached before #154 has tool results without it, and a `write`
    //    without details reads as creating the file, so an overwrite showed as "New file". Only
    //    the Gateway knows the real details and older history is never refetched, so
    //    `migrations[5]` marks tool results lacking them with `unknownToolDetails`: the card
    //    then says "Written" with nothing claimed about what was removed. Tool results that have
    //    details (cached after #154) keep them, and nothing is refetched.
    //  - v7 (#207, agent-to-agent messages) added `ChatItem.sender`. The provenance that names a
    //    sender isn't cached, but an unprojected inter-session message was cached as your turn
    //    with the Gateway's `[Inter-session message] sourceSession=…` header still in its text;
    //    `migrations[6]` (`forwardedSenderMigration`) reads the sender from that header, strips
    //    it, and shows the message as the sender's. Messages the Gateway had already projected
    //    decode without a sender until the newest page is refetched over them on open.
    //  - v8 (#199, efficient persistence) is a storage-only change: `<digest>.json` became a small
    //    manifest (`version`, `complete`, `activityMs`, `retained`, `token`, `segments`) naming
    //    segment files in `<digest>.segments/`, each a JSON array of items. Segments end at
    //    content-defined boundaries (see `segmentRanges`), so an append or a prepend leaves the
    //    existing ones byte-identical and a save writes only what changed. `migrations[7]` does
    //    nothing; the v7 single file is decoded, then saved back as a manifest and segments.

    //  - #110 (agent reply targets, v9) added `ChatItem.replyToCurrent` and `channelSenderName`, stored as optionals, so older
    //    files decode and `migrations[8]` does nothing. Assistant messages cached earlier have no reply target
    //    (the newest page is refetched on open).
    //  - v10 (#229) marks old caches for one bounded history scan because already-projected
    //    assistant rows did not retain `senderSession`; matching stable transcript ids are replaced.

    /// Upgrades a snapshot's JSON object from the version it's keyed by to the next one.
    typealias Migration = @Sendable (inout [String: Any]) throws -> Void

    /// `toolDetails` of a tool result cached before they were recorded: the Gateway's details
    /// are unknown, so a file edit card claims neither a new file nor what was removed.
    public static let unknownToolDetails: JSONValue = .object(["provenance": .string("unknown")])

    /// Keyed by source version: `migrations[n]` turns a version-n snapshot into version n + 1.
    static let migrations: [Int: Migration] = [
        5: { json in
            // A file that isn't a transcript is left for decoding to reject.
            guard var items = json["items"] as? [Any] else { return }
            for index in items.indices {
                guard var item = items[index] as? [String: Any], item["role"] as? String == ChatRole.toolResult.rawValue,
                      item["toolDetails"] == nil || item["toolDetails"] is NSNull
                else { continue }
                item["toolDetails"] = ["provenance": "unknown"]
                items[index] = item
            }
            json["items"] = items
        },
        6: forwardedSenderMigration,
        7: { _ in },
        8: { _ in },
        9: { json in json["forwardedSenderRefreshPending"] = true },
    ]

    /// v6 → v7 (#207): cached inter-session turns become the sending agent's.
    static let forwardedSenderMigration: Migration = { json in
        guard var items = json["items"] as? [Any] else { return }
        for index in items.indices {
            guard let object = items[index] as? [String: Any], object["role"] as? String == ChatRole.user.rawValue,
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  var item = try? JSONDecoder().decode(ChatItem.self, from: data),
                  item.sender == nil, let sender = MessageSender.fromPromptHeader(item.plainText)
            else { continue }
            item.sender = sender
            item.role = .assistant
            item.via = nil
            item.blocks = item.blocks.compactMap { block in
                guard case let .text(text) = block else { return block }
                let stripped = MessageSender.stripInterSessionPrefix(text)
                return stripped.isEmpty ? nil : .text(stripped)
            }
            guard let encoded = try? JSONEncoder().encode(item),
                  let migrated = try? JSONSerialization.jsonObject(with: encoded)
            else { continue }
            items[index] = migrated
        }
        json["items"] = items
    }

    /// Older transcripts are discarded rather than migrated.
    static let oldestMigratableVersion = 5

    /// Manifest (segmented) versions read as they are. Pre-v10 manifests are read and saved back
    /// with the pending refresh marker without decoding item JSON on the main thread.
    /// (#563: v8 manifests were discarded, so every chat went back to the network after the v9 bump).
    /// A migration that changes items must end this range at its source version.
    static let manifestVersions: ClosedRange<Int> = 8...Snapshot.currentVersion

    struct MigrationError: Error, CustomStringConvertible {
        var description: String
    }

    /// Decodes a transcript file, migrating an older one. Pure: never touches the disk.
    static func decode(_ data: Data) -> (snapshot: Snapshot?, outcome: LoadOutcome) {
        self.decode(data, migrations: self.migrations, oldestMigratableVersion: self.oldestMigratableVersion)
    }

    static func decode(_ data: Data, migrations: [Int: Migration], oldestMigratableVersion: Int,
                       currentVersion: Int = Snapshot.currentVersion) -> (snapshot: Snapshot?, outcome: LoadOutcome)
    {
        guard !data.isEmpty else { return (nil, .corrupt("empty file")) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return (nil, .corrupt("not JSON (truncated or garbage)"))
        }
        guard var json = object as? [String: Any] else { return (nil, .corrupt("not a JSON object")) }
        guard let number = json["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = Int(exactly: number.doubleValue)
        else { return (nil, .corrupt("no version")) }
        if version > currentVersion { return (nil, .future(version: version)) }
        if version < currentVersion {
            guard version >= oldestMigratableVersion else { return (nil, .outdated(version: version)) }
            do {
                for step in version..<currentVersion {
                    guard let migrate = migrations[step] else { return (nil, .outdated(version: version)) }
                    try migrate(&json)
                    json["version"] = step + 1
                }
            } catch {
                // The file was a sound old transcript; it just can't be upgraded.
                return (nil, .outdated(version: version))
            }
        }
        do {
            let migrated = version == currentVersion ? data : try JSONSerialization.data(withJSONObject: json)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: migrated)
            guard snapshot.version == currentVersion else { return (nil, .corrupt("version changed while decoding")) }
            return (snapshot, version == currentVersion ? .loaded : .migrated(from: version))
        } catch {
            if version != currentVersion { return (nil, .outdated(version: version)) }
            return (nil, .corrupt("not a transcript: \(Self.describe(error))"))
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, _): "missing \(key.stringValue)"
        case let DecodingError.typeMismatch(type, context):
            "\(type) expected at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.valueNotFound(type, context):
            "\(type) missing at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.dataCorrupted(context): context.debugDescription
        default: String(describing: error)
        }
    }

    /// Newest items kept on disk per chat.
    static let maxItems = 20000

    /// `PINCER_CACHE_DIR` redirects the cache (checks); `PINCER_CACHE_DIR=off` disables it.
    public static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["PINCER_CACHE_DIR"] {
            return override == "off" ? nil : URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "\(DevNamespace.folderName("Pincer"))/Transcripts", directoryHint: .isDirectory)
    }

    public static func directory(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        root?.appending(path: gatewayId.uuidString, directoryHint: .isDirectory)
    }

    public static func file(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) -> URL? {
        self.directory(gatewayId: gatewayId, root: root)?.appending(path: "\(self.digest(of: sessionKey)).json")
    }

    /// The cache file's name (without extension) for a chat.
    public static func digest(of sessionKey: String) -> String {
        SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Digests of the transcripts on disk for a Gateway (the file names carry no session key).
    public static func cachedDigests(gatewayId: UUID, root: URL? = Self.root) -> [String] {
        guard let directory = self.directory(gatewayId: gatewayId, root: root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let digest = String(name.dropLast(5))
            return self.isCacheDigest(digest) ? digest : nil
        }
    }

    /// Removes sidecars left behind without their transcript manifest. The scan and deletion run
    /// through the writer actor so a cache save cannot race the inventory on the main actor.
    package static func removeOrphanedSidecars(gatewayId: UUID, root: URL? = Self.root) async {
        guard let directory = self.directory(gatewayId: gatewayId, root: root) else { return }
        await Writer.shared.removeOrphanedSidecars(in: directory)
    }

    private static func isCacheDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.allSatisfy(\.isHexDigit)
    }

    /// Deletes a transcript known only by its digest, through the writer like `remove(gatewayId:sessionKey:)`.
    /// Its search rows go with the session (see `GatewayStore.reconcileOrphanedTranscripts`).
    static func remove(gatewayId: UUID, digest: String, root: URL?) async {
        guard let url = self.directory(gatewayId: gatewayId, root: root)?.appending(path: "\(digest).json") else { return }
        await Writer.shared.remove(url)
    }

    /// The sidecar of a current-version transcript that's on disk; nil otherwise, so a missing,
    /// empty or other-version transcript is never taken as fresh.
    static func meta(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async -> Meta? {
        guard let file = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return nil }
        let url = file.appendingPathExtension("meta")
        return await Task.detached(priority: .utility) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0,
                  let meta = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(Meta.self, from: $0) }),
                  meta.version == Snapshot.currentVersion
            else { return nil }
            return meta
        }.value
    }

    public static func load(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async -> Snapshot? {
        await self.loadWithOutcome(gatewayId: gatewayId, sessionKey: sessionKey, root: root).snapshot
    }

    /// Reads the cached transcript, migrating an older one. An unusable file is removed (a corrupt
    /// one kept in the Quarantine folder for diagnosis) along with its sidecar, and logged.
    public static func loadWithOutcome(gatewayId: UUID, sessionKey: String,
                                       root: URL? = Self.root) async -> (snapshot: Snapshot?, outcome: LoadOutcome)
    {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return (nil, .missing) }
        return await self.read(url, gatewayId: gatewayId, root: root, priority: .userInitiated)
    }

    /// `loadWithOutcome` for a transcript file already located (the search index's reconcile).
    /// With `newest`, a current-format transcript is read only as far back as the segments
    /// covering that many of its newest items (the snapshot then holds those, and possibly more).
    static func read(_ url: URL, gatewayId: UUID, root: URL? = Self.root, newest: Int? = nil,
                     priority: TaskPriority) async -> (snapshot: Snapshot?, outcome: LoadOutcome)
    {
        let quarantine = self.quarantineDirectory(gatewayId: gatewayId, root: root)
        return await Task.detached(priority: priority) {
            var attempts = 0
            while true {
                attempts += 1
                let manifestDate = Self.modificationDate(url)
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return (nil, .missing) }
                    // The file is there, so this isn't a content problem: keep it.
                    return (nil, .unavailable("unreadable: \(error.localizedDescription)"))
                }
                if let peek = try? JSONDecoder().decode(VersionPeek.self, from: data),
                   Self.manifestVersions.contains(peek.version),
                   let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
                {
                    let current = peek.version == Snapshot.currentVersion
                    var range: Range<Int>?
                    // An older manifest is read whole, so it's saved back whole at the current version.
                    if let newest, current {
                        var covered = 0
                        var start = manifest.segments.count
                        while start > 0, covered < newest {
                            start -= 1
                            covered += manifest.segments[start].count
                        }
                        range = start..<manifest.segments.count
                    }
                    switch Self.readSegments(manifest, manifestURL: url, range: range) {
                    case let .loaded(snapshot, layout):
                        guard current else {
                            var snapshot = snapshot
                            snapshot.version = Snapshot.currentVersion
                            Self.logger.notice("Migrated cached transcript \(url.lastPathComponent, privacy: .private) from v\(peek.version) to v\(Snapshot.currentVersion)")
                            // Written back behind the writer's queue; the chat being opened doesn't wait for it.
                            if !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) {
                                Task.detached(priority: .utility) { _ = await Writer.shared.write(snapshot, to: url) }
                            }
                            return (snapshot, .migrated(from: peek.version))
                        }
                        var layout = layout
                        layout.manifestDate = manifestDate
                        // Not awaited: the writer may be busy saving other chats, and opening this one
                        // must not wait for them (#563). `prime` skips a layout a newer save already set.
                        Task.detached(priority: .utility) { await Writer.shared.prime(url, layout: layout) }
                        return (snapshot, .loaded)
                    case let .unavailable(reason):
                        return (nil, .unavailable(reason))
                    case let .missing(name):
                        // A save may have replaced this manifest and deleted the segment since.
                        if attempts < 3, let again = try? Data(contentsOf: url), again != data { continue }
                        let outcome = LoadOutcome.corrupt("segment \(name) is missing")
                        await Writer.shared.discard(url, expected: data, outcome: outcome, quarantine: quarantine)
                        return (nil, outcome)
                    case let .corrupt(reason):
                        let outcome = LoadOutcome.corrupt(reason)
                        await Writer.shared.discard(url, expected: data, outcome: outcome, quarantine: quarantine)
                        return (nil, outcome)
                    }
                }
                let result = Self.decode(data)
                switch result.outcome {
                case .missing, .loaded, .unavailable:
                    break
                case let .migrated(from):
                    Self.logger.notice("Migrated cached transcript \(url.lastPathComponent, privacy: .private) from v\(from) to v\(Snapshot.currentVersion)")
                    if let snapshot = result.snapshot, !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) {
                        _ = await Writer.shared.write(snapshot, to: url)
                    }
                case .outdated, .future, .corrupt:
                    await Writer.shared.discard(url, expected: data, outcome: result.outcome, quarantine: quarantine)
                }
                return result
            }
        }.value
    }

    /// `<gateway dir>/Quarantine`: corrupt transcripts moved aside, newest `maxQuarantined` kept.
    public static func quarantineDirectory(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        self.directory(gatewayId: gatewayId, root: root)?.appending(path: "Quarantine", directoryHint: .isDirectory)
    }

    static let maxQuarantined = 5

    /// Removes an unusable transcript and its sidecar; a corrupt one is quarantined.
    static func discard(_ url: URL, outcome: LoadOutcome, quarantine: URL?) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url.appendingPathExtension("meta"))
        try? fileManager.removeItem(at: self.segmentsDirectory(of: url))
        let name = url.lastPathComponent
        guard case let .corrupt(reason) = outcome, let quarantine else {
            try? fileManager.removeItem(at: url)
            switch outcome {
            case let .outdated(version):
                self.logger.notice("Discarded cached transcript \(name, privacy: .private): v\(version) is too old to migrate")
            case let .future(version):
                self.logger.notice("Discarded cached transcript \(name, privacy: .private): v\(version) is newer than this app")
            default:
                self.logger.error("Deleted corrupt cached transcript \(name, privacy: .private) (cache off, nowhere to quarantine it)")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let target = quarantine.appending(
                path: "\(url.deletingPathExtension().lastPathComponent)-\(Self.nextQuarantineStamp()).json")
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: url, to: target)
            self.logger.error(
                "Quarantined corrupt cached transcript \(name, privacy: .private): \(reason, privacy: .public)")
            self.trimQuarantine(quarantine)
        } catch {
            try? fileManager.removeItem(at: url)
            self.logger.error(
                "Deleted corrupt cached transcript \(name, privacy: .private) (\(reason, privacy: .public)); couldn't quarantine it")
        }
    }

    private static let quarantineSequence = Atomic<Int>(0)

    /// `<ms since 1970, 15 digits>-<process-wide sequence, 8 digits>`: sorts lexically in creation
    /// order even for several files in the same millisecond, or a clock that steps back.
    static func nextQuarantineStamp(now: Date = Date()) -> String {
        let ms = max(0, Int(now.timeIntervalSince1970 * 1000))
        let sequence = self.quarantineSequence.add(1, ordering: .relaxed).newValue
        return String(format: "%015ld-%08ld", ms, sequence)
    }

    /// The `<ms>-<sequence>` a quarantined file's name ends with; nil for older `<ms>` names.
    static func quarantineOrder(_ name: String) -> (ms: Int, sequence: Int)? {
        let base = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        let parts = base.split(separator: "-")
        guard parts.count >= 2, let sequence = Int(parts[parts.count - 1]), let ms = Int(parts[parts.count - 2]),
              parts[parts.count - 1].count == 8 else { return nil }
        return (ms, sequence)
    }

    /// Keeps the newest `maxQuarantined` files: by stamped name, then (older names) by date.
    static func trimQuarantine(_ directory: URL) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > self.maxQuarantined else { return }
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let sorted = files.sorted { a, b in
            switch (self.quarantineOrder(a.lastPathComponent), self.quarantineOrder(b.lastPathComponent)) {
            case let (x?, y?): return (x.ms, x.sequence) > (y.ms, y.sequence)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let da = date(a), db = date(b)
                return da == db ? a.lastPathComponent > b.lastPathComponent : da > db
            }
        }
        for file in sorted.dropFirst(self.maxQuarantined) { try? fileManager.removeItem(at: file) }
    }

    /// Writes the transcript, then brings the Gateway's message search index (under the same
    /// `root`) up to date with it. Nothing is written for a Gateway removed from the app, even by
    /// a save already under way, nor for a transcript that hasn't changed since it was last
    /// written. With the cache off, an index kept in memory (the demo) is still updated.
    ///
    /// With `keepingOlder`, `snapshot.items` is the newest window of the chat (a windowed
    /// transcript keeps only its recent items in memory): what's stored before the window's first
    /// item stays as it is, and `complete` is the stored one. A window that doesn't join what's
    /// stored replaces it, like any save.
    public static func save(_ snapshot: Snapshot, gatewayId: UUID, sessionKey: String, keepingOlder: Bool = false,
                            root: URL? = Self.root) async
    {
        await self.saveReturningStats(snapshot, gatewayId: gatewayId, sessionKey: sessionKey, keepingOlder: keepingOlder,
                                      root: root)
    }

    /// `save`, reporting what it wrote (tests and benchmarks).
    @discardableResult
    public static func saveReturningStats(_ snapshot: Snapshot, gatewayId: UUID, sessionKey: String,
                                          keepingOlder: Bool = false, root: URL? = Self.root) async -> SaveResult
    {
        guard !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) else { return SaveResult() }
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else {
            if MessageIndex.location(gatewayId: gatewayId, root: root) == .memory {
                await MessageIndex.shared(gatewayId: gatewayId, root: root)
                    .index(sessionKey: sessionKey, snapshot: snapshot, fileMtime: Date())
            }
            return SaveResult()
        }
        let result = await Writer.shared.write(snapshot, to: url, keepingOlder: keepingOlder)
        self.recordSaveStats(result)
        guard !result.unchanged, let written = result.modified else { return result }
        guard !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) else {
            self.deleteDirectory(gatewayId: gatewayId, root: root)
            return result
        }
        let change = result.change ?? .full(token: nil)
        let index = MessageIndex.shared(gatewayId: gatewayId, root: root)
        guard let older = result.older else {
            await index.index(sessionKey: sessionKey, snapshot: snapshot, fileMtime: written, change: change)
            return result
        }
        // The index counts positions in the whole transcript. It's first given only what's at
        // hand (the boundary segment's older items and the window) and asks for the rest if it
        // needs it.
        let olderCount = older.reduce(0) { $0 + $1.count }
        let slice = result.boundaryKept + snapshot.items
        let outcome = await index.index(sessionKey: sessionKey, items: slice, itemOffset: olderCount,
                                        totalCount: olderCount + slice.count, fileMtime: written, change: change)
        guard outcome == .needsEarlierItems, let items = await self.items(of: older, url: url) else { return result }
        let whole = Snapshot(version: snapshot.version, items: items + slice, complete: result.complete ?? snapshot.complete,
                             activityMs: snapshot.activityMs, retained: snapshot.retained)
        await index.index(sessionKey: sessionKey, snapshot: whole, fileMtime: written, change: change)
        return result
    }

    /// The items of `segments` (of the transcript at `url`), oldest first; nil if any can't be read.
    private static func items(of segments: [SegmentRef], url: URL) async -> [ChatItem]? {
        let directory = self.segmentsDirectory(of: url)
        return await Task.detached(priority: .utility) {
            var items: [ChatItem] = []
            for ref in segments {
                guard case let .items(segment) = Self.loadSegment(ref, in: directory) else { return nil }
                items += segment
            }
            return items
        }.value
    }

    /// The newest `limit` cached items and whether the transcript is complete, reading only the
    /// segments that hold them. Remembers the layout, so the next save writes only what changed.
    public static func loadNewest(gatewayId: UUID, sessionKey: String, limit: Int,
                                  root: URL? = Self.root) async ->
        (items: [ChatItem], complete: Bool, outcome: LoadOutcome, forwardedSenderRefreshPending: Bool)
    {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else {
            return ([], false, .missing, false)
        }
        let (snapshot, outcome) = await self.read(url, gatewayId: gatewayId, root: root, newest: max(limit, 0),
                                                  priority: .userInitiated)
        guard let snapshot else { return ([], false, outcome, false) }
        return (Array(snapshot.items.suffix(max(limit, 0))), snapshot.complete, outcome,
                snapshot.forwardedSenderRefreshPending)
    }

    /// Up to `limit` cached items just before the item `itemId`, oldest first, reading only the
    /// segments needed. `reachedStart`: nothing older is cached. An id that isn't cached gives no
    /// items and `.missing`.
    public static func loadOlder(gatewayId: UUID, sessionKey: String, before itemId: String, limit: Int,
                                 root: URL? = Self.root) async -> (items: [ChatItem], reachedStart: Bool, outcome: LoadOutcome)
    {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return ([], false, .missing) }
        let quarantine = self.quarantineDirectory(gatewayId: gatewayId, root: root)
        let limit = max(limit, 0)
        return await Task.detached(priority: .userInitiated) {
            var attempts = 0
            while true {
                attempts += 1
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return ([], false, .missing) }
                    return ([], false, .unavailable("unreadable: \(error.localizedDescription)"))
                }
                guard let peek = try? JSONDecoder().decode(VersionPeek.self, from: data), peek.version == Snapshot.currentVersion,
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
                else {
                    // An older single file: read (and migrate) it whole.
                    let (snapshot, outcome) = await Self.read(url, gatewayId: gatewayId, root: root, priority: .userInitiated)
                    guard let snapshot, let index = snapshot.items.firstIndex(where: { $0.id == itemId }) else {
                        return ([], false, snapshot == nil ? outcome : .missing)
                    }
                    let older = snapshot.items[..<index]
                    return (Array(older.suffix(limit)), older.count <= limit, outcome)
                }
                let directory = Self.segmentsDirectory(of: url)
                // Newest first; joined once at the end (prepending each segment would copy it all again).
                var chunks: [ArraySlice<ChatItem>] = []
                var collectedCount = 0
                var found = false
                var index = manifest.segments.count
                var failure: LoadOutcome?
                while index > 0, !found || collectedCount < limit {
                    index -= 1
                    let ref = manifest.segments[index]
                    // The id is the first item of the segment: nothing of it belongs before the id.
                    if !found, ref.firstId == itemId {
                        found = true
                        continue
                    }
                    switch Self.loadSegment(ref, in: directory) {
                    case let .items(segment):
                        if found {
                            chunks.append(segment[...])
                            collectedCount += segment.count
                        } else if let position = segment.firstIndex(where: { $0.id == itemId }) {
                            found = true
                            chunks.append(segment[..<position])
                            collectedCount += position
                        }
                    case .missing:
                        if attempts < 3, let again = try? Data(contentsOf: url), again != data { failure = .missing } else {
                            failure = .corrupt("segment \(ref.file) is missing")
                        }
                    case let .unavailable(reason):
                        return ([], false, .unavailable(reason))
                    case let .corrupt(reason):
                        failure = .corrupt(reason)
                    }
                    if failure != nil { break }
                }
                switch failure {
                case .missing?:
                    continue
                case let outcome?:
                    await Writer.shared.discard(url, expected: data, outcome: outcome, quarantine: quarantine)
                    return ([], false, outcome)
                case nil:
                    guard found else { return ([], false, .missing) }
                    var collected: [ChatItem] = []
                    collected.reserveCapacity(min(collectedCount, limit))
                    var skip = max(collectedCount - limit, 0)
                    for chunk in chunks.reversed() {
                        if skip >= chunk.count {
                            skip -= chunk.count
                            continue
                        }
                        collected += chunk.dropFirst(skip)
                        skip = 0
                    }
                    return (collected, index == 0 && collectedCount <= limit, .loaded)
                }
            }
        }.value
    }

    /// Deletes one chat's cached transcript (its stored tool details included), its sidecar and
    /// its rows in the message search index, e.g. when the session is deleted or rewound. A
    /// quarantined copy is left for diagnosis. The files go through the same writer as saves, so a
    /// save already queued lands before the removal, and the index skips a chat whose file is gone,
    /// so that save can't make it searchable again.
    public static func remove(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async {
        if let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) {
            await Writer.shared.remove(url)
        }
        if root != nil || MessageIndex.location(gatewayId: gatewayId, root: root) == .memory {
            await MessageIndex.shared(gatewayId: gatewayId, root: root).remove(sessionKey: sessionKey)
        }
    }

    /// Deletes the Gateway's transcripts and message search index. `permanently`: the Gateway
    /// was removed from the app, so saves still under way don't write them again.
    public static func removeAll(gatewayId: UUID, permanently: Bool = false, root: URL? = Self.root) {
        MessageIndex.whileDeleting(root: root, gatewayId: gatewayId) {
            MessageIndex.discard(gatewayId: gatewayId, root: root, permanently: permanently)
            self.deleteDirectory(gatewayId: gatewayId, root: root)
        }
        if let directory = self.directory(gatewayId: gatewayId, root: root) { Task { await Writer.shared.forget(under: directory) } }
    }

    /// Deletes every Gateway's cached transcripts, search indexes and quarantined files (Settings'
    /// Clear Cache). Open chats keep what they show and save again on their next change. A save
    /// under way when this runs either fails harmlessly (writes are atomic, and the sidecar only
    /// follows a written transcript) or writes a fresh, valid file. Such a save isn't indexed
    /// (no index opens while the files are deleted); it's indexed when it next saves or reconciles.
    public static func removeEverything(root: URL? = Self.root) {
        guard let root else { return }
        MessageIndex.whileDeleting(root: root) {
            let fileManager = FileManager.default
            for entry in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if let id = UUID(uuidString: entry.lastPathComponent) { MessageIndex.discard(gatewayId: id, root: root) }
                try? fileManager.removeItem(at: entry)
            }
        }
        Task { await Writer.shared.forget(under: root) }
        logger.notice("Cleared the transcript cache")
    }

    /// Waits until every write and removal queued so far has landed and the Gateway's search
    /// index under `root` has finished its pending work. Replaces sleeping for the cache to settle.
    public static func flush(gatewayId: UUID, root: URL? = Self.root) async {
        await Writer.shared.drain()
        await MessageIndex.flush(gatewayId: gatewayId, root: root)
    }

    /// Waits for queued writes, then closes and forgets every search index under `root`.
    public static func shutdown(root: URL? = Self.root) async {
        await Writer.shared.drain()
        await MessageIndex.shutdown(root: root)
    }

    /// Bytes the transcript cache takes on disk, search indexes and quarantined files included.
    public static func diskUsage(root: URL? = Self.root) async -> Int64 {
        guard let root else { return 0 }
        return await Task.detached(priority: .utility) { Self.measure(root) }.value
    }

    private static func measure(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func deleteDirectory(gatewayId: UUID, root: URL?) {
        guard let directory = self.directory(gatewayId: gatewayId, root: root) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Serializes writes so an older snapshot can never land after a newer one. Remembers the
    /// layout it last wrote (or loaded) per chat so a save writes only the segments that changed.
    actor Writer {
        static let shared = Writer()

        /// Chats whose layout is remembered.
        static let maxLayouts = 64

        var layouts: [URL: Layout] = [:]
        /// Least recently used first.
        var recency: [URL] = []

        /// Returns once every write and removal queued before it has finished.
        func drain() {}

        /// Tests: `prime` for this URL first suspends this long, standing in for a writer busy with saves.
        var primeDelaysForTesting: [URL: Duration] = [:]

        func delayPrimeForTesting(_ url: URL, by delay: Duration?) {
            self.primeDelaysForTesting[url] = delay
        }

        func remove(_ url: URL) {
            self.forgetLayout(url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: TranscriptCache.segmentsDirectory(of: url))
        }

        /// Sweeps only recognized transcript sidecars whose matching manifest is absent. Runs on
        /// the same actor as writes/removals, so it can't delete a segment directory mid-commit.
        func removeOrphanedSidecars(in directory: URL) {
            let fileManager = FileManager.default
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            for name in names {
                let digest: String
                if name.hasSuffix(".json.meta") {
                    digest = String(name.dropLast(".json.meta".count))
                } else if name.hasSuffix(".segments") {
                    digest = String(name.dropLast(".segments".count))
                } else {
                    continue
                }
                guard TranscriptCache.isCacheDigest(digest) else { continue }
                let manifest = directory.appending(path: "\(digest).json")
                guard !fileManager.fileExists(atPath: manifest.path(percentEncoded: false)) else { continue }
                try? fileManager.removeItem(at: directory.appending(path: name))
            }
        }

        /// Removes an unusable transcript, unless a save replaced it since it was read.
        func discard(_ url: URL, expected: Data, outcome: LoadOutcome, quarantine: URL?) {
            if let current = try? Data(contentsOf: url), current != expected { return }
            self.forgetLayout(url)
            TranscriptCache.discard(url, outcome: outcome, quarantine: quarantine)
        }

        func forget(under directory: URL) {
            let prefix = directory.standardizedFileURL.path(percentEncoded: false)
            for url in self.recency where url.standardizedFileURL.path(percentEncoded: false).hasPrefix(prefix) {
                self.forgetLayout(url)
            }
        }
    }
}
