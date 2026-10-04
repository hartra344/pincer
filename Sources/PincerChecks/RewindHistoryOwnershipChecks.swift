import Foundation
@testable import PincerKit

@MainActor private final class RewindHistoryCheckGate {
    var entered = false
    var historyCalls = 0
    var oldPoints: [SessionRewindPoint] = []
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
private func checkRewindHistoryOwnership(key: String, methods: @escaping @MainActor () -> Set<String>?,
                                         scopes: @escaping @MainActor () -> [String], demo: Bool,
                                         request: @escaping SessionManagerModel.Request, label: String) async {
    let gate = RewindHistoryCheckGate()
    let model = SessionManagerModel(methods: methods, scopes: scopes, allowsWritesWithoutAdmin: demo,
        request: { method, params in
            let result = try await request(method, params)
            if method == SessionManager.historyMethod {
                gate.historyCalls += 1
                if gate.historyCalls == 1 {
                    gate.oldPoints = SessionRewindPoint.points(history: result)
                    gate.entered = true
                    try await gate.hold()
                }
            }
            return result
        })
    let old = Task { await model.loadRewindPoints(key: key) }
    defer { gate.release(); old.cancel() }
    let entered = await waitFor("\(label) held old rewind history", { gate.entered })
    check(entered, "\(label): actual old history response reaches the held publication boundary")
    guard entered else { return }
    check(gate.oldPoints.count >= 2, "\(label): source has a later user entry and a retained earlier entry")
    guard let cut = gate.oldPoints.first, gate.oldPoints.count >= 2 else { return }
    let rewound = await model.rewind(key: key, entryId: cut.entryId)
    check(rewound && gate.historyCalls == 2, "\(label): actual rewind completes its fresh history reload")
    guard rewound else { return }
    let expected = Array(gate.oldPoints.dropFirst())
    check(model.rewindPoints[key] == expected && model.lastEditorText == cut.text && model.rewindErrors[key] == nil,
          "\(label): fresh source IDs/text and returned editor draft match the cut path")
    gate.release(); await old.value
    check(model.rewindPoints[key] == expected && model.rewindErrors[key] == nil,
          "\(label): releasing the older real history cannot resurrect the removed entry")
}

@MainActor
func runRewindHistoryOwnershipChecks() async {
    let key = "agent:main:dashboard:garden"
    var changed = false
    await checkRewindHistoryOwnership(key: key, methods: { nil }, scopes: { [GatewayConnection.adminScope] }, demo: false,
        request: { method, _ in
            switch method {
            case SessionManager.historyMethod:
                return changed
                    ? json(#"{"messages":[{"role":"user","timestamp":1700000000000,"content":"First question","__openclaw":{"id":"u1"}}]}"#)
                    : json(#"{"messages":[{"role":"user","timestamp":1700000000000,"content":"First question","__openclaw":{"id":"u1"}},{"role":"user","timestamp":1700000001000,"content":"Later question","__openclaw":{"id":"u2"}}]}"#)
            case SessionManager.rewindMethod: changed = true; return ["editorText": "Later question"]
            case SessionManager.branchesListMethod: return ["branches": []]
            case SessionManager.describeMethod: return ["session": ["key": .string(key)]]
            default: throw GatewayError.closed("Unexpected rewind check method")
            }
        }, label: "offline")
}

@MainActor
func runDemoRewindHistoryOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let key = "agent:main:dashboard:garden"
    let connected = await waitFor("rewind history Demo connection", timeout: 25, {
        gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil
    })
    check(connected, "rewind ownership connects to the genuine seeded Demo garden session")
    guard connected else { return }
    // Use the existing built-in Demo write policy, not fabricated hello scopes.
    await checkRewindHistoryOwnership(key: key, methods: { gateway.hello?.methods },
        scopes: { gateway.hello?.scopes ?? [] }, demo: gateway.profile.isDemo,
        request: { try await gateway.connection.request($0, $1) }, label: "Demo")
}
