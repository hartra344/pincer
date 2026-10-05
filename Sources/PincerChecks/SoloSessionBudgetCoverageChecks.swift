import Foundation
import PincerKit

@MainActor func runSoloSessionBudgetCoverageChecks() async {
    #if DEBUG && os(macOS)
    do {
        let evidence = try await inspectSoloSessionBudgetCoverage(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        print("  · solo coverage diagnostics:\n\(evidence.diagnostics)")
        check(evidence.status == 0, "actual prebuilt solo lane exits successfully")
        check(evidence.existingPerfControlsPassed, "existing actual solo perf controls remain enforced")
        guard evidence.status == 0 && evidence.existingPerfControlsPassed else {
            print("  · solo routing qualification unavailable: actual perf setup failed")
            return
        }
        check(evidence.actualSessionTimingPrinted, "actual solo lane prints 300-session timing")
        check(evidence.actualSessionCounterControlsPassed, "actual session invalidation counters remain enforced")
        check(evidence.actualSessionBudgetObserved, "actual perf-smoke mode reports unchanged 50 ms budget with --skip-perf-budgets")
    } catch { check(false, "actual solo session budget coverage setup: \(error)") }
    #endif
}
