import Foundation

/// Which rows still need measuring, and which of them to measure next. Pure and platform
/// neutral: the AppKit and UIKit lists both drive their idle prefetch and scroll-time measuring
/// from it, so neither walks the whole transcript to find work.
struct TranscriptMeasureQueue {
    /// Rows within this many viewport heights of the viewport are measured ahead of time; the
    /// rest keep their estimated heights until the reader gets near.
    static let screensAhead = 10

    private(set) var unmeasured = IndexSet()

    var isEmpty: Bool { self.unmeasured.isEmpty }
    var count: Int { self.unmeasured.count }

    func contains(_ row: Int) -> Bool { self.unmeasured.contains(row) }

    mutating func markAllUnmeasured(count: Int) {
        self.unmeasured = count > 0 ? IndexSet(integersIn: 0..<count) : IndexSet()
    }

    mutating func markUnmeasured(_ row: Int) {
        guard row >= 0 else { return }
        self.unmeasured.insert(row)
    }

    mutating func markMeasured(_ row: Int) {
        self.unmeasured.remove(row)
    }

    /// Rows were inserted at these (final) indexes: later rows shift down and the new ones start
    /// out unmeasured.
    mutating func insert(rows: IndexSet) {
        for row in rows {
            self.unmeasured.shift(startingAt: row, by: 1)
            self.unmeasured.insert(row)
        }
    }

    /// Rows were removed from these (original) indexes: later rows shift up.
    mutating func remove(rows: IndexSet) {
        for row in rows.reversed() {
            self.unmeasured.remove(row)
            self.unmeasured.shift(startingAt: row + 1, by: -1)
        }
    }

    /// Starts over from a predicate, after the rows changed in ways that are cheaper to
    /// recompute than to track.
    mutating func rebuild(count: Int, isUnmeasured: (Int) -> Bool) {
        var rows = IndexSet()
        for row in 0..<max(count, 0) where isUnmeasured(row) { rows.insert(row) }
        self.unmeasured = rows
    }

    /// Up to `limit` unmeasured rows inside `window`, nearest to `center` first (`center`, then
    /// above and below alternately). Touches only the rows it returns.
    func next(center: Int, window: ClosedRange<Int>, limit: Int) -> [Int] {
        guard limit > 0, !self.unmeasured.isEmpty else { return [] }
        let center = min(max(center, window.lowerBound), window.upperBound)
        var result: [Int] = []
        var below = self.unmeasured.integerGreaterThanOrEqualTo(center)
        var above = self.unmeasured.integerLessThan(center)
        while result.count < limit {
            let hasBelow = below.map { $0 <= window.upperBound } ?? false
            let hasAbove = above.map { $0 >= window.lowerBound } ?? false
            guard hasBelow || hasAbove else { break }
            if hasBelow, let row = below {
                result.append(row)
                below = self.unmeasured.integerGreaterThan(row)
                if result.count == limit { break }
            }
            if hasAbove, let row = above {
                result.append(row)
                above = self.unmeasured.integerLessThan(row)
            }
        }
        return result
    }

    /// The window of rows worth measuring ahead of time, clamped to the transcript, given the rows
    /// the viewport padded by `screensAhead` screens covers.
    static func window(in range: Range<Int>, count: Int) -> ClosedRange<Int>? {
        guard count > 0, !range.isEmpty else { return nil }
        let low = max(range.lowerBound, 0), high = min(range.upperBound - 1, count - 1)
        return low <= high ? low...high : nil
    }
}
