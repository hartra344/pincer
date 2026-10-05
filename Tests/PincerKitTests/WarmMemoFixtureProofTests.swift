#if DEBUG && os(macOS)
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct WarmMemoFixtureProofTests {
    @Test func actualTargetWarmMemoSurvivesHeldForeignOwner() async throws {
        let evidence = try await warmMemoFixtureProof()
        try #require(evidence.ordinaryPassed, "Actual UI ordinary warm/adopt prerequisite: \(evidence.diagnostics)")
        try #require(evidence.heldQualified, "Actual held foreign owner and completed real worker prerequisites: \(evidence.diagnostics)")
        #expect(evidence.targetWarmAdopted, "Actual target warm/adopt contract: \(evidence.diagnostics)")
    }
}
#endif
