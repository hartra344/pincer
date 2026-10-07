import Foundation
import PincerKit

/// A left chat's measured row heights, kept so coming back skips measuring them again. Only measured
/// heights are stored, with the row they were measured for so an edited row is re-measured.
/// A revisit gets a fresh `TranscriptDisclosure` (#571), so heights are only kept while every card
/// is at its default: see `TranscriptDisclosure.isPristine`.
struct TranscriptHeightSnapshot {
    weak var chat: ChatStore?
    let agent: AgentSummary
    let settings: TranscriptSettings
    let entries: [String: (row: TranscriptRow, height: TranscriptRowHeight)]
}
