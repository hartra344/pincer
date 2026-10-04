import Foundation
@testable import PincerKit

@MainActor private final class DeviceAdmissionGate {
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
@MainActor private func checkDeviceLoadAdmission(request: @escaping DeviceManagementModel.Request) async {
    let gate = DeviceAdmissionGate()
    var requests = 0
    var heldResponse: JSONValue?
    let model = DeviceManagementModel { method, params in
        requests += 1
        try Task.checkCancellation()
        let result = try await request(method, params)
        heldResponse = result
        await gate.hold()
        return result
    }
    let current = Task { await model.load() }
    defer { gate.release(); current.cancel() }
    let entered = await waitFor("computed command device list response") { gate.entered }
    check(entered, "actual command device list response is held before local publication")
    guard entered else { return }
    let canceled = Task { await model.load() }
    canceled.cancel()
    await canceled.value
    check(requests == 1, "pre-canceled device list load sends no additional request")
    gate.release()
    await current.value
    guard let response = heldResponse else { check(false, "actual held device response is captured"); return }
    check(response["pending"]?.array != nil && response["paired"]?.array != nil,
          "actual held response contains legal pending and paired arrays")
    check(model.pending == DeviceManagementModel.sorted((response["pending"]?.array ?? []).compactMap(PendingDeviceRequest.init))
          && model.paired == model.sorted((response["paired"]?.array ?? []).compactMap(PairedDevice.init)),
          "healthy device read retains exact pending and paired rows")
    check(model.hasLoaded && model.loadState == .idle, "healthy device read finishes idle")
}

@MainActor func runDeviceLoadAdmissionChecks() async {
    let response: JSONValue = ["pending": [["requestId": "request-a", "deviceId": "pending-device", "publicKey": "pk", "roles": ["operator"], "scopes": ["operator.read"], "ts": 1700000000000]],
        "paired": [["deviceId": "paired-device", "publicKey": "pk", "roles": ["operator"], "scopes": ["operator.read"], "tokens": []]]]
    await checkDeviceLoadAdmission { method, params in
        check(method == DeviceManagementModel.listMethod && params == [:], "device list load uses existing get method and empty params")
        return response
    }

    for fails in [false, true] {
        let gate = DeviceAdmissionGate()
        let model = DeviceManagementModel { _, _ in
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "late device error", details: nil) }
            return response
        }
        let load = Task { await model.load() }; defer { load.cancel(); gate.release() }
        let entered = await waitFor("admitted device cancellation") { gate.entered }
        check(entered, "actual device load reaches admitted cancellation boundary")
        guard entered else { return }
        load.cancel(); gate.release(); await load.value
        check(model.pending.isEmpty && model.paired.isEmpty && !model.hasLoaded && model.loadState == .idle,
              "canceled admitted device load cannot publish late rows or errors")
    }

}

/// Read-only fresh mock coverage: actual authenticated device.pair.list response, no overlays.
@MainActor func runLiveDeviceLoadAdmissionChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Device admission check", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    gateway.start()
    defer { gateway.stop() }
    let connected = await waitFor("device list admission mock connection") { gateway.state.isConnected && gateway.hello != nil }
    check(connected, "actual mock device list connection is ready")
    guard connected else { return }
    let authorized = gateway.hello?.scopes.contains(GatewayConnection.adminScope) == true
        && gateway.hello?.methods.contains(DeviceManagementModel.listMethod) == true
    check(authorized, "mock advertises device list reads and grants actual admin scope")
    guard authorized else { return }
    await checkDeviceLoadAdmission { method, params in
        try await gateway.connection.request(method, params)
    }
}
