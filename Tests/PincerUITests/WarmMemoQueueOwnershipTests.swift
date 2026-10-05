#if DEBUG && os(macOS)
import Foundation
import Testing
import Darwin
@testable import PincerKit
@testable import PincerUI

private final class WarmMemoForeignGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var fallback = false
    private var normalRelease = false
    private var entered = false
    private var offMain = false
    func hold(_ id: String) {
        condition.lock()
        entered = true
        offMain = !Thread.isMainThread
        while !released { condition.wait() }
        condition.unlock()
    }
    func open(failedSafety: Bool = false, normalRelease: Bool = false) {
        condition.withLock {
            guard !released else { return }
            released = true
            fallback = failedSafety
            self.normalRelease = normalRelease
            condition.broadcast()
        }
    }
    var actualHeldOffMain: Bool { condition.withLock { entered && offMain && !released } }
    var notNormallyReleased: Bool { condition.withLock { !normalRelease } }
    var safetyDidNotExpire: Bool { condition.withLock { !fallback } }
}

private final class WarmMemoTargetEntry: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var rowID: String?
    private var offMain = false
    func record(_ id: String) { lock.withLock { count += 1; rowID = id; offMain = !Thread.isMainThread } }
    func matches(_ id: String) -> Bool { lock.withLock { count == 1 && rowID == id && offMain } }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct WarmMemoQueueOwnershipTests {
    private static func row(_ source: String) -> TranscriptRow {
        let id = UUID().uuidString
        var item = ChatItem(id: id, role: .user, blocks: [.text(source)], timestamp: .now)
        item.transcriptId = id
        return .entry(.user(item))
    }
    private func observed(_ predicate: @MainActor () -> Bool, seconds: Int = 3) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate() && !Task.isCancelled && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
        }
        return predicate()
    }
    // Cleanup observation deliberately ignores cancellation, but remains finite.
    private func drained(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.001) { continuation.resume() }
            }
        }
        return predicate()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_WARM_MEMO_CHILD"] != nil))
    func actualWarmMemoQueueOwnershipChild() async throws {
        let mode = ProcessInfo.processInfo.environment["PINCER_WARM_MEMO_CHILD"]
        try #require(mode == "ordinary" || mode == "held" || mode == "cancellation")
        print("PINCER_WARM_MEMO_CHILD_PID=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        defer { print("PINCER_WARM_MEMO_CHILD_COMPLETE=\(mode ?? "")"); fflush(stdout) }
        if mode == "cancellation" {
            try await actualCancellationControl()
            try emit(["mode": "cancellation", "prerequisites": true, "semanticPassed": true,
                      "admissionsIdle": true, "safetyDidNotExpire": true])
            return
        }
        let acquired = await TranscriptSharedCacheLease.shared.acquire()
        try #require(acquired)
        defer { TranscriptSharedCacheLease.shared.release() }
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let ordinarySource = "Ordinary warm control " + UUID().uuidString
        let ordinaryRows = [Self.row(ordinarySource)]
        let ordinary = TranscriptPremeasureDriver(admission: TranscriptPremeasureAdmission())
        ordinary.currentRow = { id in ordinaryRows.first { $0.id == id } }
        let ordinaryJob = try #require(ordinary.split([0], all: ordinaryRows, width: 700, renderer: renderer).offload.first)
        var ordinaryResult: [PremeasuredRow]?
        let ordinaryAdmitted = ordinary.admission.submit(ordinaryJob, env: renderer.textEnvironment, epoch: ordinary.epoch) { ordinaryResult = $0 }
        let ordinaryCompleted = await observed { ordinaryResult != nil }
        // Release/cancel ownership and observe its actual worker callback before throwing.
        if !ordinaryCompleted { ordinary.cancelAll() }
        let ordinaryDrained = await drained { ordinaryResult != nil && !ordinary.admission.active }
        if !ordinaryDrained {
            try? emit(["mode": mode ?? "", "prerequisites": false, "semanticPassed": false,
                      "setupDrainFailed": true])
            // The owned child cannot safely tear down scratch while its real worker is live.
            // Parent treats raw exit2 as setup failure, never a semantic regression.
            Darwin._exit(2)
        }
        let ready = ordinaryResult ?? []
        let ordinaryAdopted = ordinary.adopt(ready, width: 700, epoch: ordinary.epoch.current).count
        let ordinaryWarm = ordinary.split([0], all: ordinaryRows, width: 700, renderer: renderer).measureNow
        let ordinaryPassed = ordinaryAdmitted && ordinaryCompleted && ordinaryDrained && ready.count == 1
            && ready.first?.discarded == false && ready.first?.rowId == ordinaryRows[0].id
            && ready.first?.epoch == ordinary.epoch.current
            && ready.first?.rowRevision == ordinaryJob.rowRevision
            && ready.first?.bodies.first?.key.source == ordinarySource
            && ordinaryAdopted == 1 && ordinaryWarm == [0]
        let ordinaryChurnID = UUID().uuidString
        for index in 0...TranscriptText.segmentCapacity {
            _ = TranscriptText.markdown("ordinary-cache-churn-\(ordinaryChurnID)-\(index)", tone: .primary, dark: false)
        }
        let ordinaryChurnPassed = ordinaryPassed
            && ordinary.split([0], all: ordinaryRows, width: 700, renderer: renderer).offload.count == 1
        if mode == "ordinary" {
            let evidence: [String: Any] = ["mode": "ordinary", "prerequisites": ordinaryPassed && ordinaryChurnPassed,
                "ordinaryPassed": ordinaryPassed, "ordinaryChurnPassed": ordinaryChurnPassed,
                "semanticPassed": ordinaryPassed && ordinaryChurnPassed]
            try emit(evidence)
            try #require(ordinaryPassed && ordinaryChurnPassed, "actual ordinary worker/source/adoption/warmth/drain prerequisite")
            return
        }
        try #require(ordinaryPassed && ordinaryChurnPassed, "actual ordinary worker/source/adoption/warmth/drain prerequisite")
        let foreignRows = [Self.row("Foreign queue owner " + UUID().uuidString)]
        let foreign = TranscriptPremeasureDriver(admission: TranscriptPremeasureAdmission())
        foreign.currentRow = { id in foreignRows.first { $0.id == id } }
        let targetRows = [Self.row("Evict me from the text cache " + UUID().uuidString)]
        let target = TranscriptPremeasureDriver(admission: TranscriptPremeasureAdmission())
        target.currentRow = { id in targetRows.first { $0.id == id } }
        let foreignJob = try #require(foreign.split([0], all: foreignRows, width: 700, renderer: renderer).offload.first)
        let targetJob = try #require(target.split([0], all: targetRows, width: 700, renderer: renderer).offload.first)
        let gate = WarmMemoForeignGate()
        let targetEntry = WarmMemoTargetEntry()
        foreign.admission.beforeSourcePreparation = { gate.hold($0) }
        target.admission.beforeSourcePreparation = { targetEntry.record($0) }
        let safetyAction: @Sendable () -> Void = { gate.open(failedSafety: true) }
        let safety = DispatchWorkItem(block: safetyAction)
        defer { safety.cancel(); gate.open() }
        var foreignCompleted = false
        let admitted = foreign.admission.submit(foreignJob, env: renderer.textEnvironment, epoch: foreign.epoch) { _ in foreignCompleted = true }
        let entryObserved = admitted ? await observed { gate.actualHeldOffMain } : false
        let entered = admitted && entryObserved
        let held = entered && gate.actualHeldOffMain && foreign.admission.active
        let distinct = foreign.admission !== target.admission
        let captured = targetJob.request?.driver === target && targetJob.rowId == targetRows[0].id
            && targetJob.request?.revision == targetJob.rowRevision && targetJob.bodies.isEmpty
        var targetAdmissionHeld = false
        var targetObservationCompleted = false
        let releaseAction: @Sendable () -> Void = { gate.open(normalRelease: true) }
        let normalRelease = DispatchWorkItem(block: releaseAction)
        defer { normalRelease.cancel(); gate.open() }
        var measured: [PremeasuredRow] = []
        var helperSucceeded = true
        if held && !Task.isCancelled {
            // Normal explicit release is independent of this helper returning, so an eventual
            // actual-completion helper can await the same held worker without safety expiry.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: safety)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6, execute: normalRelease)
            do {
                measured = try await prepareWarmMemoFixtureRows(targetJob, driver: target, env: renderer.textEnvironment) {
                    targetAdmissionHeld = gate.actualHeldOffMain && gate.notNormallyReleased && gate.safetyDidNotExpire
                        && target.admission.active && foreign.admission.active && foreign.admission !== target.admission
                    targetObservationCompleted = true
                }
            } catch {
                helperSucceeded = false
                gate.open()
            }
        } else { gate.open() }
        var sentinelCompleted = false
        TranscriptPremeasurer.shared.submit([], env: renderer.textEnvironment, epoch: target.epoch) { _ in sentinelCompleted = true }
        let actualDrained = await drained { foreignCompleted && sentinelCompleted && !foreign.admission.active && !target.admission.active && (!held || targetObservationCompleted) }
        let admissionsIdle = !foreign.admission.active && !target.admission.active
        let targetWorkerEntered = targetEntry.matches(targetRows[0].id)
        if !actualDrained {
            try? emit(["mode": "held", "prerequisites": false, "semanticPassed": false,
                      "setupDrainFailed": true])
            Darwin._exit(2)
        }
        let prerequisites = helperSucceeded && ordinaryPassed && ordinaryChurnPassed && held && distinct && captured && targetAdmissionHeld
            && foreignCompleted && sentinelCompleted && actualDrained && admissionsIdle && gate.safetyDidNotExpire
        // Compute original readiness results only after all actual worker ownership has drained.
        let adopted = target.adopt(measured, width: 700, epoch: target.epoch.current).count
        let warm = target.split([0], all: targetRows, width: 700, renderer: renderer).measureNow
        let churnID = UUID().uuidString
        for index in 0...TranscriptText.segmentCapacity {
            _ = TranscriptText.markdown("cache-churn-\(churnID)-\(index)", tone: .primary, dark: false)
        }
        let offload = target.split([0], all: targetRows, width: 700, renderer: renderer).offload.count
        try emit(["mode": "held", "ordinaryPassed": ordinaryPassed, "ordinaryChurnPassed": ordinaryChurnPassed, "prerequisites": prerequisites,
            "foreignHeldOffMain": held, "distinctOwners": distinct, "targetJobCaptured": captured,
            "targetAdmissionHeld": targetAdmissionHeld, "targetWorkerEntered": targetWorkerEntered,
            "foreignCompleted": foreignCompleted, "queueSentinelCompleted": sentinelCompleted,
            "admissionsIdle": admissionsIdle, "safetyDidNotExpire": gate.safetyDidNotExpire,
            "measuredCount": measured.count, "adoptedCount": adopted, "warmIndices": warm,
            "evictedOffloadCount": offload, "semanticPassed": adopted == 1 && warm == [0] && offload == 1])
        try #require(prerequisites, "actual foreign/target ownership and explicit worker drain prerequisites")
        #expect(adopted == 1, "original warm memo adoption readiness")
        #expect(warm == [0], "original immediate warm memo readiness")
        #expect(offload == 1, "an evicted text entry invalidates the warm shortcut")
    }
    private func actualCancellationControl() async throws {
        let acquired = await TranscriptSharedCacheLease.shared.acquire()
        try #require(acquired)
        defer { TranscriptSharedCacheLease.shared.release() }
        let scratch = ScratchDefaults()
        var safeToRemoveScratch = false
        defer { if safeToRemoveScratch { scratch.remove() } }
        let renderer = TranscriptLayoutCacheTests.renderer(scratch)
        let rows = [Self.row("Cancellation ownership " + UUID().uuidString)]
        let driver = TranscriptPremeasureDriver(admission: TranscriptPremeasureAdmission())
        driver.currentRow = { id in rows.first { $0.id == id } }
        let job = try #require(driver.split([0], all: rows, width: 700, renderer: renderer).offload.first)
        let gate = WarmMemoForeignGate()
        driver.admission.beforeSourcePreparation = { gate.hold($0) }
        let safetyAction: @Sendable () -> Void = { gate.open(failedSafety: true) }
        let safety = DispatchWorkItem(block: safetyAction)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: safety)
        defer { safety.cancel(); gate.open() }
        var finished = false
        var cancelled = false
        var returnedRows = false
        let awaiter = Task { @MainActor in
            defer { finished = true }
            do {
                _ = try await prepareWarmMemoFixtureRows(job, driver: driver, env: renderer.textEnvironment)
                returnedRows = true
            } catch is CancellationError { cancelled = true }
            catch { /* Setup error is rejected by the strict terminal checks below. */ }
        }
        let entered = await observed { gate.actualHeldOffMain && driver.admission.active }
        awaiter.cancel()
        // A genuine subsequent Main dispatch turn allows a premature cancellation resume
        // to run. No Task.yield guessing and no synchronous wait on Main.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let retainedUntilRelease = entered && awaiter.isCancelled && !finished
            && gate.actualHeldOffMain && driver.admission.active
        gate.open()
        let actualDrained = await drained { finished && !driver.admission.active }
        safeToRemoveScratch = actualDrained
        // A failed finite drain remains inside the owned child. Never release its cache
        // isolation lease or remove scratch while actual work could still be running.
        if !actualDrained {
            try? emit(["mode": "cancellation", "prerequisites": false, "semanticPassed": false,
                       "setupDrainFailed": true])
            Darwin._exit(2)
        }
        await awaiter.value
        try #require(entered && retainedUntilRelease && gate.safetyDidNotExpire,
                     "cancelled awaiter retains its real worker until explicit release")
        try #require(cancelled && !returnedRows, "cancellation throws only after the actual worker drains")
    }
    private func emit(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("PINCER_WARM_MEMO_CHILD_EVIDENCE=" + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
}

#endif
