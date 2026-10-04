import Foundation
@testable import PincerKit

@MainActor
private final class HealthResponseGate {
    var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        self.entered = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release() }
        }
    }

    func release() {
        self.released = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
func runHealthEventOrderingChecks() async {
    func payload(_ connected: Bool, _ timestamp: Int) -> JSONValue {
        ["ok": true, "ts": .number(Double(timestamp)), "heartbeatSeconds": 0,
         "channels": ["telegram": ["accountId": "default", "enabled": true,
                                     "configured": true, "running": true, "connected": .bool(connected)]]]
    }
    for eventConnected in [true, false] {
        let gate = HealthResponseGate()
        let old = payload(!eventConnected, 1700000000000)
        let model = GatewayHealthModel { method, _ in
            if method == "health" { await gate.hold(); return old }
            return ["ts": 1700000000000, "status": "failed", "reason": "independent heartbeat"]
        }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); gate.release() }
        guard await waitFor("held offline health RPC", { gate.entered }) else {
            check(false, "actual health refresh reaches its held request"); continue
        }
        model.handle(event: "health", payload: payload(eventConnected, 1700000001000))
        check(model.health?.channels.first?.summary.connected == eventConnected,
              "the actual health event publishes before the old RPC is released")
        gate.release()
        await refresh.value
        check(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000001)
              && model.health?.channels.first?.summary.connected == eventConnected,
              "a newer health event survives an older actual refresh")
        check(model.activeIssues.filter { $0.kind == .channel }.isEmpty == eventConnected,
              "current health channel issues survive refresh ordering")
        check(model.heartbeatLoaded && model.heartbeat?.reason == "independent heartbeat",
              "health event ordering leaves heartbeat publication independent")
    }
    for code in ["UNAVAILABLE", "INVALID_REQUEST", "FAILED"] {
        let gate = HealthResponseGate()
        let model = GatewayHealthModel { method, _ in
            if method == "health" {
                await gate.hold()
                throw GatewayError.rpc(code: code, message: code == "INVALID_REQUEST" ? "unknown method: health" : "old failure", details: nil)
            }
            return .null
        }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); gate.release() }
        guard await waitFor("held offline health error", { gate.entered }) else {
            check(false, "actual health refresh reaches its held error"); continue
        }
        model.handle(event: "health", payload: payload(true, 1700000001000))
        gate.release()
        await refresh.value
        check(model.healthFailure == nil && model.isAvailable(.health) && model.loadState == .idle,
              "an older \(code) error cannot replace fresh health availability or failure state")
    }
}

@MainActor
func runDemoHealthEventOrderingChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("health ordering Demo connection", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "health ordering connects to the actual Demo Gateway"); return
    }
    let gate = HealthResponseGate()
    var oldTimestamp: Date?
    var actualHeartbeat: GatewayHeartbeat?
    let model = GatewayHealthModel { method, params in
        let result = try await gateway.connection.request(method, params, timeout: 30)
        if method == "health" {
            oldTimestamp = GatewayHealthSummary(result)?.checkedAt
            await gate.hold()
        } else if method == "last-heartbeat" {
            actualHeartbeat = GatewayHeartbeat(result)
        }
        return result
    }
    let refresh = Task { await model.refresh() }
    defer { refresh.cancel(); gate.release() }
    guard await waitFor("already returned Demo health RPC", { gate.entered }) else {
        check(false, "actual Demo health response reaches the held publication boundary"); return
    }
    do {
        // Real sequential RPCs supply their own timestamps. No fabricated health state or delay.
        var fresh: JSONValue = .null
        var summary: GatewayHealthSummary?
        for _ in 0..<4 {
            fresh = try await gateway.connection.request("health", [:], timeout: 30)
            summary = GatewayHealthSummary(fresh)
            if let current = summary?.checkedAt, let old = oldTimestamp, current > old { break }
            await Task.yield()
        }
        guard let summary, let current = summary.checkedAt, let old = oldTimestamp, current > old else {
            check(false, "real Demo health responses have distinguishable ordered timestamps"); return
        }
        model.handle(event: "health", payload: fresh)
        check(model.health?.checkedAt == current && model.health?.channels == summary.channels,
              "the actual newer Demo payload publishes through the public health event handler")
        gate.release()
        await refresh.value
        check(model.health?.checkedAt == current && model.health?.channels == summary.channels,
              "older real Demo health RPC cannot overwrite its newer actual event payload")
        check(model.heartbeatLoaded && model.heartbeat == actualHeartbeat,
              "the actual Demo heartbeat RPC still publishes alongside the superseded health RPC")
    } catch {
        check(false, "actual Demo health ordering RPC failed: \(error)")
    }
}
