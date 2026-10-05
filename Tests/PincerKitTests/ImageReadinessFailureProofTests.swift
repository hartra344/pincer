#if DEBUG && os(macOS)
import Testing
@testable import PincerKit
@Suite(.timeLimit(.minutes(2)))
struct ImageReadinessFailureProofTests {
    @Test func missingActualThumbnailFinishesAsFailedTestInsteadOfAbort() async throws {
        let evidence = try await imageReadinessFailureProof()
        try #require(evidence.ordinaryPassed, "Actual selected ordinary image child: \(evidence.diagnostics)")
        try #require(evidence.missingQualified, "Actual missing readiness boundary prerequisite: \(evidence.diagnostics)")
        #expect(evidence.missingNormalFailedCompletion, "Missing image must finish an actual FAILED one-test run: \(evidence.diagnostics)")
    }
}
#endif
