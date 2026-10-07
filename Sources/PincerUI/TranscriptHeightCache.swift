import Foundation
import PincerKit

/// A left chat's measured row heights, kept so coming back skips measuring them again. Only measured
/// heights are stored, with the row they were measured for so an edited row is re-measured.
struct TranscriptHeightSnapshot {
    weak var chat: ChatStore?
    weak var disclosure: TranscriptDisclosure?
    let agent: AgentSummary
    let settings: TranscriptSettings
    let entries: [String: (row: TranscriptRow, height: TranscriptRowHeight)]
}
