import Foundation

/// Admission result for the shared serialized attachment preparation queue. The first item starts immediately;
/// only work waiting behind it is constrained by the pending budgets.
package enum PreparationAdmission: Sendable, Equatable {
    case started
    case queued
    case rejectedPendingCount
    case rejectedPendingBytes
}

/// A small FIFO for expensive composer preparation. It bounds both retained pending bytes and
/// descriptors while preserving every admitted item and its completion order.
@MainActor
package final class BoundedPreparationQueue<Output: Sendable> {
    package static var pendingItemLimit: Int { 32 }
    package static var pendingByteLimit: Int { 32 * 1024 * 1024 }

    private struct Work {
        let retainedBytes: Int
        let operation: @MainActor @Sendable () async -> Output
        let completion: @MainActor @Sendable (Output) -> Void
    }

    private var pending: [Work] = []
    private var activeTask: Task<Void, Never>?
    private var retainedPendingBytes = 0

    package init() {}

    package var activeCount: Int { self.activeTask == nil ? 0 : 1 }
    package var pendingCount: Int { self.pending.count }
    package var pendingBytes: Int { self.retainedPendingBytes }

    /// Runs one operation at a time on the main actor's async turn. Callers must move any
    /// expensive parsing, decoding, or file I/O into their operation's detached work.
    @discardableResult
    package func submit(
        retainedBytes: Int = 0,
        operation: @escaping @MainActor @Sendable () async -> Output,
        completion: @escaping @MainActor @Sendable (Output) -> Void) -> PreparationAdmission
    {
        let retainedBytes = max(0, retainedBytes)
        let work = Work(retainedBytes: retainedBytes, operation: operation, completion: completion)
        guard self.activeTask != nil else {
            self.start(work)
            return .started
        }
        guard self.pending.count < Self.pendingItemLimit else { return .rejectedPendingCount }
        guard retainedBytes <= Self.pendingByteLimit - self.retainedPendingBytes else { return .rejectedPendingBytes }
        self.pending.append(work)
        self.retainedPendingBytes += retainedBytes
        return .queued
    }

    private func start(_ work: Work) {
        // This task holds the queue until the admitted FIFO drains. Accepted work therefore
        // completes even if the originating SwiftUI value is reconstructed or dismissed.
        self.activeTask = Task { @MainActor [self] in
            let output = await work.operation()
            work.completion(output)
            self.activeTask = nil
            self.startNextIfNeeded()
        }
    }

    private func startNextIfNeeded() {
        guard self.activeTask == nil, !self.pending.isEmpty else { return }
        let next = self.pending.removeFirst()
        self.retainedPendingBytes -= next.retainedBytes
        self.start(next)
    }
}
