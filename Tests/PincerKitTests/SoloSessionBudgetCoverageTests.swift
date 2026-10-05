#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SoloSessionBudgetCoverageTests {
    @Test func actualSoloLaneIncludesExistingSessionRowBudgetObservation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let evidence = try await inspectSoloSessionBudgetCoverage(executable: root.appendingPathComponent(".build/debug/PincerChecks"))
        try #require(evidence.status == 0, "Unqualified perf setup: \(evidence.diagnostics)")
        try #require(evidence.existingPerfControlsPassed, "Unqualified perf setup: \(evidence.diagnostics)")
        #expect(evidence.actualSessionTimingPrinted)
        #expect(evidence.actualSessionCounterControlsPassed)
        #expect(evidence.actualSessionBudgetObserved)
    }
}
#endif
