#if DEBUG && os(macOS)
import PincerKit
@MainActor func runImageReadinessFailureProofChecks() async {
    do {
        let evidence = try await imageReadinessFailureProof()
        check(evidence.ordinaryPassed, "actual ordinary image readiness child passes")
        guard evidence.ordinaryPassed else { print(evidence.diagnostics); return }
        check(evidence.missingQualified, "actual missing image readiness issue and owned child prerequisite")
        guard evidence.missingQualified else { print(evidence.diagnostics); return }
        check(evidence.missingNormalFailedCompletion, "missing image completes an actual failed test instead of abort: \(evidence.diagnostics)")
    } catch { check(false, "actual image readiness child setup: \(error)") }
}
#endif
