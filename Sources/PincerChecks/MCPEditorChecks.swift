import Foundation
import PincerKit

/// #514: per-field validation remains hidden until its own field is touched or Done is pressed.
@MainActor
func runMCPEditorChecks() {
    var draft = MCPServerDraft()
    draft.name = "filesystem"
    let problems = draft.problems(existingNames: [])
    let afterName = MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: false)
    check(problems["command"] != nil && afterName["command"] == nil,
          "typing the server name leaves the untouched required Command error hidden")

    let afterDone = MCPFieldProblemVisibility.visible(problems, touched: ["name"], showAll: true)
    check(afterDone == problems, "Done reveals every remaining MCP validation problem")
}
