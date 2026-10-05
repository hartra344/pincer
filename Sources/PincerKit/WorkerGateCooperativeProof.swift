#if DEBUG && os(macOS)
import Foundation

/// Fixture-only gate deliberately retains the captured synchronous blocking pattern in neutral.
/// Explicit release owns the held worker even when its task is cancelled.
private final class CooperativeProofGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var released = false
    private var fallback = false
    private var progressed = false
    let entry: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        entry = pair.stream
        entered = pair.continuation
    }
    func hold() async {
        entered.yield(())
        waitSynchronouslyForRelease()
    }
    private func waitSynchronouslyForRelease() { semaphore.wait() }
    func open(expired: Bool = false) {
        let signal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            fallback = expired
            return true
        }
        if signal { semaphore.signal() }
    }
    func continuationRan() {
        lock.withLock { progressed = !fallback }
        open()
    }
    var progressedBeforeFallback: Bool { lock.withLock { progressed } }
}

package struct CooperativeWorkerGateEvidence: Codable, Sendable {
    package let strictEnvironment: Bool
    package let actualLeaseHeld: Bool
    package let noEarlyPublication: Bool
    package let continuationBeforeFallback: Bool
    package let exactCompletion: Bool
    package let idleAfterCompletion: Bool
    package var passed: Bool {
        strictEnvironment && actualLeaseHeld && noEarlyPublication && continuationBeforeFallback && exactCompletion && idleAfterCompletion
    }
}

/// One real cache worker and one same-QoS continuation, not a pool saturation loop.
@MainActor package func runCooperativeWorkerGateProof() async -> CooperativeWorkerGateEvidence {
    let gate = CooperativeProofGate()
    let fallbackAction: @Sendable () -> Void = { gate.open(expired: true) }
    let fallback = DispatchWorkItem(block: fallbackAction)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3, execute: fallback)
    defer { fallback.cancel(); gate.open() }
    let cache = MessagePartExcerptCache()
    cache.preparationHoldForTesting = { await gate.hold() }
    let source = MessagePartExcerptSource("Actual excerpt.")
    _ = cache.excerpt(for: source)
    for await _ in gate.entry { break }
    let actualTask = cache.activeTaskForTesting
    let held = actualTask != nil && cache.activeCount == 1 && cache.inFlightKeyCount == 1
    let unpublished = cache.cachedCount == 0
    let continuation = Task.detached(priority: .userInitiated) { gate.continuationRan() }
    await continuation.value
    await actualTask?.value
    return CooperativeWorkerGateEvidence(
        strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1",
        actualLeaseHeld: held, noEarlyPublication: unpublished,
        continuationBeforeFallback: gate.progressedBeforeFallback,
        exactCompletion: cache.excerpt(for: source) == "Actual excerpt.",
        idleAfterCompletion: cache.activeCount == 0 && cache.inFlightKeyCount == 0)
}

package struct CooperativeWorkerChildResult: Sendable {
    package let status: Int32
    package let evidence: CooperativeWorkerGateEvidence?
}

/// The child receives STRICT before runtime startup. All process work stays off Main.
package func runCooperativeWorkerGateChild(executable: URL) async throws -> CooperativeWorkerChildResult {
    try await Task.detached {
        let child = Process(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["--cooperative-worker-gate-proof"]
        var environment = ProcessInfo.processInfo.environment
        environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
        environment["PINCER_KEYCHAIN"] = "memory"
        environment["PINCER_DEV_NAMESPACE"] = "cooperative-gate-" + UUID().uuidString
        child.environment = environment
        child.standardOutput = output
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        return CooperativeWorkerChildResult(status: child.terminationStatus,
            evidence: try? JSONDecoder().decode(CooperativeWorkerGateEvidence.self, from: data))
    }.value
}
#endif
