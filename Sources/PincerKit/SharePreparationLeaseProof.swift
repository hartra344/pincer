#if DEBUG && os(macOS)
import Foundation

package struct SharePreparationLeaseEvidence: Codable, Sendable {
    package let queuedLease: Bool
    package let cancelledWorkerHeld: Bool
    package let exactOutputs: Bool
    package let idle: Bool
    package var passed: Bool { queuedLease && cancelledWorkerHeld && exactOutputs && idle }
}
private final class ShareLeasePriority: @unchecked Sendable {
    private let lock = NSLock()
    private var priority: TaskPriority?
    private var expired = false
    private var held = false
    func record() { lock.withLock { priority = Task.currentPriority } }
    func markHeld(_ value: Bool) { lock.withLock { held = value } }
    var isHeld: Bool { lock.withLock { held } }
    func expire() { lock.withLock { expired = true } }
    var didExpire: Bool { lock.withLock { expired } }
    var value: TaskPriority? { lock.withLock { priority } }
}

@MainActor package func runSharePreparationLeaseProof() async -> SharePreparationLeaseEvidence {
    let preparer = SharedAttachmentPreparer()
    let gate = ExplicitWorkerTestGate()
    let recorded = ShareLeasePriority()
    let bytes = Data(count: 1_000)
    let content = SharedContent(files: [SharedFile(name: "report.pdf", typeIdentifier: "com.adobe.pdf", data: bytes)])
    let policy = UploadPolicy(maxPayload: nil, maxImageBytes: nil, maxAttachmentBytes: 2_000)
    let data = await Task.detached { try? JSONEncoder().encode(policy) }.value
    let open: @Sendable () -> Void = { recorded.expire(); gate.open() }
    let fallback = DispatchWorkItem(block: open)
    DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: fallback)
    defer { fallback.cancel(); gate.open() }
    let old = Task.detached {
        await preparer.prepare(content, livePolicy: nil, observedPolicy: nil, savedPolicyData: data, probe: {
            recorded.record()
            recorded.markHeld(true)
            await gate.hold()
            recorded.markHeld(false)
        })
    }
    let entered = await gate.waitUntilEntered(timeout: 2)
    old.cancel()
    guard entered, let priority = recorded.value else {
        gate.open(); _ = await old.value
        return SharePreparationLeaseEvidence(queuedLease: false, cancelledWorkerHeld: false, exactOutputs: false, idle: false)
    }
    let pending = Task.detached(priority: priority) {
        await preparer.prepare(content, livePolicy: nil, observedPolicy: nil, savedPolicyData: data, probe: nil)
    }
    let deadline = ContinuousClock.now + .seconds(2)
    var state = await preparer.preparationLeaseStateForTesting
    while state.pending != 1 && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
        state = await preparer.preparationLeaseStateForTesting
    }
    let queued = state.active && state.pending == 1 && !recorded.didExpire
    let cancelledHeld = old.isCancelled && queued && recorded.isHeld
    gate.open()
    let cancelled = await old.value
    let prepared = await pending.value
    let final = await preparer.preparationLeaseStateForTesting
    let exact = cancelled.attachments.isEmpty && cancelled.problems.isEmpty
        && prepared.attachments.count == 1 && prepared.attachments.first?.fileName == "report.pdf"
        && prepared.attachments.first?.mimeType == "application/pdf" && prepared.attachments.first?.data == bytes
        && prepared.problems.isEmpty
    return SharePreparationLeaseEvidence(queuedLease: queued, cancelledWorkerHeld: cancelledHeld,
        exactOutputs: exact, idle: !final.active && final.pending == 0)
}
#endif
