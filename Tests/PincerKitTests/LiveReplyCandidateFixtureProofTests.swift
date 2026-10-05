#if DEBUG && os(macOS)
import Testing
@testable import PincerKit

@Suite struct LiveReplyCandidateFixtureProofTests {
    @Test(.timeLimit(.minutes(2)))
    func missingCandidateFailsNormallyAfterReadinessFailure() async throws {
        let evidence = try await liveReplyCandidateFixtureProof()
        print(evidence.diagnostics)
        try #require(evidence.ordinaryPassed)
        try #require(evidence.heldQualified)
        #expect(evidence.heldCompletedAsFailedTest)
    }
}
#endif
