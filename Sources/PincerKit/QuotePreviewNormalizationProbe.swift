#if DEBUG
import Foundation
import os

/// Opt-in observation beside actual quote normalization. Only admitted identities and counts
/// are retained, never a quote's text or an unbounded event log.
package final class QuotePreviewNormalizationProbe: Sendable {
    private struct Counts {
        var mainCount = 0
        var offMainCount = 0
    }
    private let messageIDs: Set<String>
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    package init(messageIDs: [String]) {
        precondition(messageIDs.count <= 16 && messageIDs.allSatisfy {
            guard !$0.isEmpty, $0.isContiguousUTF8 else { return false }
            return $0.utf8.withContiguousStorageIfAvailable { $0.count <= 256 } == true
        })
        self.messageIDs = Set(messageIDs)
    }

    package func record(messageID: String) {
        guard self.messageIDs.contains(messageID) else { return }
        let onMain = Thread.isMainThread
        self.counts.withLock {
            guard $0.mainCount + $0.offMainCount < 256 else { return }
            if onMain { $0.mainCount += 1 } else { $0.offMainCount += 1 }
        }
    }

    package func snapshot() -> (mainCount: Int, offMainCount: Int) {
        self.counts.withLock { ($0.mainCount, $0.offMainCount) }
    }
}
#endif
