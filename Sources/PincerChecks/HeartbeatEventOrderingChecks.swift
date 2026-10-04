import Foundation
@testable import PincerKit

@MainActor
private final class HeartbeatResponseGate {
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
func runHeartbeatEventOrderingChecks() async {
    func payload(_ failed: Bool, _ timestamp: Int) -> JSONValue {
        ["ts": .number(Double(timestamp)), "status": .string(failed ? "failed" : "ok-token"),
         "reason": .string(failed ? "heartbeat failure" : "heartbeat success")]
    }
    for eventFailed in [true, false] {
        let gate = HeartbeatResponseGate()
        let old = payload(!eventFailed, 1700000000000)
        let health: JSONValue = ["ok": true, "ts": 1700000000000, "heartbeatSeconds": 0,
                                 "channels": ["telegram": ["accountId": "default", "enabled": true,
                                                             "configured": true, "running": true, "connected": false]]]
        let model = GatewayHealthModel { method, _ in
            if method == "last-heartbeat" { await gate.hold(); return old }
            return health
        }
        let refresh = Task { await model.refresh() }
        defer { refresh.cancel(); gate.release() }
        guard await waitFor("held offline heartbeat RPC", { gate.entered }) else {
            check(false, "actual heartbeat refresh reaches its held request"); continue
        }
        let event = payload(eventFailed, 1700000001000)
        model.handle(event: "heartbeat", payload: event)
        check(model.heartbeat == GatewayHeartbeat(event), "actual heartbeat event publishes before old response release")
        gate.release()
        await refresh.value
        check(model.heartbeat == GatewayHeartbeat(event), "new heartbeat timestamp, status and reason survive older refresh")
        check(model.activeIssues.contains { $0.id == "heartbeat:failed" } == eventFailed,
              "new heartbeat issue state survives older refresh")
        check(model.health?.checkedAt == Date(timeIntervalSince1970: 1700000000)
              && model.activeIssues.contains { $0.id == "channel:telegram:default" },
              "independent health publication survives heartbeat ordering")
    }
    let gate = HeartbeatResponseGate()
    let model = GatewayHealthModel { method, _ in
        if method == "last-heartbeat" {
            await gate.hold()
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method: last-heartbeat", details: nil)
        }
        return ["ok": true, "heartbeatSeconds": 0]
    }
    let refresh = Task { await model.refresh() }
    defer { refresh.cancel(); gate.release() }
    guard await waitFor("held offline heartbeat error", { gate.entered }) else {
        check(false, "actual heartbeat refresh reaches its held error"); return
    }
    let event = payload(true, 1700000001000)
    model.handle(event: "heartbeat", payload: event)
    gate.release()
    await refresh.value
    check(model.isAvailable(.heartbeat) && model.heartbeat == GatewayHeartbeat(event),
          "older missing-method error cannot disable a freshly reported heartbeat")
}

@MainActor
func runDemoHeartbeatEventOrderingChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("heartbeat ordering Demo connection", timeout: 25, { gateway.state.isConnected }) else {
        check(false, "heartbeat ordering connects to actual Demo Gateway"); return
    }
    let gate = HeartbeatResponseGate()
    var oldTimestamp: Date?
    var actualHealth: GatewayHealthSummary?
    let model = GatewayHealthModel { method, params in
        let result = try await gateway.connection.request(method, params, timeout: 30)
        if method == "last-heartbeat" {
            oldTimestamp = GatewayHeartbeat(result)?.at
            await gate.hold()
        } else if method == "health" { actualHealth = GatewayHealthSummary(result) }
        return result
    }
    let refresh = Task { await model.refresh() }
    defer { refresh.cancel(); gate.release() }
    guard await waitFor("already returned Demo heartbeat RPC", { gate.entered }) else {
        check(false, "actual Demo heartbeat reaches held publication boundary"); return
    }
    do {
        var fresh: JSONValue = .null
        var beat: GatewayHeartbeat?
        for _ in 0..<4 {
            fresh = try await gateway.connection.request("last-heartbeat", [:], timeout: 30)
            beat = GatewayHeartbeat(fresh)
            if let current = beat?.at, let old = oldTimestamp, current > old { break }
            await Task.yield()
        }
        guard let beat, let current = beat.at, let old = oldTimestamp, current > old else {
            check(false, "actual Demo heartbeat responses have distinguishable ordered timestamps"); return
        }
        model.handle(event: "heartbeat", payload: fresh)
        check(model.heartbeat == beat, "actual newer Demo heartbeat publishes through public event handler")
        gate.release()
        await refresh.value
        check(model.heartbeat == beat, "older real Demo heartbeat cannot overwrite newer actual event payload")
        check(model.health == actualHealth && actualHealth != nil,
              "actual Demo health still publishes independently of superseded heartbeat RPC")
    } catch {
        check(false, "actual Demo heartbeat ordering RPC failed: \(error)")
    }
}
