import Testing
@testable import PincerKit
@testable import PincerUI

@Suite("Agent close navigation")
struct AgentCloseNavigationTests {
    @MainActor @Test func failedSaveOpensTheConflictedWorkspaceFileAndRetryCloses() async throws {
        let demo = DemoGateway()
        let management = AgentManagementModel(scopes: { [] }, allowsWritesWithoutAdmin: true,
                                              request: { method, params in try await demo.handle(method, params) })
        let editor = management.editor(agentId: "main", name: "SOUL.md")
        await editor.load()
        editor.text += "\nlocal draft"
        let localDraft = editor.text
        let originalHash = editor.entry?.hash
        _ = try await demo.handle("agents.files.set", ["agentId": "main", "name": "SOUL.md", "content": "changed elsewhere",
                                                        "expectedHash": .string(originalHash ?? "")])

        let navigator = SettingsNavigator(destination: .page("voice"))
        navigator.path = [.skill("old-route")]
        navigator.focus = ["old-focus"]
        navigator.isReviewing = true
        var closed = false
        await navigator.saveAgentsBeforeClosing(management) { closed = true }

        #expect(!closed, "a conflict keeps Gateway Settings open")
        #expect(navigator.destination == .page(SettingsCatalog.agentsPageId))
        #expect(navigator.path == [.agent("main"), .agentFile(agentId: "main", name: "SOUL.md")])
        #expect(navigator.focus == nil && !navigator.isReviewing, "the conflict page replaces stale navigation state")
        #expect(management.failedSaveAllFile === editor)
        #expect(editor.conflict?.theirs == "changed elsewhere" && editor.conflict?.yours == localDraft)
        #expect(editor.text == localDraft && editor.isDirty, "the local draft stays in the editor")

        #expect(await editor.resolveConflictOverwrite())
        await navigator.saveAgentsBeforeClosing(management) { closed = true }
        #expect(closed, "a later successful Save closes Gateway Settings")
        #expect(management.failedSaveAllFile == nil, "successful retry clears the old failure")
    }
}
