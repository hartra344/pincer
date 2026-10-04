import Foundation
import Testing
@testable import PincerKit

@MainActor private final class SkillsLoadGate {
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?
    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                entry?.resume(); entry = nil
                if released || Task.isCancelled { continuation.resume() }
                else { delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered || Task.isCancelled { continuation.resume() } else { entry = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }
    func release() {
        released = true
        entry?.resume(); entry = nil
        delivery?.resume(); delivery = nil
    }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct SkillsLoadAdmissionTests {
    private static func report(_ agent: String) -> JSONValue {
        ["agentId": .string(agent), "workspaceDir": .string("/fixture/" + agent), "managedSkillsDir": "/fixture/skills", "skills": []]
    }

    @Test func canceledAgentLoadCannotDisplaceCurrentReportOrFeedback() async throws {
        let gate = SkillsLoadGate()
        var hold = false, requests = 0
        let model = SkillsModel(request: { method, params in
            if method == Skills.installMethod {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "Current installation failed", details: ["warning": "Current warning"])
            }
            #expect(method == Skills.statusMethod)
            requests += 1
            try Task.checkCancellation()
            if hold { await gate.hold() }
            return Self.report(params["agentId"]?.text ?? "main")
        })
        await model.load(agentId: "main")
        let skill = try #require(ClawHubSearchResult(["slug": "example", "displayName": "Example"]))
        _ = await model.installFromClawHub(skill)
        try #require(model.actionError == "Current installation failed" && model.lastWarnings == ["Current warning"])
        let expected = model.report
        hold = true
        let current = Task { await model.load(agentId: "main") }
        defer { gate.release(); current.cancel() }
        try await gate.waitForEntry()
        let before = requests
        let canceled = Task { await model.load(agentId: "research") }
        canceled.cancel()
        await canceled.value
        #expect(requests == before)
        #expect(model.agentId == "main" && model.report == expected)
        #expect(model.actionError == "Current installation failed" && model.lastWarnings == ["Current warning"])
        gate.release(); await current.value
        #expect(model.report == SkillStatusReport(Self.report("main")) && model.agentId == "main")
        #expect(model.loadError == nil && !model.isLoading)
    }

    @Test func ordinaryNewerAgentLoadWins() async throws {
        let gate = SkillsLoadGate()
        let model = SkillsModel(request: { _, params in
            let agent = params["agentId"]?.text ?? "main"
            if agent == "main" { await gate.hold() }
            return Self.report(agent)
        })
        let old = Task { await model.load(agentId: "main") }
        defer { gate.release(); old.cancel() }
        try await gate.waitForEntry()
        await model.load(agentId: "research")
        gate.release(); await old.value
        #expect(model.report == SkillStatusReport(Self.report("research")) && model.agentId == "research")
        #expect(model.loadError == nil && !model.isLoading)
    }

    @Test func currentUnavailableRemainsVisible() async {
        let model = SkillsModel(request: { _, _ in throw GatewayError.rpc(code: "UNAVAILABLE", message: "Current status unavailable", details: nil) })
        await model.load(agentId: "main")
        #expect(model.loadError == "Current status unavailable" && model.agentId == "main" && !model.isLoading)
    }

    @Test(arguments: [false, true])
    func canceledAdmittedLoadCannotPublishLateResult(fails: Bool) async throws {
        let gate = SkillsLoadGate()
        var calls = 0
        let model = SkillsModel(request: { _, _ in
            calls += 1
            if calls == 1 { return Self.report("main") }
            await gate.hold()
            if fails { throw GatewayError.rpc(code: "UNAVAILABLE", message: "Late canceled error", details: nil) }
            return ["agentId": "main", "workspaceDir": "/late", "skills": []]
        })
        await model.load(agentId: "main")
        let expected = model.report
        let canceled = Task { await model.load(agentId: "main") }
        defer { gate.release(); canceled.cancel() }
        try await gate.waitForEntry()
        canceled.cancel(); gate.release(); await canceled.value
        #expect(model.report == expected && model.loadError == nil && !model.isLoading)
    }

    @Test func canceledOlderLoadCannotIdleNewerOwner() async throws {
        let oldGate = SkillsLoadGate(), newGate = SkillsLoadGate()
        let model = SkillsModel(request: { _, params in
            let agent = params["agentId"]?.text ?? "main"
            if agent == "main" { await oldGate.hold() } else { await newGate.hold() }
            return Self.report(agent)
        })
        let old = Task { await model.load(agentId: "main") }
        defer { oldGate.release(); newGate.release(); old.cancel() }
        try await oldGate.waitForEntry()
        let newer = Task { await model.load(agentId: "research") }
        defer { newer.cancel() }
        try await newGate.waitForEntry()
        old.cancel(); oldGate.release(); await old.value
        #expect(model.isLoading && model.agentId == "research" && model.report == nil && model.loadError == nil)
        newGate.release(); await newer.value
        #expect(model.report == SkillStatusReport(Self.report("research")) && !model.isLoading && model.loadError == nil)
    }

}
