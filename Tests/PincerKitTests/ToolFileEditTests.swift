import Foundation
import Testing
@testable import PincerKit

/// File-changing tool calls read as diffs (`ToolFileEdit`, `DiffBuilder`), with the argument shapes
/// upstream OpenClaw's tools and the Claude/Codex-style aliases use.
@Suite("Tool file edits")
struct ToolFileEditTests {
    static func args(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func parse(_ tool: String, _ object: [String: Any], details: JSONValue? = nil, isError: Bool = false) -> ToolFileEdit? {
        ToolFileEdit.parse(toolName: tool, arguments: Self.args(object), details: details, isError: isError)
    }

    static func lines(_ edit: ToolFileEdit?) -> [String] {
        edit?.files.flatMap { $0.hunks.flatMap { $0.lines.map(\.unified) } } ?? []
    }

    // MARK: edit

    @Test func editWithOldAndNewText() throws {
        let edit = try #require(Self.parse("edit", ["path": "src/a.ts", "oldText": "let a = 1;\nlet b = 2;\n",
                                                    "newText": "let a = 1;\nlet b = 3;\nlet c = 4;\n"]))
        #expect(edit.kind == .edit)
        #expect(edit.files.count == 1 && edit.files[0].operation == .update && edit.files[0].path == "src/a.ts")
        #expect(edit.primaryPath == "src/a.ts" && edit.title == "a.ts" && edit.directory == "src/")
        #expect(Self.lines(edit) == [" let a = 1;", "-let b = 2;", "+let b = 3;", "+let c = 4;"])
        #expect(edit.additions == 2 && edit.deletions == 1 && edit.isStatExact && !edit.isTruncated)
        #expect(edit.statusLabel == "Edited")
        #expect(edit.accessibilitySummary == "Edited a.ts, 2 added, 1 removed")
    }

    @Test(arguments: [
        ("edit", "file_path", "old_string", "new_string"),
        ("edit", "filePath", "oldString", "newString"),
        ("Edit", "path", "old_str", "new_str"),
        ("edit_file", "path", "oldText", "newText"),
        ("multiedit", "file_path", "old_string", "new_string"),
        ("multi_edit", "file_path", "old_string", "new_string"),
        ("str_replace_editor", "path", "old_str", "new_str"),
        ("str_replace_based_edit_tool", "path", "old_str", "new_str"),
        ("notebook_edit", "notebook_path", "old_string", "new_string"),
    ])
    func editAliases(tool: String, pathKey: String, oldKey: String, newKey: String) throws {
        var object: [String: Any] = [pathKey: "lib/x.py", oldKey: "x = 1", newKey: "x = 2"]
        if tool.hasPrefix("str_replace") { object["command"] = "str_replace" }
        let edit = try #require(Self.parse(tool, object), "\(tool) \(pathKey)/\(oldKey)/\(newKey)")
        #expect(edit.kind == .edit && edit.primaryPath == "lib/x.py")
        #expect(Self.lines(edit) == ["-x = 1", "+x = 2"])
    }

    @Test func eachEditsPairIsItsOwnHunk() throws {
        let edit = try #require(Self.parse("edit", ["path": "a.swift", "edits": [
            ["oldText": "import A", "newText": "import A\nimport B"],
            ["old_string": "let x = 1", "new_string": "let x = 2"],
        ]]))
        let hunks = edit.files[0].hunks
        #expect(hunks.count == 2)
        #expect(hunks[0].lines.map(\.unified) == [" import A", "+import B"])
        #expect(hunks[1].lines.map(\.unified) == ["-let x = 1", "+let x = 2"])
        #expect(edit.additions == 2 && edit.deletions == 1)
        #expect(edit.rows.contains(.separator), "a ⋯ between the pairs")
    }

    @Test func editPairsAreCapped() throws {
        let pairs = (0..<12).map { ["oldText": "a\($0)", "newText": "b\($0)"] }
        let edit = try #require(Self.parse("edit", ["path": "a", "edits": pairs]))
        #expect(edit.files[0].hunks.count == ToolFileEdit.Limits.maxEditPairs)
        #expect(edit.isTruncated && !edit.isStatExact)
    }

    @Test func noChangeAndMissingTextAreNil() {
        #expect(Self.parse("edit", ["path": "a", "oldText": "same", "newText": "same"]) == nil)
        #expect(Self.parse("edit", ["path": "a", "oldText": "only old"]) == nil)
        #expect(Self.parse("edit", ["path": "a", "edits": []]) == nil)
        #expect(Self.parse("str_replace_editor", ["command": "view", "path": "a"]) == nil)
        #expect(Self.parse("str_replace_editor", ["command": "undo_edit", "path": "a"]) == nil)
    }

    @Test func textEditorInsertAndCreate() throws {
        let insert = try #require(Self.parse("str_replace_editor", ["command": "insert", "path": "a.txt",
                                                                    "insert_line": 4, "new_str": "one\ntwo"]))
        #expect(insert.kind == .insert && insert.additions == 2 && insert.deletions == 0)
        #expect(insert.files[0].hunks[0].lines.map(\.lineNumber) == [5, 6])
        let create = try #require(Self.parse("str_replace_editor", ["command": "create", "path": "n.txt", "file_text": "hi\nthere\n"]))
        #expect(create.kind == .write && create.files[0].operation == .add && Self.lines(create) == ["+hi", "+there"])
    }

    @Test func notebookNewSourceIsAnInsertion() throws {
        let cell = try #require(Self.parse("NotebookEdit", ["notebook_path": "a.ipynb", "new_source": "print(1)\nprint(2)"]))
        #expect(cell.kind == .insert && cell.primaryPath == "a.ipynb" && cell.additions == 2)
        #expect(Self.parse("notebookedit", ["notebook_path": "a.ipynb", "new_source": "x", "edit_mode": "delete"]) == nil)
    }

    // MARK: write

    @Test(arguments: [("create_file", "file_text")])
    func newFileWriteIsAllAdditions(tool: String, key: String) throws {
        let content = "# Title\n\nBody line\n"
        let write = try #require(Self.parse(tool, ["file_path": "docs/new.md", key: content]), "\(tool).\(key)")
        #expect(write.kind == .write && write.files[0].operation == .add && write.statusLabel == "New file")
        #expect(Self.lines(write) == ["+# Title", "+", "+Body line"])
        #expect(write.files[0].hunks[0].lines.map(\.lineNumber) == [1, 2, 3])
        #expect(write.additions == 3 && write.deletions == 0 && write.isStatExact)
        #expect(write.copyText == content, "Copy puts the raw file content")
        #expect(write.files[0].unifiedText.hasPrefix("--- /dev/null\n+++ b/docs/new.md\n@@ -0,0 +1,3 @@\n+# Title"))
    }

    @Test(arguments: [("write", "content"), ("write", "text"), ("write_file", "content"), ("Write", "file_text")])
    func plainWriteWithoutDetailsIsWritten(tool: String, key: String) throws {
        let write = try #require(Self.parse(tool, ["file_path": "docs/new.md", key: "# Title\n\nBody line\n"]))
        #expect(write.kind == .write && write.files[0].operation == .update && write.statusLabel == "Written")
        #expect(Self.lines(write) == ["+# Title", "+", "+Body line"])
        #expect(write.additions == 3 && write.deletionsBound == .unknown && !write.isStatExact)
        let statusOnly = try #require(Self.parse(tool, ["path": "a", key: "x\n"], details: .object(["status": "completed"])))
        #expect(statusOnly.statusLabel == "Written", "status scalars alone aren't a write receipt")
        let created = try #require(Self.parse(tool, ["path": "a", key: "x\n"], details: .object(["created": true])))
        #expect(created.statusLabel == "New file" && created.deletionsBound == .exact)
    }

    @Test func writeDetailsSayWhetherTheFileIsNew() throws {
        let created = try #require(Self.parse("write", ["path": "a", "content": "x\n"], details: Fixtures.json(#"{"changed":true,"created":true}"#)))
        #expect(created.files[0].operation == .add && created.isStatExact)
        let overwrite = try #require(Self.parse("write", ["path": "a", "content": "x\n"], details: Fixtures.json(#"{"changed":true,"created":false}"#)))
        #expect(overwrite.files[0].operation == .update && !overwrite.isStatExact && overwrite.statusLabel == "Written",
                "an overwrite's removals are unknown")
        #expect(Self.parse("write", ["path": "a", "content": "x\n"], details: Fixtures.json(#"{"changed":false}"#)) == nil)
        #expect(Self.parse("write", ["path": "a", "content": ""]) == nil)
    }

    @Test func writePreviewIsCapped() throws {
        let content = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let write = try #require(Self.parse("write", ["path": "big.txt", "content": content]))
        #expect(write.files[0].hunks[0].lines.count == ToolFileEdit.Limits.maxWritePreviewLines)
        #expect(write.additions == 200 && write.omittedLines == 120 && write.isTruncated)
        #expect(write.rows.last == .truncated(omitted: 120))
        #expect(ToolFileEdit.text(for: .truncated(omitted: 120)) == "Diff truncated — 120 more lines")
        #expect(write.copyText == content)
    }

    // MARK: apply_patch

    static let envelope = """
    *** Begin Patch
    *** Update File: src/net/client.ts
    @@ import { withRetry } from './retry';
    -import { legacyRetry } from './legacy-retry';
    +import type { RetryOptions } from './retry';
    @@ export class ApiClient {
    -  private retries = 3;
    +  private readonly retry: RetryOptions = { attempts: 4, baseDelayMs: 250 };
    @@ async request<T>(path: string): Promise<T> {
    -    return legacyRetry(() => this.fetchJSON<T>(path), this.retries);
    +    return withRetry(() => this.fetchJSON<T>(path), this.retry);
       }
    *** Update File: src/net/errors.ts
    *** Move to: src/net/http-errors.ts
    @@ export class HttpError extends Error {
     }
    +
    +export function isRetryable(error: unknown): boolean {
    +  return error instanceof HttpError;
    +}
    *** Add File: docs/retry.md
    +# Retries
    +
    +Up to 4 attempts.
    *** Delete File: src/net/legacy-retry.ts
    *** End Patch
    """

    @Test func multiFileEnvelope() throws {
        let patch = try #require(Self.parse("apply_patch", ["input": Self.envelope]))
        #expect(patch.kind == .patch && patch.files.count == 4 && patch.primaryPath == nil && patch.title == "4 files")
        let (client, moved, added, deleted) = (patch.files[0], patch.files[1], patch.files[2], patch.files[3])
        #expect(client.operation == .update && client.path == "src/net/client.ts" && client.hunks.count == 3)
        #expect(client.additions == 3 && client.deletions == 3)
        #expect(client.hunks[2].lines.map(\.unified) == ["-    return legacyRetry(() => this.fetchJSON<T>(path), this.retries);",
                                                          "+    return withRetry(() => this.fetchJSON<T>(path), this.retry);",
                                                          "   }"])
        #expect(moved.operation == .move && moved.sourcePath == "src/net/errors.ts" && moved.path == "src/net/http-errors.ts")
        #expect(moved.label == "Move src/net/errors.ts → src/net/http-errors.ts" && moved.additions == 4)
        #expect(added.operation == .add && added.path == "docs/retry.md" && added.additions == 3 && added.deletions == 0)
        #expect(added.hunks.flatMap(\.lines).map(\.lineNumber) == [1, 2, 3])
        #expect(deleted.operation == .delete && deleted.path == "src/net/legacy-retry.ts" && deleted.hunks.isEmpty)
        #expect(patch.additions == 10 && patch.deletions == 3)
        #expect(!patch.isStatExact, "a header-only delete doesn't say how many lines it removed")
        #expect(patch.statusLabel == "Patch")
        // Multi-file patches label every file; the delete (no lines) still gets its row.
        let fileRows = patch.rows.compactMap { if case let .file(file) = $0 { file.path } else { nil } }
        #expect(fileRows == ["src/net/client.ts", "src/net/http-errors.ts", "docs/retry.md", "src/net/legacy-retry.ts"])
        let unified = patch.unifiedText
        #expect(unified.contains("--- a/src/net/errors.ts\n+++ b/src/net/http-errors.ts"))
        #expect(unified.contains("--- /dev/null\n+++ b/docs/retry.md"))
        #expect(unified.contains("--- a/src/net/legacy-retry.ts\n+++ /dev/null"))
    }

    @Test(arguments: [("apply_patch", "input"), ("applypatch", "input"), ("patch", "patch"), ("apply_patch", "diff")])
    func patchAliases(tool: String, key: String) throws {
        let patch = try #require(Self.parse(tool, [key: Self.envelope]), "\(tool).\(key)")
        #expect(patch.files.count == 4)
    }

    @Test func singleFilePatchOperations() throws {
        let add = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch"]))
        #expect(add.statusLabel == "New file" && add.primaryPath == "a.txt" && add.isStatExact)
        let delete = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** Delete File: a.txt\n*** End Patch"]))
        #expect(delete.statusLabel == "Deleted" && delete.rows.first == .file(delete.files[0]))
        let move = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** Update File: a/Old.swift\n*** Move to: a/New.swift\n*** End Patch"]))
        #expect(move.statusLabel == "Moved" && move.title == "Old.swift → New.swift" && move.directory == nil)
    }

    /// #159: a header-only delete lists no removed lines, so the label says the file was deleted.
    @Test func headerOnlyDeleteLabelsDeletedFiles() throws {
        let one = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** Delete File: a.txt\n*** End Patch"]))
        #expect(one.deletionsLabel == "1 file deleted", "\(one.deletionsLabel ?? "nil")")
        #expect(one.accessibilitySummary.contains("1 file deleted"), Comment(rawValue: one.accessibilitySummary))
        let two = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** Delete File: a.txt\n*** Delete File: b.txt\n*** End Patch"]))
        #expect(two.deletionsLabel == "2 files deleted", "\(two.deletionsLabel ?? "nil")")
    }

    @Test func deleteWithListedLinesKeepsCountLabel() throws {
        let patch = "*** Begin Patch\n*** Delete File: a.txt\n-one\n-two\n*** End Patch"
        if let edit = Self.parse("apply_patch", ["input": patch]), edit.deletions > 0 {
            #expect(edit.deletionsLabel == "−\(edit.deletions)")
        }
    }

    @Test func plainUnifiedDiffPatch() throws {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -10,3 +10,4 @@ struct A {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             let d = 5
        --- /dev/null
        +++ b/Sources/B.swift
        @@ -0,0 +1,1 @@
        +struct B {}
        """
        let patch = try #require(Self.parse("apply_patch", ["patch": diff]))
        #expect(patch.files.map(\.path) == ["Sources/A.swift", "Sources/B.swift"])
        #expect(patch.files.map(\.operation) == [.update, .add])
        let hunk = patch.files[0].hunks[0]
        #expect(hunk.oldStart == 10 && hunk.newStart == 10 && hunk.header == "@@ -10,3 +10,4 @@")
        #expect(hunk.lines.map(\.lineNumber) == [10, 11, 11, 12, 13])
        #expect(patch.additions == 3 && patch.deletions == 1)
    }

    @Test func emptyOrUnrecognisedPatchesAreNil() {
        #expect(Self.parse("apply_patch", ["input": ""]) == nil)
        #expect(Self.parse("apply_patch", ["input": "just some words"]) == nil)
        #expect(Self.parse("apply_patch", ["input": "*** Begin Patch\n*** End Patch"]) == nil)
        #expect(Self.parse("apply_patch", ["command": "x"]) == nil)
    }

    @Test func hugePatchIsClipped() throws {
        let body = (1...5000).map { "+line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n")
        let raw = "*** Begin Patch\n*** Add File: big.txt\n\(body)\n*** End Patch"
        let patch = try #require(Self.parse("apply_patch", ["input": raw]))
        #expect(patch.isTruncated && !patch.isStatExact)
        #expect(patch.files.flatMap(\.hunks).flatMap(\.lines).count <= ToolFileEdit.Limits.maxRenderedLines)
        #expect(patch.copyText == raw, "a clipped patch copies what the agent sent")
    }

    @Test func renderedLinesAreCappedAcrossFiles() throws {
        let file = { (name: String) in "*** Add File: \(name)\n" + (1...300).map { "+\($0)" }.joined(separator: "\n") }
        let patch = try #require(Self.parse("apply_patch", ["input": "*** Begin Patch\n\(file("a"))\n\(file("b"))\n*** End Patch"]))
        #expect(patch.files.flatMap(\.hunks).flatMap(\.lines).count == ToolFileEdit.Limits.maxRenderedLines)
        #expect(patch.additions == 600 && patch.omittedLines == 200 && patch.isTruncated)
    }

    // MARK: details.diff and errors

    /// `details.diff` of upstream's edit receipt (`prepareFileDiff`): numbered lines, `...` between hunks.
    static let receipt = """
    + 1 import { isRetryable } from './http-errors';
      2 import { sleep } from './sleep';
      3 
    + 4 const MAX_DELAY_MS = 30_000;
    + 5 
      6 export interface RetryOptions {
        ...
     14     try {
     17       attempt += 1;
    -15       const delay = opts.baseDelayMs * 2 ** attempt;
    +18       if (attempt >= opts.attempts || !isRetryable(error)) throw error;
     20       await sleep(delay);
        ...
    """

    @Test func appliedDiffWinsOverArguments() throws {
        let details = JSONValue.object(["changed": true, "diff": .string(Self.receipt)])
        let edit = try #require(Self.parse("edit", ["path": "src/net/retry.ts", "oldText": "a", "newText": "b"], details: details))
        #expect(edit.primaryPath == "src/net/retry.ts" && edit.kind == .edit)
        #expect(edit.files[0].hunks.count == 2)
        #expect(edit.additions == 4 && edit.deletions == 1)
        #expect(!Self.lines(edit).contains("-a"), "arguments ignored when the receipt has a diff")
        let second = edit.files[0].hunks[1]
        #expect(second.lines.map(\.lineNumber) == [14, 17, 15, 18, 20])
        #expect(second.lines[2] == DiffLine(.deletion, "      const delay = opts.baseDelayMs * 2 ** attempt;", lineNumber: 15))
        #expect(edit.files[0].hunks[0].lines[2] == DiffLine(.context, "", lineNumber: 3))
        // Even a call whose arguments never parsed shows the applied diff.
        #expect(ToolFileEdit.parse(toolName: "write", arguments: "{", details: details)?.kind == .write)
    }

    @Test func truncatedReceipt() throws {
        let details = JSONValue.object(["diff": "+1 a\n...(truncated)..."])
        let edit = try #require(ToolFileEdit.parse(toolName: "edit", arguments: nil, details: details))
        #expect(edit.isTruncated && !edit.isStatExact && edit.rows.last == .truncated(omitted: nil))
        #expect(ToolFileEdit.text(for: .truncated(omitted: nil)) == "Diff truncated")
    }

    @Test func unreadableReceiptFallsBackToArguments() throws {
        let details = JSONValue.object(["diff": "not a numbered diff"])
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": "x", "newText": "y"], details: details))
        #expect(Self.lines(edit) == ["-x", "+y"])
        #expect(Self.parse("edit", ["path": "a", "oldText": "x", "newText": "y"], details: .object(["diff": ""])) != nil)
    }

    @Test func failedCallsWithoutAnAppliedDiffAreNil() {
        let object: [String: Any] = ["path": "a", "oldText": "x", "newText": "y"]
        #expect(Self.parse("edit", object, isError: true) == nil)
        #expect(Self.parse("write", ["path": "a", "content": "x"], isError: true) == nil)
        #expect(Self.parse("apply_patch", ["input": Self.envelope], isError: true) == nil)
        #expect(Self.parse("edit", object, details: .object(["diff": "+1 y"]), isError: true) != nil)
    }

    @Test func malformedArgumentsAreNil() {
        for tool in ["edit", "write", "apply_patch"] {
            for raw: String? in [nil, "", "{", "{\"path\":", "[]", "null", "42", "\"text\"", "{\"path\": 3}"] {
                #expect(ToolFileEdit.parse(toolName: tool, arguments: raw) == nil, "\(tool) \(raw ?? "nil")")
            }
        }
        #expect(Self.parse("exec", ["command": "ls", "path": "a", "content": "x"]) == nil)
        #expect(Self.parse("read", ["path": "a"]) == nil)
        #expect(!ToolFileEdit.handles(toolName: "exec") && ToolFileEdit.handles(toolName: " Apply_Patch "))
    }

    // MARK: caps

    @Test func hugeEditInputIsClipped() throws {
        let old = (1...1000).map { "old \($0)" }.joined(separator: "\n")
        // Changes near both ends leave a 996-line differing middle, past 600 lines per side.
        let new = (1...1000).map { $0 == 3 || $0 == 998 ? "changed \($0)" : "old \($0)" }.joined(separator: "\n")
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": old, "newText": new]))
        #expect(edit.isTruncated && !edit.isStatExact, "a differing middle past 600 lines per side is clipped")
        #expect(Self.lines(edit).contains("+changed 3") && Self.lines(edit).contains("-old 3"))
        #expect(!Self.lines(edit).contains("+changed 998"), "only the start of a clipped input is compared")
        #expect(Self.lines(edit).count <= ToolFileEdit.Limits.maxRenderedLines)
    }

    @Test func smallChangeInBigTextStaysExact() throws {
        let old = (1...1000).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...1000).map { $0 == 500 ? "changed" : "old \($0)" }.joined(separator: "\n")
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": old, "newText": new]))
        #expect(edit.isStatExact && !edit.isTruncated && edit.additions == 1 && edit.deletions == 1)
        #expect(Self.lines(edit) == ["old 497", "old 498", "old 499"].map { " " + $0 } + ["-old 500", "+changed"]
                + ["old 501", "old 502", "old 503"].map { " " + $0 })
    }

    @Test func overCharacterBudgetEditIsTruncatedWithoutLines() throws {
        let big = String(repeating: "y", count: ToolFileEdit.Limits.maxInputCharacters + 1)
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": "x", "newText": big]))
        #expect(edit.files[0].hunks.isEmpty && edit.isTruncated && edit.rows == [.file(edit.files[0]), .truncated(omitted: nil)])
    }

    @Test func longDiffIsCappedAtRenderedLines() throws {
        let old = (1...500).map { "a\($0)" }.joined(separator: "\n")
        let new = (1...500).map { "b\($0)" }.joined(separator: "\n")
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": old, "newText": new]))
        #expect(Self.lines(edit).count == ToolFileEdit.Limits.maxRenderedLines)
        #expect(edit.additions == 500 && edit.deletions == 500 && edit.omittedLines == 600 && edit.isStatExact)
    }

    @Test func largeCardsCollapse() throws {
        let content = (1...30).map { "l\($0)" }.joined(separator: "\n")
        let write = try #require(Self.parse("write", ["path": "a", "content": content]))
        #expect(write.isLarge)
        let collapsed = write.rows(collapsed: true)
        #expect(collapsed.rows.count == ToolFileEdit.Limits.collapsedRows && collapsed.hidden == 30 - 12)
        #expect(write.rows(collapsed: false).rows.count == 30 && write.rows(collapsed: false).hidden == 0)
        let small = try #require(Self.parse("write", ["path": "a", "content": "a\nb"]))
        #expect(!small.isLarge && small.rows(collapsed: true).hidden == 0)
    }

    // MARK: Stat bounds and labels

    @Test func exactCountsLabelBothSides() throws {
        let edit = try #require(Self.parse("edit", ["path": "src/a.ts", "oldText": "b\n", "newText": "c\nd\n"]))
        #expect(edit.additionsBound == .exact && edit.deletionsBound == .exact && edit.isStatExact)
        #expect(edit.additionsLabel == "+2" && edit.deletionsLabel == "−1")
        #expect(edit.accessibilitySummary == "Edited a.ts, 2 added, 1 removed")
        let addOnly = try #require(Self.parse("edit", ["path": "a", "oldText": "x", "newText": "x\ny"]))
        #expect(addOnly.additionsLabel == "+1" && addOnly.deletionsLabel == nil, "a zero side isn't shown")
        #expect(addOnly.accessibilitySummary == "Edited a, 1 added")
    }

    @Test func clippedEditIsALowerBoundOnBothSides() throws {
        let old = (1...1000).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...1000).map { $0 == 3 || $0 == 998 ? "changed \($0)" : "old \($0)" }.joined(separator: "\n")
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": old, "newText": new]))
        #expect(edit.additionsBound == .atLeast && edit.deletionsBound == .atLeast)
        #expect(edit.additionsLabel == "+\(edit.additions)+" && edit.deletionsLabel == "−\(edit.deletions)+")
        #expect(edit.accessibilitySummary == "Edited a, at least \(edit.additions) added, at least \(edit.deletions) removed")
    }

    @Test func onlyATruncatedReceiptIsALowerBound() throws {
        let details = JSONValue.object(["changed": true, "diff": .string(Self.receipt)])
        let edit = try #require(Self.parse("edit", ["path": "src/net/retry.ts", "oldText": "a", "newText": "b"], details: details))
        #expect(edit.isStatExact && edit.additionsLabel == "+4" && edit.deletionsLabel == "−1", "a whole receipt is exact")
        let clipped = try #require(ToolFileEdit.parse(toolName: "edit", arguments: nil,
                                                      details: .object(["diff": "+1 a\n+2 b\n-1 c\n...(truncated)..."])))
        #expect(clipped.additionsBound == .atLeast && clipped.deletionsBound == .atLeast)
        #expect(clipped.additionsLabel == "+2+" && clipped.deletionsLabel == "−1+")
    }

    @Test func headerOnlyDeleteLeavesAdditionsExact() throws {
        let patch = try #require(Self.parse("apply_patch", ["input": Self.envelope]))
        #expect(patch.additionsBound == .exact && patch.deletionsBound == .atLeast && !patch.isStatExact)
        #expect(patch.additionsLabel == "+10" && patch.deletionsLabel == "−3+")
        #expect(patch.accessibilitySummary == "Edited 4 files, 10 added, at least 3 removed")
    }

    @Test func overwriteAndNotebookInsertHideRemovals() throws {
        let overwrite = try #require(Self.parse("write", ["path": "src/w.ts", "content": "a\nb\n"],
                                                details: Fixtures.json(#"{"changed":true,"created":false}"#)))
        #expect(overwrite.additionsBound == .exact && overwrite.deletionsBound == .unknown)
        #expect(overwrite.additionsLabel == "+2" && overwrite.deletionsLabel == nil)
        #expect(overwrite.accessibilitySummary == "Wrote w.ts, 2 added")
        let notebook = try #require(Self.parse("notebook_edit", ["notebook_path": "n.ipynb", "new_source": "x = 1\ny = 2"]))
        #expect(notebook.deletionsBound == .unknown && notebook.deletionsLabel == nil && notebook.additionsLabel == "+2")
    }

    @Test func runningWriteSaysWriting() throws {
        let write = try #require(Self.parse("write", ["path": "src/w.ts", "content": "a\nb\n"],
                                            details: .object(["changed": true, "created": true])))
        #expect(write.statusLabel(isRunning: true) == "Writing")
        #expect(write.accessibilitySummary(isRunning: true) == "Writing w.ts, 2 added")
        #expect(write.statusLabel == write.statusLabel(isRunning: false) && write.statusLabel == "New file")
        #expect(write.accessibilitySummary == "Created w.ts, 2 added")
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": "x", "newText": "y"]))
        #expect(edit.statusLabel(isRunning: true) == "Edited", "only writes change wording while running")
    }

    @Test func legacyInitMapsInexactToLowerBounds() {
        let file = FileDiff(path: "a", operation: .update, hunks: [DiffHunk(lines: [DiffLine(.addition, "x", lineNumber: 1)])])
        let inexact = ToolFileEdit(kind: .edit, files: [file], isStatExact: false)
        #expect(inexact.additionsBound == .atLeast && inexact.deletionsBound == .atLeast)
        let exact = ToolFileEdit(kind: .edit, files: [file], isStatExact: true)
        #expect(exact.additionsBound == .exact && exact.deletionsBound == .exact)
    }

    // MARK: Copy text

    @Test func truncatedCopyTextSaysWhereItWasCut() throws {
        let old = (1...500).map { "a\($0)" }.joined(separator: "\n")
        let new = (1...500).map { "b\($0)" }.joined(separator: "\n")
        let capped = try #require(Self.parse("edit", ["path": "a", "oldText": old, "newText": new]))
        #expect(capped.copyText == capped.unifiedText + "\nDiff truncated — 600 more lines")
        let receipt = try #require(ToolFileEdit.parse(toolName: "edit", arguments: nil,
                                                      details: .object(["diff": "+1 a\n...(truncated)..."])))
        #expect(receipt.copyText.hasSuffix("\nDiff truncated"))
        let whole = try #require(Self.parse("edit", ["path": "a", "oldText": "x", "newText": "y"]))
        #expect(whole.copyText == whole.unifiedText, "an untruncated edit copies just the diff")
    }

    // MARK: apply_patch with a receipt

    @Test func multiFilePatchReceiptKeepsPerFileSections() throws {
        let details = JSONValue.object(["diff": "+1 something else"])
        let patch = try #require(Self.parse("apply_patch", ["input": Self.envelope], details: details))
        #expect(patch.files.count == 4 && patch.title == "4 files")
        #expect(patch.files.map(\.operation) == [.update, .move, .add, .delete])
    }

    @Test func singleFilePatchReceiptTakesThePathFromTheEnvelope() throws {
        let input = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-x\n+y\n*** End Patch"
        let details = JSONValue.object(["diff": "- 4 old line\n+ 4 new line\n  5 tail"])
        let patch = try #require(Self.parse("apply_patch", ["input": input], details: details))
        #expect(patch.title == "a.ts" && patch.directory == "src/" && patch.primaryPath == "src/a.ts")
        #expect(Self.lines(patch) == ["-old line", "+new line", " tail"], "the applied diff wins over the envelope's lines")
        #expect(patch.files[0].hunks[0].lines.map(\.lineNumber) == [4, 4, 5])
    }

    // MARK: DiffBuilder

    @Test func diffsPastTheCollapseThresholdKeepThreeLinesOfContext() throws {
        let old = (1...30).map { "same \($0)" } + ["old line", "end"]
        let new = (1...30).map { "same \($0)" } + ["new line", "end"]
        let result = DiffBuilder.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        #expect(result.hunks.count == 1 && !result.isTruncated)
        #expect(result.hunks[0].lines.map(\.unified) == [" same 28", " same 29", " same 30", "-old line", "+new line", " end"])
        let edit = try #require(Self.parse("edit", ["path": "a", "oldText": old.joined(separator: "\n"),
                                                    "newText": new.joined(separator: "\n")]))
        let shown = edit.rows(collapsed: true).rows
        #expect(shown.contains { if case let .line(line) = $0 { line.kind == .deletion && line.text == "old line" } else { false } },
                "the first change is visible on a collapsed card")
    }

    @Test func diffsUpToTheCollapseThresholdStayWhole() {
        let old = (1...18).map { "same \($0)" } + ["old line"]
        let new = (1...18).map { "same \($0)" } + ["new line"]
        let result = DiffBuilder.diff(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        #expect(result.hunks.count == 1 && result.hunks[0].lines.count == ToolFileEdit.Limits.collapseThreshold)
        #expect(result.hunks[0].lines.first?.text == "same 1")
    }

    @Test func lineDiffIsMinimalAndOrdered() {
        let result = DiffBuilder.diff(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        #expect(result.hunks.count == 1 && !result.isTruncated)
        #expect(result.hunks[0].lines.map(\.unified) == [" a", "-b", "+B", " c", "+d"])
        #expect(DiffBuilder.diff(old: "", new: "").hunks.isEmpty)
        #expect(DiffBuilder.diff(old: "", new: "x").hunks[0].lines.map(\.unified) == ["+x"])
        #expect(DiffBuilder.diff(old: "x\r\ny", new: "x\ny").hunks[0].lines.allSatisfy { $0.kind == .context }, "CRLF is normalized")
    }

    @Test(arguments: [1, 7, 42, 1234])
    func lineDiffReconstructsBothSides(seed: Int) {
        var rng = SplitMix(seed: UInt64(seed))
        let words = ["alpha", "beta", "gamma", "delta", "}", ""]
        let old = (0..<60).map { _ in words[Int(rng.next() % UInt64(words.count))] }
        var new = old
        for _ in 0..<10 {
            let index = Int(rng.next() % UInt64(new.count))
            if rng.next() % 2 == 0 { new.remove(at: index) } else { new.insert("new \(rng.next() % 100)", at: index) }
        }
        let lines = DiffBuilder.lines(old: old, new: new)
        #expect(lines.filter { $0.kind != .addition }.map(\.text) == old)
        #expect(lines.filter { $0.kind != .deletion }.map(\.text) == new)
        let lcs = lines.count { $0.kind == .context }
        #expect(lcs >= old.count - 10, "at most one line lost per edit")
    }

    @Test func hunksKeepContextAroundDistantChanges() {
        let old = (1...100).map { "l\($0)" }
        var new = old
        new[9] = "changed 10"
        new[79] = "changed 80"
        let hunks = DiffBuilder.hunks(DiffBuilder.lines(old: old, new: new), context: 3)
        #expect(hunks.count == 2)
        #expect(hunks.map(\.lines.count) == [8, 8])
        #expect(hunks[0].lines.first?.text == "l7" && hunks[0].lines.last?.text == "l13")
        let capped = DiffBuilder.cap(hunks, budget: 10)
        #expect(capped.hunks.map(\.lines.count) == [8, 2] && capped.omitted == 6)
    }

    // MARK: Integration

    @Test func toolActivityExposesTheDiff() {
        let call = ToolActivity(id: "c1", name: "edit", arguments: Self.args(["path": "a", "oldText": "x", "newText": "y"]),
                                result: "Successfully replaced 1 block(s) in a.", isError: false, isRunning: false)
        #expect(call.fileEdit?.primaryPath == "a")
        let exec = ToolActivity(id: "c2", name: "exec", arguments: #"{"command":"ls"}"#, result: nil, isError: false, isRunning: false)
        #expect(exec.fileEdit == nil)
        let streaming = ToolActivity(id: "c3", name: "write", arguments: #"{"path":"a","con"#, result: nil, isError: false, isRunning: true)
        #expect(streaming.fileEdit == nil, "half-streamed arguments fall back to raw text")
    }

    @Test func toolResultKeepsOnlyDiffDetails() {
        let item = ChatItem(Fixtures.json("""
        {"role":"toolResult","toolCallId":"c1","toolName":"edit","isError":false,
         "content":[{"type":"text","text":"ok"}],
         "details":{"changed":true,"diff":"+1 y","patch":"--- a\\n+++ a","firstChangedLine":1,"huge":"zzz"}}
        """), fallbackIndex: 0)
        #expect(item?.toolDetails == .object(["changed": true, "diff": "+1 y"]))
    }

    /// The demo chat's calls (`DemoGateway+FileEdits.swift`) all read as diffs.
    @Test func demoChatParses() throws {
        let transcript = DemoGateway.seedFileEditsTranscript()
        let calls = transcript.flatMap { $0["content"]?.array ?? [] }
            .filter { $0["type"]?.string == "toolCall" }
        let detailsById = Dictionary(transcript.compactMap { row in
            row["toolCallId"]?.string.flatMap { id in row["details"].map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        #expect(calls.compactMap { $0["name"]?.string } == ["edit", "write", "apply_patch"])
        let edits = try calls.map { call in
            try #require(ToolFileEdit.parse(toolName: call["name"]?.string ?? "", arguments: ContentBlock.prettyJSON(call["arguments"] ?? .null),
                                            details: call["id"]?.string.flatMap { detailsById[$0] }))
        }
        #expect(edits[0].kind == .edit && edits[0].primaryPath == DemoGateway.fileEditsRetryPath && edits[0].additions == 2 && edits[0].deletions == 1)
        #expect(edits[1].files[0].operation == .add && edits[1].additions == 17 && edits[1].deletions == 0)
        #expect(edits[2].files.map(\.operation) == [.update, .move, .add, .delete] && edits[2].files[0].hunks.count == 3)
    }
}

/// Deterministic generator for property checks.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
