import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Approval history canceled admission", .timeLimit(.minutes(2)))
struct ApprovalHistoryCanceledAdmissionTests {
    @MainActor final class Gate {
        var entered = false, open = false, attempts = 0
        var held: CheckedContinuation<Void, Never>?
        let page: JSONValue = ["items": [["id": "terminal-one", "presentation": ["kind": "exec", "commandText": "echo fixture", "allowedDecisions": ["allow-once", "deny"]], "urlPath": "/approve/terminal-one", "expiresAtMs": 1700000002000, "reason": "user", "status": "denied", "createdAtMs": 1700000000000, "resolvedAtMs": 1700000001000, "decision": "deny"]], "nextCursor": "opaque-next"]
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            attempts += 1
            #expect(method == "approval.history" && params == ["limit": 50])
            try Task.checkCancellation()
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in if open { continuation.resume() } else { held = continuation } }
            } onCancel: { Task { @MainActor in self.release() } }
            return page
        }
        func release() { open = true; held?.resume(); held = nil }
    }
    @Test func preCanceledLoadCannotReplaceHeldTerminalHistory() async throws {
        let gate = Gate(), model = ApprovalHistoryModel(request: gate.request)
        let healthy = Task { await model.load() }
        defer { healthy.cancel(); gate.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !gate.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        let canceled = Task { await model.load() }; canceled.cancel(); await canceled.value
        gate.release(); await healthy.value
        #expect(gate.attempts == 1)
        #expect(model.items == gate.page["items"]!.array!.compactMap(ApprovalRecord.init))
        #expect(model.nextCursor == "opaque-next" && model.hasLoaded && model.loadState == .idle)
    }
    @Test func ordinaryAndCurrentUnavailableRetainSemantics() async {
        let gate = Gate(); gate.release()
        let model = ApprovalHistoryModel(request: gate.request)
        await model.load()
        #expect(model.items.count == 1 && model.nextCursor == "opaque-next" && model.hasLoaded)
        let failed = ApprovalHistoryModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "current ledger unavailable", details: nil) }
        await failed.load()
        #expect(failed.hasLoaded && failed.loadState == .failed("current ledger unavailable"))
    }
}
