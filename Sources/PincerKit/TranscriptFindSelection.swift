/// Selection publication shared by the Find UI and its non-UI checks.
package struct TranscriptFindSelection: Sendable {
    package struct Capture: Sendable {
        package let previous: TranscriptSearch.Match?
        package let row: Int?
        package let preferred: TranscriptSearch.Match?
    }
    package private(set) var current: Int?
    package init() {}
    package mutating func select(_ index: Int?) { self.current = index }
    package func capture(matches: [TranscriptSearch.Match], rowIndex: [String: Int],
                         preferred: TranscriptSearch.Match? = nil) -> Capture {
        let previous = self.current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        return Capture(previous: previous, row: previous.flatMap { rowIndex[$0.entryId] }, preferred: preferred)
    }
    @discardableResult
    package mutating func complete(_ capture: Capture, matches: [TranscriptSearch.Match],
                                   rowIndex: [String: Int]) -> Int? {
        self.current = TranscriptSearch.reselect(capture.previous, in: matches, rowIndex: rowIndex,
                                                near: capture.row, preferred: capture.preferred)
        return self.current
    }
}
