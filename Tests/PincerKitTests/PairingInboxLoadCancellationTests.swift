import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Pairing Inbox admitted cancellation", .timeLimit(.minutes(2)))
struct PairingInboxLoadCancellationTests {
    @MainActor final class ResponseGate {
        var entered = false, open = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            // Delivers an already-computed reply even after cancellation, to test publication guards.
            await withCheckedContinuation { continuation in
                if open { continuation.resume() } else { self.continuation = continuation }
            }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }
    private func awaitEntry(_ gate: ResponseGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !gate.entered {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
    }
    @Test(arguments: ["success", "UNKNOWN_METHOD", "missing-scope", "UNAVAILABLE"])
    func canceledAdmittedReplyPreservesFullKnownState(outcome: String) async throws {
        let gate = ResponseGate()
        var attempts = 0
        let initial = PairingFixtures.list([PairingFixtures.request("known")], owner: false)
        let model = PairingInboxModel { method, params in
            #expect(method == PairingInboxModel.listMethod && params == [:])
            attempts += 1
            if attempts == 1 { return initial }
            await gate.hold()
            if outcome == "success" { return PairingFixtures.list([PairingFixtures.request("obsolete")]) }
            let message = outcome == "missing-scope" ? "missing scope: operator.pairing" : "Obsolete pairing failure"
            throw GatewayError.rpc(code: outcome == "missing-scope" ? "INVALID_REQUEST" : outcome, message: message, details: nil)
        }
        await model.load()
        let requests = model.requests, accounts = model.accounts, limits = model.limits
        #expect(requests.count == 1 && accounts.count == 2 && model.hasLoaded)
        let task = Task { await model.load() }
        do { try await awaitEntry(gate) } catch {
            task.cancel(); gate.release(); await task.value; throw error
        }
        task.cancel(); gate.release(); await task.value
        #expect(attempts == 2)
        #expect(model.requests == requests && model.accounts == accounts && model.limits == limits)
        #expect(!model.commandOwnerConfigured && model.hasLoaded && model.supported && !model.needsAccess)
        #expect(model.loadState == .idle)
    }
    @Test func olderCanceledErrorCannotIdleNewerRunningLoad() async throws {
        let oldGate = ResponseGate(), newGate = ResponseGate()
        var attempts = 0
        let latestResponse = PairingFixtures.list([PairingFixtures.request("latest")], owner: false)
        let expectedRequests = PairingInboxModel.sorted(latestResponse["requests"]!.array!.compactMap(PairingRequest.init))
        let expectedAccounts = latestResponse["accounts"]!.array!.compactMap(PairingAccount.init)
        try #require(expectedRequests.count == 1 && expectedAccounts.count == 2)
        let model = PairingInboxModel { method, params in
            #expect(method == PairingInboxModel.listMethod && params == [:])
            attempts += 1
            if attempts == 1 {
                await oldGate.hold()
                throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "Obsolete response", details: nil)
            }
            await newGate.hold()
            return latestResponse
        }
        let old = Task { await model.load() }
        var newer: Task<Void, Never>?
        do {
            try await awaitEntry(oldGate)
            old.cancel()
            let latest = Task { await model.load() }; newer = latest
            try await awaitEntry(newGate)
            oldGate.release(); await old.value
            #expect(model.loadState == .running && !model.hasLoaded && model.supported)
            newGate.release(); await latest.value
            #expect(attempts == 2 && model.requests == expectedRequests && model.accounts == expectedAccounts)
            #expect(!model.commandOwnerConfigured && model.limits?.pendingPerAccount == 3 && model.limits?.ttl == 3600)
            #expect(model.loadState == .idle && model.hasLoaded && model.supported && !model.needsAccess)
        } catch {
            old.cancel(); newer?.cancel(); oldGate.release(); newGate.release()
            await old.value; if let newer { await newer.value }
            throw error
        }
    }
    @Test func unsupportedCurrentAdmissionRetainsExistingPolicy() async {
        var attempts = 0
        let model = PairingInboxModel(methods: { ["health"] }) { _, _ in attempts += 1; return [:] }
        await model.load()
        #expect(attempts == 0 && model.hasLoaded && !model.supported && model.loadState == .idle)
    }
}
