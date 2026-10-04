import Foundation
@testable import PincerKit

@MainActor private final class DetailCheckGate {
    var entered = false
    var released = false
    var waiter: CheckedContinuation<Void, Never>?
    func release() { released = true; let old = waiter; waiter = nil; old?.resume() }
    func hold() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { waiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }
}

@MainActor
private func checkSessionDetailDeletion(key: String, demo: Bool, oldFails: Bool,
                                        methods: @escaping @MainActor () -> Set<String>?,
                                        scopes: @escaping @MainActor () -> [String],
                                        request: @escaping SessionManagerModel.Request, label: String) async {
    let gate = DetailCheckGate()
    let model = SessionManagerModel(methods: methods, scopes: scopes, allowsWritesWithoutAdmin: demo,
        request: { method, params in
            let response = try await request(method, params)
            if method == SessionManager.describeMethod {
                check(response["session"]?["key"] == .string(key), "\(label): actual describe supplies the selected session")
                gate.entered = true
                try await gate.hold()
                if oldFails { throw GatewayError.closed("old describe fixture failure") }
            }
            return response
        })
    await model.load(filter: .all)
    check(model.row(key) != nil, "\(label): actual listed session admits the delete action")
    guard model.row(key) != nil else { return }
    let old = Task { await model.loadDetails(key: key) }
    defer { gate.release(); old.cancel() }
    let entered = await waitFor("\(label) held describe", { gate.entered })
    check(entered, "\(label): old real describe reaches its held publication boundary")
    guard entered else { return }
    let result = await model.delete([key])
    check(result.succeeded == [key] && result.failed.isEmpty, "\(label): actual session delete succeeds")
    guard result.succeeded == [key] else { return }
    check(model.row(key) == nil && model.details[key] == nil && model.detailErrors[key] == nil,
          "\(label): delete clears both listed and cached session metadata")
    gate.release(); await old.value
    check(model.row(key) == nil && model.details[key] == nil && model.detailErrors[key] == nil,
          "\(label): old describe completion cannot resurrect metadata or attach an obsolete error")
}

@MainActor
func runSessionDetailOwnershipChecks() async {
    let key = "agent:main:dashboard:alpha"
    for oldFails in [false, true] {
        await checkSessionDetailDeletion(key: key, demo: false, oldFails: oldFails,
            methods: { nil }, scopes: { [GatewayConnection.adminScope] }, request: { method, _ in
                let row: JSONValue = ["key": .string(key), "agentId": "main", "sessionId": "s-alpha"]
                switch method {
                case SessionManager.listMethod: return ["sessions": [row]]
                case SessionManager.describeMethod: return ["session": row]
                case SessionManager.deleteMethod: return ["deleted": true]
                default: throw GatewayError.closed("Unexpected session detail check method")
                }
            }, label: oldFails ? "offline stale failure" : "offline stale success")
    }
}

@MainActor
func runDemoSessionDetailOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:garden"
    let connected = await waitFor("session detail Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil
    })
    check(connected, "detail checks connect to the real seeded Demo garden")
    guard connected else { return }
    // Built-in Demo permits management in its isolated in-memory instance. Hello
    // scopes and all describe/delete request and response fields remain untouched.
    await checkSessionDetailDeletion(key: key, demo: gateway.profile.isDemo, oldFails: false,
        methods: { gateway.hello?.methods }, scopes: { gateway.hello?.scopes ?? [] },
        request: { try await gateway.connection.request($0, $1) }, label: "Demo")
}
