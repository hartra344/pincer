import Foundation
@testable import PincerKit

@MainActor private final class UsageStatusAdmissionGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                if released || Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

/// Only delivery of an already-computed actual response is held; no backend mutation.
@MainActor private func checkUsageStatusAdmission(request: @escaping UsageModel.Request) async {
    let gate = UsageStatusAdmissionGate()
    var requests = 0
    var held: JSONValue?
    let model = UsageModel { method, params in
        requests += 1
        check(method == "usage.status" && params == [:], "status read uses the existing method and empty params")
        try Task.checkCancellation()
        let result = try await request(method, params)
        held = result
        await gate.hold()
        return result
    }
    let current = Task { await model.loadStatus() }
    defer { gate.release(); current.cancel() }
    let entered = await waitFor("computed usage status response") { gate.entered }
    check(entered, "actual usage status response reaches held local delivery")
    guard entered else {
        gate.release(); current.cancel(); await current.value
        return
    }
    guard let held, let expected = UsageStatusSummary(held) else {
        check(false, "held actual usage status response decodes")
        gate.release(); current.cancel(); await current.value
        return
    }
    check(!expected.providers.isEmpty, "held report contains actual provider rows")
    let canceled = Task { await model.loadStatus() }
    canceled.cancel()
    await canceled.value
    check(requests == 1, "pre-canceled status load admits no additional RPC")
    gate.release(); await current.value
    check(model.status.value == expected, "active usage read retains full exact provider report")
    check(model.status.hasLoaded && model.status.loadState == .idle, "active usage read completes healthy")
}

@MainActor func runUsageLoadAdmissionChecks() async {
    let response: JSONValue = ["updatedAt": 1700000000000,
        "providers": [["provider": "openai", "displayName": "Current", "windows": [["label": "Week", "usedPercent": 42]]]]]
    await checkUsageStatusAdmission { _, _ in response }
    for fails in [false, true] {
        let gate = UsageStatusAdmissionGate()
        var requests = 0
        let model = UsageModel { _, _ in
            requests += 1
            if requests == 1 { return response }
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Late canceled error", details: nil) }
            return ["updatedAt": 1700000000001, "providers": []]
        }
        await model.loadStatus()
        let canceled = Task { await model.loadStatus() }
        defer { gate.release(); canceled.cancel() }
        let entered = await waitFor("admitted usage cancellation") { gate.entered }
        check(entered, "late cancellation control reaches actual request")
        guard entered else {
            gate.release(); canceled.cancel(); await canceled.value
            return
        }
        canceled.cancel(); gate.release(); await canceled.value
        check(model.status.value == UsageStatusSummary(response) && model.status.loadState == .idle
              && model.status.hasLoaded && model.status.supported,
              "canceled admitted usage read retains healthy data without late success or error")
    }
}

/// Genuine Demo usage.status response forwarded without overlays or writes.
@MainActor func runDemoUsageLoadAdmissionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("usage admission Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "genuine Demo usage connection is ready")
    guard connected else { return }
    await checkUsageStatusAdmission { method, params in
        try await gateway.connection.request(method, params)
    }
}
