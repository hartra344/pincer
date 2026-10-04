#if DEBUG
import Foundation
import Synchronization

/// Payload-free observation of the actual cold estimate normalization boundary.
enum ColdTranscriptHeightEstimateProbe {
    struct Stats: Sendable, Equatable {
        var operations = 0
        var joinedSources = 0
        var inputBytes = 0
        var metadataVisits = 0
    }
    private static let records = Mutex<[String: Stats]>([:])
    static func register(_ rowID: String) {
        guard rowID.isContiguousUTF8,
              rowID.utf8.withContiguousStorageIfAvailable({ !$0.isEmpty && $0.count <= 256 }) == true else { return }
        self.records.withLock { records in
            guard records[rowID] != nil || records.count < 16 else { return }
            records[rowID] = Stats()
        }
    }
    static func remove(_ rowID: String) { self.records.withLock { $0[rowID] = nil } }
    static func snapshot(_ rowID: String) -> Stats { self.records.withLock { $0[rowID] ?? Stats() } }
    static func recordWork(_ rowID: String, bytes: Int, visits: Int) {
        self.records.withLock { records in
            guard var value = records[rowID], value.operations < 256 else { return }
            value.operations += 1
            value.inputBytes += bytes
            value.metadataVisits += visits
            records[rowID] = value
        }
    }
    static func record(_ rowID: String, text: String, joined: Bool) {
        self.records.withLock { records in
            guard var value = records[rowID], value.operations < 256 else { return }
            value.operations += 1
            value.joinedSources += joined ? 1 : 0
            if text.isContiguousUTF8,
               let bytes = text.utf8.withContiguousStorageIfAvailable({ $0.count }) {
                value.inputBytes += min(bytes, Int.max / 512)
            }
            records[rowID] = value
        }
    }
}
#endif
