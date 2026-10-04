import Foundation
import Testing
@testable import PincerKit

@MainActor private final class FileReloadCompletionGate {
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

@MainActor @Suite("Agent file reload completion controls", .timeLimit(.minutes(2)))
struct AgentFileReloadCompletionTests {
    @Test(arguments: [false, true])
    func olderSuccessOrErrorCannotReplaceLatestLoad(_ failOld: Bool) async throws {
        let gate = FileReloadCompletionGate(); defer { gate.release() }
        var count = 0
        let model = AgentManagementModel { _, _ in
            count += 1
            if count == 1 {
                await gate.wait()
                if failOld { throw GatewayError.rpc(code: "UNAVAILABLE", message: "old load failed", details: nil) }
                return ["file": ["name": "SOUL.md", "content": "old document", "hash": "old"]]
            }
            return ["file": ["name": "SOUL.md", "content": "latest document", "hash": "latest"]]
        }
        let editor = model.editor(agentId: "main", name: "SOUL.md")
        let old = Task { await editor.load() }; defer { old.cancel(); gate.release() }
        try await self.wait { gate.arrived }
        await editor.load()
        gate.release(); await old.value
        #expect(editor.text == "latest document" && editor.entry?.hash == "latest" && editor.loadState == .idle)
    }

    @Test func precanceledLoadDoesNotDisplaceHealthyActiveLoad() async throws {
        let gate = FileReloadCompletionGate(); defer { gate.release() }
        var count = 0
        let model = AgentManagementModel { _, _ in
            count += 1; await gate.wait()
            return ["file": ["name": "SOUL.md", "content": "healthy document"]]
        }
        let editor = model.editor(agentId: "main", name: "SOUL.md")
        let healthy = Task { await editor.load() }; defer { healthy.cancel(); gate.release() }
        try await self.wait { gate.arrived }
        let canceled = Task { await editor.load() }; canceled.cancel(); await canceled.value
        gate.release(); await healthy.value
        #expect(count == 1 && editor.text == "healthy document" && editor.loadState == .idle)
    }

    @Test func canceledCurrentCompletionDoesNotInstallAndReleasesLoadingState() async throws {
        let gate = FileReloadCompletionGate(); defer { gate.release() }
        let model = AgentManagementModel { _, _ in
            await gate.wait()
            return ["file": ["name": "SOUL.md", "content": "canceled document"]]
        }
        let editor = model.editor(agentId: "main", name: "SOUL.md")
        let load = Task { await editor.load() }; defer { load.cancel(); gate.release() }
        try await self.wait { gate.arrived }
        load.cancel(); gate.release(); await load.value
        #expect(editor.entry == nil && editor.text.isEmpty && editor.loadState == .idle)
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
