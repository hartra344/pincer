#if DEBUG
import Foundation

/// Per-model, payload-free observation of actual search work. Recording stops after 256 operations.
package final class SettingsFieldSearchProbe: @unchecked Sendable {
    package enum Operation { case traversal, normalization, matching }
    package struct Snapshot: Sendable {
        package var mainTraversals = 0
        package var offMainTraversals = 0
        package var mainNormalizations = 0
        package var offMainNormalizations = 0
        package var mainMatches = 0
        package var offMainMatches = 0
    }
    private let lock = NSLock()
    private var recorded = 0
    private var counts = Snapshot()
    package init() {}
    package func record(_ operation: Operation) {
        self.lock.withLock {
            guard self.recorded < 256 else { return }
            self.recorded += 1
            switch (operation, Thread.isMainThread) {
            case (.traversal, true): self.counts.mainTraversals += 1
            case (.traversal, false): self.counts.offMainTraversals += 1
            case (.normalization, true): self.counts.mainNormalizations += 1
            case (.normalization, false): self.counts.offMainNormalizations += 1
            case (.matching, true): self.counts.mainMatches += 1
            case (.matching, false): self.counts.offMainMatches += 1
            }
        }
    }
    package func snapshot() -> Snapshot { self.lock.withLock { self.counts } }
}
#endif
