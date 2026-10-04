import Foundation
@testable import PincerKit

@MainActor private final class PolicyAdmissionGate {
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

/// The held request has already obtained its response. Only local delivery is deferred.
@MainActor private func checkPolicyLoadAdmission(response: JSONValue,
                                                request: @escaping ExecPolicyModel.Request) async {
    let gate = PolicyAdmissionGate()
    var requests = 0
    let model = ExecPolicyModel { method, params in
        requests += 1
        try Task.checkCancellation()
        let result = try await request(method, params)
        await gate.hold()
        return result
    }
    let current = Task { await model.load() }
    defer { gate.release(); current.cancel() }
    let entered = await waitFor("computed command policy response") { gate.entered }
    check(entered, "actual command policy response is held before local publication")
    guard entered else { return }
    let canceled = Task { await model.load() }
    canceled.cancel()
    await canceled.value
    check(requests == 1, "pre-canceled policy load sends no additional request")
    gate.release()
    await current.value
    check(model.snapshot == ExecApprovalsSnapshot(response) && model.snapshot?.hash == response["hash"]?.text,
          "valid active policy read retains exact snapshot and hash")
    check(model.hasLoaded && model.loadState == .idle, "valid active policy read finishes healthy")
}

@MainActor func runExecPolicyLoadAdmissionChecks() async {
    let response: JSONValue = ["path": "policy.json", "exists": true, "hash": "current-policy",
        "file": ["version": 1, "defaults": ["security": "allowlist", "ask": "on-miss"]]]
    await checkPolicyLoadAdmission(response: response) { method, params in
        check(method == ExecPolicy.getMethod && params == [:], "policy load uses existing get method and empty params")
        return response
    }
    for fails in [false, true] {
        let gate = PolicyAdmissionGate()
        let model = ExecPolicyModel { _, _ in
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "late local error", details: nil) }
            return response
        }
        let load = Task { await model.load() }
        defer { gate.release(); load.cancel() }
        let entered = await waitFor("admitted policy cancellation") { gate.entered }
        check(entered, "policy cancellation control reaches actual request")
        guard entered else { return }
        load.cancel()
        gate.release()
        await load.value
        check(model.snapshot == nil && !model.hasLoaded && model.loadState == .idle,
              "canceled admitted policy read cannot publish late success or failure")
    }
}

/// Read-only fresh mock coverage: actual authenticated exec.approvals.get response, no overlays.
@MainActor func runLiveExecPolicyLoadAdmissionChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Policy admission check", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start()
    defer { gateway.stop() }
    let connected = await waitFor("policy admission mock connection") { gateway.state.isConnected && gateway.hello != nil }
    check(connected, "actual mock policy connection is ready")
    guard connected else { return }
    let authorized = gateway.hello?.scopes.contains(GatewayConnection.adminScope) == true
        && gateway.hello?.methods.contains(ExecPolicy.getMethod) == true
    check(authorized, "mock advertises policy reads and grants actual admin scope")
    guard authorized else { return }
    do {
        let response = try await gateway.connection.request(ExecPolicy.getMethod, [:])
        check(response["hash"]?.text != nil && response["file"]?.object != nil,
              "actual mock provides a policy snapshot and hash")
        await checkPolicyLoadAdmission(response: response) { method, params in
            try await gateway.connection.request(method, params)
        }
    } catch {
        check(false, "actual mock policy read failed")
    }
}
