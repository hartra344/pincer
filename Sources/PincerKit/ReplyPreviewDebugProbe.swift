#if DEBUG
import Foundation
import Synchronization

/// Exact-message instrumentation for the real Reply preview preparation path. No text or model
/// snapshots enter this registry; both record count and retained identifier bytes are bounded.
package enum ReplyPreviewDebugProbe {
    package struct Stats: Sendable, Equatable {
        package var mainThreadNormalizations = 0
        package var offMainNormalizations = 0
    }

    private struct Record: Sendable {
        var stats = Stats()
        var lastUse: UInt64
    }

    private struct State: Sendable {
        static let capacity = 16
        static let identifierByteLimit = 128
        var records: [String: Record] = [:]
        var clock: UInt64 = 0
        mutating func tick() -> UInt64 { self.clock &+= 1; return self.clock }
    }

    private static let state = Mutex(State())

    package static func reset(tracking messageID: String) {
        guard messageID.utf8.prefix(State.identifierByteLimit + 1).count <= State.identifierByteLimit else { return }
        self.state.withLock { state in
            if state.records[messageID] == nil, state.records.count >= State.capacity,
               let oldest = state.records.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            { state.records[oldest] = nil }
            state.records[messageID] = Record(lastUse: state.tick())
        }
    }

    package static func stats(for messageID: String) -> Stats {
        self.state.withLock { state in
            guard var record = state.records[messageID] else { return Stats() }
            record.lastUse = state.tick()
            state.records[messageID] = record
            return record.stats
        }
    }

    package static func unregister(tracking messageID: String) {
        self.state.withLock { $0.records[messageID] = nil }
    }

    package static func recordNormalization(for messageID: String) {
        self.state.withLock { state in
            guard var record = state.records[messageID] else { return }
            if Thread.isMainThread { record.stats.mainThreadNormalizations += 1 }
            else { record.stats.offMainNormalizations += 1 }
            record.lastUse = state.tick()
            state.records[messageID] = record
        }
    }
}
#endif
