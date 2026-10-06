import Foundation

/// A persisted attachment of an unsent message. The bytes live in `OutboxAttachmentStore`, not in
/// the outbox JSON.
public struct OutboxAttachmentRef: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var fileName: String
    public var mimeType: String
    public var byteCount: Int

    public init(id: UUID, fileName: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

/// Attachment bytes of unsent messages, one raw file each at
/// `<OutboxStore.root>/Attachments/<gatewayId>/<entryId>/<attachmentId>`. They are user content
/// (Application Support, included in backups) and are removed when their entry leaves the outbox.
///
/// File work runs on the Gateway's outbox write queue, in the order it was requested and ahead
/// of the outbox JSON that references it, so `OutboxStore.load` and `flushWrites` wait for it.
/// `OutboxStore.saveNow` runs whatever is still pending on the calling thread first.
public enum OutboxAttachmentStore {
    /// The most attachment bytes one Gateway's outbox keeps on disk; a send over it stays memory-only.
    public static let maxTotalBytes = 200 * 1024 * 1024

    public static func isAvailable(root: URL? = OutboxStore.root) -> Bool { root != nil }

    static func gatewayDirectory(gatewayId: UUID, root: URL?) -> URL? {
        root?.appending(path: "Attachments/\(gatewayId.uuidString)", directoryHint: .isDirectory)
    }

    public static func directory(gatewayId: UUID, entryId: String, root: URL? = OutboxStore.root) -> URL? {
        guard !entryId.isEmpty, entryId != "..", entryId != ".", !entryId.contains("/") else { return nil }
        return self.gatewayDirectory(gatewayId: gatewayId, root: root)?.appending(path: entryId, directoryHint: .isDirectory)
    }

    public static func fileURL(gatewayId: UUID, entryId: String, attachmentId: UUID, root: URL? = OutboxStore.root) -> URL? {
        self.directory(gatewayId: gatewayId, entryId: entryId, root: root)?.appending(path: attachmentId.uuidString)
    }

    public static func refs(for attachments: [OutgoingAttachment]) -> [OutboxAttachmentRef] {
        attachments.map { OutboxAttachmentRef(id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType, byteCount: $0.data.count) }
    }

    /// Whether every attachment file of the entry is on disk (once pending writes have landed).
    public static func filesExist(for entry: OutboxEntry, gatewayId: UUID, root: URL? = OutboxStore.root) -> Bool {
        self.drain(gatewayId: gatewayId, root: root)
        return entry.attachments.allSatisfy { ref in
            self.fileURL(gatewayId: gatewayId, entryId: entry.id, attachmentId: ref.id, root: root)
                .map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        }
    }

    /// Reads the entry's attachment bytes, or nil when any file is missing.
    public static func read(entry: OutboxEntry, gatewayId: UUID, root: URL? = OutboxStore.root) async -> [OutgoingAttachment]? {
        await Task.detached(priority: .userInitiated) {
            self.drain(gatewayId: gatewayId, root: root)
            var result: [OutgoingAttachment] = []
            for ref in entry.attachments {
                guard let url = self.fileURL(gatewayId: gatewayId, entryId: entry.id, attachmentId: ref.id, root: root),
                      let data = try? Data(contentsOf: url) else { return nil }
                result.append(OutgoingAttachment(id: ref.id, fileName: ref.fileName, mimeType: ref.mimeType, data: data))
            }
            return result
        }.value
    }

    /// Reads one image for an inline pending-row preview. The caller is the serialized preview
    /// worker, so this never competes with another original image buffer. It drains queued writes
    /// first, then maps only the selected image instead of loading every file in the outbox entry.
    static func readImageAttachment(
        entryId: String,
        attachment: OutboxAttachmentRef,
        gatewayId: UUID,
        root: URL?) -> OutgoingAttachment?
    {
        guard attachment.mimeType.lowercased().hasPrefix("image/"),
              attachment.byteCount > 0, attachment.byteCount <= GatewayMediaClient.explicitMaxBytes,
              let url = self.fileURL(gatewayId: gatewayId, entryId: entryId, attachmentId: attachment.id, root: root)
        else { return nil }
        self.drain(gatewayId: gatewayId, root: root)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty, data.count <= GatewayMediaClient.explicitMaxBytes
        else { return nil }
        return OutgoingAttachment(id: attachment.id, fileName: attachment.fileName, mimeType: attachment.mimeType, data: data)
    }

    // MARK: Queued file work

    /// Queues writing the files; false when the store is off or the entry id can't be a directory name.
    @discardableResult
    static func enqueueWrite(_ attachments: [OutgoingAttachment], entryId: String, gatewayId: UUID, root: URL?) -> Bool {
        guard let dir = self.directory(gatewayId: gatewayId, entryId: entryId, root: root) else { return false }
        self.enqueue(gatewayId: gatewayId, root: root) {
            do {
                try OutboxStore.createDirectory(dir)
                for attachment in attachments {
                    try attachment.data.write(to: dir.appending(path: attachment.id.uuidString), options: OutboxStore.writeOptions)
                }
            } catch {
                OutboxStore.logger.error("Couldn't write outbox attachments: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: dir)
            }
        }
        return true
    }

    static func enqueueRemove(entryId: String, gatewayId: UUID, root: URL?) {
        guard let dir = self.directory(gatewayId: gatewayId, entryId: entryId, root: root) else { return }
        self.enqueue(gatewayId: gatewayId, root: root) { try? FileManager.default.removeItem(at: dir) }
    }

    static func enqueueMove(from entryId: String, to newId: String, gatewayId: UUID, root: URL?) {
        guard let from = self.directory(gatewayId: gatewayId, entryId: entryId, root: root),
              let to = self.directory(gatewayId: gatewayId, entryId: newId, root: root) else { return }
        self.enqueue(gatewayId: gatewayId, root: root) {
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Deletes entry directories that no entry in `keeping` owns.
    static func enqueueSweep(keeping: Set<String>, gatewayId: UUID, root: URL?) {
        guard let dir = self.gatewayDirectory(gatewayId: gatewayId, root: root) else { return }
        self.enqueue(gatewayId: gatewayId, root: root) {
            let files = FileManager.default
            for url in (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where !keeping.contains(url.lastPathComponent)
            {
                try? files.removeItem(at: url)
            }
            if keeping.isEmpty { try? files.removeItem(at: dir) }
        }
    }

    /// Deletes this Gateway's attachment files now (the Gateway was removed).
    static func removeAll(gatewayId: UUID, root: URL?) {
        guard let dir = self.gatewayDirectory(gatewayId: gatewayId, root: root) else { return }
        self.drain(gatewayId: gatewayId, root: root)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Plumbing

    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pending: [URL: [@Sendable () -> Void]] = [:]
    private static let running = NSLock()

    private static func enqueue(gatewayId: UUID, root: URL?, _ work: @escaping @Sendable () -> Void) {
        guard let key = self.gatewayDirectory(gatewayId: gatewayId, root: root) else { return }
        self.pendingLock.withLock { self.pending[key, default: []].append(work) }
        OutboxStore.enqueueWork(gatewayId: gatewayId, root: root) { self.drain(gatewayId: gatewayId, root: root) }
    }

    /// Runs the file work still pending for this Gateway, in order, on the calling thread.
    static func drain(gatewayId: UUID, root: URL?) {
        guard let key = self.gatewayDirectory(gatewayId: gatewayId, root: root) else { return }
        self.running.lock()
        defer { self.running.unlock() }
        let work = self.pendingLock.withLock { self.pending.removeValue(forKey: key) ?? [] }
        for item in work { item() }
    }
}
