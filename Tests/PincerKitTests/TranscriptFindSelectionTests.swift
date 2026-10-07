import Testing
@testable import PincerKit

@Suite("Transcript Find completion selection")
struct TranscriptFindSelectionTests {
    let matches = (0..<3).map { TranscriptSearch.Match(entryId: "row-\($0)", section: .message(0), occurrence: 0) }
    var rows: [String: Int] { Dictionary(self.matches.enumerated().map { ($1.entryId, $0) }, uniquingKeysWith: { a, _ in a }) }
    @Test(arguments: [true, false]) func refreshPreservesNavigation(forward: Bool) throws {
        var state = TranscriptFindSelection()
        state.select(1)
        let captured = state.capture(matches: self.matches, rowIndex: self.rows)
        let next = try #require(TranscriptSearch.step(from: state.current, count: self.matches.count, forward: forward))
        state.select(next)
        try #require(state.current == next && next != 1)
        state.complete(captured, matches: self.matches, rowIndex: self.rows)
        #expect(state.current == next)
    }
    @Test func refreshPreferredAndRemovedSelectionControls() {
        var state = TranscriptFindSelection()
        state.select(1)
        let captured = state.capture(matches: self.matches, rowIndex: self.rows)
        #expect(state.complete(captured, matches: self.matches, rowIndex: self.rows) == 1)
        #expect(state.complete(captured, matches: Array(self.matches.prefix(1)), rowIndex: self.rows) == 0)
        let preferred = state.capture(matches: self.matches, rowIndex: self.rows, preferred: self.matches[2])
        #expect(state.complete(preferred, matches: self.matches, rowIndex: self.rows) == 2)
    }
}
