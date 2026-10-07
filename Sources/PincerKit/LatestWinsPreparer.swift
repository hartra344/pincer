import Foundation
import Synchronization

/// The shared "latest wins" policy for off-main preparation: at most one active detached worker
/// plus one replaceable pending request. Only the most recent request can deliver a value; a
/// replaced pending request, an invalidated request and a superseded active request all finish
/// with `nil`. The active worker is never abandoned, so its lease (and memory) is held until it
/// actually exits, and the next pending request starts only then.
///
/// Inputs are captured by the `work` closure (COW snapshots), so at most two inputs are retained.
@MainActor
package final class LatestWinsPreparer<Output: Sendable> {
    /// Identifies one submitted request.
    package struct Ticket: Hashable, Sendable {
        package let id: UUID
    }

    /// Set from any thread by task cancellation; read when the worker finishes.
    private final class Cancellation: Sendable {
        private let flag = Mutex(false)
        var isCanceled: Bool { self.flag.withLock { $0 } }
        func cancel() { self.flag.withLock { $0 = true } }
    }

    private struct Job {
        let ticket: Ticket
        let priority: TaskPriority
        let start: @MainActor () -> @Sendable () async -> Output
        let accept: @MainActor () -> Bool
        let finished: (@MainActor (Output) -> Void)?
        let completion: @MainActor (Output?) -> Void
        let cancellation: Cancellation
    }

    private let cancelsSupersededWork: Bool
    private var current: Ticket?
    private var active: Ticket?
    private var activeWorker: Task<Output, Never>?
    private var pending: Job?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The task awaiting the active worker; tests use it to observe the worker's real lifetime.
    package private(set) var workerTask: Task<Void, Never>?

    /// - Parameter cancelsSupersededWork: cancel the active worker's task as soon as its request
    ///   can no longer deliver (superseded, invalidated or cancelled), for work that checks
    ///   `Task.isCancelled` to stop early. The worker still holds the lease until it exits.
    package init(cancelsSupersededWork: Bool = false) {
        self.cancelsSupersededWork = cancelsSupersededWork
    }

    package var activeCount: Int { self.active == nil ? 0 : 1 }
    package var pendingCount: Int { self.pending == nil ? 0 : 1 }
    package var isIdle: Bool { self.active == nil && self.pending == nil }
    /// The most recent request that may still deliver.
    package var currentTicket: Ticket? { self.current }

    /// Submits `work` as the latest request. A request already pending finishes with `nil`.
    /// - Parameters:
    ///   - accept: checked on the main actor when the worker finishes; `false` delivers `nil`.
    ///   - finished: receives every finished output, current or not (for example, to keep a cache).
    ///   - completion: the current output, or `nil` when the request was replaced, invalidated,
    ///     cancelled or not accepted. Called exactly once.
    @discardableResult
    package func submit(priority: TaskPriority = .userInitiated,
                        accept: @escaping @MainActor () -> Bool = { true },
                        work: @escaping @Sendable () async -> Output,
                        finished: (@MainActor (Output) -> Void)? = nil,
                        completion: @escaping @MainActor (Output?) -> Void) -> Ticket
    {
        self.submit(priority: priority, accept: accept, start: { work }, finished: finished, completion: completion)
    }

    /// Like `submit(work:)`, but `start` builds the worker on the main actor at the moment the
    /// request becomes active (for state that should only be handed over then, such as a cache).
    @discardableResult
    package func submit(priority: TaskPriority = .userInitiated,
                        accept: @escaping @MainActor () -> Bool = { true },
                        start: @escaping @MainActor () -> @Sendable () async -> Output,
                        finished: (@MainActor (Output) -> Void)? = nil,
                        completion: @escaping @MainActor (Output?) -> Void) -> Ticket
    {
        self.enqueue(Job(ticket: Ticket(id: UUID()), priority: priority, start: start, accept: accept,
                         finished: finished, completion: completion, cancellation: Cancellation()))
    }

    /// Async form of `submit`. Cancelling the calling task finishes this request with `nil`
    /// (immediately if it was still pending); an active worker still runs to completion.
    package func prepare(priority: TaskPriority = .userInitiated,
                         accept: @escaping @MainActor () -> Bool = { true },
                         work: @escaping @Sendable () async -> Output,
                         finished: (@MainActor (Output) -> Void)? = nil) async -> Output?
    {
        await self.prepare(priority: priority, accept: accept, start: { work }, finished: finished)
    }

    package func prepare(priority: TaskPriority = .userInitiated,
                         accept: @escaping @MainActor () -> Bool = { true },
                         start: @escaping @MainActor () -> @Sendable () async -> Output,
                         finished: (@MainActor (Output) -> Void)? = nil) async -> Output?
    {
        guard !Task.isCancelled else { return nil }
        let ticket = Ticket(id: UUID()), cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.enqueue(Job(ticket: ticket, priority: priority, start: start, accept: accept, finished: finished,
                                 completion: { continuation.resume(returning: $0) }, cancellation: cancellation))
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(ticket) }
        }
    }

    /// Nothing submitted so far may deliver. A pending request finishes with `nil` at once;
    /// the active worker keeps its lease until it exits, then delivers `nil`.
    package func invalidate() {
        self.current = nil
        self.cancelActiveWorkIfSuperseded()
        self.dropPending()
    }

    /// Finishes `ticket` with `nil` if it hasn't delivered yet.
    package func cancel(_ ticket: Ticket) {
        if self.current == ticket {
            self.current = nil
            self.cancelActiveWorkIfSuperseded()
        }
        if self.pending?.ticket == ticket { self.dropPending() }
    }

    /// Returns once no worker is active and nothing is pending.
    package func waitForIdle() async {
        guard !self.isIdle else { return }
        await withCheckedContinuation { self.idleWaiters.append($0) }
    }

    private func enqueue(_ job: Job) -> Ticket {
        self.current = job.ticket
        if self.active != nil {
            self.cancelActiveWorkIfSuperseded()
            // Install the new request before completing the displaced one, so a completion that
            // submits again replaces this request rather than being overwritten by it.
            let displaced = self.pending
            self.pending = job
            displaced?.completion(nil)
        } else {
            self.start(job)
        }
        return job.ticket
    }

    private func dropPending() {
        guard let displaced = self.pending else { return }
        self.pending = nil
        displaced.completion(nil)
        self.resumeIdleWaitersIfIdle()
    }

    private func cancelActiveWorkIfSuperseded() {
        guard self.cancelsSupersededWork, self.active != nil, self.active != self.current else { return }
        self.activeWorker?.cancel()
    }

    private func start(_ job: Job) {
        self.active = job.ticket
        let work = job.start()
        let worker = Task.detached(priority: job.priority) { await work() }
        self.activeWorker = worker
        // Holds the preparer until the worker exits, so the pending request still runs and every
        // request completes exactly once even if the owner lets go of the preparer meanwhile.
        self.workerTask = Task { [self] in
            let output = await worker.value
            job.finished?(output)
            let accepted = self.current == job.ticket && !job.cancellation.isCanceled && job.accept()
            self.active = nil
            self.activeWorker = nil
            self.workerTask = nil
            if let next = self.pending {
                self.pending = nil
                self.start(next)
            }
            job.completion(accepted ? output : nil)
            self.resumeIdleWaitersIfIdle()
        }
    }

    private func resumeIdleWaitersIfIdle() {
        guard self.isIdle, !self.idleWaiters.isEmpty else { return }
        let waiters = self.idleWaiters
        self.idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
