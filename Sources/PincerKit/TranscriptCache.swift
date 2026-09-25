import CryptoKit
import Foundation

/// On-disk copy of each chat's committed transcript. Reopening a chat is instant (even offline) and
/// older history — which doesn't change — never has to be refetched; only the newest page is.
enum TranscriptCache {
    struct Snapshot: Codable, Sendable {
        var version = Self.currentVersion
        var items: [ChatItem]
        /// The transcript reaches back to the first message (no older history on the Gateway).
        var complete: Bool
        /// Session activity when saved; an unchanged session needs no background refresh.
        var activityMs: Double?

        static let currentVersion = 2
    }

    /// Written next to each transcript so freshness checks don't decode the whole thing.
    struct Meta: Codable, Sendable {
        var complete: Bool
        var activityMs: Double?
    }

    /// Newest items kept on disk per chat.
    static let maxItems = 20000

    /// `PINCER_CACHE_DIR` redirects the cache (checks); `PINCER_CACHE_DIR=off` disables it.
    static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["PINCER_CACHE_DIR"] {
            return override == "off" ? nil : URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Pincer/Transcripts", directoryHint: .isDirectory)
    }

    static func directory(gatewayId: UUID) -> URL? {
        self.root?.appending(path: gatewayId.uuidString, directoryHint: .isDirectory)
    }

    static func file(gatewayId: UUID, sessionKey: String) -> URL? {
        let digest = SHA256.hash(data: Data(sessionKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return self.directory(gatewayId: gatewayId)?.appending(path: "\(digest).json")
    }

    static func meta(gatewayId: UUID, sessionKey: String) async -> Meta? {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey)?.appendingPathExtension("meta") else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        }.value
    }

    static func load(gatewayId: UUID, sessionKey: String) async -> Snapshot? {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == Snapshot.currentVersion
            else { return nil }
            return snapshot
        }.value
    }

    static func save(_ snapshot: Snapshot, gatewayId: UUID, sessionKey: String) async {
        guard let url = self.file(gatewayId: gatewayId, sessionKey: sessionKey) else { return }
        await Writer.shared.write(snapshot, to: url)
    }

    static func removeAll(gatewayId: UUID) {
        guard let directory = self.directory(gatewayId: gatewayId) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Serializes writes so an older snapshot can never land after a newer one.
    private actor Writer {
        static let shared = Writer()

        func write(_ snapshot: Snapshot, to url: URL) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                let meta = try JSONEncoder().encode(Meta(complete: snapshot.complete, activityMs: snapshot.activityMs))
                try meta.write(to: url.appendingPathExtension("meta"), options: [.atomic, .completeFileProtection])
            } catch {
                // A missing cache only costs a refetch.
            }
        }
    }
}
