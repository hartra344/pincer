#if DEBUG && os(macOS)
import Foundation
import Darwin

/// Fixture suspension retains the actual RawConfig validation worker until explicit release.
/// Explicit release owns the held worker even when its task is cancelled.
private final class RawProofGate: @unchecked Sendable {
    private let lock = NSLock()
    private let suspension = ExplicitWorkerTestGate()
    private var priority: TaskPriority?
    private var calls = 0
    private var released = false
    private var fallback = false
    private var progressed = false
    var onEntry: (@Sendable () -> Void)?
    func hold() async {
        let first = lock.withLock { () -> Bool in calls += 1; if calls == 1 { priority = Task.currentPriority }; return calls == 1 }
        guard first else { return }
        onEntry?()
        let expiryAction: @Sendable () -> Void = { self.open(expired: true) }
        let expiry = DispatchWorkItem(block: expiryAction)
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: expiry)
        defer { expiry.cancel() }
        await suspension.hold()
    }
    func open(expired: Bool = false) {
        let signal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            fallback = expired
            return true
        }
        if signal { suspension.open() }
    }
    func continuationRan() {
        lock.withLock { progressed = !fallback }
        open()
    }
    var isHeld: Bool { lock.withLock { !released && calls > 0 } }
    var workerPriority: TaskPriority? { lock.withLock { priority } }
    var progressedBeforeFallback: Bool { lock.withLock { progressed } }
}

package struct RawWorkerGateEvidence: Codable, Sendable {
    package let ordinaryPassed: Bool
    package let strictEnvironment: Bool
    package let actualLeaseHeld: Bool
    package let noEarlyPublication: Bool
    package let priorityRecorded: Bool
    package let priorityMatched: Bool
    package let workerPriorityRaw: UInt8?
    package let continuationPriorityRaw: UInt8?
    package let bothTasksCapturedAndDrained: Bool
    package let heldMode: Bool
    package let continuationBeforeFallback: Bool
    package let exactCompletion: Bool
    package let idleAfterCompletion: Bool
    package var passed: Bool { ordinaryPassed && strictEnvironment && noEarlyPublication && exactCompletion && idleAfterCompletion && (!heldMode || (actualLeaseHeld && priorityRecorded && priorityMatched && bothTasksCapturedAndDrained && continuationBeforeFallback)) }
}
package struct RawWorkerChildResult: Sendable {
    package let status: Int32
    package let ownedChildNormalExit: Bool
    package let evidence: RawWorkerGateEvidence?
}

@MainActor private final class RawProofObservation {
    var oldTask: Task<Void, Never>?
    var continuation: Task<TaskPriority, Never>?
    var held = false
    var guards = false
    var recorded: TaskPriority?
}

@MainActor package func runRawWorkerGateProof(holdWorker: Bool = true) async -> RawWorkerGateEvidence {
    let draft = RawConfigEditorDraft()
    draft.updateSnapshot("{value:1}")
    draft.edit("{value:2}")
    await draft.waitForValidation()
    let ordinary = draft.text == "{value:2}" && draft.baseline == "{value:1}" && draft.isEdited && !draft.validationPending && draft.validationError == nil
    draft.edit("{invalid:")
    await draft.waitForValidation()
    let invalid = draft.validationError != nil && draft.isEdited && !draft.validationPending && draft.baseline == "{value:1}"
    draft.revert()
    await draft.waitForValidation()
    let reverted = draft.text == "{value:1}" && !draft.isEdited
    if !holdWorker {
        return RawWorkerGateEvidence(ordinaryPassed: ordinary && invalid && reverted, strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1", actualLeaseHeld: false, noEarlyPublication: !draft.validationPending, priorityRecorded: false, priorityMatched: false, workerPriorityRaw: nil, continuationPriorityRaw: nil, bothTasksCapturedAndDrained: true, heldMode: false, continuationBeforeFallback: false, exactCompletion: ordinary && invalid && reverted, idleAfterCompletion: !draft.validationPending)
    }
    let gate = RawProofGate()
    let observed = RawProofObservation()
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let action: @Sendable () -> Void = { gate.open(expired: true) }
    let fallback = DispatchWorkItem(block: action)
    defer { fallback.cancel(); gate.open(); gate.onEntry = nil }
    gate.onEntry = {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                observed.oldTask = draft.actualValidationTaskForTesting
                observed.held = gate.isHeld && observed.oldTask != nil && draft.validationPending
                observed.recorded = gate.workerPriority
                draft.updateSnapshot("{value:2}")
                observed.guards = draft.validationPending && draft.beginSave() == nil && draft.text == "{value:1}" && draft.baseline == "{value:2}"
                if let priority = observed.recorded {
                    observed.continuation = Task.detached(priority: priority) {
                        let actual = Task.currentPriority
                        gate.continuationRan()
                        return actual
                    }
                } else { gate.open() }
                signal.continuation.yield(())
            }
        }
    }
    draft.validationObserver = { await gate.hold() }
    draft.edit("{value:1}")
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: fallback)
    for await _ in signal.stream { break }
    let priority = await observed.continuation?.value
    await observed.oldTask?.value
    await draft.waitForValidation()
    let exact = draft.isEdited && draft.text == "{value:1}" && draft.baseline == "{value:2}" && draft.validationError == nil
    return RawWorkerGateEvidence(ordinaryPassed: ordinary && invalid && reverted, strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1", actualLeaseHeld: observed.held, noEarlyPublication: observed.guards, priorityRecorded: observed.recorded != nil, priorityMatched: observed.recorded != nil && observed.recorded == priority, workerPriorityRaw: observed.recorded?.rawValue, continuationPriorityRaw: priority?.rawValue, bothTasksCapturedAndDrained: observed.oldTask != nil && draft.actualValidationTaskForTesting == nil, heldMode: true, continuationBeforeFallback: gate.progressedBeforeFallback, exactCompletion: exact, idleAfterCompletion: !draft.validationPending)
}

/// The child receives STRICT before runtime startup. All process work stays off Main.
package func runRawWorkerGateChild(executable: URL, ordinary: Bool = false) async throws -> RawWorkerChildResult {
    try await withCheckedThrowingContinuation { completion in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do {
                let child = Process()
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("raw-worker-output-" + UUID().uuidString)
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
                child.executableURL = executable
                child.arguments = [ordinary ? "--raw-worker-gate-ordinary" : "--raw-worker-gate-proof"]
                var environment = ProcessInfo.processInfo.environment
                environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
                environment["PINCER_KEYCHAIN"] = "memory"
                environment["PINCER_DEV_NAMESPACE"] = "raw-gate-" + UUID().uuidString
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
                completion.resume(returning: RawWorkerChildResult(status: child.terminationStatus, ownedChildNormalExit: child.terminationReason == .exit,
                    evidence: try? JSONDecoder().decode(RawWorkerGateEvidence.self, from: data)))
            } catch { completion.resume(throwing: error) }
        }
    }
}
#endif
