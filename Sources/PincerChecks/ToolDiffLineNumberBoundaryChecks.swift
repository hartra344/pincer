import Foundation
@testable import PincerKit

private func boundaryDiff() -> ToolFileEdit? {
    let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["input": "--- a/file.txt\n+++ b/file.txt\n@@ -\(Int.max),1 +\(Int.max),1 @@\n context"]), as: UTF8.self)
    return ToolFileEdit.parse(toolName: "apply_patch", arguments: args)
}

private func exactBoundary(_ edit: ToolFileEdit?) -> Bool {
    guard let edit, edit.files.count == 1, let file = edit.files.first,
          file.path == "file.txt", file.hunks.count == 1, let hunk = file.hunks.first else { return false }
    return hunk.lines.map(\.unified) == [" context"] && hunk.lines.map(\.lineNumber) == [Int.max]
        && edit.additions == 0 && edit.deletions == 0
}

@MainActor func runToolDiffLineNumberBoundaryChecks() async {
    let result = await Task.detached { boundaryDiff() }.value
    check(exactBoundary(result),
          "actual local parser preserves the complete representable boundary file, hunk, context and line number")
}

@MainActor func runDemoToolDiffLineNumberBoundaryChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
    let key = "agent:coder:dashboard:retry-fix"
    let ready = await waitFor("diff boundary Demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped && gateway.sessions[key] != nil }
    check(ready, "genuine Demo tool transcript connects")
    guard ready else { return }
    let chat = gateway.chat(for: key)
    await chat.load()
    let tools = chat.entries.flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools }
        return []
    }
    guard let tool = tools.first(where: { ToolFileEdit.handles(toolName: $0.name) }) else {
        check(false, "actual Demo history contains a supported file edit tool"); return
    }
    let name = tool.name, args = tool.arguments, details = tool.details, isError = tool.isError
    let actual = await Task.detached { ToolFileEdit.parse(toolName: name, arguments: args, details: details, isError: isError) }.value
    check(actual != nil, "unchanged genuine Demo tool arguments retain their file-diff presentation")
    // Explicitly LOCAL parser fixture, not an altered Gateway response or tool execution.
    let local = await Task.detached { boundaryDiff() }.value
    check(exactBoundary(local),
          "local boundary fixture cannot terminate real Demo tool-card read processing")
}

@MainActor func runToolDiffCursorExhaustionChecks() async {
    let valid = await Task.detached {
        [" context", "+added", "-deleted"].allSatisfy { line in
            let input = "--- a/file.txt\n+++ b/file.txt\n@@ -\(Int.max),3 +\(Int.max),3 @@\n\(line)\n\(line)\n\(line)"
            let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["input": input]), as: UTF8.self)
            guard let edit = ToolFileEdit.parse(toolName: "apply_patch", arguments: args),
                  edit.files.count == 1, let file = edit.files.first,
                  file.hunks.count == 1, let hunk = file.hunks.first else { return false }
            return hunk.lines.map(\.unified) == [line, line, line]
                && hunk.lines.map(\.lineNumber) == [Int.max, nil, nil]
                && edit.additions == (line.hasPrefix("+") ? 3 : 0)
                && edit.deletions == (line.hasPrefix("-") ? 3 : 0)
        }
    }.value
    check(valid, "actual context, addition and deletion cursors become unavailable after their last representable line")
}
