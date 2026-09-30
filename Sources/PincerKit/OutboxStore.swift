import Foundation
import os
import PincerPush

/// On-disk outboxes, one versioned JSON file per Gateway. Unsent messages are user content, so
/// they live in Application Support (like drafts), not in Caches.
public enum OutboxStore {
    struct Envelope: Codable {
        var version: Int
        var outbox: Outbox
    }

    public enum LoadOutcome: Equatable, Sendable {
        case missing
        case loaded
        /// Unreadable or undecodable; moved aside as `<id>.corrupt.json`.
        case corrupt(String)
        /// Written by a newer app; moved aside as `<id>.v<version>.json` so it isn't overwritten.
        case future(version: Int)
    }

    public static let currentVersion = 1
    static let logger = Logger(subsystem: "chat.pincer", category: "Outbox")

    /// `PINCER_OUTBOX_DIR` redirects outboxes (checks); `PINCER_OUTBOX_DIR=off` disables them.
    public static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["PINCER_OUTBOX_DIR"] {
            return override == "off" ? nil : URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "\(DevNamespace.folderName("Pincer"))/Outbox", directoryHint: .isDirectory)
    }

    public static func file(gatewayId: UUID, root: URL? = Self.root) -> URL? {
        root?.appending(path: "\(gatewayId.uuidString).json")
    }

    static func decode(_ data: Data) -> (outbox: Outbox?, outcome: LoadOutcome) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, .corrupt("not a JSON object"))
        }
        guard let version = json["version"] as? Int else { return (nil, .corrupt("no version")) }
        if version > self.currentVersion { return (nil, .future(version: version)) }
        do {
            let envelope = try self.decoder.decode(Envelope.self, from: data)
            return (envelope.outbox, .loaded)
        } catch {
            return (nil, .corrupt(String(describing: error)))
        }
    }

    public static func load(gatewayId: UUID, root: URL? = Self.root) async -> (outbox: Outbox?, outcome: LoadOutcome) {
        guard let url = self.file(gatewayId: gatewayId, root: root) else { return (nil, .missing) }
        // A store that just stopped may still be writing this file; read what it wrote last.
        await self.pendingWrite(to: url)?.value
        return await Task.detached(priority: .userInitiated) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return (nil, .missing) }
                let outcome = LoadOutcome.corrupt("unreadable: \(error.localizedDescription)")
                Self.moveAside(url, suffix: "corrupt")
                return (nil, outcome)
            }
            let result = Self.decode(data)
            switch result.outcome {
            case let .corrupt(reason):
                Self.logger.error("Set aside corrupt outbox \(url.lastPathComponent, privacy: .private): \(reason, privacy: .public)")
                Self.moveAside(url, suffix: "corrupt")
            case let .future(version):
                Self.logger.notice("Set aside outbox \(url.lastPathComponent, privacy: .private): v\(version) is newer than this app")
                Self.moveAside(url, suffix: "v\(version)")
            case .missing, .loaded:
                break
            }
            return result
        }.value
    }

    /// Writes the outbox (only entries that survive a relaunch), or removes the file when empty.
    public static func save(_ outbox: Outbox, gatewayId: UUID, root: URL? = Self.root) async {
        self.enqueueSave(outbox, gatewayId: gatewayId, root: root)
        await self.flushWrites(gatewayId: gatewayId, root: root)
    }

    /// Queues a `save` behind this Gateway's earlier ones and returns at once. `load` waits for
    /// the queue, so a store started right after another stopped (editing a Gateway, a relaunch in
    /// checks) reads the last outbox the old one wrote, not an older file.
    public static func enqueueSave(_ outbox: Outbox, gatewayId: UUID, root: URL? = Self.root) {
        guard let url = self.file(gatewayId: gatewayId, root: root) else { return }
        let outbox = outbox.persistable
        self.queue.withLock { queue in
            let generation = queue.next(for: url)
            let previous = queue.tasks[url]
            queue.tasks[url] = Task.detached(priority: .utility) {
                await previous?.value
                Self.write(outbox, to: url, generation: generation)
            }
        }
    }

    /// Writes the outbox on this thread, ahead of anything still queued (which then never lands):
    /// for when the app is about to quit and a queued write might not get to run.
    public static func saveNow(_ outbox: Outbox, gatewayId: UUID, root: URL? = Self.root) {
        guard let url = self.file(gatewayId: gatewayId, root: root) else { return }
        OutboxAttachmentStore.drain(gatewayId: gatewayId, root: root)
        let generation = self.queue.withLock { $0.next(for: url) }
        self.write(outbox.persistable, to: url, generation: generation)
    }

    /// Runs `work` on this Gateway's write queue, after everything queued before it; `load` and
    /// `flushWrites` wait for it.
    static func enqueueWork(gatewayId: UUID, root: URL?, _ work: @escaping @Sendable () -> Void) {
        guard let url = self.file(gatewayId: gatewayId, root: root) else { return }
        self.queue.withLock { queue in
            let previous = queue.tasks[url]
            queue.tasks[url] = Task.detached(priority: .utility) {
                await previous?.value
                work()
            }
        }
    }

    /// Returns once every write queued so far for this Gateway has landed.
    public static func flushWrites(gatewayId: UUID, root: URL? = Self.root) async {
        guard let url = self.file(gatewayId: gatewayId, root: root) else { return }
        await self.pendingWrite(to: url)?.value
    }

    /// Deletes the file now; writes still queued for it never land.
    public static func remove(gatewayId: UUID, root: URL? = Self.root) {
        self.saveNow(Outbox(), gatewayId: gatewayId, root: root)
    }

    private struct WriteQueue {
        /// The last queued write per file; each waits for the one before it.
        var tasks: [URL: Task<Void, Never>] = [:]
        var generations: [URL: Int] = [:]

        mutating func next(for url: URL) -> Int {
            let generation = self.generations[url, default: 0] + 1
            self.generations[url] = generation
            return generation
        }
    }

    private static let queue = OSAllocatedUnfairLock(initialState: WriteQueue())
    /// Serializes file writes and remembers the newest generation written per file, so an older
    /// outbox never lands after a newer one.
    private static let written = NSLock()
    nonisolated(unsafe) private static var writtenGenerations: [URL: Int] = [:]

    private static func pendingWrite(to url: URL) -> Task<Void, Never>? {
        self.queue.withLock { $0.tasks[url] }
    }

    private static func write(_ outbox: Outbox, to url: URL, generation: Int) {
        self.written.lock()
        defer { self.written.unlock() }
        guard generation > self.writtenGenerations[url, default: 0] else { return }
        self.writtenGenerations[url] = generation
        let files = FileManager.default
        guard !outbox.isEmpty else {
            try? files.removeItem(at: url)
            return
        }
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try OutboxStore.encoder.encode(Envelope(version: OutboxStore.currentVersion, outbox: outbox))
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            OutboxStore.logger.error("Couldn't write outbox \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func moveAside(_ url: URL, suffix: String) {
        let target = url.deletingPathExtension().appendingPathExtension(suffix).appendingPathExtension("json")
        try? FileManager.default.removeItem(at: target)
        if (try? FileManager.default.moveItem(at: url, to: target)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
