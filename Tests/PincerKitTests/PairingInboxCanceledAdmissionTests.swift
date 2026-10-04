import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Pairing Inbox canceled admission", .timeLimit(.minutes(2)))
struct PairingInboxCanceledAdmissionTests {
    @MainActor final class Gate {
        var entered = false, open = false, attempts = 0
        var held: CheckedContinuation<Void, Never>?
        let response = PairingFixtures.list([PairingFixtures.request("held-request", metadata: ["name": "Fixture sender"])], owner: false)
        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            attempts += 1
            #expect(method == PairingInboxModel.listMethod && params == [:])
            try Task.checkCancellation()
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in if open { continuation.resume() } else { held = continuation } }
            } onCancel: { Task { @MainActor in self.release() } }
            return response
        }
        func release() { open = true; held?.resume(); held = nil }
    }
    @Test func preCanceledLoadCannotDiscardFullPendingInbox() async throws {
        let gate = Gate(), model = PairingInboxModel(request: gate.request)
        let expectedRequests = PairingInboxModel.sorted(gate.response["requests"]!.array!.compactMap(PairingRequest.init))
        let expectedAccounts = gate.response["accounts"]!.array!.compactMap(PairingAccount.init)
        try #require(!expectedRequests.isEmpty && !expectedAccounts.isEmpty)
        let healthy = Task { await model.load() }
        defer { healthy.cancel(); gate.release() }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !gate.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield() }
        } catch {
            healthy.cancel(); gate.release(); await healthy.value
            throw error
        }
        let canceled = Task { await model.load() }; canceled.cancel(); await canceled.value
        gate.release(); await healthy.value
        #expect(gate.attempts == 1)
        #expect(model.requests == expectedRequests && model.accounts == expectedAccounts)
        #expect(!model.commandOwnerConfigured && model.limits?.pendingPerAccount == 3 && model.limits?.ttl == 3600)
        #expect(model.loadState == .idle && model.hasLoaded && model.supported && model.canManage)
    }
    @Test func ordinaryAndCurrentFailureRetainSemantics() async {
        let gate = Gate(); gate.release()
        let model = PairingInboxModel(request: gate.request)
        await model.load()
        #expect(model.requests.count == 1 && model.accounts.count == 2 && model.loadState == .idle)
        let failed = PairingInboxModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "Current inbox unavailable", details: nil) }
        await failed.load()
        #expect(failed.loadState == .failed("Current inbox unavailable") && failed.hasLoaded && failed.supported)
    }
}
