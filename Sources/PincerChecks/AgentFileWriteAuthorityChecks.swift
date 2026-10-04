import Foundation
@testable import PincerKit

@MainActor private final class FileWriteAuthorityGate {
    var arrived = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() } else { held = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; let old = held; held = nil; old?.resume() }
}

@MainActor func runAgentFileWriteAuthorityChecks() async {
    for failed in [false, true] {
        let gate = FileWriteAuthorityGate(); defer { gate.release() }
        var gets = 0
        let management = AgentManagementModel { method, _ in
            if method == "agents.files.set" {
                if failed { throw GatewayError.rpc(code: "UNAVAILABLE", message: "current write failed", details: nil) }
                return ["file": ["name": "SOUL.md", "content": "saved version", "hash": "saved"]]
            }
            gets += 1
            if gets == 2 { await gate.wait() }
            return ["file": ["name": "SOUL.md", "content": "old version", "hash": "old"]]
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        let reload = Task { await editor.load() }; defer { reload.cancel(); gate.release() }
        let ready = await waitFor("older file read", timeout: 20) { gate.arrived }
        check(ready, "actual older file read reaches completion gate")
        guard ready else { return }
        editor.text = "saved version"
        let saved = await editor.save()
        let error = editor.error
        check(saved == !failed && !editor.loadState.isRunning, "accepted write releases superseded reload busy state")
        gate.release(); await reload.value
        if failed {
            check(editor.error == error && error != nil && editor.text == "saved version",
                  "obsolete reload cannot clear the actual current write error")
        } else {
            check(editor.entry?.content == "saved version" && editor.entry?.hash == "saved"
                  && editor.text == "saved version" && !editor.isDirty,
                  "completed actual Save keeps authoritative baseline over older reload")
        }
    }
}

@MainActor func runDemoAgentFileWriteAuthorityChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let connected = await waitFor("file write Demo connection", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "actual Demo connects for file write authority")
    guard connected else { return }
    let gate = FileWriteAuthorityGate(); defer { gate.release() }
    var gets = 0
    // Established Demo write allowance; hello/scopes and every real RPC remain unchanged.
    let management = AgentManagementModel(scopes: { gateway.hello?.scopes ?? [] }, allowsWritesWithoutAdmin: true) { method, params in
        let response = try await gateway.connection.request(method, params)
        if method == "agents.files.get" { gets += 1; if gets == 2 { await gate.wait() } }
        return response
    }
    let editor = management.editor(agentId: "main", name: "SOUL.md")
    await editor.load()
    guard let original = editor.entry?.content else { check(false, "actual Demo file loads"); return }
    let reload = Task { await editor.load() }; defer { reload.cancel(); gate.release() }
    let ready = await waitFor("real old Demo file response", timeout: 20) { gate.arrived }
    check(ready, "real Demo read is computed before Save")
    guard ready else { return }
    editor.text = original + "\n<!-- local write authority check -->\n"
    let saved = await editor.save()
    let savedEntry = editor.entry
    check(saved && !editor.isDirty, "actual Demo set succeeds before older get is released")
    gate.release(); await reload.value
    check(editor.entry == savedEntry && editor.text == savedEntry?.content && !editor.isDirty,
          "actual completed Demo set remains the authoritative baseline")
    do {
        let wire = try await gateway.connection.request("agents.files.get", ["agentId": "main", "name": "SOUL.md"])
        check(wire["file"]?["hash"]?.string == savedEntry?.hash && wire["file"]?["content"]?.string == editor.text,
              "genuine backend file matches the retained saved baseline")
        editor.text = original
        let restored = await editor.save()
        check(restored, "actual Demo file is restored through existing hash-checked set")
    } catch { check(false, "actual Demo file verification/restoration succeeds") }
}
