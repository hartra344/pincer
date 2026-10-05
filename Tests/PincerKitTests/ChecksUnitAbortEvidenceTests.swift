#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ChecksUnitAbortEvidenceTests {
    @Test func actualAbortRetainsOwnedNonTimeoutEvidence() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test_checks_unit_abort_evidence.py")
        let result = try await runUnitAbortEvidenceFixture(script: script)
        #expect(result.0 == 0, "Actual owned diagnostic subprocess controls: \(result.1)")
    }
}
#endif
