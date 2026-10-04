import Foundation
@testable import PincerKit

@MainActor private final class HealthAdmissionGate {
    var entered = false, released = false
    var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor private func checkHealthCanceledAdmission(request: @escaping GatewayHealthModel.Request) async {
    let gate = HealthAdmissionGate()
    var calls: [String: Int] = [:]
    var returned: [String: JSONValue] = [:]
    let model = GatewayHealthModel { method, params in
        check(["health", "last-heartbeat", "system-presence"].contains(method) && params == [:], "health admission uses only exact empty-parameter read methods")
        calls[method, default: 0] += 1
        try Task.checkCancellation()
        let value = try await request(method, params)
        returned[method] = value
        if method == "health" { await gate.hold() }
        return value
    }
    let healthy = Task { await model.load() }
    defer { healthy.cancel(); gate.release() }
    guard await waitFor("actual held health response", timeout: 15, { gate.entered && returned.count == 3 }) else {
        check(false, "health admission reaches actual held response")
        healthy.cancel(); gate.release(); await healthy.value; return
    }
    let canceled = Task { await model.refresh() }
    canceled.cancel()
    await canceled.value
    gate.release()
    await healthy.value
    check(calls == ["health": 1, "last-heartbeat": 1, "system-presence": 1], "pre-canceled refresh admits no additional health RPC")
    check(model.health == returned["health"].flatMap(GatewayHealthSummary.init)
          && model.heartbeat == returned["last-heartbeat"].flatMap(GatewayHeartbeat.init)
          && model.presence == returned["system-presence"].map(GatewayPresenceEntry.list),
          "all actual returned health, heartbeat and presence fields survive canceled admission")
    check(model.health != nil && model.heartbeatLoaded && model.hasLoaded, "healthy held load publishes after canceled refresh")
    check(model.loadState == .idle, "canceled refresh cannot publish an error or strand load readiness")
}

@MainActor func runHealthCanceledAdmissionChecks() async {
    var freshnessCalls = 0
    let freshness = GatewayHealthModel { method, _ in
        freshnessCalls += 1
        return method == "health" ? ["ok": true, "ts": 1700000000000, "channels": [:]] : .null
    }
    let now = Date(timeIntervalSince1970: 1700000000)
    let canceled = Task { await freshness.refresh(now: now) }
    canceled.cancel(); await canceled.value
    await freshness.refreshIfStale(now: now)
    check(freshnessCalls == 2 && freshness.health != nil, "canceled refresh does not consume the actual staleness window")
    await checkHealthCanceledAdmission { method, _ in
        if method == "health" { return ["ok": true, "ts": 1700000000000, "channels": [:]] }
        if method == "last-heartbeat" { return ["ts": 1700000000000, "status": "ok"] }
        return []
    }
}
@MainActor func runDemoHealthCanceledAdmissionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    guard await waitFor("health admission Demo", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "actual Demo connects for health admission"); return
    }
    await checkHealthCanceledAdmission { method, params in
        try await gateway.connection.request(method, params, timeout: 30)
    }
}
