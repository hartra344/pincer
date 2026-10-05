#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct RawWorkerGateTests {
    @Test func actualHeldWorkerAllowsSameQoSContinuationBeforeFallback() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/PincerChecks")
        let ordinary = try await runRawWorkerGateChild(executable: executable, ordinary: true)
        try #require(ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true)
        let result = try await runRawWorkerGateChild(executable: executable)
        let evidence = try #require(result.evidence)
        try #require(result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1))
        try #require(evidence.strictEnvironment && evidence.ordinaryPassed)
        try #require(evidence.actualLeaseHeld && evidence.noEarlyPublication)
        try #require(evidence.priorityRecorded && evidence.priorityMatched)
        try #require(evidence.bothTasksCapturedAndDrained)
        try #require(evidence.exactCompletion && evidence.idleAfterCompletion)
        #expect(evidence.continuationBeforeFallback, "Actual Raw validation worker controls: \(evidence)")
    }
}
#endif
