#if DEBUG && os(macOS)
import Foundation
import PincerKit

@MainActor
func runLiveReplyCandidateFixtureProofChecks() async {
    do {
    let evidence = try await liveReplyCandidateFixtureProof()
    print(evidence.diagnostics)
    check(evidence.ordinaryPassed, "actual candidate ordinary output and FIFO cleanup control")
    guard evidence.ordinaryPassed else { return }
    check(evidence.heldQualified, "actual held candidate readiness failure and owned child qualify")
    guard evidence.heldQualified else { return }
    check(evidence.heldCompletedAsFailedTest, "missing actual candidate completes as failed test without native abort")
    } catch { check(false, "actual candidate child setup: \(error)") }
}
#endif
