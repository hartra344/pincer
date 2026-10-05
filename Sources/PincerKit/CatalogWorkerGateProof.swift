#if DEBUG && os(macOS)
import Foundation
import Darwin

/// Neutral fixture reproduces the existing synchronous catalog discovery gate.
/// Explicit release owns the held worker even when its task is cancelled.
private final class CatalogProofGate: @unchecked Sendable {
    private let lock = NSLock()
    private let suspension = DispatchSemaphore(value: 0)
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
    func hold() {
        entered.yield(())
        suspension.wait()
    }
    func open(expired: Bool = false) {
        let signal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            fallback = expired
            return true
        }
        if signal { suspension.signal() }
    }
    func continuationRan() {
        lock.withLock { progressed = !fallback }
        open()
    }
    var progressedBeforeFallback: Bool { lock.withLock { progressed } }
}

/// One actual utility discovery worker and one same-QoS continuation.
@MainActor package func runCatalogWorkerGateProof() async -> CooperativeWorkerGateEvidence {
    let gate = CatalogProofGate()
    let fallbackAction: @Sendable () -> Void = { gate.open(expired: true) }
    let fallback = DispatchWorkItem(block: fallbackAction)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: fallback)
    defer { fallback.cancel(); gate.open() }
    let expected = DeviceSpeechCatalogSnapshot(localeIdentifier: "en-US", voices: [
        DeviceSpeechVoice(id: "fixture.voice", name: "Fixture", language: "en-US", quality: 1)
    ], dictationSupport: nil)
    let catalog = DeviceSpeechCatalog { _ in gate.hold(); return expected }
    catalog.refresh(localeIdentifier: "en-US")
    for await _ in gate.entry { break }
    let actualTask = catalog.actualDiscoveryTaskForTesting
    let held = actualTask != nil && catalog.isRefreshing
    let unpublished = catalog.snapshot == nil
    let continuation = Task.detached(priority: .utility) { gate.continuationRan() }
    await continuation.value
    let result = await actualTask?.value
    let deadline = ContinuousClock.now + .seconds(2)
    while catalog.isRefreshing && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return CooperativeWorkerGateEvidence(
        strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1",
        actualLeaseHeld: held, noEarlyPublication: unpublished,
        continuationBeforeFallback: gate.progressedBeforeFallback,
        exactCompletion: result == expected && catalog.snapshot == expected,
        idleAfterCompletion: !catalog.isRefreshing && catalog.actualDiscoveryTaskForTesting == nil)
}

/// The child receives STRICT before runtime startup. All process work stays off Main.
package func runCatalogWorkerGateChild(executable: URL) async throws -> CooperativeWorkerChildResult {
    try await withCheckedThrowingContinuation { completion in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do {
                let child = Process(), output = Pipe()
                child.executableURL = executable
                child.arguments = ["--catalog-worker-gate-proof"]
                var environment = ProcessInfo.processInfo.environment
                environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
                environment["PINCER_KEYCHAIN"] = "memory"
                environment["PINCER_DEV_NAMESPACE"] = "catalog-gate-" + UUID().uuidString
                child.environment = environment
                child.standardOutput = output
                try child.run()
                func stopped(after seconds: Double) -> Bool {
                    let deadline = ContinuousClock.now + .seconds(seconds)
                    while child.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    return !child.isRunning
                }
                if !stopped(after: 15) {
                    if child.isRunning {
                        guard kill(child.processIdentifier, SIGTERM) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                        }
                    }
                    if !stopped(after: 3) {
                        if child.isRunning {
                            guard kill(child.processIdentifier, SIGKILL) == 0 else {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                            }
                        }
                        guard stopped(after: 3) else { throw CocoaError(.executableRuntimeMismatch) }
                    }
                }
                child.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                completion.resume(returning: CooperativeWorkerChildResult(status: child.terminationStatus,
                    evidence: try? JSONDecoder().decode(CooperativeWorkerGateEvidence.self, from: data)))
            } catch { completion.resume(throwing: error) }
        }
    }
}
#endif
