import Foundation

/// Runs replaceable measurements away from the main actor while retaining only the newest
/// request that arrives during active work.
@MainActor
public final class LatestMeasurementWorker<Input: Sendable, Output: Sendable> {
    public typealias Operation = @Sendable (Input) async -> Output
    public typealias ResultHandler = @MainActor @Sendable (Output) -> Void

    private struct Request: Sendable {
        let token: UUID
        let generation: UInt64
        let input: Input
        let onResult: ResultHandler
    }

    private enum Completion: Sendable {
        case completed(Output)
        case cancelled
    }

    private let operation: Operation
    private var generation: UInt64 = 0
    private var activeToken: UUID?
    private var activeTask: Task<Void, Never>?
    private var pending: Request?

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    deinit {
        self.activeTask?.cancel()
    }

    /// The active slot remains occupied until its operation returns, even after invalidation.
    public var activeCount: Int { self.activeToken == nil ? 0 : 1 }
    public var pendingCount: Int { self.pending == nil ? 0 : 1 }

    public func submit(_ input: Input, onResult: @escaping ResultHandler) {
        self.generation &+= 1
        let request = Request(token: UUID(), generation: self.generation, input: input, onResult: onResult)
        guard self.activeToken == nil else {
            self.pending = request
            return
        }
        self.start(request)
    }

    /// Invalidates pending and active results. A running operation keeps its slot until it exits,
    /// preventing a replacement from overlapping work that ignores cancellation.
    public func invalidate() {
        self.generation &+= 1
        self.pending = nil
        self.activeTask?.cancel()
    }

    private func start(_ request: Request) {
        guard self.activeToken == nil else {
            self.pending = request
            return
        }
        self.activeToken = request.token
        let operation = self.operation
        self.activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let completion: Completion
            if Task.isCancelled {
                completion = .cancelled
            } else {
                completion = .completed(await operation(request.input))
            }
            await self?.finish(request, completion: completion)
        }
    }

    private func finish(_ request: Request, completion: Completion) {
        guard self.activeToken == request.token else { return }
        self.activeToken = nil
        self.activeTask = nil

        if request.generation == self.generation, case let .completed(output) = completion {
            // Clear the active slot before invoking client code; callbacks may submit recursively.
            request.onResult(output)
        }

        guard self.activeToken == nil, let next = self.pending else { return }
        self.pending = nil
        self.start(next)
    }
}
