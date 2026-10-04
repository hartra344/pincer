import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ToolDiffLineNumberBoundaryTests {
    @Test func representableHeaderBoundaryDoesNotTrap() async {
        let result = await Task.detached {
            ToolFileEditTests.parse("apply_patch", ["input": "--- a/file.txt\n+++ b/file.txt\n@@ -\(Int.max),1 +\(Int.max),1 @@\n context"])
        }.value
        #expect(result == nil || result?.files.flatMap { $0.hunks.flatMap { $0.lines.map(\.unified) } } == [" context"],
                "unrepresentable following line may fall back, but parsing must not terminate the client")
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
}
