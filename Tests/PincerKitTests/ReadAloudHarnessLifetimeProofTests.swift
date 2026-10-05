#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit
@Suite(.timeLimit(.minutes(2)))
struct ReadAloudHarnessLifetimeProofTests {
    @Test func releasedActualHarnessDoesNotAbortItsQueuedControllerTask() async throws {
        let evidence = try await readAloudHarnessLifetimeProof()
        try #require(evidence.retainedPassed, "exact selected ordinary child must complete: \(evidence.diagnostics)")
        #expect(evidence.releasedPassed, "released actual Harness child must finish normally, status \(evidence.releasedStatus): \(evidence.diagnostics)")
    }
}
#endif
