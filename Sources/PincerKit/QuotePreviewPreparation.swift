import Foundation

/// Two bounded text snapshots, never a retained ChatItem, media payload or sender metadata.
package struct QuotePreviewInput: Hashable, Sendable {
    package let isLoaded: Bool
    package let primary: ReplyPreviewSource?
    package let fallback: ReplyPreviewSource?
    package var retainedByteCount: Int {
        (self.primary?.retainedByteCount ?? 0) + (self.fallback?.retainedByteCount ?? 0) + 128
    }

    private enum Line { case text(String), empty, unavailable }

    private static func line(_ source: ReplyPreviewSource?) -> Line {
        guard let source else { return .unavailable }
        let head = self.completeUTF8(source.bytes)
        let text = MediaDirectives.extract(from: head).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.isEmpty ? "" : Replies.previewLine(text)
        guard !line.isEmpty else {
            return source.hasTruncatedText || source.hasUninspectedBlocks ? .unavailable : .empty
        }
        let preview = String(line.prefix(280))
        if preview.utf8.count <= 2048 { return .text(preview) }
        return .text(self.completeUTF8(Array(preview.utf8.prefix(2048))))
    }

    private static func completeUTF8(_ bytes: [UInt8]) -> String {
        for removed in 0...min(3, bytes.count) {
            if let text = String(bytes: bytes.dropLast(removed), encoding: .utf8) { return text }
        }
        return ""
    }

    /// Text-only normalization: unavailable is never treated as proven empty.
    package func prepare() -> QuotePreparedText {
        if self.isLoaded {
            switch Self.line(self.primary) {
            case let .text(text): return QuotePreparedText(text: text)
            case .unavailable: return QuotePreparedText(text: nil)
            case .empty: break
            }
        }
        switch Self.line(self.fallback) {
        case let .text(text): return QuotePreparedText(text: text)
        case .empty, .unavailable: return QuotePreparedText(text: nil)
        }
    }
}

package struct QuotePreparedText: Sendable { package let text: String? }

/// Incidental row decoration cannot consume interactive Reply/send queue admission.
@MainActor
package final class QuotePreviewPreparationService {
    package static let shared = QuotePreviewPreparationService()
    package static let pendingLimit = 32
    package static let activeInputBytesLimit = 2 * ReplyPreviewPreparationService.activeInputBytesLimit + 128
    package static let pendingBytesLimit = pendingLimit * activeInputBytesLimit
    package static let cacheLimit = 128
    package static let cacheBytesLimit = 2 * 1024 * 1024
    package static let watcherLimit = 128
    package static let watcherBytesLimit = 2 * 1024 * 1024
    package static let deniedOwnerLimit = 128
    package static let deniedOwnerBytesLimit = deniedOwnerLimit * 512

    /// Capacity retries retain no source bytes or target text.
    private struct DeniedOwner {
        weak var chat: ChatStore?
        let lifecycle: Int
        let contentRevision: Int
    }

    private struct Watcher {
        weak var chat: ChatStore?
        let ownerID: UUID
        let targetID: String
        let input: QuotePreviewInput
        let lifecycle: Int
        let contentRevision: Int
        var cost: Int { self.input.retainedByteCount + 512 }
    }
    private var cache = BoundedLRUCache<QuotePreviewInput, QuotePreparedText>(countLimit: cacheLimit, costLimit: cacheBytesLimit)
    private var jobs: [QuotePreviewInput: Task<QuotePreparedText?, Never>] = [:]
    private var order: [QuotePreviewInput] = []
    private var tail: Task<QuotePreparedText?, Never>?
    private var watchers: [Watcher] = []
    private var publishing: [UUID: Watcher] = [:]
    private var deniedOwners: [UUID: DeniedOwner] = [:]
    private var retryPublishing: [UUID: DeniedOwner] = [:]
    private var publication: Task<Void, Never>?
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    package private(set) var activeCount = 0
    package var pendingCount: Int { max(0, self.jobs.count - 1) }
    package var pendingByteCount: Int { self.order.dropFirst().reduce(0) { $0 + $1.retainedByteCount } }
    package var cachedCount: Int { self.cache.count }
    package var cachedByteCount: Int { self.cache.totalCost }
    package var watcherCount: Int { self.watchers.count + self.publishing.count }
    package var deniedOwnerCount: Int { self.deniedOwners.count + self.retryPublishing.count }
    package var deniedOwnerByteCount: Int { self.deniedOwnerCount * 512 }
    package var watcherByteCount: Int {
        self.watchers.reduce(0) { $0 + $1.cost } + self.publishing.values.reduce(0) { $0 + $1.cost }
    }
#if DEBUG
    package var normalizationGate: (@Sendable (String) async -> Void)?
#endif
    package init() {}

    package func cachedText(for input: QuotePreviewInput) -> QuotePreparedText? { self.cache.value(for: input) }

    package func request(_ input: QuotePreviewInput, targetID: String, chat: ChatStore) {
        guard !chat.cachingStopped, self.cache.value(for: input) == nil, input.retainedByteCount <= Self.activeInputBytesLimit,
              targetID.isContiguousUTF8,
              targetID.utf8.withContiguousStorageIfAvailable({ !$0.isEmpty && $0.count <= 256 }) == true else { return }
        self.watchers.removeAll { $0.chat == nil || ($0.ownerID == chat.quotePreviewOwnerID && $0.targetID == targetID) }
        let watcher = Watcher(chat: chat, ownerID: chat.quotePreviewOwnerID, targetID: targetID, input: input,
                              lifecycle: chat.quotePreviewLifecycle, contentRevision: chat.contentRevision)
        guard self.watcherCount < Self.watcherLimit, watcher.cost <= Self.watcherBytesLimit - self.watcherByteCount else {
            self.registerDeniedOwner(chat)
            return
        }
        if self.jobs[input] == nil {
            guard self.jobs.count < Self.pendingLimit + 1 else { self.registerDeniedOwner(chat); return }
            if !self.jobs.isEmpty, input.retainedByteCount > Self.pendingBytesLimit - self.pendingByteCount {
                self.registerDeniedOwner(chat)
                return
            }
        }
        self.watchers.append(watcher)
        guard self.jobs[input] == nil else { return }
        let predecessor = self.tail
#if DEBUG
        let gate = self.normalizationGate
        let probe = chat.quotePreviewNormalizationProbe
#endif
        self.order.append(input)
        let task = Task { @MainActor [weak self] () -> QuotePreparedText? in
            _ = await predecessor?.value
            guard let self else { return nil }
            defer {
                self.activeCount = 0
                self.jobs[input] = nil
                self.order.removeAll { $0 == input }
                if self.jobs.isEmpty { self.tail = nil }
                self.capacityReleased()
                self.finishDrainIfIdle()
            }
            guard !Task.isCancelled else { self.watchers.removeAll { $0.input == input }; return nil }
            self.activeCount = 1
            let worker = Task.detached(priority: .utility) { () -> QuotePreparedText? in
#if DEBUG
                if let gate { await gate(targetID) }
#endif
                guard !Task.isCancelled else { return nil }
#if DEBUG
                probe?.record(messageID: targetID)
#endif
                return input.prepare()
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if let result, !Task.isCancelled {
                // Conservatively charge input capacity, normalization backing and output backing.
                _ = self.cache.insert(result, for: input, cost: input.retainedByteCount + 2 * ReplyPreviewSource.byteLimit + 2048)
                let ready = self.watchers.filter { $0.input == input }
                self.watchers.removeAll { $0.input == input }
                for watcher in ready { self.publishing[watcher.ownerID] = watcher }
                self.schedulePublication()
            } else { self.watchers.removeAll { $0.input == input } }
            return result
        }
        self.jobs[input] = task
        self.tail = task
    }

    private func schedulePublication() {
        guard self.publication == nil, !self.publishing.isEmpty || !self.retryPublishing.isEmpty else { return }
        self.publication = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            let ready = self.publishing
            let retry = self.retryPublishing
            self.publishing.removeAll()
            self.retryPublishing.removeAll()
            self.publication = nil
            var notified: Set<UUID> = []
            for watcher in ready.values {
                guard let chat = watcher.chat, !chat.cachingStopped, chat.quotePreviewLifecycle == watcher.lifecycle,
                      chat.contentRevision == watcher.contentRevision else { continue }
                chat.quotePreviewDidComplete()
                notified.insert(watcher.ownerID)
            }
            for (ownerID, denied) in retry where !notified.contains(ownerID) {
                guard let chat = denied.chat, !chat.cachingStopped, chat.quotePreviewLifecycle == denied.lifecycle,
                      chat.contentRevision == denied.contentRevision else { continue }
                chat.quotePreviewDidComplete()
            }
            self.finishDrainIfIdle()
        }
    }

    @discardableResult
    package func remove(ownerID: UUID) -> Bool {
        let hadRegistration = self.watchers.contains { $0.ownerID == ownerID } || self.publishing[ownerID] != nil
            || self.deniedOwners[ownerID] != nil || self.retryPublishing[ownerID] != nil
        self.watchers.removeAll { $0.ownerID == ownerID || $0.chat == nil }
        self.publishing[ownerID] = nil
        self.deniedOwners[ownerID] = nil
        self.retryPublishing[ownerID] = nil
        return hadRegistration
    }

    private func registerDeniedOwner(_ chat: ChatStore) {
        guard !chat.cachingStopped else { return }
        self.deniedOwners = self.deniedOwners.filter { $0.value.chat != nil }
        self.retryPublishing = self.retryPublishing.filter { $0.value.chat != nil }
        let ownerID = chat.quotePreviewOwnerID
        if self.deniedOwners[ownerID] == nil && self.retryPublishing[ownerID] == nil {
            guard self.deniedOwnerCount < Self.deniedOwnerLimit,
                  self.deniedOwnerByteCount <= Self.deniedOwnerBytesLimit - 512 else { return }
        }
        let owner = DeniedOwner(chat: chat, lifecycle: chat.quotePreviewLifecycle, contentRevision: chat.contentRevision)
        if self.retryPublishing[ownerID] != nil { self.retryPublishing[ownerID] = owner }
        else { self.deniedOwners[ownerID] = owner }
    }

    private func capacityReleased() {
        guard !self.deniedOwners.isEmpty else { return }
        for (ownerID, denied) in self.deniedOwners { self.retryPublishing[ownerID] = denied }
        self.deniedOwners.removeAll()
        self.schedulePublication()
    }

    package func drain() async {
        guard !Task.isCancelled, !self.jobs.isEmpty || self.publication != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, self.drainWaiters.count < 32 else { continuation.resume(); return }
                self.drainWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.drainWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func finishDrainIfIdle() {
        guard self.jobs.isEmpty, self.publication == nil else { return }
        let waiters = self.drainWaiters
        self.drainWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }
}
