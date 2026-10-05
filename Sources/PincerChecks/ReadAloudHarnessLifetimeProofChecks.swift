#if DEBUG && os(macOS)
@testable import PincerKit
@MainActor func runReadAloudHarnessLifetimeProofChecks() async {
    do {
        let evidence = try await readAloudHarnessLifetimeProof()
        check(evidence.retainedPassed, "exact ordinary actual Harness child completes")
        check(evidence.retainedPassed && evidence.releasedPassed, "released actual Harness child completes without abort")
    } catch { check(false, "owned Harness lifetime child setup succeeds") }
}
#endif
