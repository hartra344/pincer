#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ShareWorkerGateTests {
    @Test func actualHeldWorkerAllowsSameQoSContinuationBeforeFallback() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/PincerChecks")
        let ordinary = try await runShareWorkerGateChild(executable: executable, ordinary: true)
        try #require(ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true)
        let result = try await runShareWorkerGateChild(executable: executable)
        let evidence = try #require(result.evidence)
        try #require(result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1))
        try #require(evidence.strictEnvironment && evidence.ordinaryPassed)
        try #require(evidence.actualLeaseHeld && evidence.noEarlyPublication)
        try #require(evidence.priorityRecorded && evidence.priorityMatched)
        try #require(evidence.bothTasksCapturedAndDrained && evidence.oldCancelled)
        try #require(evidence.exactCompletion && evidence.idleAfterCompletion)
        #expect(evidence.continuationBeforeFallback, "Actual Share worker controls: \(evidence)")
    }
}
#endif
