import Foundation
import Testing
@testable import PincerKit

/// Parks each request by arrival order (round 1, 2, ...) until `release(round)`. A cancelled
/// request releases its own round. Subclasses call `hold()` from their `request` and inspect `entered`.
@MainActor class RoundGate {
    private(set) var entered = 0
    var failures: Set<Int> = []
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func release(_ round: Int) { released.insert(round); waiters.removeValue(forKey: round)?.resume() }
    func releaseAll() { for round in 1...max(entered, 2) { release(round) } }

    /// Enters the next round and returns once it is released; throws on cancellation, or `failure` for a failing round.
    func hold(failure: (Int) -> Error) async throws -> Int {
        entered += 1
        let round = entered
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released.contains(round) || Task.isCancelled { continuation.resume() }
                else { waiters[round] = continuation }
            }
        } onCancel: { Task { @MainActor in self.release(round) } }
        try Task.checkCancellation()
        if failures.contains(round) { throw failure(round) }
        return round
    }
}

@MainActor
@Suite("RoundGate")
struct RoundGateTests {
    private final class Gate: RoundGate {}

    @Test(.timeLimit(.minutes(1))) func roundsParkUntilReleasedInAnyOrder() async throws {
        let gate = Gate()
        var done: [Int] = []
        let first = Task { @MainActor in done.append(try await gate.hold { _ in CancellationError() }) }
        while gate.entered < 1 { await Task.yield() }
        let second = Task { @MainActor in done.append(try await gate.hold { _ in CancellationError() }) }
        while gate.entered < 2 { await Task.yield() }
        gate.release(2); try await second.value
        #expect(done == [2])
        gate.release(1); try await first.value
        #expect(done == [2, 1])
    }

    @Test(.timeLimit(.minutes(1))) func failingRoundThrowsAndCancelledRoundIsReleased() async throws {
        let gate = Gate()
        gate.failures = [1]
        let failing = Task { @MainActor in try await gate.hold { GatewayError.closed("round \($0) failed") } }
        while gate.entered < 1 { await Task.yield() }
        gate.release(1)
        await #expect(throws: GatewayError.self) { try await failing.value }
        let cancelled = Task { @MainActor in try await gate.hold { _ in CancellationError() } }
        while gate.entered < 2 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
