import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ToolDiffLineNumberBoundaryTests {
    @Test func representableHeaderBoundaryDoesNotTrap() async throws {
        let result = await Task.detached {
            ToolFileEditTests.parse("apply_patch", ["input": "--- a/file.txt\n+++ b/file.txt\n@@ -\(Int.max),1 +\(Int.max),1 @@\n context"])
        }.value
        let edit = try #require(result)
        try #require(edit.files.count == 1)
        #expect(edit.files[0].path == "file.txt")
        try #require(edit.files[0].hunks.count == 1)
        try #require(edit.files[0].hunks[0].lines.count == 1)
        #expect(edit.files[0].hunks[0].lines.map(\.unified) == [" context"])
        #expect(edit.files[0].hunks[0].lines.map(\.lineNumber) == [Int.max])
        #expect(edit.additions == 0 && edit.deletions == 0)
    }
    @Test func ordinaryHunkAndRawFallbackRemainExact() async throws {
        let values = await Task.detached {
            (ToolFileEditTests.parse("apply_patch", ["input": "--- a/file.txt\n+++ b/file.txt\n@@ -10,2 +20,2 @@\n context\n-old\n+new"]),
             ToolFileEditTests.parse("apply_patch", ["input": "not a patch"]))
        }.value
        let edit = try #require(values.0)
        let lines = edit.files.flatMap { $0.hunks.flatMap(\.lines) }
        #expect(lines.map(\.unified) == [" context", "-old", "+new"])
        #expect(lines.map(\.lineNumber) == [20, 11, 21])
        #expect(edit.additions == 1 && edit.deletions == 1 && values.1 == nil)
    }
    @Test(arguments: [" context", "+added", "-deleted"])
    func exhaustedHunkCursorHasNoFollowingNumber(first: String) async throws {
        let result = await Task.detached {
            ToolFileEditTests.parse("apply_patch", ["input": "--- a/file.txt\n+++ b/file.txt\n@@ -\(Int.max),3 +\(Int.max),3 @@\n\(first)\n\(first)\n\(first)"])
        }.value
        let edit = try #require(result)
        try #require(edit.files.count == 1)
        try #require(edit.files[0].hunks.count == 1)
        let lines = edit.files[0].hunks[0].lines
        #expect(lines.map(\.unified) == [first, first, first])
        #expect(lines.map(\.lineNumber) == [Int.max, nil, nil])
        #expect(edit.additions == (first.hasPrefix("+") ? 3 : 0))
        #expect(edit.deletions == (first.hasPrefix("-") ? 3 : 0))
    }

}
