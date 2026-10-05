/// Selection publication shared by the Find UI and its non-UI checks.
package struct TranscriptFindSelection: Sendable {
    package struct Capture: Sendable {
        package let previous: TranscriptSearch.Match?
        package let row: Int?
        package let preferred: TranscriptSearch.Match?
        fileprivate let revision: UInt64
        fileprivate let matches: [TranscriptSearch.Match]
        fileprivate let rows: [String: Int]
    }
    package private(set) var current: Int?
    private var revision: UInt64 = 0
    package init() {}
    package mutating func select(_ index: Int?) {
        self.revision &+= 1
        self.current = index
    }
    package func capture(matches: [TranscriptSearch.Match], rowIndex: [String: Int],
                         preferred: TranscriptSearch.Match? = nil) -> Capture {
        let previous = self.current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        return Capture(previous: previous, row: previous.flatMap { rowIndex[$0.entryId] }, preferred: preferred,
                       revision: self.revision, matches: matches, rows: rowIndex)
    }
    @discardableResult
    package mutating func complete(_ capture: Capture, matches: [TranscriptSearch.Match],
                                   rowIndex: [String: Int]) -> Int? {
        // Navigation still addresses the displayed, old match inventory until publication.
        // Retain that inventory by COW; resolving the selected identity adds no per-keypress scan.
        let navigated = self.revision != capture.revision
        let previous = navigated ? self.current.flatMap {
            capture.matches.indices.contains($0) ? capture.matches[$0] : nil
        } : capture.previous
        let near = navigated ? previous.flatMap { capture.rows[$0.entryId] } : capture.row
        self.current = TranscriptSearch.reselect(previous, in: matches, rowIndex: rowIndex,
                                                near: near, preferred: navigated ? nil : capture.preferred)
        return self.current
    }
}
