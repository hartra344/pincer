#if DEBUG
import CryptoKit
import Foundation
@testable import PincerKit

@MainActor private final class ShareTargetGate {
    var entered = 0, open = false
    var held: [CheckedContinuation<Void, Never>] = []
    func hold() async { entered += 1; if !open { await withCheckedContinuation { held.append($0) } } }
    func release() { open = true; let values = held; held = []; for value in values { value.resume() } }
}
@MainActor private func checkDisconnectedShareTargets(defaults: UserDefaults, profile: GatewayProfile, hello: GatewayHello,
                                                     request: @escaping @MainActor (String, JSONValue, TimeInterval) async throws -> JSONValue) async {
    let gate = ShareTargetGate()
    var state: ShareConnection.StateHandler?
    let model = ShareModel(profiles: [profile], identity: DeviceIdentity(privateKey: .init()), defaults: defaults,
        connectionFactory: { _, _ in ShareConnection(request: { method, params, timeout in
            check((method == "agents.list" && params == [:] && timeout == 20)
                  || (method == "sessions.list" && params == ["limit": 200, "includeLastMessage": false, "archived": false] && timeout == 30), "share target reads preserve exact existing requests")
            let result = try await request(method, params, timeout)
            check(method == "agents.list" ? !(result["agents"]?.array ?? []).compactMap(AgentSummary.init).isEmpty
                  : !(result["sessions"]?.array ?? []).compactMap(SessionRow.init).isEmpty,
                  "actual target response has fully available source rows before hold")
            await gate.hold(); return result
        }, setHandlers: { _, handler in state = handler }, start: { state?(.connected, hello) }, stop: {}) })
    model.connect()
    defer { gate.release(); model.disconnect() }
    guard await waitFor("actual share target responses", timeout: 15, { gate.entered == 2 }), let task = model.actualPumpTask else {
        check(false, "actual ShareModel pump reaches both held target responses"); gate.release(); model.disconnect(); return
    }
    let agents = model.agents, chats = model.chats, target = model.target, phase = model.phase
    model.disconnect(); gate.release(); await task.value
    check(model.agents == agents && model.chats == chats && model.target == target && model.phase == phase,
          "disconnected actual ShareModel rejects old target publication")
}
@MainActor func runShareTargetOwnershipChecks() async {
    let (defaults,suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    await checkDisconnectedShareTargets(defaults: defaults, profile: .demo(), hello: GatewayHello(payload: [:])) { method, _, _ in
        method == "agents.list" ? ["agents": [["id": "main", "name": "Main"]], "defaultId": "main"]
            : ["sessions": [["key": "agent:main:main", "agentId": "main", "kind": "direct", "updatedAt": 1700000000000]]]
    }
}
@MainActor func runDemoShareTargetOwnershipChecks() async {
    let (defaults,suite) = scratchDefaults(); defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    guard await waitFor("share target Demo", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }), let hello = gateway.hello else {
        check(false, "genuine Demo hello is available"); return
    }
    await checkDisconnectedShareTargets(defaults: defaults, profile: .demo(), hello: hello) { method, params, timeout in
        try await gateway.connection.request(method, params, timeout: timeout)
    }
}
#endif
