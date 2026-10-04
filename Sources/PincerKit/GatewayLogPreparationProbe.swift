#if DEBUG
import Foundation

/// One model's actual page work, with at most 128 observations per phase and no payload retention.
package final class GatewayLogPreparationProbe: @unchecked Sendable {
    package enum Phase { case parsing, rowPreparation }
    package struct Snapshot: Sendable {
        package var mainParses = 0
        package var offMainParses = 0
        package var mainRows = 0
        package var offMainRows = 0
    }
    private let lock = NSLock()
    private var counts = Snapshot()
    package init() {}
    package func record(_ phase: Phase) {
        self.lock.withLock {
            switch phase {
            case .parsing:
                guard self.counts.mainParses + self.counts.offMainParses < 128 else { return }
                if Thread.isMainThread { self.counts.mainParses += 1 } else { self.counts.offMainParses += 1 }
            case .rowPreparation:
                guard self.counts.mainRows + self.counts.offMainRows < 128 else { return }
                if Thread.isMainThread { self.counts.mainRows += 1 } else { self.counts.offMainRows += 1 }
            }
        }
    }
    package func snapshot() -> Snapshot { self.lock.withLock { self.counts } }
}
#endif
