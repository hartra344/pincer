#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SettingsDiscoveryWorkerTests {
    @Test func actualSettingsDiscoveryAllowsSamePriorityContinuation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/PincerChecks")
        let ordinary = try await runSettingsDiscoveryWorkerGateChild(executable: executable, ordinary: true)
        let ordinaryEvidence = try #require(ordinary.evidence)
        try #require(ordinary.ownedChildNormalExit && ordinary.status == 0 && !ordinaryEvidence.heldMode && ordinaryEvidence.passed, "ordinary actual discovery prerequisite: \(ordinaryEvidence)")
        let result = try await runSettingsDiscoveryWorkerGateChild(executable: executable)
        let evidence = try #require(result.evidence)
        try #require(result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1), "owned child completed coherently: \(evidence)")
        try #require(evidence.heldMode && evidence.prerequisites, "actual held discovery prerequisites: \(evidence)")
        #expect(evidence.continuationBeforeFallback, "same measured priority continuation before external fallback: \(evidence)")
    }
}
#endif
