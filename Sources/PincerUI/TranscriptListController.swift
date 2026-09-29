import CoreGraphics
import Foundation
import PincerKit

/// Where the reader is anchored in the transcript: following the end, or a row and how far its
/// top sits below the top of the viewport.
enum TranscriptAnchor: Equatable {
    case bottom
    case row(String, CGFloat)
}

/// A row's height and whether it came from a real layout at `width` or only an estimate.
struct TranscriptRowHeight {
    var value: CGFloat
    var width: CGFloat
    var measured: Bool

    func isCurrent(at width: CGFloat) -> Bool { self.measured && self.width == width }
}

/// Platform-free logic shared by the AppKit and UIKit transcript lists; scrolling, cells and
/// table/collection updates stay in the views.
enum TranscriptListController {
    /// How a new row list relates to the current one.
    enum RowsChange: Equatable {
        /// Same ids, only the last row differs: one in-place update, no diffing.
        case streamingTail
        case other
    }

    static func classify(old: [TranscriptRow], new: [TranscriptRow]) -> RowsChange {
        if let last = new.last, old.count == new.count, old.last?.id == last.id, old.dropLast() == new.dropLast() {
            return .streamingTail
        }
        return .other
    }

    /// A height counts as changed only when it moved by more than half a point (or is new).
    static func heightMoved(from old: CGFloat?, to new: CGFloat) -> Bool {
        old.map { abs($0 - new) > 0.5 } ?? true
    }

    /// Whether the reader is close enough to the end to follow it.
    static func isAtBottom(maxOffset: CGFloat, offset: CGFloat, stickDistance: CGFloat) -> Bool {
        maxOffset - offset <= stickDistance
    }

    /// The scroll offset that puts `anchor` back where it was; `nil` if its row is gone.
    static func restoreTarget(for anchor: TranscriptAnchor, rowTop: (String) -> CGFloat?,
                              range: ClosedRange<CGFloat>) -> CGFloat?
    {
        switch anchor {
        case .bottom:
            return range.upperBound
        case let .row(id, offset):
            guard let top = rowTop(id) else { return nil }
            return min(max(top - offset, range.lowerBound), range.upperBound)
        }
    }

    /// The anchor that shows a row's match a little above the middle of the visible area.
    static func revealAnchor(id: String, insetTop: CGFloat, visibleHeight: CGFloat,
                             matchY: CGFloat?, rowHeight: CGFloat) -> TranscriptAnchor
    {
        let y = min(matchY ?? 0, rowHeight)
        return .row(id, insetTop + visibleHeight * 0.4 - y)
    }

    /// Single entry point for the background height prefetch (walk order and slicing).
    ///
    /// Walks outward from `center` (below, above, below, above…), skipping rows for which
    /// `isMeasured` is true and calling `measure` (which returns whether the height moved) on the
    /// rest until `budget` seconds have passed. `remaining` means the budget ran out first.
    static func prefetchSlice(rows: [TranscriptRow], center: Int, budget: TimeInterval,
                              isMeasured: (TranscriptRow) -> Bool,
                              measure: (Int, TranscriptRow) -> Bool) -> (changed: IndexSet, remaining: Bool)
    {
        let deadline = Date().addingTimeInterval(budget)
        var changed = IndexSet()
        var remaining = false
        var below = center, above = center - 1
        while below < rows.count || above >= 0 {
            for row in [below, above] where row >= 0 && row < rows.count {
                let item = rows[row]
                if isMeasured(item) { continue }
                if Date() >= deadline { remaining = true; break }
                if measure(row, item) { changed.insert(row) }
            }
            if remaining { break }
            below += 1
            above -= 1
        }
        return (changed, remaining)
    }
}
