import Foundation

/// A content key made from a fixed-size prefix only. It deliberately retains no transcript body.
package struct MessagePartExcerptSource: Hashable, Sendable {
    package static let characterLimit = 44
    package static let snapshotByteLimit = Self.characterLimit * 4 + 1

    private let bytes: [UInt8]

    package init(_ text: String) {
        self.bytes = Array(text.utf8.prefix(Self.snapshotByteLimit))
    }

    package var retainedByteCount: Int { self.bytes.count }

    package func normalizedExcerpt() -> String {
        AccessibilityText.streamingExcerpt(String(decoding: self.bytes, as: UTF8.self), limit: Self.characterLimit)
    }
}

/// Small shared cache for VoiceOver's per-message action labels. Only bounded byte snapshots enter
/// the serial worker; decoded text and Markdown cleanup never run on the main thread.
@MainActor
package final class MessagePartExcerptCache {
    nonisolated package static let entryLimit = 512
    nonisolated package static let byteLimit = 128 * 1024

    package typealias Normalizer = @Sendable (MessagePartExcerptSource) -> String

    package static let shared = MessagePartExcerptCache()

    private var values: BoundedLRUCache<MessagePartExcerptSource, String>
    private var inFlight: Set<MessagePartExcerptSource> = []
    private let queue = BoundedPreparationQueue<String>()
    private let normalize: Normalizer

#if DEBUG
    /// One bounded observer for deterministic fixtures; production callers never wait for text.
    package var preparationDidFinishForTesting: (@MainActor (MessagePartExcerptSource) -> Void)?
#endif

    package init(
        entryLimit: Int = MessagePartExcerptCache.entryLimit,
        byteLimit: Int = MessagePartExcerptCache.byteLimit,
        normalize: @escaping Normalizer = { $0.normalizedExcerpt() }
    ) {
        self.values = BoundedLRUCache(countLimit: entryLimit, costLimit: byteLimit)
        self.normalize = normalize
    }

    package var cachedCount: Int { self.values.count }
    package var cachedByteCount: Int { self.values.totalCost }
    package var activeCount: Int { self.queue.activeCount }
    package var pendingCount: Int { self.queue.pendingCount }
    package var pendingByteCount: Int { self.queue.pendingBytes }
    package var inFlightKeyCount: Int { self.inFlight.count }

    /// Returns an already prepared excerpt or schedules bounded off-main normalization. A miss is
    /// intentionally cheap; accessibility can ask again after the worker has populated the cache.
    package func excerpt(for source: MessagePartExcerptSource) -> String? {
        if let ready = self.values.value(for: source) { return ready }
        guard !self.inFlight.contains(source) else { return nil }
        self.inFlight.insert(source)
        let normalize = self.normalize
        let admission = self.queue.submit(retainedBytes: source.retainedByteCount) {
            await Task.detached(priority: .userInitiated) { normalize(source) }.value
        } completion: { [weak self] result in
            guard let self else { return }
            self.inFlight.remove(source)
            _ = self.values.insert(result, for: source, cost: source.retainedByteCount + result.utf8.count)
#if DEBUG
            self.preparationDidFinishForTesting?(source)
#endif
        }
        switch admission {
        case .started, .queued:
            break
        case .rejectedPendingCount, .rejectedPendingBytes:
            self.inFlight.remove(source)
        }
        return nil
    }
}
