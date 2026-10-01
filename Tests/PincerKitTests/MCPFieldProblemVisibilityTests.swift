import Testing
@testable import PincerKit

/// #514: editing one MCP field must not surface validation in untouched fields.
@Suite("MCP field problem visibility")
struct MCPFieldProblemVisibilityTests {
    @Test func editingNameDoesNotRevealTheUntouchedCommandProblem() {
        var draft = MCPServerDraft()
        draft.name = "filesystem"
        let problems = draft.problems(existingNames: [])
        #expect(problems["command"] != nil)

        let visible = MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: false)
        #expect(visible["name"] == nil)
        #expect(visible["command"] == nil, "typing a name must not show the untouched required Command error")
    }

    @Test func fieldProblemsAppearAfterThatFieldIsTouched() {
        var draft = MCPServerDraft()
        draft.name = ""
        draft.command = ""
        let problems = draft.problems(existingNames: [])
        #expect(problems["name"] != nil && problems["command"] != nil)

        let visible = MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: false)
        #expect(visible.keys.sorted() == ["name"])
    }

    @Test func revertingAFieldKeepsItsTouchAndDoesNotRevealOtherProblems() {
        var draft = MCPServerDraft()
        draft.name = "filesystem" // edited from the initial empty value
        draft.name = "" // reverted; the field remains touched
        let problems = draft.problems(existingNames: [])
        #expect(problems["name"] != nil && problems["command"] != nil)

        let visible = MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: false)
        #expect(visible.keys.sorted() == ["name"])
    }

    @Test func doneRevealsAllRemainingProblems() {
        let problems = ["name": "Enter a name.", "command": "Enter the command to run."]
        #expect(MCPFieldProblemVisibility.visible(problems, touched: [], showAll: false).isEmpty)
        #expect(MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: true) == problems)
    }
}
