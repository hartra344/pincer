import Foundation
@testable import PincerKit

@MainActor private final class SkillsStatusAdmissionGate {
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

/// The real status response is computed before a local delivery hold; no server writes.
@MainActor private func checkSkillsStatusAdmission(request: @escaping SkillsModel.Request) async {
    let gate = SkillsStatusAdmissionGate()
    var calls = 0, hold = false
    var held: JSONValue?
    let model = SkillsModel(request: { method, params in
        calls += 1
        check(method == Skills.statusMethod && (params == ["agentId": "main"] || params == ["agentId": "research"]),
              "status read uses exact legal Main or Research agent params")
        try Task.checkCancellation()
        let response = try await request(method, params)
        if hold { held = response; await gate.hold() }
        return response
    })
    await model.load(agentId: "main")
    let expected = model.report
    check(expected != nil && model.loadError == nil, "initial actual Main status report loads")
    guard expected != nil && model.loadError == nil else { return }
    hold = true
    let current = Task { await model.load(agentId: "main") }
    defer { gate.release(); current.cancel() }
    let entered = await waitFor("computed Skills status response") { gate.entered }
    check(entered, "actual Main status response reaches local delivery hold")
    guard entered else { gate.release(); current.cancel(); await current.value; return }
    guard let held else { check(false, "held real status response exists"); gate.release(); current.cancel(); await current.value; return }
    let before = calls
    let canceled = Task { await model.load(agentId: "research") }
    canceled.cancel(); await canceled.value
    check(calls == before, "pre-canceled Research load admits no additional request")
    check(model.agentId == "main" && model.report == expected, "pre-canceled agent load preserves full current report and selected agent")
    gate.release(); await current.value
    check(model.report == SkillStatusReport(held) && model.agentId == "main" && model.loadError == nil && !model.isLoading,
          "actual active Main report finishes healthy with exact held response")
}

@MainActor func runSkillsLoadAdmissionChecks() async {
    await checkSkillsStatusAdmission { _, _ in
        ["agentId": "main", "workspaceDir": "/fixture/main", "managedSkillsDir": "/fixture/skills", "skills": []]
    }
    for fails in [false, true] {
        let gate = SkillsStatusAdmissionGate()
        let expected: JSONValue = ["agentId": "main", "workspaceDir": "/fixture/main", "skills": []]
        var calls = 0
        let model = SkillsModel(request: { _, _ in
            calls += 1
            if calls == 1 { return expected }
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Late canceled error", details: nil) }
            return ["agentId": "main", "workspaceDir": "/late", "skills": []]
        })
        await model.load(agentId: "main")
        let canceled = Task { await model.load(agentId: "main") }
        defer { gate.release(); canceled.cancel() }
        let entered = await waitFor("admitted Skills cancellation") { gate.entered }
        check(entered, "actual Skills cancellation control reaches the request")
        guard entered else { gate.release(); canceled.cancel(); await canceled.value; return }
        canceled.cancel(); gate.release(); await canceled.value
        check(model.report == SkillStatusReport(expected) && model.loadError == nil && !model.isLoading,
              "canceled admitted Skills load cannot publish late success or failure")
    }
}

@MainActor func runDemoSkillsLoadAdmissionChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    let connected = await waitFor("Skills admission Demo connection", timeout: 25) {
        gateway.state.isConnected && gateway.bootstrapped
    }
    check(connected, "genuine Demo Skills connection is ready")
    guard connected else { return }
    await checkSkillsStatusAdmission { method, params in try await gateway.connection.request(method, params) }
}
