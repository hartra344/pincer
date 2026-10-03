import Foundation

/// Only admitted text strings are retained. Admission reads contiguous UTF-8 metadata and
/// block tags on Main; it never copies prefixes, joins text or keeps a ChatItem/media payload.
struct BookmarkPreviewInput: Sendable {
    static let messageByteLimit = 256 * 1024
    static let blockLimit = 64
    static let locatorByteLimit = 2048
    static let previewByteLimit = 2048
    let texts: [String]
    let retainedBytes: Int

    static func capture(_ item: ChatItem?, sessionKey: String, messageId: String) -> Self? {
        func byteCount(_ text: String) -> Int? {
            guard text.isContiguousUTF8 else { return nil }
            return text.utf8.withContiguousStorageIfAvailable { $0.count }
        }
        guard let sessionBytes = byteCount(sessionKey), let messageBytes = byteCount(messageId),
              sessionBytes <= Self.locatorByteLimit, messageBytes <= Self.locatorByteLimit,
              (item?.blocks.count ?? 0) <= Self.blockLimit else { return nil }
        var bytes = 0
        var texts: [String] = []
        for block in item?.blocks ?? [] {
            guard case let .text(text) = block else { continue }
            guard let size = byteCount(text), size <= Self.messageByteLimit - bytes else { return nil }
            bytes += size
            texts.append(text)
        }
        // The joined block separators and locator separator also have bounded storage.
        return Self(texts: texts, retainedBytes: bytes + texts.count * 2 + sessionBytes + messageBytes + 1)
    }
}

/// One shared worker across gateways. Canceled active work remains charged until its real
/// detached worker exits; canceled pending work releases its text immediately.
@MainActor
final class BookmarkPreviewPreparationQueue {
    static let shared = BookmarkPreviewPreparationQueue()
    static let pendingLimit = 32
    static let byteLimit = 8 * 1024 * 1024

    private struct Work {
        let token: UUID
        let id: String
        let input: BookmarkPreviewInput
        let probe: (@Sendable (String, Bool) -> Void)?
        let completion: @MainActor @Sendable (String) -> Void
    }

    private var active: Work?
    private var pending: [Work] = []
    private(set) var retainedBytes = 0
    var activeCount: Int { self.active == nil ? 0 : 1 }
    var pendingCount: Int { self.pending.count }
#if DEBUG
    private let beforePrepare: (@Sendable (String) async -> Void)?
    private var drainWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(beforePrepare: (@Sendable (String) async -> Void)? = nil) {
        self.beforePrepare = beforePrepare
    }

    func waitUntilIdle() async {
        guard self.active != nil || !self.pending.isEmpty else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { self.drainWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.drainWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }
#else
    init() {}
#endif

    @discardableResult
    func submit(token: UUID, id: String, input: BookmarkPreviewInput,
                probe: (@Sendable (String, Bool) -> Void)?,
                completion: @escaping @MainActor @Sendable (String) -> Void) -> Bool {
        guard input.retainedBytes <= Self.byteLimit - self.retainedBytes,
              self.active == nil || self.pending.count < Self.pendingLimit else { return false }
        let work = Work(token: token, id: id, input: input, probe: probe, completion: completion)
        self.retainedBytes += input.retainedBytes
        if self.active == nil { self.start(work) } else { self.pending.append(work) }
        return true
    }

    func cancel(_ token: UUID) {
        guard let index = self.pending.firstIndex(where: { $0.token == token }) else { return }
        self.retainedBytes -= self.pending.remove(at: index).input.retainedBytes
    }

    nonisolated private static func prepare(_ input: BookmarkPreviewInput, id: String,
                                           probe: (@Sendable (String, Bool) -> Void)?) -> String {
        probe?(id, Thread.isMainThread)
        let preview = Bookmark.preview(input.texts.joined(separator: "\n\n"))
        // A single Unicode grapheme can contain a payload-sized combining sequence.
        // Bound the finished value before Main persists, encodes or measures it.
        return preview.utf8.count <= BookmarkPreviewInput.previewByteLimit ? preview : ""
    }

    private func start(_ work: Work) {
        self.active = work
#if DEBUG
        let gate = self.beforePrepare
#endif
        // The detached closure captures text-only input, bounded locator and observer. The
        // completion (and its weak store reference) stays on Main, outside the worker.
        let input = work.input
        let id = work.id
        let probe = work.probe
        let preparation = Task.detached(priority: .utility) {
#if DEBUG
            await gate?(id)
#endif
            return Self.prepare(input, id: id, probe: probe)
        }
        Task { @MainActor [self] in
            let preview = await preparation.value
            work.completion(preview)
            self.retainedBytes -= work.input.retainedBytes
            self.active = nil
            if !self.pending.isEmpty {
                self.start(self.pending.removeFirst())
            } else {
#if DEBUG
                let waiters = self.drainWaiters
                self.drainWaiters.removeAll()
                for waiter in waiters.values { waiter.resume() }
#endif
            }
        }
    }
}
