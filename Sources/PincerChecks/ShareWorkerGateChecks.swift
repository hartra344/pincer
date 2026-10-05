import Foundation
import PincerKit

@MainActor func runShareWorkerGateChecks() async {
    #if DEBUG && os(macOS)
    do {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let ordinary = try await runShareWorkerGateChild(executable: executable, ordinary: true)
        check(ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true, "actual ordinary Share child completes full policy controls")
        guard ordinary.ownedChildNormalExit && ordinary.status == 0 && ordinary.evidence?.passed == true else { return }
        let result = try await runShareWorkerGateChild(executable: executable)
        guard let evidence = result.evidence else {
            check(false, "strict owned child completed with actual worker evidence")
            return
        }
        let prerequisites = result.ownedChildNormalExit && result.status == (evidence.passed ? 0 : 1)
            && evidence.strictEnvironment && evidence.ordinaryPassed
            && evidence.actualLeaseHeld && evidence.noEarlyPublication
            && evidence.priorityRecorded && evidence.priorityMatched
            && evidence.bothTasksCapturedAndDrained && evidence.oldCancelled
            && evidence.exactCompletion && evidence.idleAfterCompletion
        check(prerequisites, "actual Share worker entry, priority, policy and drain prerequisites: \(evidence)")
        guard prerequisites else { return }
        check(evidence.continuationBeforeFallback, "same-priority Share continuation progresses before external fallback: \(evidence)")
        check(evidence.serializedEvidence?.passed == true, "cancelled held Share lease serializes actual nil-probe preparation: \(evidence.serializedEvidence)")
    } catch { check(false, "strict owned Share worker child setup: \(error)") }
    #endif
}
