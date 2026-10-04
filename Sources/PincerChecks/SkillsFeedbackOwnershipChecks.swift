import Foundation
@testable import PincerKit

@MainActor
private final class SkillsFeedbackGate {
    var entered = false
    private var terminal = false
    private var released = false
    private var admission: CheckedContinuation<Bool, Never>?
    private var response: CheckedContinuation<Void, Never>?
    func hold() async {
        self.entered = true
        self.admission?.resume(returning: true)
        self.admission = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.released || Task.isCancelled { continuation.resume() }
                else { self.response = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func finished() {
        self.terminal = true
        self.admission?.resume(returning: self.entered)
        self.admission = nil
    }
    func waitForAdmission() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.entered || self.terminal || Task.isCancelled { continuation.resume(returning: self.entered) }
                else { self.admission = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        self.released = true
        self.response?.resume()
        self.response = nil
        self.admission?.resume(returning: self.entered)
        self.admission = nil
    }
}

@MainActor
func runSkillsFeedbackOwnershipChecks() async {
    for failed in [false, true] {
      for context in ["changed", "ABA", "clear", "reload"] {
        let gate = SkillsFeedbackGate()
        let model = SkillsModel(request: { method, params in
            if method == Skills.statusMethod { return ["agentId": params["agentId"] ?? "main", "skills": []] }
            check(method == Skills.installMethod && params == ["source": "clawhub", "slug": "example", "agentId": "main"],
                  "held install preserves the admitted agent and exact existing wire fields")
            await gate.hold()
            if failed { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Installation failed", details: ["warning": "Review publisher"]) }
            return ["ok": true, "version": "1.2.3", "warning": "Review publisher"]
        })
        await model.load(agentId: "main")
        guard let result = ClawHubSearchResult(["slug": "example", "displayName": "Example"]) else {
            check(false, "existing ClawHub result parses"); return
        }
        let action = Task { let outcome = await model.installFromClawHub(result); gate.finished(); return outcome }
        defer { action.cancel(); gate.release() }
        let admitted = await gate.waitForAdmission()
        check(admitted, "the real model emits the install before agent selection")
        guard admitted else { return }
        if context == "changed" || context == "ABA" {
            await model.load(agentId: "research")
            check(model.report?.agentId == "research", "new agent status is actually loaded while install waits")
            if context == "ABA" { await model.load(agentId: "main") }
        } else if context == "clear" { model.clearMessages() }
        else { await model.reload() }
        gate.release()
        let outcome = await action.value
        check(outcome == (failed ? .failed("Installation failed") : .done("Installed Example 1.2.3")),
              "original action returns its real result despite context replacement")
        if context == "reload" {
            check(model.lastWarnings == ["Review publisher"]
                  && (failed ? model.actionError == "Installation failed" : model.lastMessage == "Installed Example 1.2.3"),
                  "same-agent refresh preserves the current operation's feedback")
        } else {
            check(model.lastMessage == nil && model.actionError == nil && model.lastWarnings.isEmpty,
                  "agent selection or explicit Clear cannot revive obsolete feedback or warnings")
        }
        check(model.busy.isEmpty && model.report?.agentId == (context == "changed" ? "research" : "main"),
              "completion releases busy state and preserves current status")
      }
    }
    for latestFails in [false, true] {
        let gate = SkillsFeedbackGate()
        let model = SkillsModel(request: { method, params in
            if method == Skills.statusMethod { return ["agentId": params["agentId"] ?? "main", "skills": []] }
            check(method == Skills.installMethod, "newer feedback still uses the existing install RPC")
            if params["slug"] == "latest" {
                if latestFails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Latest failed", details: ["warning": "Latest warning"]) }
                return ["ok": true, "version": "2.0.0", "warning": "Latest warning"]
            }
            await gate.hold()
            return ["ok": true, "version": "1.2.3", "warning": "Old warning"]
        })
        await model.load(agentId: "main")
        guard let old = ClawHubSearchResult(["slug": "old", "displayName": "Old"]),
              let latest = ClawHubSearchResult(["slug": "latest", "displayName": "Latest"]) else {
            check(false, "existing ClawHub results parse"); return
        }
        let action = Task { let outcome = await model.installFromClawHub(old); gate.finished(); return outcome }
        defer { action.cancel(); gate.release() }
        let admitted = await gate.waitForAdmission()
        check(admitted, "old actual install is held before newer action")
        guard admitted else { return }
        let latestOutcome = await model.installFromClawHub(latest)
        check(latestOutcome == (latestFails ? .failed("Latest failed") : .done("Installed Latest 2.0.0")),
              "newest action publishes its real outcome")
        let message = model.lastMessage
        let error = model.actionError
        gate.release()
        let oldOutcome = await action.value
        check(oldOutcome == .done("Installed Old 1.2.3"), "old caller still receives its own result")
        check(model.lastMessage == message && model.actionError == error && model.lastWarnings == ["Latest warning"],
              "old completion cannot overwrite newer message, error or warnings")
        check(model.busy.isEmpty, "both different-key actions release busy entries")
    }

}

@MainActor
func runDemoSkillsFeedbackOwnershipChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("Skills feedback Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "feedback check connects to the genuine Demo Gateway")
    guard connected else { return }
    let gate = SkillsFeedbackGate()
    // The Demo's established Skills write policy permits this isolated simulated install.
    // Every response and agent report below comes from its actual Gateway RPC handler.
    let model = SkillsModel(methods: { gateway.hello?.methods }, scopes: { gateway.hello?.scopes ?? [] },
                            allowsWritesWithoutAdmin: true, request: { method, params in
        let response = try await gateway.connection.request(method, params)
        if method == Skills.installMethod { await gate.hold() }
        return response
    })
    await model.load(agentId: "main")
    await model.search("home assistant")
    guard let result = model.searchResults.first(where: { $0.slug == "home-assistant" }) else {
        check(false, "genuine Demo ClawHub search supplies Home Assistant"); return
    }
    check(model.installState(for: result) == .notInstalled, "seeded skill starts uninstalled")
    let action = Task { let outcome = await model.installFromClawHub(result); gate.finished(); return outcome }
    defer { action.cancel(); gate.release() }
    let admitted = await gate.waitForAdmission()
    check(admitted, "hold an already computed genuine skills.install response before local publication")
    guard admitted else { return }
    await model.load(agentId: "research")
    check(model.report?.agentId == "research" && !model.skills.isEmpty, "actual Research status loads while old feedback is held")
    await model.load(agentId: "main")
    gate.release()
    let outcome = await action.value
    check(outcome == .done("Installed Home Assistant 2.4.1"), "actual Demo install returns its seeded version to the original caller")
    check(model.lastMessage == nil && model.actionError == nil && model.lastWarnings.isEmpty,
          "real install success cannot restore a dismissed agent-context banner")
    check(model.busy.isEmpty && model.report?.agentId == "main", "real completion preserves the current report and clears busy")
    check(model.installState(for: result) == .installed(version: "2.4.1"),
          "suppressing stale feedback does not discard the real server mutation")
}
