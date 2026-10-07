import Foundation

/// Admission result for the shared serialized attachment preparation queue. The first item starts immediately;
/// only work waiting behind it is constrained by the pending budgets.
package enum PreparationAdmission: Sendable, Equatable {
    case started
    case queued
    case rejectedPendingCount
    case rejectedPendingBytes
}

@MainActor
package protocol OwnerCancellablePreparation: AnyObject {
    func cancel(owner: UUID)
}

/// Cancels a retired owner's work on every live preparation queue, so closing or replacing a
/// draft frees the queue instead of preparing results nobody will use.
@MainActor
package enum PreparationOwnerCancellation {
    private struct Entry {
        weak var queue: (any OwnerCancellablePreparation)?
    }

    private static var entries: [Entry] = []

    static func register(_ queue: any OwnerCancellablePreparation) {
        self.entries.removeAll { $0.queue == nil }
        self.entries.append(Entry(queue: queue))
    }

    package static func cancel(owner: UUID) {
        for entry in self.entries { entry.queue?.cancel(owner: owner) }
    }
}

/// A small FIFO for expensive composer preparation. It bounds both retained pending bytes and
/// descriptors while preserving every admitted item and its completion order. An item with a
/// `timeoutOutput` gets a deadline, so one hung read or decode can't hold the slot forever.
@MainActor
package final class BoundedPreparationQueue<Output: Sendable>: OwnerCancellablePreparation {
    package static var pendingItemLimit: Int { 32 }
    package static var pendingByteLimit: Int { 32 * 1024 * 1024 }

    package typealias Timer = @Sendable (Duration) async -> Void

    private struct Work {
        let owner: UUID?
        let retainedBytes: Int
        let timeoutOutput: Output?
        let operation: @MainActor @Sendable () async -> Output
        let completion: @MainActor @Sendable (Output) -> Void
    }

    private struct Active {
        let id: UInt64
        let owner: UUID?
        let operation: Task<Void, Never>
        let deadline: Task<Void, Never>?
    }

    private let itemDeadline: Duration?
    private let timer: Timer
    private var pending: [Work] = []
    private var active: Active?
    private var nextActiveID: UInt64 = 0
    private var retainedPendingBytes = 0

    package init(itemDeadline: Duration? = nil, timer: @escaping Timer = { try? await Task.sleep(for: $0) }) {
        self.itemDeadline = itemDeadline
        self.timer = timer
        PreparationOwnerCancellation.register(self)
    }

    package var activeCount: Int { self.active == nil ? 0 : 1 }
    package var pendingCount: Int { self.pending.count }
    package var pendingBytes: Int { self.retainedPendingBytes }

    /// Runs one operation at a time on the main actor's async turn. Callers must move any
    /// expensive parsing, decoding, or file I/O into their operation's detached work.
    @discardableResult
    package func submit(
        owner: UUID? = nil,
        retainedBytes: Int = 0,
        timeoutOutput: Output? = nil,
        operation: @escaping @MainActor @Sendable () async -> Output,
        completion: @escaping @MainActor @Sendable (Output) -> Void) -> PreparationAdmission
    {
        let retainedBytes = max(0, retainedBytes)
        let work = Work(owner: owner, retainedBytes: retainedBytes, timeoutOutput: timeoutOutput,
                        operation: operation, completion: completion)
        guard self.active != nil else {
            self.start(work)
            return .started
        }
        guard self.pending.count < Self.pendingItemLimit else { return .rejectedPendingCount }
        guard retainedBytes <= Self.pendingByteLimit - self.retainedPendingBytes else { return .rejectedPendingBytes }
        self.pending.append(work)
        self.retainedPendingBytes += retainedBytes
        return .queued
    }

    /// Drops the owner's queued work and abandons its active item. Cancelled items never call
    /// their completion; the owner releases its own reservations.
    package func cancel(owner: UUID) {
        let removedBytes = self.pending.reduce(0) { $0 + ($1.owner == owner ? $1.retainedBytes : 0) }
        self.pending.removeAll { $0.owner == owner }
        self.retainedPendingBytes -= removedBytes
        if let active = self.active, active.owner == owner {
            self.release(active)
            self.startNextIfNeeded()
        }
    }

    private func start(_ work: Work) {
        self.nextActiveID &+= 1
        let id = self.nextActiveID
        // This task holds the queue until the item finishes, times out or its owner cancels it.
        // Accepted work therefore completes even if the originating SwiftUI value is dismissed.
        let operation = Task { @MainActor [weak self] in
            let output = await work.operation()
            self?.finish(id, output: output, completion: work.completion)
        }
        var deadline: Task<Void, Never>?
        if let itemDeadline = self.itemDeadline, let timeoutOutput = work.timeoutOutput {
            let timer = self.timer
            deadline = Task { @MainActor [weak self] in
                await timer(itemDeadline)
                guard !Task.isCancelled else { return }
                self?.finish(id, output: timeoutOutput, completion: work.completion)
            }
        }
        self.active = Active(id: id, owner: work.owner, operation: operation, deadline: deadline)
    }

    private func finish(_ id: UInt64, output: Output, completion: @MainActor @Sendable (Output) -> Void) {
        guard let active = self.active, active.id == id else { return }
        completion(output)
        // Keep the slot through callback reentrancy, so work enqueued by the callback waits its turn.
        self.release(active)
        self.startNextIfNeeded()
    }

    private func release(_ active: Active) {
        active.deadline?.cancel()
        active.operation.cancel()
        self.active = nil
    }

    private func startNextIfNeeded() {
        guard self.active == nil, !self.pending.isEmpty else { return }
        let next = self.pending.removeFirst()
        self.retainedPendingBytes -= next.retainedBytes
        self.start(next)
    }
}
