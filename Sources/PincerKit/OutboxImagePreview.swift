import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OutboxImagePreviewKey: Hashable, Sendable {
    var entryId: String
    var attachmentId: UUID
}

private struct OutboxImagePreviewRequest: Sendable {
    var key: OutboxImagePreviewKey
    var attachment: OutboxAttachmentRef?
    var fileName: String
    var mimeType: String
}

struct OutboxImagePreviewIdentity: Hashable {
    var imageCacheKey: String
    var mimeType: String?
    var alt: String?
    var width: Int?
    var height: Int?

    init(_ image: ImageRef) {
        self.imageCacheKey = image.cacheKey
        self.mimeType = image.mimeType
        self.alt = image.alt
        self.width = image.width
        self.height = image.height
    }
}

struct OutboxImagePreviewEviction: Hashable {
    var key: OutboxImagePreviewKey
    var image: OutboxImagePreviewIdentity

    init(key: OutboxImagePreviewKey, image: ImageRef) {
        self.key = key
        self.image = OutboxImagePreviewIdentity(image)
    }

}

/// LRU for image sources embedded in pending ChatItems. Rows also retain the same ImageRef, so
/// eviction is paired with a row rebuild that replaces `.image` with the original `.file` block.
struct OutboxImagePreviewCache {
    static let defaultByteLimit = 1_048_576
    let byteLimit: Int

    init(byteLimit: Int = Self.defaultByteLimit) {
        self.byteLimit = max(0, byteLimit)
    }

    private struct Value {
        var image: ImageRef
        var bytes: Int
        var older: OutboxImagePreviewKey?
        var newer: OutboxImagePreviewKey?
    }

    private var values: [OutboxImagePreviewKey: Value] = [:]
    private var leastRecent: OutboxImagePreviewKey?
    private var mostRecent: OutboxImagePreviewKey?
    private(set) var retainedBytes = 0

    func contains(_ key: OutboxImagePreviewKey) -> Bool { self.values[key] != nil }

    mutating func image(for key: OutboxImagePreviewKey) -> ImageRef? {
        guard let value = self.values[key] else { return nil }
        self.touch(key)
        return value.image
    }

    mutating func retain(only active: Set<OutboxImagePreviewKey>) {
        for key in Array(self.values.keys) where !active.contains(key) {
            _ = self.remove(key)
        }
    }

    mutating func insert(_ image: ImageRef, encodedBytes: Int, for key: OutboxImagePreviewKey) -> [OutboxImagePreviewEviction] {
        guard encodedBytes > 0, encodedBytes <= self.byteLimit else { return [] }
        var evicted: [OutboxImagePreviewEviction] = []
        if let previous = self.remove(key) {
            evicted.append(OutboxImagePreviewEviction(key: key, image: previous.image))
        }
        while self.retainedBytes + encodedBytes > self.byteLimit, let oldest = self.leastRecent {
            if let removed = self.remove(oldest) {
                evicted.append(OutboxImagePreviewEviction(key: oldest, image: removed.image))
            }
        }
        self.values[key] = Value(image: image, bytes: encodedBytes, older: self.mostRecent, newer: nil)
        if let mostRecent = self.mostRecent {
            self.values[mostRecent]?.newer = key
        } else {
            self.leastRecent = key
        }
        self.mostRecent = key
        self.retainedBytes += encodedBytes
        return evicted
    }

    private mutating func touch(_ key: OutboxImagePreviewKey) {
        guard self.mostRecent != key, let value = self.values[key] else { return }
        self.unlink(key, value: value)
        self.values[key]?.older = self.mostRecent
        self.values[key]?.newer = nil
        if let mostRecent = self.mostRecent {
            self.values[mostRecent]?.newer = key
        } else {
            self.leastRecent = key
        }
        self.mostRecent = key
    }

    @discardableResult
    private mutating func remove(_ key: OutboxImagePreviewKey) -> Value? {
        guard let value = self.values.removeValue(forKey: key) else { return nil }
        self.unlink(key, value: value)
        self.retainedBytes -= value.bytes
        return value
    }

    private mutating func unlink(_ key: OutboxImagePreviewKey, value: Value) {
        if let older = value.older { self.values[older]?.newer = value.newer }
        else { self.leastRecent = value.newer }
        if let newer = value.newer { self.values[newer]?.older = value.older }
        else { self.mostRecent = value.older }
    }
}

/// Performs each persisted read, downsample and encode serially off the main actor. An entry's
/// original bytes are never retained by the worker after its small display source is returned.
actor OutboxImagePreviewWorker {
    static let shared = OutboxImagePreviewWorker()
    static let maxEncodedBytes = 192 * 1024

    func prepare(
        _ attachment: OutgoingAttachment,
        probe: (@Sendable () -> Void)?) -> (image: ImageRef, encodedBytes: Int)?
    {
        guard !Task.isCancelled, attachment.isImage else { return nil }
        probe?()
        guard !Task.isCancelled else { return nil }
        return Self.thumbnail(attachment.data, fileName: attachment.fileName, mimeType: attachment.mimeType)
    }

    func preparePersisted(
        entryId: String,
        attachment: OutboxAttachmentRef,
        gatewayId: UUID,
        root: URL?,
        probe: (@Sendable () -> Void)?) -> (image: ImageRef, encodedBytes: Int)?
    {
        guard !Task.isCancelled else { return nil }
        probe?()
        guard !Task.isCancelled,
              let source = OutboxAttachmentStore.readImageAttachment(
                  entryId: entryId, attachment: attachment, gatewayId: gatewayId, root: root)
        else { return nil }
        return Self.thumbnail(source.data, fileName: source.fileName, mimeType: source.mimeType)
    }

    private static func thumbnail(_ data: Data, fileName: String, mimeType: String) -> (image: ImageRef, encodedBytes: Int)? {
        guard !Task.isCancelled, data.count <= GatewayMediaClient.explicitMaxBytes else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for pixels in [512, 384, 320] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard !Task.isCancelled, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let isPNG = Self.hasAlpha(image)
            let output = NSMutableData()
            let encodedType = (isPNG ? UTType.png : UTType.jpeg).identifier as CFString
            guard let destination = CGImageDestinationCreateWithData(output, encodedType, 1, nil) else { continue }
            let properties: [CFString: Any] = isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.62]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let encodedData = output as Data
            guard encodedData.count <= Self.maxEncodedBytes else { continue }
            let encoded = encodedData.base64EncodedString()
            let previewMIME = isPNG ? "image/png" : "image/jpeg"
            let dataURL = "data:\(previewMIME);base64,\(encoded)"
            let reference = ImageRef(
                artifactId: nil, base64: dataURL, url: nil, mimeType: previewMIME,
                alt: fileName, width: image.width, height: image.height)
            return (reference, dataURL.utf8.count)
        }
        return nil
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
    }
}

extension ChatStore {
    /// Completion seam for checks that inspect restored image rows. The batch can schedule a
    /// follow-up if another outbox entry arrived while this one was being prepared.
    func waitForOutboxImagePreviews() async {
        while let task = self.outboxPreviewTask { await task.value }
    }

    func pruneOutboxImagePreviews(_ entries: [OutboxEntry]) {
        let requests = self.outboxImagePreviewRequests(for: entries)
        var active = Set(requests.map(\.key))
        let acceptedPendingIds = Set(self.items.lazy.filter { $0.isPending && $0.outboxState == nil }
            .compactMap(\.idempotencyKey))
        active.formUnion(self.outboxPreviewActiveKeys.filter { acceptedPendingIds.contains($0.entryId) })
        self.outboxPreviewActiveKeys = active
        self.outboxImagePreviews.retain(only: active)
        self.outboxPreviewAttempts.formIntersection(active)
    }

    func releaseCommittedOutboxImagePreviews(_ committedIds: Set<String>) {
        guard !committedIds.isEmpty else { return }
        let stillPendingIds = Set(self.items.lazy.filter { $0.isPending }.compactMap(\.idempotencyKey))
        self.outboxPreviewActiveKeys = Set(self.outboxPreviewActiveKeys.filter {
            !committedIds.contains($0.entryId) || stillPendingIds.contains($0.entryId)
        })
        self.outboxImagePreviews.retain(only: self.outboxPreviewActiveKeys)
        self.outboxPreviewAttempts.formIntersection(self.outboxPreviewActiveKeys)
    }

    func cancelOutboxImagePreviews() {
        self.outboxPreviewGeneration &+= 1
        self.outboxPreviewTask?.cancel()
        self.outboxPreviewTask = nil
        self.outboxPreviewActiveKeys.removeAll()
        self.outboxPreviewAttempts.removeAll()
        self.outboxImagePreviews = OutboxImagePreviewCache(byteLimit: self.outboxImagePreviews.byteLimit)
        var items = self.items
        for index in items.indices where items[index].isPending {
            let files = items[index].blocks.map { block -> ContentBlock in
                guard case let .image(image) = block else { return block }
                return .file(FileRef(name: image.alt ?? "image", mimeType: image.mimeType))
            }
            if files != items[index].blocks { items[index].blocks = files }
        }
        if items != self.items { self.items = items }
    }

    private func releaseEvictedAcceptedPreviewRows(_ evictions: [OutboxImagePreviewEviction]) {
        guard !evictions.isEmpty else { return }
        let acceptedIds = Set(self.items.lazy.filter { $0.isPending && $0.outboxState == nil }
            .compactMap(\.idempotencyKey))
        guard !acceptedIds.isEmpty else { return }
        var imagesByEntry: [String: Set<OutboxImagePreviewIdentity>] = [:]
        for eviction in evictions where acceptedIds.contains(eviction.key.entryId) {
            imagesByEntry[eviction.key.entryId, default: []].insert(eviction.image)
        }
        guard !imagesByEntry.isEmpty else { return }
        var items = self.items
        for index in items.indices {
            guard let key = items[index].idempotencyKey, let evictedImages = imagesByEntry[key] else { continue }
            let blocks = items[index].blocks.map { block -> ContentBlock in
                guard case let .image(image) = block,
                      evictedImages.contains(OutboxImagePreviewIdentity(image)) else { return block }
                return .file(FileRef(name: image.alt ?? "image", mimeType: image.mimeType))
            }
            if blocks != items[index].blocks { items[index].blocks = blocks }
        }
        if items != self.items { self.items = items }
    }

    func outboxPreviewBlocks(for entry: OutboxEntry) -> [ContentBlock] {
        var blocks: [ContentBlock] = entry.displayText.isEmpty ? [] : [.text(entry.displayText)]
        var seen = Set<UUID>()
        for attachment in entry.attachments {
            seen.insert(attachment.id)
            blocks.append(contentsOf: self.outboxBlocks(
                entryId: entry.id, id: attachment.id, name: attachment.fileName, mimeType: attachment.mimeType))
        }
        for attachment in self.gateway?.outboxAttachments[entry.id] ?? [] where !seen.contains(attachment.id) {
            seen.insert(attachment.id)
            blocks.append(contentsOf: self.outboxBlocks(
                entryId: entry.id, id: attachment.id, name: attachment.fileName, mimeType: attachment.mimeType))
        }
        return blocks
    }

    private func outboxBlocks(entryId: String, id: UUID, name: String, mimeType: String) -> [ContentBlock] {
        guard mimeType.lowercased().hasPrefix("image/") else {
            return [.file(FileRef(name: name, mimeType: mimeType))]
        }
        let key = OutboxImagePreviewKey(entryId: entryId, attachmentId: id)
        if let preview = self.outboxImagePreviews.image(for: key) { return [.image(preview)] }
        return [.file(FileRef(name: name, mimeType: mimeType))]
    }

    private func outboxImagePreviewRequests(for entries: [OutboxEntry]) -> [OutboxImagePreviewRequest] {
        var requests: [OutboxImagePreviewRequest] = []
        var seen = Set<OutboxImagePreviewKey>()
        for entry in entries {
            for attachment in entry.attachments where attachment.mimeType.lowercased().hasPrefix("image/") {
                let key = OutboxImagePreviewKey(entryId: entry.id, attachmentId: attachment.id)
                guard seen.insert(key).inserted else { continue }
                requests.append(OutboxImagePreviewRequest(
                    key: key, attachment: attachment, fileName: attachment.fileName, mimeType: attachment.mimeType))
            }
            for attachment in self.gateway?.outboxAttachments[entry.id] ?? [] where attachment.isImage {
                let key = OutboxImagePreviewKey(entryId: entry.id, attachmentId: attachment.id)
                guard seen.insert(key).inserted else { continue }
                requests.append(OutboxImagePreviewRequest(
                    key: key, attachment: nil, fileName: attachment.fileName, mimeType: attachment.mimeType))
            }
        }
        return requests
    }

    func scheduleOutboxImagePreviews(_ entries: [OutboxEntry]) {
        guard !self.cachingStopped, self.outboxPreviewTask == nil, let gateway = self.gateway else { return }
        let requests = self.outboxImagePreviewRequests(for: entries).filter {
            !self.outboxPreviewAttempts.contains($0.key) && !self.outboxImagePreviews.contains($0.key)
        }
        guard !requests.isEmpty else { return }
        let gatewayId = gateway.id
        let root = gateway.outboxRoot
        let sessionKey = self.sessionKey
        let generation = self.outboxPreviewGeneration
        self.outboxPreviewTask = Task { @MainActor [weak self, weak gateway] in
            var evictions: [OutboxImagePreviewEviction] = []
            for request in requests {
                guard !Task.isCancelled, let self, self.outboxPreviewGeneration == generation,
                      self.outboxPreviewActiveKeys.contains(request.key),
                      !self.outboxImagePreviews.contains(request.key),
                      !self.outboxPreviewAttempts.contains(request.key)
                else { continue }

                let memoryAttachment = gateway?.outboxAttachments[request.key.entryId]?.first {
                    $0.id == request.key.attachmentId
                }
                let probe = self.outboxImagePreviewProbe
                let preview: (image: ImageRef, encodedBytes: Int)?
                if let memoryAttachment {
                    preview = await OutboxImagePreviewWorker.shared.prepare(memoryAttachment, probe: probe)
                } else if let attachment = request.attachment {
                    preview = await OutboxImagePreviewWorker.shared.preparePersisted(
                        entryId: request.key.entryId, attachment: attachment, gatewayId: gatewayId, root: root, probe: probe)
                } else {
                    preview = nil
                }
                guard !Task.isCancelled, self.outboxPreviewGeneration == generation,
                      self.outboxPreviewActiveKeys.contains(request.key)
                else { break }
                self.outboxPreviewAttempts.insert(request.key)
                if let preview {
                    let newlyEvicted = self.outboxImagePreviews.insert(
                        preview.image, encodedBytes: preview.encodedBytes, for: request.key)
                    evictions.append(contentsOf: newlyEvicted)
                }
            }
            guard let self, !Task.isCancelled, self.outboxPreviewGeneration == generation,
                  !self.cachingStopped else { return }
            self.releaseEvictedAcceptedPreviewRows(evictions)
            self.outboxPreviewTask = nil
            if let gateway {
                self.syncOutbox(gateway.outbox.entries(for: sessionKey))
            }
        }
    }
}
