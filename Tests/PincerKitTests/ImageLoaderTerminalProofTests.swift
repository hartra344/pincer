#if DEBUG
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ImageLoaderTerminalProofTests {
    @Test func completedEvictingLoaderSatisfiesActualRSSProbeCompletion() async throws {
        let evidence = try await inspectImageLoaderTerminal()
        try #require(evidence.activeAtAdmission == 3)
        try #require(evidence.terminal)
        try #require(evidence.failures == 0 && evidence.exactPixels)
        #expect(evidence.retained == 1 && evidence.retained < evidence.admitted)
        #expect(evidence.probeReportsComplete)
    }
}
#endif
