import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Skills action feedback belongs to its agent context")
struct SkillsActionFeedbackOwnershipTests {
    enum Context: String, CaseIterable { case unchanged, changed, returnedToOriginal }

    @MainActor
    private final class Server {
        var calls: [(String, JSONValue)] = []
        var admitted = false
        var released = false
        var failed = false
        private var waiter: CheckedContinuation<Void, Never>?

        func release() {
            self.released = true
            let waiter = self.waiter
            self.waiter = nil
            waiter?.resume()
        }

        func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
            self.calls.append((method, params))
            if method == Skills.statusMethod {
                return ["agentId": params["agentId"] ?? "main", "skills": []]
            }
            try #require(method == Skills.installMethod)
            self.admitted = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    if self.released || Task.isCancelled { waiter.resume() }
                    else { self.waiter = waiter }
                }
            } onCancel: { Task { @MainActor in self.release() } }
            try Task.checkCancellation()
            if self.failed {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "Installation failed", details: ["warning": "Review publisher"])
            }
            return ["ok": true, "version": "1.2.3", "warning": "Review publisher"]
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: Context.allCases, [false, true])
    func actualHeldInstallCannotRestoreFeedbackClearedByAgentSelection(_ context: Context, _ failed: Bool) async throws {
        let server = Server()
        server.failed = failed
        let model = SkillsModel(request: { try await server.request($0, $1) })
        await model.load(agentId: "main")
        let result = try #require(ClawHubSearchResult(["slug": "example", "installRef": "example", "displayName": "Example"]))
        let action = Task { await model.installFromClawHub(result) }
        defer { action.cancel(); server.release() }
        while !server.admitted {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.busy.contains("example"))
        #expect(server.calls.last?.1 == ["source": "clawhub", "slug": "example", "agentId": "main"])
        if context != .unchanged {
            await model.load(agentId: "research")
            if context == .returnedToOriginal { await model.load(agentId: "main") }
        }
        let currentAgent = context == .changed ? "research" : "main"
        try #require(model.report?.agentId == currentAgent)
        try #require(model.lastMessage == nil && model.actionError == nil && model.lastWarnings.isEmpty)
        server.release()
        let outcome = await action.value
        #expect(outcome == (failed ? .failed("Installation failed") : .done("Installed Example 1.2.3")),
                "The original caller still receives the actual server outcome")
        #expect(model.busy.isEmpty && model.report?.agentId == currentAgent && model.agentId == currentAgent)
        #expect(model.loadError == nil)
        if context == .unchanged {
            #expect(model.lastWarnings == ["Review publisher"])
            #expect(failed ? model.actionError == "Installation failed" : model.lastMessage == "Installed Example 1.2.3")
        } else {
            #expect(model.lastMessage == nil && model.actionError == nil,
                    "An old agent operation cannot restore feedback explicitly cleared by selection")
            #expect(model.lastWarnings.isEmpty, "Warnings also belong to the admitted agent context")
        }
    }
}
