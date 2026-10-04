#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct GatewayLogCopyOwnershipTests {
    actor Gate {
        var entered = false, open = false
        var arrival: CheckedContinuation<Void, Never>?, held: CheckedContinuation<Void, Never>?
        func hold() async { entered = true; arrival?.resume(); arrival = nil; if !open { await withCheckedContinuation { held = $0 } } }
        func wait() async { if !entered, !open { await withCheckedContinuation { arrival = $0 } } }
        func release() { open = true; arrival?.resume(); arrival = nil; held?.resume(); held = nil }
    }
    @Test(arguments: [false, true])
    func completedOldWorkerCannotPublishOverLatestOrDisappearance(disappear: Bool) async throws {
        let gate = Gate(), helper = GatewayLogCopyPreparation(), probe = GatewayLogCopyProbe()
        helper.probe = probe; helper.didPrepare = { await gate.hold() }
        let entries = await Task.detached { ["old", "middle", "latest"].enumerated().map { GatewayLogEntry(id: $0.offset, line: GatewayLogLine.parse($0.element)) } }.value
        var published: [String] = []
        helper.request([entries[0]], style: .raw) { published.append($0) }
        defer { helper.invalidate(); Task { await gate.release() } }
        try await withTaskCancellationHandler {
            await gate.wait()
            let activeWorker = try #require(helper.workerTask)
            helper.request([entries[1]], style: .raw) { published.append($0) }
            let middleID = helper.requestID
            let latest = Task { await helper.prepare([entries[2]], style: .raw) }
            while helper.requestID == middleID { try await Task.sleep(for: .milliseconds(10)) }
            if disappear { helper.invalidate() }
            await gate.release()
            let text = await latest.value
            await activeWorker.value
            #expect(text == (disappear ? "" : "latest"))
            #expect(published.isEmpty)
            #expect(probe.snapshot().main == 0)
            #expect(probe.snapshot().worker <= 2)
        } onCancel: { Task { await gate.release() } }
    }
    @Test func currentRequestPublishesExactText() async {
        let helper = GatewayLogCopyPreparation()
        let entries = await Task.detached { [GatewayLogEntry(id: 1, line: GatewayLogLine.parse("current"))] }.value
        let text: String = await withCheckedContinuation { continuation in
            helper.request(entries, style: .raw) { continuation.resume(returning: $0) }
        }
        #expect(text == "current")
    }
}
#endif
