import Foundation
import PincerKit

@MainActor func runRawWorkerGateChecks() async {
    #if DEBUG && os(macOS)
    do {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let ordinary = try await runRawWorkerGateChild(executable: executable, ordinary: true)
        check(ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true, "actual ordinary Raw child completes full validation and baseline controls")
        guard ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true else { return }
        let result = try await runRawWorkerGateChild(executable: executable)
        guard let evidence = result.evidence else {
            check(false, "strict owned child completed with actual worker evidence")
            return
        }
        let prerequisites = result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1)
            && evidence.strictEnvironment && evidence.ordinaryPassed
            && evidence.actualLeaseHeld && evidence.noEarlyPublication
            && evidence.priorityRecorded && evidence.priorityMatched
            && evidence.bothTasksCapturedAndDrained
            && evidence.exactCompletion && evidence.idleAfterCompletion
        check(prerequisites, "actual Raw worker entry, priority, validation and baseline drain prerequisites: \(evidence)")
        guard prerequisites else { return }
        check(evidence.continuationBeforeFallback, "same-priority Raw continuation progresses before external fallback: \(evidence)")
    } catch { check(false, "strict owned Raw worker child setup: \(error)") }
    #endif
}
