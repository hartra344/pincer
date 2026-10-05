#if DEBUG && os(macOS)
import PincerKit
@MainActor func runUnitNativeBacktraceProofChecks() async {
    do {
        let evidence = try await unitNativeBacktraceProof()
        check(evidence.ordinaryPassed, "actual single native child completes normally")
        guard evidence.ordinaryPassed else { print(evidence.diagnostics); return }
        check(evidence.crashOwnedStatus, "actual native SIGSEGV exit and owned PID match")
        guard evidence.crashOwnedStatus else { print(evidence.diagnostics); return }
        check(evidence.crashBacktracePassed, "actual owned Swift signal retains native header and fixture frame: \(evidence.diagnostics)")
    } catch { check(false, "actual native backtrace child setup: \(error)") }
}
#endif
