import Foundation
import PincerKit

@MainActor func runSettingsDiscoveryWorkerChecks() async {
    #if DEBUG && os(macOS)
    do {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let ordinary = try await runSettingsDiscoveryWorkerGateChild(executable: executable, ordinary: true)
        guard let ordinaryEvidence = ordinary.evidence,
              ordinary.ownedChildNormalExit && ordinary.status == 0 && !ordinaryEvidence.heldMode && ordinaryEvidence.passed else {
            check(false, "ordinary actual Settings discovery prerequisite: \(String(describing: ordinary.evidence))")
            return
        }
        check(true, "ordinary actual Settings discovery output and task drain")
        let result = try await runSettingsDiscoveryWorkerGateChild(executable: executable)
        guard let evidence = result.evidence,
              result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1),
              evidence.heldMode && evidence.prerequisites else {
            check(false, "actual held Settings discovery prerequisites: \(String(describing: result.evidence))")
            return
        }
        check(true, "actual discovery call held off-main with matching priority and no early snapshot")
        check(true, "actual discovery completed exact voices and drained worker")
        check(evidence.continuationBeforeFallback, "same measured priority continuation before external fallback: \(evidence)")
    } catch { check(false, "Settings discovery owned child setup: \(error)") }
    #endif
}
