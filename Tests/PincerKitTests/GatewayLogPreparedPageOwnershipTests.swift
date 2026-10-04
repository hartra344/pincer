#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Prepared log page ownership", .timeLimit(.minutes(2)))
struct GatewayLogPreparedPageOwnershipTests {
    actor Gate {
        var entered = false
        var open = false
        var arrival: CheckedContinuation<Void, Never>?
        var held: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            arrival?.resume(); arrival = nil
            if !open { await withCheckedContinuation { held = $0 } }
        }
        func wait() async {
            if !entered { await withCheckedContinuation { arrival = $0 } }
        }
        func release() { open = true; arrival?.resume(); arrival = nil; held?.resume(); held = nil }
    }

    @Test(arguments: [false, true])
    func completedWorkerCannotUndoClear(cancel: Bool) async {
        let gate = Gate()
        let model = GatewayLogsModel { _, _ in
            .object(["cursor": JSONValue(20), "size": JSONValue(20),
                     "lines": .array([.string("prepared line")])])
        }
        model.didPreparePage = { await gate.hold() }
        let probe = GatewayLogPreparationProbe()
        model.pagePreparationProbe = probe
        let task = Task { await model.poll() }
        await withTaskCancellationHandler { await gate.wait() } onCancel: { Task { await gate.release() } }
        #expect(probe.snapshot().offMainRows == 1)
        #expect(model.isFetching)
        model.clear()
        if cancel { task.cancel() }
        #expect(model.isFetching)
        await gate.release()
        await task.value
        #expect(model.entries.isEmpty)
        #expect(model.cursor == 20)
        #expect(!model.isFetching)
        #expect(model.bufferedBytes == 0)
    }

    @Test
    func preparedRowsKeepExistingEntryAndByteBounds() async {
        let model = GatewayLogsModel { _, _ in
            .object(["cursor": JSONValue(30), "lines": .array((0..<20).map { .string("line \($0)") })])
        }
        model.capacity = 4
        model.byteCapacity = 15
        await model.poll()
        #expect(model.entries.map(\.message) == ["line 18", "line 19"])
        #expect(model.entries.map(\.id) == [3, 4])
        #expect(model.bufferedBytes == 14)
        #expect(model.lineCount == 2)
    }
}
#endif
