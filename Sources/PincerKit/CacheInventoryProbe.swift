#if DEBUG
import Foundation

/// One store's actual directory enumerations; no paths, names or payloads are retained.
package final class CacheInventoryProbe: @unchecked Sendable {
    package struct Counts: Sendable { package var main = 0; package var offMain = 0 }
    private let lock = NSLock()
    private var counts = Counts()
    package init() {}
    package func record() {
        self.lock.withLock {
            guard self.counts.main + self.counts.offMain < 32 else { return }
            if Thread.isMainThread { self.counts.main += 1 } else { self.counts.offMain += 1 }
        }
    }
    package func snapshot() -> Counts { self.lock.withLock { self.counts } }
}
#endif
