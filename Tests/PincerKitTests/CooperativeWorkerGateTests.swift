#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct CooperativeWorkerGateTests {
    @Test func actualHeldWorkerAllowsSameQoSContinuationBeforeFallback() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = try await runCooperativeWorkerGateChild(executable: root.appendingPathComponent(".build/debug/PincerChecks"))
        let evidence = try #require(result.evidence)
        #expect(evidence.strictEnvironment)
        #expect(evidence.actualLeaseHeld && evidence.noEarlyPublication)
        #expect(evidence.continuationBeforeFallback)
        #expect(evidence.exactCompletion && evidence.idleAfterCompletion)
        #expect(result.status == 0)
    }
}
#endif
