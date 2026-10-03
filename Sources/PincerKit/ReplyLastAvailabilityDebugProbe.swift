import Foundation
import Synchronization

#if DEBUG
/// Observes the actual full-text availability boundary; retains only bounded IDs and counters.
package enum ReplyLastAvailabilityDebugProbe {
    package struct Stats: Equatable, Sendable {
        package var mainNormalizations = 0
        package var offMainNormalizations = 0
    }
    private static let records = Mutex<[String: Stats]>([:])
    package static var trackedCount: Int { self.records.withLock { $0.count } }
    package static func reset(tracking id: String) {
        guard id.isContiguousUTF8,
              let bytes = id.utf8.withContiguousStorageIfAvailable({ $0.count }), bytes <= 256 else { return }
        self.records.withLock { records in
            guard records[id] != nil || records.count < 16 else { return }
            records[id] = Stats()
        }
    }
    package static func stats(for id: String) -> Stats { self.records.withLock { $0[id] ?? Stats() } }
    package static func unregister(tracking id: String) { self.records.withLock { $0[id] = nil } }
    package static func record(tracking id: String) {
        let main = Thread.isMainThread
        self.records.withLock { records in
            guard var stats = records[id] else { return }
            if main { stats.mainNormalizations += 1 }
            else { stats.offMainNormalizations += 1 }
            records[id] = stats
        }
    }
}
#endif
