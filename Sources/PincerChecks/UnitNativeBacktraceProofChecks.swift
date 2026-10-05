#if DEBUG && os(macOS)
import Foundation
import PincerKit
@MainActor func runUnitNativeBacktraceProofChecks() async {
    do {
        let evidence = try await unitNativeBacktraceProof()
        let phases = await Task.detached(priority: .utility) {
            String(decoding: (try? JSONEncoder().encode(evidence.phases)) ?? Data(), as: UTF8.self)
        }.value
        print("Native control observed phases: \(phases)")
        check(evidence.ordinaryPassed, "actual single native child completes normally")
        guard evidence.ordinaryPassed else { print(evidence.diagnostics); return }
        check(evidence.crashOwnedStatus, "actual native SIGSEGV exit and owned PID match")
        guard evidence.crashOwnedStatus else { print(evidence.diagnostics); return }
        check(evidence.crashBacktracePassed, "actual owned Swift signal retains native header and fixture frame: \(evidence.diagnostics)")
        check(evidence.phases.count == 2 && evidence.phases.map(\.mode) == ["ordinary", "crash"]
              && evidence.phases.allSatisfy(\.observationsFollowLaunch)
              && evidence.phases.allSatisfy { $0.wrapperExitMilliseconds != nil },
              "actual control launches precede available observations and wrapper exits recorded")
        let retention = try await unitNativeRetentionProof()
        check(retention.actualFailureQualified, "actual deliberately disabled backtrace control qualifies failure")
        check(retention.retainedOwnedArtifacts && retention.boundedManifest,
              "actual failed control retains bounded owned output and metadata")
    } catch { check(false, "actual native backtrace child setup: \(error)") }
}
#endif
