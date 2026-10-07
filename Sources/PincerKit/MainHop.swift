import Foundation

/// Runs main-actor work from a system callback whose thread isn't guaranteed (BGTask expiration,
/// background-task expiration, remote commands). `MainActor.assumeIsolated` traps off-main, which
/// crashed the app in the background whenever a refresh outlived its time (#930).
public enum MainHop {
    /// Inline when already on the main thread (so synchronous handlers stay synchronous), otherwise
    /// queued on the main queue.
    public static func run(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

/// One system-launched background refresh: runs the work and reports completion exactly once,
/// whether the work finishes or the system's time runs out first.
@MainActor
public final class BackgroundRefreshJob {
    private let work: @MainActor () async -> Bool
    private let complete: @MainActor (_ success: Bool) -> Void
    private var task: Task<Void, Never>?
    public private(set) var finished = false

    public init(work: @escaping @MainActor () async -> Bool, complete: @escaping @MainActor (_ success: Bool) -> Void) {
        self.work = work
        self.complete = complete
    }

    public func start() {
        self.task = Task { @MainActor in
            let success = await self.work()
            self.finish(success: success && !Task.isCancelled)
        }
    }

    /// The system's expiration handler. `BGTask` calls it on a background queue, so it must not
    /// assume the main actor. It cancels the work and completes at once, as the system requires.
    public nonisolated func expire() {
        MainHop.run { self.expireNow() }
    }

    private func expireNow() {
        self.task?.cancel()
        self.finish(success: false)
    }

    private func finish(success: Bool) {
        guard !self.finished else { return }
        self.finished = true
        self.complete(success)
    }
}
