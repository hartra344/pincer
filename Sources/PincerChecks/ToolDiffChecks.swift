import Foundation
import PincerKit

// File-changing tool calls rendered as diffs (issue #37): the parser on its own, the demo's
// "Fix retry backoff" chat, and the mock Gateway's upstream-shaped calls and receipts.

private func toolArgs(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func diffLines(_ edit: ToolFileEdit?) -> [String] {
    edit?.files.flatMap { $0.hunks.flatMap { $0.lines.map(\.unified) } } ?? []
}

private let demoDeleteCallID = "call_demo_delete_retry_adapter"
private let demoDeletePath = "src/net/retry-legacy-adapter.ts"

@MainActor
func checkToolDiffs() {
    print("Tool diffs")
    let edit = ToolFileEdit.parse(toolName: "edit", arguments: toolArgs(["file_path": "a.swift", "old_string": "let a = 1",
                                                                         "new_string": "let a = 2\nlet b = 3"]))
    check(diffLines(edit) == ["-let a = 1", "+let a = 2", "+let b = 3"] && edit?.additions == 2 && edit?.deletions == 1,
          "edit old_string/new_string → -1 +2 (\(diffLines(edit)))")
    check(edit?.additionsLabel == "+2" && edit?.deletionsLabel == "−1",
          "an edit with both sides keeps its exact addition and deletion header labels")
    check(edit?.unifiedText.hasPrefix("--- a/a.swift\n+++ b/a.swift\n@@") == true
          && edit?.unifiedText.hasSuffix("\n-let a = 1\n+let a = 2\n+let b = 3") == true, "edit unified text has headers and lines")
    let write = ToolFileEdit.parse(toolName: "write", arguments: toolArgs(["path": "n.md", "content": "# N\nbody\n"]),
                                   details: .object(["changed": true, "created": true]))
    check(write?.files.first?.operation == .add && diffLines(write) == ["+# N", "+body"] && write?.deletions == 0,
          "new-file write (created: true) is all additions")
    let bare = ToolFileEdit.parse(toolName: "write", arguments: toolArgs(["path": "n.md", "content": "# N\nbody\n"]))
    check(bare?.files.first?.operation == .update && bare?.statusLabel == "Written", "write without details is \"Written\"")
    let patch = ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": """
    *** Begin Patch
    *** Update File: a.txt
    @@ one
    -two
    +2
    @@ five
    -six
    +6
    *** Add File: b.txt
    +new
    *** End Patch
    """]))
    check(patch?.files.count == 2 && patch?.files.first?.hunks.count == 2 && patch?.additions == 3 && patch?.deletions == 2,
          "multi-hunk, multi-file apply_patch")
    let deleteOne = ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": "*** Begin Patch\n*** Delete File: old.txt\n*** End Patch"]))
    let deleteTwo = ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": "*** Begin Patch\n*** Delete File: a.txt\n*** Delete File: b.txt\n*** End Patch"]))
    check(deleteOne?.statusLabel == "Deleted" && deleteOne?.deletionsLabel == nil
          && deleteOne?.accessibilitySummary == "Deleted old.txt"
          && deleteTwo?.deletionsLabel == "2 files deleted",
          "single header-only delete relies on its badge; multi-delete keeps its count")
    let mixedDelete = ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": "*** Begin Patch\n*** Delete File: old.txt\n*** Add File: new.txt\n+new\n*** End Patch"]))
    check(mixedDelete?.statusLabel == "Patch" && mixedDelete?.deletionsLabel == "1 file deleted",
          "mixed patch keeps the header-only deleted-file count beside the generic Patch badge")
    let headerOnlyDelete = "*** Begin Patch\n*** Delete File: old.txt\n*** End Patch"
    check(ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": headerOnlyDelete]), isError: true) == nil
          && ToolFileEdit.parse(toolName: "apply_patch", arguments: toolArgs(["input": headerOnlyDelete])) != nil,
          "only a successful header-only deletion produces a diff card")
    check(ToolFileEdit.parse(toolName: "edit", arguments: "{\"path\":") == nil
          && ToolFileEdit.parse(toolName: "exec", arguments: toolArgs(["command": "ls"])) == nil
          && ToolFileEdit.parse(toolName: "edit", arguments: toolArgs(["path": "a", "oldText": "x", "newText": "y"]), isError: true) == nil,
          "malformed, other tools and failed calls fall back to raw arguments")
    let receipt = ToolFileEdit.parse(toolName: "edit", arguments: toolArgs(["path": "a", "oldText": "x", "newText": "y"]),
                                     details: .object(["diff": "  1 keep\n- 2 x\n+ 2 y\n    ..."]))
    check(receipt?.files.first?.hunks.first?.lines.map(\.lineNumber) == [1, 2, 2], "details.diff wins, with line numbers")
    let big = (1...300).map { "line \($0)" }.joined(separator: "\n")
    let capped = ToolFileEdit.parse(toolName: "write", arguments: toolArgs(["path": "big", "content": big]))
    check(capped?.isTruncated == true && capped?.additions == 300 && capped?.isLarge == true
          && capped?.rows(collapsed: true).rows.count == ToolFileEdit.Limits.collapsedRows, "big write is capped and collapses")
}

@MainActor
private func connectForDiffs(_ profile: GatewayProfile, _ label: String) async -> GatewayStore? {
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor(label, timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "\(label) connected")
    return connected ? gateway : nil
}

@MainActor
private func tools(_ chat: ChatStore) -> [ToolActivity] {
    chat.entries.flatMap { entry -> [ToolActivity] in
        if case let .assistant(turn) = entry { return turn.tools }
        return []
    }
}

private let retryFixKey = "agent:coder:dashboard:retry-fix"

/// The seeded retry-fix chat's `edit`, new-file `write` and multi-file `apply_patch` all read as diffs.
@MainActor
private func checkRetryFixChat(_ chat: ChatStore, label: String, editHasReceipt: Bool) async {
    await chat.load()
    let loaded = await waitFor("\(label) retry-fix history") {
        let calls = tools(chat)
        return calls.count >= 3 && (label != "demo" || calls.contains { $0.id == demoDeleteCallID })
    }
    let calls = tools(chat)
    check(loaded && calls.prefix(3).map(\.name) == ["edit", "write", "apply_patch"],
          "\(label): retry-fix chat has edit, write, apply_patch (\(calls.map(\.name)))")
    guard calls.count >= 3 else { return }
    let edit = calls[0].fileEdit, write = calls[1].fileEdit, patch = calls[2].fileEdit
    check(edit?.kind == .edit && edit?.primaryPath == "src/net/retry.ts", "\(label): edit → diff of src/net/retry.ts")
    if editHasReceipt {
        // Upstream's `details.diff` receipt: two hunks with the file's real line numbers.
        check(edit?.files.first?.hunks.count == 2 && edit?.additions == 5 && edit?.deletions == 1
              && edit?.files.first?.hunks.first?.lines.first?.lineNumber == 1
              && edit?.files.first?.hunks.last?.lines.contains { $0.kind == .deletion && $0.lineNumber == 15 } == true,
              "\(label): edit reads the applied details.diff (\(edit?.files.first?.hunks.map(\.lines.count) ?? []), +\(edit?.additions ?? -1) -\(edit?.deletions ?? -1))")
    } else {
        check(edit?.additions == 2 && edit?.deletions == 1 && diffLines(edit).contains("-      const delay = opts.baseDelayMs * 2 ** attempt;"),
              "\(label): edit diffs old_string → new_string (\(diffLines(edit)))")
        if label == "demo" {
            check(edit?.additionsLabel == "+2" && edit?.deletionsLabel == "−1",
                  "demo: the loaded retry edit supplies both visible header counts")
        }
    }
    check(write?.kind == .write && write?.files.first?.operation == .add && write?.additions == 17 && write?.deletions == 0
          && write?.primaryPath == "src/net/retry.test.ts" && write?.isStatExact == true,
          "\(label): write → new file, 17 additions (\(write?.files.first?.operation.rawValue ?? "nil"), \(write?.statusLabel ?? ""), +\(write?.additions ?? -1) -\(write?.deletions ?? -1), exact \(write?.isStatExact ?? false))")
    check(patch?.kind == .patch && patch?.files.map(\.operation) == [.update, .move, .add, .delete]
          && patch?.files.first?.hunks.count == 3 && patch?.files[1].sourcePath == "src/net/errors.ts"
          && patch?.files[1].path == "src/net/http-errors.ts",
          "\(label): apply_patch → update (3 hunks), move, add, delete (\(patch?.files.map(\.operation.rawValue) ?? []))")
    check(patch?.additions == 11 && patch?.deletions == 3 && patch?.title == "4 files",
          "\(label): patch counts +11 -3 (+\(patch?.additions ?? -1) -\(patch?.deletions ?? -1))")
    // The delete is header-only, so removals are a lower bound; additions stay exact.
    check(patch?.additionsLabel == "+11" && patch?.deletionsLabel == "−3+"
          && patch?.accessibilitySummary == "Edited 4 files, 11 added, at least 3 removed",
          "\(label): patch header reads +11 −3+ (\(patch?.additionsLabel ?? "nil") \(patch?.deletionsLabel ?? "nil"), \(patch?.accessibilitySummary ?? ""))")
    check(patch?.unifiedText.contains("--- /dev/null\n+++ b/docs/retry.md") == true
          && patch?.unifiedText.contains("--- a/src/net/legacy-retry.ts\n+++ /dev/null") == true,
          "\(label): patch unified text marks the add and the delete")
    check(!calls.contains { $0.name == "edit" && $0.isError }, "\(label): no failed file edits")
    if label == "demo" {
        let deletion = calls.first { $0.id == demoDeleteCallID }
        let deleteEdit = deletion?.fileEdit
        check(deleteEdit?.statusLabel == "Deleted" && deleteEdit?.files.count == 1
              && deleteEdit?.files.first?.operation == .delete && deleteEdit?.deletionsLabel == nil
              && deleteEdit?.accessibilitySummary == "Deleted retry-legacy-adapter.ts"
              && deletion?.arguments?.contains(demoDeletePath) == true,
              "demo: a loaded single-file header-only delete shows its Deleted badge/path without a duplicate count")
    }
}

@MainActor
func runDemoToolDiffs() async {
    guard let gateway = await connectForDiffs(.demo(), "demo for tool diffs") else { return }
    defer { gateway.stop() }
    check(gateway.sessions[retryFixKey] != nil, "demo has the Fix retry backoff chat")
    await checkRetryFixChat(gateway.chat(for: retryFixKey), label: "demo", editHasReceipt: false)
}

@MainActor
func runLiveToolDiffs(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock diffs", url: url, authMode: .token)
    profile.secret = token
    guard let gateway = await connectForDiffs(profile, "mock for tool diffs") else { return }
    defer { gateway.stop() }
    let chat = gateway.chat(for: retryFixKey)
    await checkRetryFixChat(chat, label: "mock", editHasReceipt: true)

    // A live `edit` streams its call, then its result with the receipt.
    let before = tools(chat).count
    let nonce = UUID().uuidString.prefix(6)
    await chat.send("show me the config patch \(nonce)")
    var liveEdit: ToolFileEdit?
    let finished = await waitFor("live edit run", timeout: 60, every: 20) {
        if case let .assistant(turn)? = chat.entries.last, turn.isStreaming,
           let call = turn.tools.first(where: { $0.name == "edit" }), let edit = call.fileEdit
        {
            liveEdit = edit
        }
        return !chat.isRunning && tools(chat).count > before
    }
    check(finished, "live edit run finished")
    check(liveEdit?.primaryPath == "config/retry.json" && liveEdit?.additions == 2 && liveEdit?.deletions == 2,
          "streamed edit shows its diff while running (\(diffLines(liveEdit)))")
    let committed = tools(chat).last { $0.name == "edit" && $0.fileEdit?.primaryPath == "config/retry.json" }?.fileEdit
    check(committed?.files.first?.hunks.first?.lines.map(\.lineNumber) == [1, 2, 3, 2, 3, 4],
          "committed edit reads its details.diff receipt (\(committed?.files.first?.hunks.first?.lines.map(\.lineNumber) ?? []))")
}
