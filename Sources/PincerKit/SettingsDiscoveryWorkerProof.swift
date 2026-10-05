#if DEBUG && os(macOS)
import Foundation
import Darwin

/// Replicates the existing SettingsDiscoveryGate's synchronous five-second condition wait.
/// Entry and call count describe the actual discover callback, not the earlier async hold seam.
private final class SettingsDiscoveryProofGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var fallback = false
    private var expired = false
    private var calls = 0
    private var onMain = false
    private var priority: TaskPriority?
    private var progressed = false
    var onEntry: (@Sendable () -> Void)?
    func discover(locale: String) -> DeviceSpeechCatalogSnapshot {
        condition.lock()
        calls += 1
        onMain = Thread.isMainThread
        if calls == 1 { priority = Task.currentPriority }
        onEntry?()
        if !Thread.isMainThread {
            let deadline = Date().addingTimeInterval(5)
            while !released && condition.wait(until: deadline) {}
            if !released { expired = true }
        }
        condition.unlock()
        return Self.expected(locale)
    }
    static func expected(_ locale: String) -> DeviceSpeechCatalogSnapshot {
        DeviceSpeechCatalogSnapshot(localeIdentifier: locale,
            voices: [DeviceSpeechVoice(id: "settings.saved-voice", name: "Saved Voice", language: "en-US", quality: 2)],
            dictationSupport: DeviceDictationSupport(language: "English", supported: true))
    }
    func open(fallback: Bool = false) {
        condition.withLock {
            guard !released else { return }
            released = true
            self.fallback = fallback
            condition.broadcast()
        }
    }
    func continuationRan() {
        condition.withLock { progressed = !released && !fallback && !expired }
        open()
    }
    var held: Bool { condition.withLock { calls == 1 && !released && !expired } }
    var workerPriority: TaskPriority? { condition.withLock { priority } }
    var actualCallCount: Int { condition.withLock { calls } }
    var ranOffMain: Bool { condition.withLock { calls == 1 && !onMain } }
    var didExpire: Bool { condition.withLock { expired } }
    var continuationBeforeFallback: Bool { condition.withLock { progressed } }
}

@MainActor private final class SettingsDiscoveryObservation {
    var task: Task<DeviceSpeechCatalogSnapshot, Never>?
    var continuation: Task<TaskPriority, Never>?
    var held = false
    var unpublished = false
    var priority: TaskPriority?
}

package struct SettingsDiscoveryWorkerEvidence: Codable, Sendable {
    package let heldMode: Bool
    package let strictEnvironment: Bool
    package let actualTaskCapturedAndDrained: Bool
    package let actualDiscoveryHeld: Bool
    package let noEarlyPublication: Bool
    package let actualDiscoveryOffMain: Bool
    package let actualDiscoveryCallCount: Int
    package let priorityMatched: Bool
    package let workerPriorityRaw: UInt8?
    package let continuationPriorityRaw: UInt8?
    package let discoveryDidNotExpire: Bool
    package let exactCompletion: Bool
    package let idleAfterCompletion: Bool
    package let continuationBeforeFallback: Bool
    package var prerequisites: Bool {
        strictEnvironment && actualTaskCapturedAndDrained && noEarlyPublication && actualDiscoveryOffMain && actualDiscoveryCallCount == 1 && discoveryDidNotExpire && exactCompletion && idleAfterCompletion && (!heldMode || (actualDiscoveryHeld && priorityMatched))
    }
    package var passed: Bool { prerequisites && (!heldMode || continuationBeforeFallback) }
}
package struct SettingsDiscoveryWorkerChildResult: Sendable {
    package let status: Int32
    package let ownedChildNormalExit: Bool
    package let evidence: SettingsDiscoveryWorkerEvidence?
}

@MainActor package func runSettingsDiscoveryWorkerProof(holdWorker: Bool = true) async -> SettingsDiscoveryWorkerEvidence {
    let gate = SettingsDiscoveryProofGate()
    let catalog = DeviceSpeechCatalog { gate.discover(locale: $0) }
    let observed = SettingsDiscoveryObservation()
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let continuationCompletion = AsyncStream<TaskPriority>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let fallbackAction: @Sendable () -> Void = { gate.open(fallback: true) }
    let fallback = DispatchWorkItem(block: fallbackAction)
    defer { fallback.cancel(); gate.open(); gate.onEntry = nil }
    if holdWorker {
        gate.onEntry = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    observed.task = catalog.actualDiscoveryTaskForTesting
                    observed.held = gate.held && observed.task != nil && catalog.isRefreshing
                    observed.unpublished = catalog.snapshot == nil
                    observed.priority = gate.workerPriority
                    if let priority = observed.priority {
                        observed.continuation = Task.detached(priority: priority) {
                            let actual = Task.currentPriority
                            gate.continuationRan()
                            continuationCompletion.continuation.yield(actual)
                            continuationCompletion.continuation.finish()
                            return actual
                        }
                    } else { gate.open(); continuationCompletion.continuation.finish() }
                    signal.continuation.yield(())
                }
            }
        }
    } else { gate.open() }
    catalog.refresh(localeIdentifier: "en-US")
    if holdWorker {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: fallback)
        for await _ in signal.stream { break }
    } else {
        observed.task = catalog.actualDiscoveryTaskForTesting
        observed.unpublished = catalog.snapshot == nil && catalog.isRefreshing
    }
    var actualPriority: TaskPriority?
    if holdWorker {
        // Observe completion without awaiting its Task handle, which can donate the parent priority.
        for await priority in continuationCompletion.stream { actualPriority = priority; break }
        _ = await observed.continuation?.value
    }
    let result = await observed.task?.value
    let deadline = ContinuousClock.now + .seconds(2)
    while catalog.isRefreshing && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return SettingsDiscoveryWorkerEvidence(heldMode: holdWorker,
        strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1",
        actualTaskCapturedAndDrained: observed.task != nil,
        actualDiscoveryHeld: observed.held, noEarlyPublication: observed.unpublished,
        actualDiscoveryOffMain: gate.ranOffMain, actualDiscoveryCallCount: gate.actualCallCount,
        priorityMatched: observed.priority != nil && actualPriority == observed.priority,
        workerPriorityRaw: observed.priority?.rawValue, continuationPriorityRaw: actualPriority?.rawValue,
        discoveryDidNotExpire: !gate.didExpire,
        exactCompletion: result == SettingsDiscoveryProofGate.expected("en-US") && catalog.snapshot == result,
        idleAfterCompletion: !catalog.isRefreshing && catalog.actualDiscoveryTaskForTesting == nil,
        continuationBeforeFallback: gate.continuationBeforeFallback)
}

/// The child receives STRICT before runtime startup. All process work stays off Main.
package func runSettingsDiscoveryWorkerGateChild(executable: URL, ordinary: Bool = false) async throws -> SettingsDiscoveryWorkerChildResult {
    try await withCheckedThrowingContinuation { completion in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do {
                let child = Process()
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("settings-discovery-worker-output-" + UUID().uuidString)
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
                child.executableURL = executable
                child.arguments = [ordinary ? "--settings-discovery-worker-ordinary" : "--settings-discovery-worker-proof"]
                var environment = ProcessInfo.processInfo.environment
                environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
                environment["PINCER_KEYCHAIN"] = "memory"
                environment["PINCER_DEV_NAMESPACE"] = "settings-discovery-gate-" + UUID().uuidString
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
                try output.synchronize()
                let data = try Data(contentsOf: outputURL)
                completion.resume(returning: SettingsDiscoveryWorkerChildResult(status: child.terminationStatus, ownedChildNormalExit: child.terminationReason == .exit,
                    evidence: try? JSONDecoder().decode(SettingsDiscoveryWorkerEvidence.self, from: data)))
            } catch { completion.resume(throwing: error) }
        }
    }
}
#endif
