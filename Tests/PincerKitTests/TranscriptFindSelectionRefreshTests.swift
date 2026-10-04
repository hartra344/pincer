import Testing
@testable import PincerKit

@Suite("Transcript Find changed inventory")
struct TranscriptFindSelectionRefreshTests {
    func match(_ id: String) -> TranscriptSearch.Match { .init(entryId: id, section: .message(0), occurrence: 0) }
    @Test func insertedRowsPreserveSelectedIdentityAndManualSelectionOverridesPreferred() throws {
        let old = [self.match("a"), self.match("b"), self.match("c")]
        var state = TranscriptFindSelection()
        state.select(0)
        let capture = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2], preferred: old[2])
        state.select(1)
        let fresh = [self.match("inserted")] + old
        let completed = state.complete(capture, matches: fresh, rowIndex: ["inserted": 0, "a": 1, "b": 2, "c": 3])
        let index = try #require(completed)
        #expect(fresh[index] == old[1])
        #expect(index == 2)
    }
    @Test func removedNavigatedMatchUsesItsNearestRowAndABAIsStillManualIntent() throws {
        let old = [self.match("a"), self.match("b"), self.match("c")]
        var state = TranscriptFindSelection()
        state.select(0)
        let capture = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2], preferred: old[2])
        state.select(1)
        // Removing the entire middle entry makes the remaining row index dense.
        let remaining = [old[0], old[2]]
        #expect(state.complete(capture, matches: remaining, rowIndex: ["a": 0, "c": 1]) == 1)
        state.select(0)
        let aba = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2], preferred: old[2])
        state.select(1)
        state.select(0)
        #expect(state.complete(aba, matches: old, rowIndex: ["a": 0, "b": 1, "c": 2]) == 0)
    }
}
