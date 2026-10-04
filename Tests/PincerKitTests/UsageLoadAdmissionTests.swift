import Foundation
import Testing
@testable import PincerKit

@MainActor private final class UsageAdmissionGate {
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
struct UsageLoadAdmissionTests {
    private static func response(_ name: String) -> JSONValue {
        ["updatedAt": 1700000000000, "providers": [["provider": "openai", "displayName": .string(name),
            "windows": [["label": "Week", "usedPercent": 42, "resetAt": 1700003600000]]]]]
    }

    @Test func canceledCallerCannotDisplaceCurrentStatusRead() async throws {
        let gate = UsageAdmissionGate()
        let expected = Self.response("Current")
        var requests = 0
        let model = UsageModel { method, params in
            #expect(method == "usage.status" && params == [:])
            requests += 1
            try Task.checkCancellation()
            await gate.hold()
            return expected
        }
        let current = Task { await model.loadStatus() }
        defer { gate.release(); current.cancel() }
        try await gate.waitForEntry()
        let canceled = Task { await model.loadStatus() }
        canceled.cancel() // MainActor admission cannot run before this parent suspends.
        await canceled.value
        #expect(requests == 1)
        gate.release(); await current.value
        #expect(model.status.value == UsageStatusSummary(expected))
        #expect(model.status.hasLoaded && model.status.loadState == .idle)
    }

    @Test func ordinaryNewerStatusReadWins() async throws {
        let gate = UsageAdmissionGate()
        var requests = 0
        let model = UsageModel { _, _ in
            requests += 1
            let number = requests
            if number == 1 { await gate.hold() }
            return Self.response(number == 1 ? "Old" : "New")
        }
        let old = Task { await model.loadStatus() }
        defer { gate.release(); old.cancel() }
        try await gate.waitForEntry()
        await model.loadStatus()
        gate.release(); await old.value
        #expect(requests == 2 && model.status.value == UsageStatusSummary(Self.response("New")))
        #expect(model.status.loadState == .idle)
    }

    @Test func currentUnavailableRemainsFailed() async {
        let model = UsageModel { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "Current usage unavailable", details: nil) }
        await model.loadStatus()
        #expect(model.status.loadState == .failed("Current usage unavailable"))
        #expect(model.status.hasLoaded && model.status.supported)
    }

    @Test func independentCostReadDoesNotDisplaceStatus() async throws {
        let gate = UsageAdmissionGate()
        let expected = Self.response("Current")
        let model = UsageModel { method, _ in
            if method == "usage.status" { await gate.hold(); return expected }
            #expect(method == "usage.cost")
            return ["updatedAt": 1700000000000, "days": 7, "daily": [], "totals": ["totalTokens": 42, "totalCost": 1.25]]
        }
        let status = Task { await model.loadStatus() }
        defer { gate.release(); status.cancel() }
        try await gate.waitForEntry()
        await model.loadCost()
        #expect(model.cost.value?.totals.totalTokens == 42 && model.cost.loadState == .idle)
        gate.release(); await status.value
        #expect(model.status.value == UsageStatusSummary(expected) && model.status.loadState == .idle)
    }
}
