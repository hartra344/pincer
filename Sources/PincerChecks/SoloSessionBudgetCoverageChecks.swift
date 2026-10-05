import Foundation
import PincerKit

@MainActor func runSoloSessionBudgetCoverageChecks() async {
    #if DEBUG && os(macOS)
    do {
        let evidence = try await inspectSoloSessionBudgetCoverage(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        check(evidence.status == 0, "actual prebuilt solo lane exits successfully")
        check(evidence.existingPerfControlsPassed, "existing actual solo perf controls remain enforced")
        check(evidence.actualSessionTimingPrinted, "actual solo lane prints 300-session timing")
        check(evidence.actualSessionBudgetPassed, "actual solo lane enforces unchanged 50 ms session-row budget")
    } catch { check(false, "actual solo session budget coverage setup: \(error)") }
    #endif
}
