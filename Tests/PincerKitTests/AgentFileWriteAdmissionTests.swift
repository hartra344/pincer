import Foundation
import Testing
@testable import PincerKit

@MainActor private final class WriteAdmissionReloadGate {
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

@MainActor @Suite("Agent file write admission", .timeLimit(.minutes(2)))
struct AgentFileWriteAdmissionTests {
    @Test(arguments: [false, true])
    func rejectedOrPrecanceledSaveCannotDisplaceHealthyReload(_ oversized: Bool) async throws {
        let rejectedText = await Task.detached {
            oversized ? String(repeating: "x", count: AgentManagement.maxFileBytes + 1) : "edited draft"
        }.value
        let gate = WriteAdmissionReloadGate(); defer { gate.release() }
        var gets = 0
        var sets = 0
        let management = AgentManagementModel { method, _ in
            if method == "agents.files.set" { sets += 1; return [:] }
            #expect(method == "agents.files.get")
            gets += 1
            if gets == 1 { return ["file": ["name": "SOUL.md", "content": "initial"]] }
            await gate.wait()
            return ["file": ["name": "SOUL.md", "content": "latest"]]
        }
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        let reload = Task { await editor.load() }; defer { reload.cancel(); gate.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !gate.arrived {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            await Task.yield()
        }
        editor.text = rejectedText
        let save = Task { await editor.save() }
        if !oversized { save.cancel() }
        #expect(await save.value == false)
        #expect(sets == 0 && editor.loadState.isRunning, "nonadmitted Save preserves the active reload")
        gate.release(); await reload.value
        #expect(editor.entry?.content == "latest" && editor.loadState == .idle,
                "healthy reload still applies its authoritative version")
        #expect(editor.text == rejectedText && editor.isDirty,
                "existing reload typing preservation remains intact")
    }
}
