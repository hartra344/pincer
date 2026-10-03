#if DEBUG && os(macOS)
import Foundation

/// Exact-ID observation beside existing cold-label work. No text or models are retained.
@MainActor
final class ColdRotorLabelProbe {
    enum Operation { case fullTextJoin, characterPrefix, authorFormatting }
    private let rowIDs: Set<String>
    private var records = 0
    private(set) var mainFullTextJoins = 0
    private(set) var mainCharacterPrefixes = 0
    private(set) var mainAuthorFormattings = 0

    init(rowIDs: [String]) {
        precondition(rowIDs.count <= 16 && rowIDs.allSatisfy {
            $0.isContiguousUTF8 && $0.utf8.withContiguousStorageIfAvailable { $0.count <= 256 } == true
        })
        self.rowIDs = Set(rowIDs)
    }

    func record(_ operation: Operation, rowID: String) {
        guard self.records < 32, self.rowIDs.contains(rowID) else { return }
        self.records += 1
        guard Thread.isMainThread else { return }
        switch operation {
        case .fullTextJoin: self.mainFullTextJoins += 1
        case .characterPrefix: self.mainCharacterPrefixes += 1
        case .authorFormatting: self.mainAuthorFormattings += 1
        }
    }
}
#endif
