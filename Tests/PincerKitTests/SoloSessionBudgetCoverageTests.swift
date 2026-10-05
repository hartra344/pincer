#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SoloSessionBudgetCoverageTests {
    @Test func actualSoloLaneEnforcesExistingSessionRowBudget() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let evidence = try await inspectSoloSessionBudgetCoverage(executable: root.appendingPathComponent(".build/debug/PincerChecks"))
        #expect(evidence.status == 0)
        #expect(evidence.existingPerfControlsPassed)
        #expect(evidence.actualSessionTimingPrinted)
        #expect(evidence.actualSessionBudgetPassed)
    }
}
#endif
