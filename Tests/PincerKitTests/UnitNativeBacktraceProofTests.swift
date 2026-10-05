#if DEBUG && os(macOS)
import Foundation
import Darwin
import Testing
@testable import PincerKit

@inline(never) private func pincerOwnedSwiftCrashFrameForTesting() {
    UnsafeMutablePointer<UInt8>(bitPattern: 1)!.pointee = 0
    _exit(99)
}

@Suite(.timeLimit(.minutes(2)))
struct UnitNativeBacktraceProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"] != nil))
    func actualOwnedSwiftCrashChild() throws {
        let mode = ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"]
        try #require(mode == "ordinary" || mode == "crash")
        print("PINCER_NATIVE_BACKTRACE_CHILD_BEGIN")
        if mode == "crash" {
            var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
            let coreDisabled = Darwin.setrlimit(RLIMIT_CORE, &coreLimit)
            try #require(coreDisabled == 0)
            print("PINCER_NATIVE_CRASH_PID=\(getpid())")
            fflush(stdout)
            pincerOwnedSwiftCrashFrameForTesting()
        }
        print("PINCER_NATIVE_BACKTRACE_CHILD_COMPLETE")
    }
    @Test func actualOwnedSwiftSignalRetainsNativeBacktrace() async throws {
        let evidence = try await unitNativeBacktraceProof()
        try #require(evidence.ordinaryPassed, "Actual one-child ordinary prerequisite: \(evidence.diagnostics)")
        try #require(evidence.crashOwnedStatus, "Actual SIGSEGV/PID metadata prerequisite: \(evidence.diagnostics)")
        #expect(evidence.crashBacktracePassed, "Actual owned Swift signal backtrace: \(evidence.diagnostics)")
        try #require(evidence.phases.count == 2)
        #expect(evidence.phases.map(\.mode) == ["ordinary", "crash"])
        #expect(evidence.phases.allSatisfy { $0.observationsFollowLaunch })
        #expect(evidence.phases.allSatisfy { $0.wrapperExitMilliseconds != nil })
    }
    @Test func actualFailedNativeControlRetainsBoundedOwnedArtifacts() async throws {
        let evidence = try await unitNativeRetentionProof()
        try #require(evidence.actualFailureQualified)
        #expect(evidence.retainedOwnedArtifacts && evidence.boundedManifest)
    }
}
#endif
