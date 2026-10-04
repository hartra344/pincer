import Foundation
import Testing
@testable import PincerKit

@MainActor private final class SavedFileReloadGate {
    var arrived = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func wait() async {
        self.arrived = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released || Task.isCancelled { continuation.resume() }
                else { self.held = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }
    func release() { released = true; let old = held; held = nil; old?.resume() }
}

@MainActor
@Suite("Agent file Save versus reload authority", .timeLimit(.minutes(2)))
struct AgentFileSaveReloadAuthorityTests {
    enum SaveResult: String, CaseIterable, Sendable { case success, conflict, unavailable }

    @Test(arguments: SaveResult.allCases)
    func aPriorReloadCannotReplaceCompletedSaveAuthority(_ mode: SaveResult) async throws {
        let initial = await Self.response("initial server document")
        let saved = await Self.response("new saved document")
        let conflict = await Self.response("externally changed document")
        let gate = SavedFileReloadGate()
        defer { gate.release() }
        var gets = 0
        var sets = 0
        let management = AgentManagementModel { method, params in
            #expect(params["agentId"] == "main" && params["name"] == "SOUL.md")
            switch method {
            case "agents.files.get":
                gets += 1
                if gets == 2 {
                    let captured = initial // The earlier read is already computed before its completion waits.
                    await gate.wait()
                    return captured
                }
                return gets == 1 ? initial : conflict
            case "agents.files.set":
                sets += 1
                #expect(params["content"] == "new saved document")
                #expect(params["expectedHash"] == initial["file"]?["hash"] && params["expectedMissing"] == nil)
                switch mode {
                case .success: return saved
                case .conflict:
                    throw GatewayError.rpc(code: "INVALID_REQUEST", message: "agent file \"SOUL.md\" changed since it was read",
                                           details: ["type": "agent_file_conflict", "name": "SOUL.md",
                                                     "currentHash": conflict["file"]?["hash"] ?? .null])
                case .unavailable:
                    throw GatewayError.rpc(code: "UNAVAILABLE", message: "current file write unavailable", details: nil)
                }
            default: Issue.record("Unexpected file authority request: \(method)"); return [:]
            }
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        let reload = Task { await editor.load() }
        defer { reload.cancel(); gate.release() }
        try await self.wait { gate.arrived }
        editor.text = "new saved document"
        #expect(editor.canSave, "current UI permits Save while a reload waits")
        let save = Task { await editor.save() }
        defer { save.cancel() }
        let succeeded = await save.value // Actual Save completes before the older reload is released.
        #expect(succeeded == (mode == .success) && sets == 1)
        let saveError = editor.error
        let saveConflict = editor.conflict
        let saveState = editor.saveState
        if mode == .success {
            #expect(editor.entry?.hash == saved["file"]?["hash"]?.text && !editor.isDirty)
        } else if mode == .conflict {
            #expect(saveConflict?.theirsHash == conflict["file"]?["hash"]?.text)
        } else { #expect(saveError != nil) }
        gate.release()
        await reload.value // Actual reload completion, not gate arrival or a return marker.
        if mode == .success {
            #expect(editor.entry?.hash == saved["file"]?["hash"]?.text
                    && editor.entry?.content == "new saved document",
                    "completed Save baseline/hash must remain authoritative over the older read")
            #expect(editor.text == "new saved document" && !editor.isDirty,
                    "the actual saved document must remain clean after obsolete reload completion")
        } else if mode == .conflict {
            #expect(editor.conflict == saveConflict && editor.conflict != nil,
                    "older reload must not clear the current Save conflict")
        } else {
            #expect(editor.error == saveError && editor.error != nil,
                    "older reload must not clear the current Save error")
        }
        #expect(editor.saveState == saveState)
    }

    @Test func ordinaryReloadWithoutSaveStillInstallsTheNewServerVersion() async {
        let initial = await Self.response("old document")
        let latest = await Self.response("latest document")
        var gets = 0
        let management = AgentManagementModel { method, _ in
            #expect(method == "agents.files.get")
            gets += 1
            return gets == 1 ? initial : latest
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        editor.text = "deliberately discarded draft"
        await editor.resolveConflictKeepTheirs()
        #expect(editor.entry?.hash == latest["file"]?["hash"]?.text && editor.text == "latest document"
                && !editor.isDirty && editor.loadState == .idle)
    }

    private nonisolated static func response(_ content: String) async -> JSONValue {
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
