import Foundation

/// Rough cold geometry only. Exact off-main layout replaces it when premeasurement finishes.
/// Unknown/truncated content receives a fixed allowance, not an asserted upper bound.
package struct ColdTranscriptFootprint: Sendable {
    package static let byteLimit = 16 * 1024
    package static let visitLimit = 64
    package var lines: Double = 1
    package var hasRawText = false
    package var textSourceCount = 0
    package var hasImages = false
    package var fileCount = 0
    package var reactionCount = 0
    package var inspectedBytes = 0
    package var metadataVisits = 0
    package var incomplete = false
    package var extraHeight: Double { self.incomplete ? 240 : 0 }

    @MainActor package static func estimate(_ entry: TranscriptEntry, charactersPerLine: Double,
                                           hasReactions: (String) -> Bool = { _ in false }) -> Self {
        var result = Self()
        let wrapping = charactersPerLine.isFinite ? max(10, charactersPerLine) : 10
        var closedLines: Double = 0
        var scalars: Double = 0
        var seenText = 0
        func newline() {
            closedLines += max(1, (scalars / wrapping).rounded(.up))
            scalars = 0
        }
        func visit() -> Bool {
            guard result.metadataVisits < Self.visitLimit else { result.incomplete = true; return false }
            result.metadataVisits += 1
            return true
        }
        func text(_ text: String) {
            if seenText > 0 { newline(); newline(); result.hasRawText = true }
            seenText += 1
            guard text.isContiguousUTF8 else { result.incomplete = true; result.hasRawText = true; return }
            guard text.utf8.withContiguousStorageIfAvailable({ buffer -> Bool in
                if !buffer.isEmpty { result.hasRawText = true }
                let remaining = Self.byteLimit - result.inspectedBytes
                let admitted = min(remaining, buffer.count)
                if admitted < buffer.count { result.incomplete = true }
                result.inspectedBytes += admitted
                for byte in buffer.prefix(admitted) {
                    if byte == 10 { newline() }
                    else if byte & 0xC0 != 0x80 { scalars += 1 }
                }
                return true
            }) == true else { result.incomplete = true; result.hasRawText = true; return }
        }
        func reaction(_ id: String?, eligible: () -> Bool = { true }) {
            guard let id else { return }
            guard visit() else { result.reactionCount += 1; return }
            // Refuse foreign/oversized lookup keys rather than hash unbounded metadata on Main.
            guard id.isContiguousUTF8,
                  id.utf8.withContiguousStorageIfAvailable({ $0.count <= 256 }) == true else {
                result.incomplete = true; result.reactionCount += 1; return
            }
            guard eligible() else { return }
            if hasReactions(id) { result.reactionCount += 1 }
        }
        switch entry {
        case .marker: return result
        case let .user(item):
            for block in item.blocks {
                guard visit() else { break }
                switch block {
                case let .text(value): result.textSourceCount += 1; text(value)
                case .image: result.hasImages = true
                case .file: result.fileCount += 1
                default: break
                }
            }
            if result.metadataVisits < item.blocks.count { result.incomplete = true; result.hasRawText = true }
            reaction(item.transcriptId, eligible: { item.isReplyable })
        case let .assistant(turn):
            result.textSourceCount = turn.text.count
            result.hasImages = !turn.images.isEmpty
            result.fileCount = turn.files.count
            for source in turn.text {
                guard visit() else { break }
                text(source)
            }
            for id in turn.textIds {
                guard result.metadataVisits < Self.visitLimit else {
                    result.incomplete = true; result.reactionCount += 1; break
                }
                // Nil IDs still consume a metadata visit.
                if id == nil { _ = visit() } else { reaction(id) }
            }
        }
        result.lines = closedLines + max(1, (scalars / wrapping).rounded(.up))
        return result
    }
}
