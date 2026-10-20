import Foundation
import Testing

/// Parks `hold(key)` callers until `release(key)` or `release()`. A cancelled holder releases every key.
@MainActor final class KeyedTestGate<Key: Hashable> {
    private(set) var entered: Set<Key> = []
    private(set) var isReleased = false
    private var releasedKeys: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ key: Key) async {
        entered.insert(key)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isReleased || releasedKeys.contains(key) || Task.isCancelled { continuation.resume() }
                else { waiters[key, default: []].append(continuation) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.release() } }
    }

    func release(_ key: Key) {
        releasedKeys.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
    }

    func release() {
        isReleased = true
        let parked = waiters.values.joined()
        waiters = [:]
        for waiter in parked { waiter.resume() }
    }
}

@MainActor
@Suite("KeyedTestGate")
struct KeyedTestGateTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "gate condition not reached")
            await Task.yield()
        }
    }

    @Test(.timeLimit(.minutes(1))) func releasesPerKeyThenAll() async throws {
        let gate = KeyedTestGate<String>()
        var resumed: [String] = []
        let a = Task { @MainActor in await gate.hold("a"); resumed.append("a") }
        let b = Task { @MainActor in await gate.hold("b"); resumed.append("b") }
        try await waitUntil { gate.entered == ["a", "b"] }
        #expect(resumed.isEmpty && !gate.isReleased)
        gate.release("a")
        await a.value
        #expect(resumed == ["a"])
        gate.release()
        await b.value
        #expect(resumed == ["a", "b"] && gate.isReleased)
        await gate.hold("late")
        #expect(gate.entered.contains("late"))
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAHolderReleasesEveryKey() async throws {
        let gate = KeyedTestGate<String>()
        let holder = Task { @MainActor in await gate.hold("x") }
        try await waitUntil { gate.entered.contains("x") }
        holder.cancel()
        await holder.value
        #expect(gate.isReleased)
    }
}
