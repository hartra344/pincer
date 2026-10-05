import Foundation
import PincerKit

@MainActor func runSoloSessionBudgetCoverageChecks() async {
    #if DEBUG && os(macOS)
    do {
        let evidence = try await inspectSoloSessionBudgetCoverage(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        check(evidence.status == 0, "actual prebuilt solo lane exits successfully")
        check(evidence.existingPerfControlsPassed, "existing actual solo perf controls remain enforced")
        check(evidence.actualSessionTimingPrinted, "actual solo lane prints 300-session timing")
        check(evidence.actualSessionCounterControlsPassed, "actual session invalidation counters remain enforced")
        check(evidence.actualSessionBudgetObserved, "actual perf-smoke mode reports unchanged 50 ms budget with --skip-perf-budgets")
    } catch { check(false, "actual solo session budget coverage setup: \(error)") }
    #endif
}
