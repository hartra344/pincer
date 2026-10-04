import Foundation
import Testing
@testable import PincerKit

@MainActor private final class AgentFileReloadGate {
    var arrived = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        self.arrived = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { held in
                if self.released || Task.isCancelled { held.resume() } else { self.continuation = held }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() {
        self.released = true
        let held = self.continuation
        self.continuation = nil
        held?.resume()
    }
}

@MainActor
@Suite("Agent file reload draft ownership", .timeLimit(.minutes(2)))
struct AgentFileReloadDraftOwnershipTests {
    enum Later: String, CaseIterable, Sendable { case unchanged, typing, aba }

    @Test(arguments: Later.allCases)
    func reloadTheirsDiscardsOnlyIntentBeforeItsAdmission(_ later: Later) async throws {
        let initial = await Self.response(content: "initial loaded document")
        let latest = await Self.response(content: "fresh server document")
        let gate = AgentFileReloadGate()
        defer { gate.release() }
        var calls = 0
        let management = AgentManagementModel { method, params in
            #expect(method == "agents.files.get" && params["agentId"] == "main" && params["name"] == "SOUL.md")
            calls += 1
            if calls == 1 { return initial }
            await gate.hold()
            return latest
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        #expect(editor.text == "initial loaded document" && !editor.isDirty)
        let oldDraft = "draft deliberately discarded by Reload Theirs"
        editor.text = oldDraft
        let reload = Task { await editor.resolveConflictKeepTheirs() }
        defer { reload.cancel(); gate.release() }
        try await self.wait { gate.arrived }
        #expect(editor.loadState.isRunning && editor.canEdit)
        switch later {
        case .unchanged: break
        case .typing: editor.text = "typed after Reload Theirs began"
        case .aba: editor.text = "intermediate later typing"; editor.text = oldDraft
        }
        gate.release()
        await reload.value // Actual model completion, not request-return or observer delivery.
        let expected = later == .unchanged ? "fresh server document"
            : later == .typing ? "typed after Reload Theirs began" : oldDraft
        #expect(editor.text == expected, "late reload must preserve post-admission typing, including ABA")
        #expect(editor.entry?.content == "fresh server document" && editor.entry?.hash == latest["file"]?["hash"]?.text,
                "fresh authoritative entry/hash still advance even when newer local typing is kept")
        #expect(editor.isDirty == (later != .unchanged) && editor.loadState == .idle)
        #expect(calls == 2)
    }

    @Test func currentReloadFailureKeepsDraftAndPublishesItsOwnLoadError() async throws {
        let initial = await Self.response(content: "loaded document")
        var calls = 0
        let management = AgentManagementModel { _, _ in
            calls += 1
            if calls == 1 { return initial }
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "document temporarily unavailable", details: nil)
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        editor.text = "unsaved draft"
        await editor.resolveConflictKeepTheirs()
        #expect(editor.text == "unsaved draft" && editor.isDirty)
        if case .failed = editor.loadState {} else { Issue.record("current reload failure must publish its load error") }
    }

    private nonisolated static func response(content: String) async -> JSONValue {
        await Task.detached { () -> JSONValue in
            ["agentId": "main", "workspace": "/workspace/main", "file": ["name": "SOUL.md",
             "path": "/workspace/main/SOUL.md", "missing": false, "content": .string(content),
             "size": .number(Double(content.utf8.count)), "updatedAtMs": 1_700_000_000_000,
             "hash": .string(AgentManagement.sha256Hex(content))]]
        }.value
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
