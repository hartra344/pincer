import Foundation
import Testing
@testable import PincerKit

/// Transport-boundary delivery of a response already computed by logs.tail.
/// Cancellation releases owned continuations; completion is always awaited via the real poll task.
@MainActor private final class ComputedLogPageGate {
    private var entered = false
    private var released = false
    private var delivery: CheckedContinuation<Void, Never>?
    private var admission: CheckedContinuation<Void, Never>?

    func hold() async {
        self.entered = true
        self.admission?.resume(); self.admission = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func waitEntered() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.entered || Task.isCancelled { continuation.resume() }
                else { self.admission = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }
    func release() {
        self.released = true
        let delivery = self.delivery; self.delivery = nil; delivery?.resume()
        let admission = self.admission; self.admission = nil; admission?.resume()
    }
}

@MainActor @Suite("Gateway Logs Clear ownership", .timeLimit(.minutes(2)))
struct GatewayLogsClearOwnershipTests {
    // Official openclaw 9c66d4c9a39b16d70e7c55186fe7e8550468a663:
    // packages/gateway-protocol/src/schema/logs-chat.ts and gateway/server-methods/logs.ts.
    private static func page(_ cursor: Int, _ message: String, file: String = "/tmp/openclaw/fixture.log", reset: Bool = false) -> JSONValue {
        ["file": .string(file), "cursor": JSONValue(cursor), "size": JSONValue(cursor),
         "lines": .array([.string("{\"level\":\"info\",\"message\":\"" + message + "\"}")]),
         "reset": .bool(reset), "truncated": false]
    }

    @Test(arguments: [false, true])
    func alreadyComputedPageCannotReappearAfterClear(_ clear: Bool) async throws {
        let gate = ComputedLogPageGate(); defer { gate.release() }
        var params: [JSONValue] = []
        let model = GatewayLogsModel { method, request in
            #expect(method == "logs.tail")
            #expect(request["limit"]?.int == GatewayLogsModel.limit && request["maxBytes"]?.int == GatewayLogsModel.maxBytes)
            params.append(request)
            let result = Self.page(params.count * 10, params.count == 1 ? "initial" : params.count == 2 ? "computed before Clear" : "new after Clear")
            if params.count == 2 { await gate.hold() }
            return result
        }
        await model.poll()
        #expect(model.entries.map(\.message) == ["initial"] && model.cursor == 10)
        let poll = Task { await model.poll() }
        defer { poll.cancel(); gate.release() }
        try await gate.waitEntered()
        #expect(model.isFetching && params[1]["cursor"]?.int == 10)
        if clear {
            model.clear()
            #expect(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0 && model.cursor == 10)
        }
        gate.release(); await poll.value
        #expect(!model.isFetching && model.hasLoaded && model.failure == nil)
        if clear {
            #expect(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0,
                    "Clear must not resurrect a page computed before it")
        } else {
            #expect(model.entries.map(\.message) == ["initial", "computed before Clear"], "current delivery still appends")
        }
        #expect(model.cursor == 20, "discarded display data still advances the cursor to prevent replay")
        await model.poll()
        #expect(params[2]["cursor"]?.int == 20)
        #expect(model.entries.last?.message == "new after Clear" && model.cursor == 30)
        if clear { #expect(model.entries.count == 1 && model.lineCount == 1) }
    }

    @Test func completedClearKeepsCursorAndAcceptsNewPage() async {
        var requests = 0
        let model = GatewayLogsModel { _, params in
            requests += 1
            if requests == 2 { #expect(params["cursor"]?.int == 10) }
            return Self.page(requests * 10, requests == 1 ? "old" : "new")
        }
        await model.poll(); model.clear()
        #expect(model.entries.isEmpty && model.cursor == 10)
        await model.poll()
        #expect(model.entries.map(\.message) == ["new"] && model.cursor == 20)
    }

    @Test func currentRotatedPageRetainsMarkerAndCursor() async {
        var requests = 0
        let model = GatewayLogsModel { _, _ in
            requests += 1
            return requests == 1 ? Self.page(10, "old") : Self.page(3, "rotated", file: "/tmp/openclaw/rotated.log", reset: true)
        }
        await model.poll(); await model.poll()
        #expect(model.cursor == 3 && model.file == "/tmp/openclaw/rotated.log")
        #expect(model.lineCount == 2 && model.entries.count == 3)
        #expect(model.entries.last?.message == "rotated")
    }
    @Test func repeatedClearSuppressesOldRotationMarkerButKeepsTransportMetadata() async throws {
        let gate = ComputedLogPageGate(); defer { gate.release() }
        var requests = 0
        let model = GatewayLogsModel { _, _ in
            requests += 1
            let response = requests == 1 ? Self.page(10, "old") : Self.page(3, "old rotated",
                file: "/tmp/openclaw/rotated.log", reset: true)
            if requests == 2 { await gate.hold() }
            return response
        }
        await model.poll()
        let old = Task { await model.poll() }; defer { old.cancel(); gate.release() }
        try await gate.waitEntered()
        model.clear(); model.clear(); gate.release(); await old.value
        #expect(model.entries.isEmpty && model.lineCount == 0 && model.bufferedBytes == 0 && !model.showsRecentOnly)
        #expect(model.cursor == 3 && model.size == 3 && model.file == "/tmp/openclaw/rotated.log")
    }

}
