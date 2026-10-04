import Foundation
@testable import PincerKit

@MainActor private final class AgentFileReloadCheckGate {
    var arrived = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        arrived = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { held in
                if released || Task.isCancelled { held.resume() } else { continuation = held }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; let held = continuation; continuation = nil; held?.resume() }
}

@MainActor func runAgentFileReloadOwnershipChecks() async {
    let gate = AgentFileReloadCheckGate(); defer { gate.release() }
    var calls = 0
    let management = AgentManagementModel { method, params in
        check(method == "agents.files.get" && params["agentId"] == "main" && params["name"] == "SOUL.md",
              "actual file editor uses existing verified get parameters")
        calls += 1
        if calls == 1 { return ["file": ["name": "SOUL.md", "content": "initial", "hash": "initial"]] }
        await gate.hold()
        return ["file": ["name": "SOUL.md", "content": "latest", "hash": "latest"]]
    }
    let editor = management.editor(agentId: "main", name: "SOUL.md")
    await editor.load()
    editor.text = "discarded draft"
    let reload = Task { await editor.resolveConflictKeepTheirs() }
    defer { reload.cancel(); gate.release() }
    let ready = await waitFor("actual file reload request", timeout: 20) { gate.arrived }
    check(ready, "actual reload reaches held request")
    guard ready else { return }
    editor.text = "later draft"; editor.text = "discarded draft"
    gate.release(); await reload.value
    check(editor.text == "discarded draft" && editor.entry?.content == "latest" && editor.entry?.hash == "latest" && editor.isDirty,
          "actual reload preserves later ABA intent while advancing authoritative baseline")
    await editor.resolveConflictKeepTheirs()
    check(editor.text == "latest" && !editor.isDirty && editor.loadState == .idle,
          "ordinary Reload Theirs still discards a pre-admission draft")
}

@MainActor func runDemoAgentFileReloadOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("file reload Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "actual Demo connects before workspace reload checks")
    guard connected else { return }
    let gate = AgentFileReloadCheckGate(); defer { gate.release() }
    var gets = 0
    let management = AgentManagementModel(methods: { Set(gateway.hello?.methods ?? []) }, scopes: { gateway.hello?.scopes ?? [] }) { method, params in
        let response = try await gateway.connection.request(method, params)
        if method == "agents.files.get" { gets += 1; if gets == 2 { await gate.hold() } }
        return response // Genuine Demo result; no file writes or response overlays.
    }
    let editor = management.editor(agentId: "main", name: "SOUL.md")
    await editor.load()
    guard let loaded = editor.entry?.content, let hash = editor.entry?.hash else { check(false, "actual Demo file supplies content/hash"); return }
    editor.text = "pre-reload local draft"
    let reload = Task { await editor.resolveConflictKeepTheirs() }
    defer { reload.cancel(); gate.release() }
    let ready = await waitFor("genuine Demo file response", timeout: 20) { gate.arrived }
    check(ready, "actual Demo file response reaches completion gate")
    guard ready else { return }
    editor.text = "newer local document"
    gate.release(); await reload.value
    check(editor.text == "newer local document" && editor.entry?.content == loaded && editor.entry?.hash == hash && editor.isDirty,
          "actual Demo reload keeps later typing over its real loaded version")
    await editor.resolveConflictKeepTheirs()
    check(editor.text == loaded && !editor.isDirty && gets == 3,
          "ordinary actual Demo reload discards prior draft without any file write")
}
