#if DEBUG && os(macOS)
import Foundation
import Darwin

/// Fixture suspension retains the actual Share worker until explicit release.
/// Explicit release owns the held worker even when its task is cancelled.
private final class ShareProofGate: @unchecked Sendable {
    private let lock = NSLock()
    private let suspension = DispatchSemaphore(value: 0)
    private var priority: TaskPriority?
    private var calls = 0
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
        let first = lock.withLock { () -> Bool in calls += 1; if calls == 1 { priority = Task.currentPriority }; return calls == 1 }
        guard first else { return }
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
    var workerPriority: TaskPriority? { lock.withLock { priority } }
    var progressedBeforeFallback: Bool { lock.withLock { progressed } }
}

package struct ShareWorkerGateEvidence: Codable, Sendable {
    package let ordinaryPassed: Bool
    package let strictEnvironment: Bool
    package let actualLeaseHeld: Bool
    package let noEarlyPublication: Bool
    package let priorityRecorded: Bool
    package let priorityMatched: Bool
    package let workerPriorityRaw: UInt8?
    package let continuationPriorityRaw: UInt8?
    package let bothTasksCapturedAndDrained: Bool
    package let oldCancelled: Bool
    package let heldMode: Bool
    package let continuationBeforeFallback: Bool
    package let exactCompletion: Bool
    package let idleAfterCompletion: Bool
    package var passed: Bool { ordinaryPassed && strictEnvironment && noEarlyPublication && exactCompletion && idleAfterCompletion && (!heldMode || (actualLeaseHeld && priorityRecorded && priorityMatched && bothTasksCapturedAndDrained && oldCancelled && continuationBeforeFallback)) }
}
package struct ShareWorkerChildResult: Sendable {
    package let status: Int32
    package let ownedChildNormalExit: Bool
    package let evidence: ShareWorkerGateEvidence?
}

@MainActor package func runShareWorkerGateProof(holdWorker: Bool = true) async -> ShareWorkerGateEvidence {
    let gate = ShareProofGate()
    let action: @Sendable () -> Void = { gate.open(expired: true) }
    let fallback = DispatchWorkItem(block: action)
    let suite = "share-proof-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { fallback.cancel(); gate.open(); defaults.removePersistentDomain(forName: suite) }
    let roomy = GatewayProfile(name: "Roomy", url: "ws://127.0.0.1:10", authMode: .none)
    let tight = GatewayProfile(name: "Tight", url: "ws://127.0.0.1:9", authMode: .none)
    let policy = UploadPolicy(maxPayload: nil, maxImageBytes: nil, maxAttachmentBytes: 100)
    let bytes = Data(count: 1_000)
    let encoded = await Task.detached { try? JSONEncoder().encode(policy) }.value
    defaults.set(encoded, forKey: GatewayStore.uploadPolicyKey(tight.id))
    let model = ShareModel(profiles: [roomy, tight], identity: nil, defaults: defaults)
    let content = SharedContent(files: [SharedFile(name: "report.pdf", typeIdentifier: "com.adobe.pdf", data: bytes)])
    model.setContent(content)
    let ordinaryTask = model.actualAttachmentPreparationTaskForTesting
    let ordinaryAdmission = ordinaryTask != nil && model.isPreparingAttachments && model.attachments.isEmpty && model.attachmentProblems.isEmpty
    await ordinaryTask?.value
    let ordinary = ordinaryAdmission && model.attachments.count == 1 && model.attachments.first?.fileName == "report.pdf" && model.attachments.first?.mimeType == "application/pdf" && model.attachments.first?.data == bytes && model.attachmentProblems.isEmpty && !model.isPreparingAttachments
    if !holdWorker {
        model.profileId = tight.id
        await model.actualAttachmentPreparationTaskForTesting?.value
        let rejected = model.attachments.isEmpty && model.attachmentProblems.count == 1 && model.attachmentProblems.first?.contains("last known limit") == true && !model.isPreparingAttachments
        return ShareWorkerGateEvidence(ordinaryPassed: ordinary && rejected, strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1", actualLeaseHeld: false, noEarlyPublication: ordinaryAdmission, priorityRecorded: false, priorityMatched: false, workerPriorityRaw: nil, continuationPriorityRaw: nil, bothTasksCapturedAndDrained: ordinaryTask != nil, oldCancelled: false, heldMode: false, continuationBeforeFallback: false, exactCompletion: ordinary && rejected, idleAfterCompletion: !model.isPreparingAttachments)
    }
    model.attachmentPreparationProbe = { gate.hold() }
    model.setContent(content)
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: fallback)
    for await _ in gate.entry { break }
    let oldTask = model.actualAttachmentPreparationTaskForTesting
    let held = oldTask != nil && model.isPreparingAttachments
    let unpublished = model.attachments.isEmpty && model.attachmentProblems.isEmpty
    model.profileId = tight.id
    let currentTask = model.actualAttachmentPreparationTaskForTesting
    let recorded = gate.workerPriority
    var actualPriority: TaskPriority?
    if let recorded {
        let continuation = Task.detached(priority: recorded) { () -> TaskPriority in
            let priority = Task.currentPriority
            gate.continuationRan()
            return priority
        }
        actualPriority = await continuation.value
    } else { gate.open() }
    await oldTask?.value
    await currentTask?.value
    let exact = model.attachments.isEmpty && model.attachmentProblems.count == 1 && model.attachmentProblems.first?.contains("last known limit") == true
    return ShareWorkerGateEvidence(ordinaryPassed: ordinary, strictEnvironment: ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1", actualLeaseHeld: held, noEarlyPublication: unpublished, priorityRecorded: recorded != nil, priorityMatched: recorded != nil && actualPriority == recorded, workerPriorityRaw: recorded?.rawValue, continuationPriorityRaw: actualPriority?.rawValue, bothTasksCapturedAndDrained: oldTask != nil && currentTask != nil, oldCancelled: oldTask?.isCancelled == true, heldMode: true, continuationBeforeFallback: gate.progressedBeforeFallback, exactCompletion: exact, idleAfterCompletion: !model.isPreparingAttachments && model.actualAttachmentPreparationTaskForTesting == nil)
}

/// The child receives STRICT before runtime startup. All process work stays off Main.
package func runShareWorkerGateChild(executable: URL, ordinary: Bool = false) async throws -> ShareWorkerChildResult {
    try await withCheckedThrowingContinuation { completion in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do {
                let child = Process()
                let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("share-worker-output-" + UUID().uuidString)
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
                child.executableURL = executable
                child.arguments = [ordinary ? "--share-worker-gate-ordinary" : "--share-worker-gate-proof"]
                var environment = ProcessInfo.processInfo.environment
                environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
                environment["PINCER_KEYCHAIN"] = "memory"
                environment["PINCER_DEV_NAMESPACE"] = "share-gate-" + UUID().uuidString
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
                completion.resume(returning: ShareWorkerChildResult(status: child.terminationStatus, ownedChildNormalExit: child.terminationReason == .exit,
                    evidence: try? JSONDecoder().decode(ShareWorkerGateEvidence.self, from: data)))
            } catch { completion.resume(throwing: error) }
        }
    }
}
#endif
