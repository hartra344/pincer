#if DEBUG && os(macOS)
import PincerKit

@MainActor func runWarmMemoFixtureProofChecks() async {
    do {
        let evidence = try await warmMemoFixtureProof()
        check(evidence.cancellationPassed, "actual UI cancelled awaiter drains owned worker")
        guard evidence.cancellationPassed else { print(evidence.diagnostics); return }
        check(evidence.ordinaryPassed, "actual UI ordinary warm/adopt control")
        guard evidence.ordinaryPassed else { print(evidence.diagnostics); return }
        check(evidence.heldQualified, "actual held foreign owner and completed workers qualify warm memo control")
        guard evidence.heldQualified else { print(evidence.diagnostics); return }
        check(evidence.targetWarmAdopted, "actual target warm/adopt survives held foreign owner: \(evidence.diagnostics)")
    } catch { check(false, "actual UI warm memo child setup: \(error)") }
}
#endif
