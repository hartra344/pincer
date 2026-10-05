import Foundation
import PincerKit

@MainActor func runUnitAbortEvidenceChecks() async {
    #if DEBUG && os(macOS)
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test_checks_unit_abort_evidence.py")
    do {
        let result = try await runUnitAbortEvidenceFixture(script: script)
        check(result.0 == 0, "actual owned abort exit and non-timeout identity evidence: \(result.1)")
    } catch { check(false, "actual owned abort fixture setup: \(error)") }
    #endif
}

@MainActor func runUnitNativeEvidenceChecks() async {
    #if DEBUG && os(macOS)
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test_checks_unit_native_evidence.py")
    do {
        let result = try await runUnitAbortEvidenceFixture(script: script)
        check(result.0 == 0, "actual owned native identity and parser-only report selection: \(result.1)")
    } catch { check(false, "owned native evidence fixture setup: \(error)") }
    #endif
}
