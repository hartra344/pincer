import CryptoKit
import Foundation

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

        public static let currentVersion = 4

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

    static func meta(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async -> Meta? {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root)?.appendingPathExtension("meta") else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        }.value
    }

    public static func load(gatewayId: UUID, sessionKey: String, root: URL? = Self.root) async -> Snapshot? {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey, root: root) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == Snapshot.currentVersion
            else { return nil }
            return snapshot
        }.value
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

    /// Deletes the Gateway's transcripts and message search index. `permanently`: the Gateway
    /// was removed from the app, so saves still under way don't write them again.
    public static func removeAll(gatewayId: UUID, permanently: Bool = false) {
        MessageIndex.discard(gatewayId: gatewayId, permanently: permanently)
        self.deleteDirectory(gatewayId: gatewayId, root: Self.root)
    }

    /// Deletes the Gateway's transcripts under another cache root (tests).
    static func removeAll(gatewayId: UUID, root: URL?) {
        self.deleteDirectory(gatewayId: gatewayId, root: root)
    }

    private static func deleteDirectory(gatewayId: UUID, root: URL?) {
        guard let directory = self.directory(gatewayId: gatewayId, root: root) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Serializes writes so an older snapshot can never land after a newer one.
    private actor Writer {
        static let shared = Writer()

        /// The file's modification date once written, or nil when it couldn't be.
        func write(_ snapshot: Snapshot, to url: URL) -> Date? {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let meta = try JSONEncoder().encode(Meta(complete: snapshot.complete, activityMs: snapshot.activityMs))
                try meta.write(to: url.appendingPathExtension("meta"), options: [.atomic, .completeFileProtection])
                return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            } catch {
                // A missing cache only costs a refetch.
                return nil
            }
        }
    }
}
