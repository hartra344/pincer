import CryptoKit
import Foundation
import os

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

        public static let currentVersion = 7

        public init(version: Int = Self.currentVersion, items: [ChatItem], complete: Bool, activityMs: Double? = nil) {
            self.version = version
            self.items = items
            self.complete = complete
            self.activityMs = activityMs
        }
    }

    /// Written next to each transcript so freshness checks don't decode the whole thing.
    struct Meta: Codable, Sendable {
        var complete: Bool
        var activityMs: Double?
        /// The transcript's `Snapshot.version`; a sidecar without one (written before it was
        /// recorded) or for another version never vouches for freshness.
        var version: Int?
    }

    /// What `loadWithOutcome` found on disk. Anything but `missing`, `loaded` and `migrated` means
    /// the file was unusable and has been removed, so the chat is refetched from the Gateway.
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

        /// The file couldn't be used and was removed.
        public var discarded: Bool {
            switch self {
            case .missing, .loaded, .migrated: false
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

    private static func describe(_ error: Error) -> String {
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
            .appending(path: "Pincer/Transcripts", directoryHint: .isDirectory)
    }

    public static func directory(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        root?.appending(path: gatewayId.uuidString, directoryHint: .isDirectory)
    }

    public static func file(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) -> URL? {
        let digest = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return self.directory(gatewayId: gatewayId, root: root)?.appending(path: "\(digest).json")
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
    static func read(_ url: URL, gatewayId: UUID, root: URL? = Self.root,
                     priority: TaskPriority) async -> (snapshot: Snapshot?, outcome: LoadOutcome)
    {
        let quarantine = self.quarantineDirectory(gatewayId: gatewayId, root: root)
        return await Task.detached(priority: priority) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return (nil, .missing) }
                let outcome = LoadOutcome.corrupt("unreadable: \(error.localizedDescription)")
                Self.discard(url, outcome: outcome, quarantine: quarantine)
                return (nil, outcome)
            }
            let result = Self.decode(data)
            switch result.outcome {
            case .missing, .loaded:
                break
            case let .migrated(from):
                Self.logger.notice("Migrated cached transcript \(url.lastPathComponent, privacy: .private) from v\(from) to v\(Snapshot.currentVersion)")
                if let snapshot = result.snapshot, !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) {
                    _ = await Writer.shared.write(snapshot, to: url)
                }
            case .outdated, .future, .corrupt:
                Self.discard(url, outcome: result.outcome, quarantine: quarantine)
            }
            return result
        }.value
    }

    /// `<gateway dir>/Quarantine`: corrupt transcripts moved aside, newest `maxQuarantined` kept.
    public static func quarantineDirectory(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        self.directory(gatewayId: gatewayId, root: root)?.appending(path: "Quarantine", directoryHint: .isDirectory)
    }

    static let maxQuarantined = 5

    /// Removes an unusable transcript and its sidecar; a corrupt one is quarantined.
    private static func discard(_ url: URL, outcome: LoadOutcome, quarantine: URL?) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url.appendingPathExtension("meta"))
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
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let target = quarantine.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(stamp).json")
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

    private static func trimQuarantine(_ directory: URL) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > self.maxQuarantined else { return }
        let sorted = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da == db ? a.lastPathComponent > b.lastPathComponent : da > db
        }
        for file in sorted.dropFirst(self.maxQuarantined) { try? fileManager.removeItem(at: file) }
    }

    /// Writes the transcript, then brings the Gateway's message search index up to date with it.
    /// Nothing is written for a Gateway removed from the app, even by a save already under way.
    /// With the cache off, an index kept in memory (the demo) is still updated.
    public static func save(_ snapshot: Snapshot, gatewayId: UUID, sessionKey: String) async {
        guard !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) else { return }
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey) else {
            if MessageIndex.location(gatewayId: gatewayId) == .memory {
                await MessageIndex.shared(gatewayId: gatewayId).index(sessionKey: sessionKey, snapshot: snapshot, fileMtime: Date())
            }
            return
        }
        guard let written = await Writer.shared.write(snapshot, to: url) else { return }
        guard !MessageIndex.isDiscardedPermanently(gatewayId: gatewayId) else {
            self.deleteDirectory(gatewayId: gatewayId, root: Self.root)
            return
        }
        await MessageIndex.shared(gatewayId: gatewayId).index(sessionKey: sessionKey, snapshot: snapshot, fileMtime: written)
    }

    /// Writes the transcript under another cache root (tests). The message search index, which
    /// lives under the default root, isn't touched.
    static func save(_ snapshot: Snapshot, gatewayId: UUID, sessionKey: String, root: URL?) async {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return }
        _ = await Writer.shared.write(snapshot, to: url)
    }

    /// Deletes one chat's cached transcript (its stored tool details included), its sidecar and
    /// its rows in the message search index, e.g. when the session is deleted or rewound. A
    /// quarantined copy is left for diagnosis. The files go through the same writer as saves, so a
    /// save already queued lands before the removal, and the index skips a chat whose file is gone,
    /// so that save can't make it searchable again.
    public static func remove(gatewayId: UUID, sessionKey: String) async {
        await self.remove(gatewayId: gatewayId, sessionKey: sessionKey, root: Self.root)
        if Self.root != nil || MessageIndex.location(gatewayId: gatewayId) == .memory {
            await MessageIndex.shared(gatewayId: gatewayId).remove(sessionKey: sessionKey)
        }
    }

    /// Deletes one chat's transcript and sidecar under another cache root (tests); the message
    /// search index, which lives under the default root, isn't touched.
    static func remove(gatewayId: UUID, sessionKey: String, root: URL?) async {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return }
        await Writer.shared.remove(url)
    }

    /// Deletes the Gateway's transcripts and message search index. `permanently`: the Gateway
    /// was removed from the app, so saves still under way don't write them again.
    public static func removeAll(gatewayId: UUID, permanently: Bool = false) {
        MessageIndex.whileDeleting {
            MessageIndex.discard(gatewayId: gatewayId, permanently: permanently)
            self.deleteDirectory(gatewayId: gatewayId, root: Self.root)
        }
    }

    /// Deletes the Gateway's transcripts under another cache root (tests).
    static func removeAll(gatewayId: UUID, root: URL?) {
        self.deleteDirectory(gatewayId: gatewayId, root: root)
    }

    /// Deletes every Gateway's cached transcripts, search indexes and quarantined files (Settings'
    /// Clear Cache). Open chats keep what they show and save again on their next change. A save
    /// under way when this runs either fails harmlessly (writes are atomic, and the sidecar only
    /// follows a written transcript) or writes a fresh, valid file. Such a save isn't indexed
    /// (no index opens while the files are deleted); it's indexed when it next saves or reconciles.
    public static func removeEverything() {
        guard let root = Self.root else { return }
        MessageIndex.whileDeleting {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries {
                if let id = UUID(uuidString: entry.lastPathComponent) { MessageIndex.discard(gatewayId: id) }
            }
            self.removeEverything(root: root)
        }
        logger.notice("Cleared the transcript cache")
    }

    /// Deletes everything under another cache root (tests); search indexes in memory aren't touched.
    static func removeEverything(root: URL?) {
        guard let root else { return }
        let fileManager = FileManager.default
        for entry in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Bytes the transcript cache takes on disk, search indexes and quarantined files included.
    public static func diskUsage() async -> Int64 {
        await self.diskUsage(root: Self.root)
    }

    static func diskUsage(root: URL?) async -> Int64 {
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

    /// Serializes writes so an older snapshot can never land after a newer one.
    private actor Writer {
        static let shared = Writer()

        func remove(_ url: URL) {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
            try? FileManager.default.removeItem(at: url)
        }

        /// The file's modification date once written, or nil when it couldn't be.
        func write(_ snapshot: Snapshot, to url: URL) -> Date? {
            let metaURL = url.appendingPathExtension("meta")
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                // The sidecar goes first and comes back only once the transcript is written, so it
                // never vouches for a transcript that isn't there.
                try? FileManager.default.removeItem(at: metaURL)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let meta = try JSONEncoder().encode(
                    Meta(complete: snapshot.complete, activityMs: snapshot.activityMs, version: snapshot.version))
                try meta.write(to: metaURL, options: [.atomic, .completeFileProtection])
                return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            } catch {
                // A missing cache only costs a refetch.
                try? FileManager.default.removeItem(at: metaURL)
                TranscriptCache.logger.error("Couldn't write cached transcript \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
