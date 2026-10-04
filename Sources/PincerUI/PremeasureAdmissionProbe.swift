#if DEBUG
import Foundation
import Synchronization

/// Exact-ID, payload-free observations at real admission and worker boundaries.
enum PremeasureAdmissionProbe {
    enum Operation { case joinedSource, sourceSize, warmLookup, measured }
    struct Stats: Sendable, Equatable {
        var mainJoins = 0
        var mainSizes = 0
        var mainWarmLookups = 0
        var offMainMeasurements = 0
        var offMainJoins = 0
        var offMainSizes = 0
        var observedBytes = 0
        var records = 0
    }
    private static let storage = Mutex<[String: Stats]>([:])
    static func register(_ id: String) {
        guard id.isContiguousUTF8,
              id.utf8.withContiguousStorageIfAvailable({ !$0.isEmpty && $0.count <= 256 }) == true else { return }
        self.storage.withLock { values in
            guard values[id] != nil || values.count < 16 else { return }
            values[id] = Stats()
        }
    }
    static func remove(_ id: String) { self.storage.withLock { $0[id] = nil } }
    static func snapshot(_ id: String) -> Stats { self.storage.withLock { $0[id] ?? Stats() } }
    static func record(_ id: String, operation: Operation, source: String? = nil) {
        self.storage.withLock { values in
            guard var value = values[id], value.records < 256 else { return }
            value.records += 1
            let main = Thread.isMainThread
            switch operation {
            case .joinedSource: if main { value.mainJoins += 1 } else { value.offMainJoins += 1 }
            case .sourceSize: if main { value.mainSizes += 1 } else { value.offMainSizes += 1 }
            case .warmLookup: if main { value.mainWarmLookups += 1 }
            case .measured: if !main { value.offMainMeasurements += 1 }
            }
            if let source, source.isContiguousUTF8,
               let bytes = source.utf8.withContiguousStorageIfAvailable({ $0.count }) {
                value.observedBytes += min(bytes, Int.max / 512)
            }
            values[id] = value
        }
    }
}
#endif
