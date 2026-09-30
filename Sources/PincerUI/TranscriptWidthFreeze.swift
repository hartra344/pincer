import CoreGraphics
import Foundation

/// Tracks whether the transcript should keep laying out at its previous width while the clip view's
/// width is animating (sidebar/inspector slides, live window resize). Pure and deterministic: time
/// is injected so tests don't need a run loop.
struct TranscriptWidthFreeze {
    static let quietInterval: TimeInterval = 0.1
    /// Longest the thaw waits for the worker to measure the window around the viewport at the final width.
    static let prewarmBudget: TimeInterval = 0.05

    /// The width layout keeps using while frozen.
    private(set) var frozenWidth: CGFloat?
    private(set) var lastChange: TimeInterval?

    var isFrozen: Bool { self.frozenWidth != nil }

    /// A new live width was observed. Freezes at `old` on the first change and records the time.
    /// Returns true when the caller should schedule (or extend) a thaw.
    @discardableResult
    mutating func widthChanged(from old: CGFloat, to new: CGFloat, at now: TimeInterval) -> Bool {
        guard old != new else { return false }
        if self.frozenWidth == nil { self.frozenWidth = old }
        self.lastChange = now
        // Back at the frozen width: nothing left to relayout, but still let the thaw run.
        return true
    }

    /// Whether the width has been stable for `quietInterval`.
    func isQuiet(at now: TimeInterval) -> Bool {
        guard let last = self.lastChange else { return true }
        return now - last >= Self.quietInterval
    }

    /// Time until a thaw is due, given the last change (for rescheduling a timer).
    func remainingQuiet(at now: TimeInterval) -> TimeInterval {
        guard let last = self.lastChange else { return 0 }
        return max(0, Self.quietInterval - (now - last))
    }

    /// Ends the freeze. Returns the width that was frozen, or nil when not frozen.
    @discardableResult
    mutating func thaw() -> CGFloat? {
        defer {
            self.frozenWidth = nil
            self.lastChange = nil
        }
        return self.frozenWidth
    }
}
