import Foundation

/// Only a bounded opening is retained. Capturing bytes never joins text blocks or forces a
/// bridged String to materialize UTF-8 storage on the UI actor.
package struct ReplyPreviewSource: Hashable, Sendable {
    package static let byteLimit = 4 * 1024
    package static let blockLimit = 64
    package let bytes: [UInt8]
    package let hasImage: Bool
    package let hasUninspectedBlocks: Bool
    package let hasTruncatedText: Bool

    package init?(blocks: [ContentBlock]) {
        var bytes: [UInt8] = []
        var hasImage = false
        var hasTruncatedText = false
        for block in blocks.prefix(Self.blockLimit) {
            if case .image = block { hasImage = true }
            guard case let .text(text) = block else { continue }
            if bytes.count >= Self.byteLimit {
                hasTruncatedText = true
                continue
            }
            guard text.isContiguousUTF8 else { return nil }
            if !bytes.isEmpty {
                bytes.append(contentsOf: [10, 10].prefix(Self.byteLimit - bytes.count))
            }
            let remaining = Self.byteLimit - bytes.count
            guard let _ = text.utf8.withContiguousStorageIfAvailable({ buffer in
                if buffer.count > remaining { hasTruncatedText = true }
                bytes.append(contentsOf: buffer.prefix(remaining))
            }) else { return nil }
        }
        // An empty bounded opening cannot establish the media/text fallback when more block
        // tags remain. Explicit unavailability is preferable to quoting an older opening.
        guard !bytes.isEmpty || blocks.count <= Self.blockLimit else { return nil }
        self.bytes = bytes
        self.hasImage = hasImage
        self.hasUninspectedBlocks = blocks.count > Self.blockLimit
        self.hasTruncatedText = hasTruncatedText
    }

    package init?(text: String) { self.init(blocks: [.text(text)]) }
    package var retainedByteCount: Int { self.bytes.capacity + 512 }

    package func normalizedLine() -> String? {
        let head = Self.completeUTF8Prefix(self.bytes)
        let text = MediaDirectives.extract(from: head).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || (!self.hasUninspectedBlocks && !self.hasTruncatedText) else { return nil }
        let line = text.isEmpty ? (self.hasImage ? "Image" : "Attachment") : Replies.previewLine(text)
        var bounded = String(line.prefix(280))
        if bounded.utf8.count > 2 * 1024 {
            bounded = Self.completeUTF8Prefix(Array(bounded.utf8.prefix(2 * 1024)))
        }
        return bounded
    }

    /// Input comes from valid String UTF-8. Only its final scalar can be incomplete after a byte
    /// cap, requiring at most three bytes to be dropped. A literal U+FFFD is valid and retained.
    private static func completeUTF8Prefix(_ bytes: [UInt8]) -> String {
        for clipped in 0...min(3, bytes.count) {
            if let text = String(bytes: bytes.dropLast(clipped), encoding: .utf8) { return text }
        }
        // Defensive only: bounded captures cannot contain malformed interior UTF-8.
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A pinned preparation handle is independent of cache eviction and of the active UI selection.
@MainActor
package final class ReplyPreviewPreparationHandle {
    package let source: ReplyPreviewSource
    package let task: Task<String?, Never>
    private var finished = false
    private var result: String?
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    package init(source: ReplyPreviewSource, task: Task<String?, Never>) {
        self.source = source
        self.task = task
        Task { @MainActor [weak self] in
            let result = await task.value
            guard let self else { return }
            self.finished = true
            self.result = result
            let waiting = self.waiters.values
            self.waiters.removeAll()
            for continuation in waiting { continuation.resume(returning: result) }
        }
    }
    package func value() async -> String? {
        if Task.isCancelled { return nil }
        if self.finished { return self.result }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.finished { continuation.resume(returning: self.result) }
                else if Task.isCancelled { continuation.resume(returning: nil) }
                else { self.waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(returning: nil) }
        }
    }
}

/// A serial worker with separately bounded pending snapshots and completed results.
@MainActor
package final class ReplyPreviewPreparationService {
    /// One production budget across all gateways/chats. Fixtures inject their own service.
    package static let shared = ReplyPreviewPreparationService()
    package static let pendingLimit = 32
    /// Capture is limited to 4 KiB of bytes, but Array's growth capacity is charged too.
    package static let activeInputBytesLimit = 2 * ReplyPreviewSource.byteLimit + 512
    package static let pendingBytesLimit = 32 * (ReplyPreviewSource.byteLimit + 512)
    package static let cacheLimit = 128
    package static let cacheBytesLimit = 1024 * 1024

    private var cache = BoundedLRUCache<ReplyPreviewSource, String>(
        countLimit: ReplyPreviewPreparationService.cacheLimit, costLimit: ReplyPreviewPreparationService.cacheBytesLimit)
    private var jobs: [ReplyPreviewSource: ReplyPreviewPreparationHandle] = [:]
    private var tail: Task<String?, Never>?
    private var queuedBytes = 0
    private var queueOrder: [ReplyPreviewSource] = []
    package private(set) var activeCount = 0
    package var pendingCount: Int { max(0, self.jobs.count - 1) }
    package var pendingByteCount: Int { self.queuedBytes - (self.queueOrder.first?.retainedByteCount ?? 0) }
    package var cachedCount: Int { self.cache.count }
    package var cachedByteCount: Int { self.cache.totalCost }
#if DEBUG
    package var normalizationGate: (@Sendable (String) async -> Void)?
    package var normalizationDidFinish: (@MainActor (String) -> Void)?
#endif

    package init() {}

    package func cachedLine(for source: ReplyPreviewSource) -> String? { self.cache.value(for: source) }

    package func request(_ source: ReplyPreviewSource, messageID: String) -> ReplyPreviewPreparationHandle? {
        if let line = self.cache.value(for: source) {
            return ReplyPreviewPreparationHandle(source: source, task: Task { line })
        }
        if let job = self.jobs[source] { return job }
        guard self.jobs.count < Self.pendingLimit + 1,
              source.retainedByteCount <= Self.activeInputBytesLimit else { return nil }
        // The head's actual capacity is separate from the pending budget. Fixed head slack
        // would let cheap active work hide an over-budget pending snapshot.
        if !self.jobs.isEmpty {
            guard source.retainedByteCount <= Self.pendingBytesLimit - self.pendingByteCount else { return nil }
        }
        let diagnosticID = messageID.isContiguousUTF8 && messageID.utf8.prefix(129).count <= 128 ? messageID : ""
        let predecessor = self.tail
#if DEBUG
        let gate = self.normalizationGate
#endif
        self.queuedBytes += source.retainedByteCount
        self.queueOrder.append(source)
        let task = Task { @MainActor [weak self] () -> String? in
            _ = await predecessor?.value
            guard let self else { return nil }
            defer {
                self.activeCount = 0
                self.jobs[source] = nil
                self.queuedBytes -= source.retainedByteCount
                if self.queueOrder.first == source { self.queueOrder.removeFirst() }
                if self.jobs.isEmpty { self.tail = nil }
            }
            guard !Task.isCancelled else { return nil }
            self.activeCount = 1
            let worker = Task.detached(priority: .userInitiated) { () -> String? in
#if DEBUG
                if let gate { await gate(diagnosticID) }
#endif
                guard !Task.isCancelled else { return nil }
#if DEBUG
                ReplyPreviewDebugProbe.recordNormalization(for: diagnosticID)
#endif
                return source.normalizedLine()
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if let result {
                // Include the maximum bounded normalization buffer as a conservative String
                // backing-store allowance, in addition to source capacity and entry metadata.
                _ = self.cache.insert(result, for: source, cost: source.retainedByteCount + ReplyPreviewSource.byteLimit)
            }
#if DEBUG
            self.normalizationDidFinish?(diagnosticID)
#endif
            return result
        }
        let handle = ReplyPreviewPreparationHandle(source: source, task: task)
        self.jobs[source] = handle
        self.tail = task
        return handle
    }

    package func drain() async {
        let handles = Array(self.jobs.values)
        for handle in handles {
            guard !Task.isCancelled else { return }
            _ = await handle.value()
        }
    }

    package func cancel() {
        for handle in self.jobs.values { handle.task.cancel() }
    }
}
