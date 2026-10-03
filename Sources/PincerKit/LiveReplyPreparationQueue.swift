import Foundation

/// The minimal text-only input retained while deciding whether an accepted assistant message is
/// worth speaking. Its strings are bounded at admission; media and the source `ChatItem` are not
/// captured by queued work.
package struct LiveReplyPreparationInput: Sendable {
    package let ownerID: UUID
    package let generation: UInt64
    /// Per-ChatStore accepted-message revision. Queue order is assigned separately by the queue.
    package let sequence: UInt64
    /// Changes when the same live item is refreshed without moving its original FIFO position.
    package let revision: UInt64
    package let itemID: String
    package let transcriptID: String?
    package let fallbackIndex: Int
    package let textBlocks: [String]
    /// Logical UTF-8 bytes of joined text, checked against the per-message ceiling.
    package let textByteCount: Int
    /// Logical text and locator UTF-8 bytes, excluding allocator/COW capacity.
    package let retainedBytes: Int

    package init(ownerID: UUID, generation: UInt64, sequence: UInt64, revision: UInt64, itemID: String,
                 transcriptID: String?, fallbackIndex: Int, textBlocks: [String],
                 textByteCount: Int, retainedBytes: Int) {
        self.ownerID = ownerID
        self.generation = generation
        self.sequence = sequence
        self.revision = revision
        self.itemID = itemID
        self.transcriptID = transcriptID
        self.fallbackIndex = fallbackIndex
        self.textBlocks = textBlocks
        self.textByteCount = max(0, textByteCount)
        self.retainedBytes = max(0, retainedBytes)
    }
}

/// The bounded lookup/result identity returned to Main after normalization; it carries no text.
package struct LiveReplyPreparationToken: Sendable {
    package let ownerID: UUID
    package let generation: UInt64
    package let sequence: UInt64
    package let revision: UInt64
    package let queueOrder: UInt64
    package let itemID: String
    package let transcriptID: String?
    package let fallbackIndex: Int

    package init(_ input: LiveReplyPreparationInput, queueOrder: UInt64) {
        self.ownerID = input.ownerID
        self.generation = input.generation
        self.sequence = input.sequence
        self.revision = input.revision
        self.queueOrder = queueOrder
        self.itemID = input.itemID
        self.transcriptID = input.transcriptID
        self.fallbackIndex = input.fallbackIndex
    }
}

/// A single serial worker shared by chats. Overflow is reported to the owning ChatStore, which
/// suppresses that live-reply generation instead of doing text work on Main or dropping one row.
@MainActor
package final class LiveReplyPreparationQueue {
    nonisolated package static let pendingItemLimit = 32
    nonisolated package static let retainedByteLimit = 8 * 1024 * 1024
    nonisolated package static let messageTextByteLimit = 256 * 1024

    package typealias Normalizer = @Sendable (LiveReplyPreparationInput) -> Bool
    package typealias Completion = @MainActor @Sendable (LiveReplyPreparationToken, Bool) -> Void

    package static let shared = LiveReplyPreparationQueue()

    private struct Work {
        var input: LiveReplyPreparationInput
        let queueOrder: UInt64
        let completion: Completion

        var token: LiveReplyPreparationToken { LiveReplyPreparationToken(self.input, queueOrder: self.queueOrder) }
    }

    @MainActor
    private final class ActiveWork {
        var current: Work
        var stage: Work?
        var replacement: Work?

        init(_ work: Work) { self.current = work }
    }

    private let pendingItemLimit: Int
    private let retainedByteLimit: Int
    private let normalizer: Normalizer
    private var pending: [Work] = []
    private var active: ActiveWork?
    private var activeTask: Task<Void, Never>?
    private var nextQueueOrder: UInt64 = 0
    private var retainedBytes = 0

    package init(pendingItemLimit: Int = LiveReplyPreparationQueue.pendingItemLimit,
                 retainedByteLimit: Int = LiveReplyPreparationQueue.retainedByteLimit,
                 normalizer: @escaping Normalizer = { SpeechText.isSpeakable(textBlocks: $0.textBlocks, itemID: $0.itemID) }) {
        self.pendingItemLimit = max(0, pendingItemLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        self.normalizer = normalizer
    }

    package var activeCount: Int { self.active == nil ? 0 : 1 }
    package var pendingCount: Int { self.pending.count }
    package var pendingBytes: Int { self.pending.reduce(0) { $0 + $1.input.retainedBytes } }
    package var retainedByteCount: Int { self.retainedBytes }
    package var isIdle: Bool { self.active == nil && self.pending.isEmpty }

    /// A bounded snapshot of the logical jobs currently owned by one live-reply generation.
    /// Replacements retain their queue order, so a terminal barrier can track membership even
    /// when a later accepted revision has a newer event sequence.
    package func outstandingQueueOrders(ownerID: UUID, generation: UInt64) -> Set<UInt64> {
        var result = Set<UInt64>()
        if let active = self.active {
            for work in [active.current, active.stage, active.replacement].compactMap({ $0 })
                where work.input.ownerID == ownerID && work.input.generation == generation
            {
                result.insert(work.queueOrder)
            }
        }
        for work in self.pending where work.input.ownerID == ownerID && work.input.generation == generation {
            result.insert(work.queueOrder)
        }
        return result
    }

    @discardableResult
    package func submit(_ input: LiveReplyPreparationInput,
                        completion: @escaping Completion) -> PreparationAdmission {
        guard self.isWithinMessageLimit(input), input.retainedBytes <= self.retainedByteLimit else {
            return .rejectedPendingBytes
        }
        guard self.retainedBytes <= self.retainedByteLimit - input.retainedBytes else {
            return .rejectedPendingBytes
        }
        self.nextQueueOrder &+= 1
        let work = Work(input: input, queueOrder: self.nextQueueOrder, completion: completion)
        if self.active == nil {
            self.retainedBytes += input.retainedBytes
            self.start(work)
            return .started
        }
        guard self.pending.count < self.pendingItemLimit else { return .rejectedPendingCount }
        self.pending.append(work)
        self.retainedBytes += input.retainedBytes
        return .queued
    }

    /// Replaces the text snapshot for matching active or pending work without changing its
    /// original FIFO position or logical completion count. Active work retains one latest refresh
    /// behind its current normalization stage.
    @discardableResult
    package func replace(_ input: LiveReplyPreparationInput) -> Bool {
        guard self.isWithinMessageLimit(input) else { return false }
        if let index = self.pending.firstIndex(where: { self.matches($0, input) }) {
            let oldBytes = self.pending[index].input.retainedBytes
            let newTotal = self.retainedBytes - oldBytes + input.retainedBytes
            guard newTotal <= self.retainedByteLimit else { return false }
            self.pending[index].input = input
            self.retainedBytes = newTotal
            return true
        }
        guard let active = self.active,
              self.matches(active.current, input) || active.stage.map({ self.matches($0, input) }) == true
        else { return false }
        let oldBytes = active.replacement?.input.retainedBytes ?? 0
        let newTotal = self.retainedBytes - oldBytes + input.retainedBytes
        guard newTotal <= self.retainedByteLimit else { return false }
        let base = active.replacement ?? active.stage ?? active.current
        active.replacement = Work(input: input, queueOrder: base.queueOrder, completion: base.completion)
        self.retainedBytes = newTotal
        return true
    }

    /// Requeues an already-completed candidate at its original global FIFO position. This is used
    /// only when authoritative history replaces that candidate; the old candidate is temporarily
    /// cleared while the new bounded snapshot is prepared.
    @discardableResult
    package func submitRevalidation(_ input: LiveReplyPreparationInput, queueOrder: UInt64,
                                   completion: @escaping Completion) -> PreparationAdmission {
        guard self.isWithinMessageLimit(input), input.retainedBytes <= self.retainedByteLimit,
              self.retainedBytes <= self.retainedByteLimit - input.retainedBytes else {
            return .rejectedPendingBytes
        }
        guard self.active != nil else {
            self.retainedBytes += input.retainedBytes
            self.start(Work(input: input, queueOrder: queueOrder, completion: completion))
            return .started
        }
        guard self.pending.count < self.pendingItemLimit else { return .rejectedPendingCount }
        let work = Work(input: input, queueOrder: queueOrder, completion: completion)
        let insertion = self.pending.firstIndex(where: { $0.queueOrder > queueOrder }) ?? self.pending.endIndex
        self.pending.insert(work, at: insertion)
        self.retainedBytes += input.retainedBytes
        return .queued
    }

    /// Removes queued work for a generation. The active synchronous normalizer keeps its slot
    /// until it returns; its result is rejected by the owning ChatStore's generation check.
    package func cancelPending(ownerID: UUID, generation: UInt64) {
        let removed = self.pending.filter { $0.input.ownerID == ownerID && $0.input.generation == generation }
        self.pending.removeAll { $0.input.ownerID == ownerID && $0.input.generation == generation }
        self.retainedBytes -= removed.reduce(0) { $0 + $1.input.retainedBytes }
        if let active = self.active, active.replacement?.input.ownerID == ownerID,
           active.replacement?.input.generation == generation
        {
            self.retainedBytes -= active.replacement?.input.retainedBytes ?? 0
            active.replacement = nil
        }
    }

    private func start(_ work: Work) {
        let active = ActiveWork(work)
        self.active = active
        let normalizer = self.normalizer
        self.activeTask = Task { @MainActor [weak self, active] in
            var current = active.current
            var currentResult = await Self.normalize(current.input, using: normalizer)

            while let self, self.active === active, let next = active.replacement {
                active.replacement = nil
                active.stage = next
                // `current`, `stage`, and a newly-arriving replacement are all counted while
                // the detached compare/normalize operation is running.
                let stageResult = await Self.normalize(next.input, reusing: current.input,
                                                       previousResult: currentResult, using: normalizer)
                guard self.active === active else { return }
                self.retainedBytes -= current.input.retainedBytes
                current = next
                active.current = next
                active.stage = nil
                currentResult = stageResult
            }

            guard let self, self.active === active else { return }
            current.completion(current.token, currentResult)
            // Keep the active slot through callback reentrancy. If a callback enqueued work, it
            // must remain behind the just-finished operation until its normalizer has exited.
            self.retainedBytes -= current.input.retainedBytes
            self.active = nil
            self.activeTask = nil
            self.startNextIfNeeded()
        }
    }

    private func startNextIfNeeded() {
        guard self.active == nil, !self.pending.isEmpty else { return }
        let next = self.pending.removeFirst()
        self.start(next)
    }

    private func isWithinMessageLimit(_ input: LiveReplyPreparationInput) -> Bool {
        input.textByteCount <= Self.messageTextByteLimit
    }

    private func matches(_ work: Work, _ input: LiveReplyPreparationInput) -> Bool {
        work.input.ownerID == input.ownerID && work.input.generation == input.generation &&
            work.input.itemID == input.itemID
    }

    nonisolated private static func normalize(_ input: LiveReplyPreparationInput, using normalizer: @escaping Normalizer) async -> Bool {
        await Task.detached(priority: .userInitiated) { normalizer(input) }.value
    }

    nonisolated private static func normalize(_ input: LiveReplyPreparationInput,
                                  reusing previousInput: LiveReplyPreparationInput,
                                  previousResult: Bool,
                                  using normalizer: @escaping Normalizer) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            if input.itemID == previousInput.itemID, input.textBlocks == previousInput.textBlocks {
                return previousResult
            }
            return normalizer(input)
        }.value
    }
}
