#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Gateway log Export ownership", .timeLimit(.minutes(2)))
struct GatewayLogExportOwnershipTests {
    actor Gate {
        var entered = false, released = false
        var arrival: CheckedContinuation<Void, Never>?
        var held: CheckedContinuation<Void, Never>?
        func holdFirst() async {
            guard !entered else { return }
            entered = true; arrival?.resume(); arrival = nil
            if !released { await withCheckedContinuation { held = $0 } }
        }
        func wait() async { if !entered && !released { await withCheckedContinuation { arrival = $0 } } }
        func release() { released = true; arrival?.resume(); arrival = nil; held?.resume(); held = nil }
    }

    @Test(arguments: [false, true])
    func completedWorkerCannotPublishOldOrCanceledRequest(cancel: Bool) async {
        let entries = await Task.detached {
            (0..<3).map { [GatewayLogEntry(id: $0, line: GatewayLogLine.parse("request \($0)"))] }
        }.value
        let preparation = GatewayLogExportPreparation(), gate = Gate()
        preparation.afterPreparation = { await gate.holdFirst() }
        let probe = GatewayLogExportProbe(); preparation.probe = probe
        var published: [Data] = []
        preparation.request(entries[0], gatewayName: "first") { published.append($0.data) }
        defer { preparation.cancel(); Task { await gate.release() } }
        await withTaskCancellationHandler {
            await gate.wait()
            #expect(preparation.activeCount == 1 && preparation.pendingCount == 0 && published.isEmpty)
            preparation.request(entries[1], gatewayName: "superseded") { published.append($0.data) }
            preparation.request(entries[2], gatewayName: "latest") { published.append($0.data) }
            #expect(preparation.activeCount == 1 && preparation.pendingCount == 1)
            if cancel {
                preparation.cancel()
                #expect(preparation.activeCount == 1 && preparation.pendingCount == 0)
            }
            await gate.release()
            await preparation.waitForIdle()
            #expect(published == (cancel ? [] : [Data("request 2".utf8)]))
            #expect(preparation.activeCount == 0 && preparation.pendingCount == 0)
            let counts = probe.snapshot()
            #expect(counts.mainJoins == 0 && counts.mainEncodes == 0)
            #expect(counts.workerJoins == (cancel ? 1 : 2) && counts.workerEncodes == (cancel ? 1 : 2))
            // Cancellation/disappearance does not permanently disable a later current request.
            preparation.request(entries[1], gatewayName: "new current") { published.append($0.data) }
            await preparation.waitForIdle()
            #expect(published.last == Data("request 1".utf8))
        } onCancel: { Task { await gate.release() } }
    }
}
#endif
