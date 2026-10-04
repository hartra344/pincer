import Foundation
import Testing
@testable import PincerKit

@MainActor private final class PolicyLoadGate {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                entry?.resume(); entry = nil
                if released || Task.isCancelled { continuation.resume() }
                else { delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered || Task.isCancelled { continuation.resume() } else { entry = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }
    func release() {
        released = true
        entry?.resume(); entry = nil
        delivery?.resume(); delivery = nil
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ExecPolicyLoadAdmissionTests {
    private static func snapshot(_ hash: String, ask: String = "on-miss") -> JSONValue {
        ["path": "policy.json", "exists": true, "hash": .string(hash),
         "file": ["version": 1, "defaults": ["security": "allowlist", "ask": .string(ask)]]]
    }

    @Test func canceledCallerCannotDisplaceCurrentPolicyRead() async throws {
        let gate = PolicyLoadGate()
        let expected = Self.snapshot("healthy-current")
        var requests = 0
        let model = ExecPolicyModel { method, params in
            #expect(method == ExecPolicy.getMethod && params == [:])
            requests += 1
            try Task.checkCancellation()
            await gate.hold()
            return expected
        }
        let current = Task { await model.load() }
        defer { gate.release(); current.cancel() }
        try await gate.waitForEntry()
        // Neither task can enter this MainActor method until its parent suspends.
        let canceled = Task { await model.load() }
        canceled.cancel()
        await canceled.value
        #expect(requests == 1, "pre-canceled load must not send another RPC")
        gate.release()
        await current.value
        #expect(model.snapshot == ExecApprovalsSnapshot(expected))
        #expect(model.snapshot?.hash == "healthy-current")
        #expect(model.loadState == .idle && model.hasLoaded)
    }

    @Test func ordinaryNewerReadWinsAnOlderCompletion() async throws {
        let gate = PolicyLoadGate()
        var requests = 0
        let model = ExecPolicyModel { _, _ in
            requests += 1
            let number = requests
            if number == 1 { await gate.hold() }
            return Self.snapshot(number == 1 ? "old" : "new")
        }
        let old = Task { await model.load() }
        defer { gate.release(); old.cancel() }
        try await gate.waitForEntry()
        await model.load()
        #expect(model.snapshot?.hash == "new")
        gate.release(); await old.value
        #expect(requests == 2 && model.snapshot?.hash == "new" && model.loadState == .idle)
    }

    @Test func currentReadFailureRemainsVisible() async {
        let model = ExecPolicyModel { _, _ in
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "policy unavailable", details: nil)
        }
        await model.load()
        #expect(model.loadState == .failed("policy unavailable"))
        #expect(model.hasLoaded && model.snapshot == nil)
    }

    @Test func typingDuringAValidReloadPreservesTheDraft() async throws {
        let gate = PolicyLoadGate()
        var requests = 0
        let model = ExecPolicyModel { _, _ in
            requests += 1
            if requests > 1 { await gate.hold() }
            return Self.snapshot(requests == 1 ? "initial" : "new-server")
        }
        await model.load()
        let reload = Task { await model.load() }
        defer { gate.release(); reload.cancel() }
        try await gate.waitForEntry()
        model.set(.ask, "always", agent: nil)
        gate.release(); await reload.value
        #expect(model.snapshot?.hash == "initial")
        #expect(model.draft.defaults[.ask] == "always" && model.hasChanges)
        #expect(model.loadState == .idle)
    }
}

extension ExecPolicyLoadAdmissionTests {
    @Test(arguments: [false, true])
    func cancellationAfterAdmissionCannotPublishLateResult(fails: Bool) async throws {
        let gate = PolicyLoadGate()
        let model = ExecPolicyModel { _, _ in
            await gate.hold()
            if fails {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "late local error", details: nil)
            }
            return Self.snapshot("canceled-read")
        }
        let load = Task { await model.load() }
        defer { gate.release(); load.cancel() }
        try await gate.waitForEntry()
        #expect(model.loadState == .running)
        load.cancel()
        gate.release()
        await load.value
        #expect(model.snapshot == nil && !model.hasLoaded)
        #expect(model.loadState == .idle && model.banner == nil)
    }
}
