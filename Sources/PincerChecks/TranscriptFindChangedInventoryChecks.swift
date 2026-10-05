@testable import PincerKit

@MainActor
func runTranscriptFindChangedInventoryChecks() {
    let old = ["a", "b", "c"].map { TranscriptSearch.Match(entryId: $0, section: .message(0), occurrence: 0) }
    var state = TranscriptFindSelection()
    state.select(0)
    let capture = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2], preferred: old[2])
    state.select(1)
    let fresh = [TranscriptSearch.Match(entryId: "inserted", section: .message(0), occurrence: 0)] + old
    let index = state.complete(capture, matches: fresh, rowIndex: ["inserted": 0, "a": 1, "b": 2, "c": 3])
    check(index == 2 && index.map { fresh[$0] } == old[1], "Find follows manually selected identity across inserted rows")
    state.select(0)
    let removed = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2])
    state.select(1)
    check(state.complete(removed, matches: [old[0], old[2]], rowIndex: ["a": 0, "c": 1]) == 1,
          "removed navigated match falls back near its actual old row")
    state.select(0)
    let aba = state.capture(matches: old, rowIndex: ["a": 0, "b": 1, "c": 2], preferred: old[2])
    state.select(1)
    state.select(0)
    check(state.complete(aba, matches: old, rowIndex: ["a": 0, "b": 1, "c": 2]) == 0,
          "manual ABA selection supersedes an admitted preferred match")
}
