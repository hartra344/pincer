#if os(macOS)
import Foundation
import Testing

@Suite("Actual checks runner pending diagnostics", .serialized, .timeLimit(.minutes(2)))
struct ChecksPendingProgressTests {
    private func execute(_ arguments: [String]) async throws -> (Int32, String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test_checks_pending_progress.py")
        return try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path] + arguments
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
    @Test func heldFirstUnitLaneExposesBoundedPendingProgressBeforeCompletion() async throws {
        let result = try await execute([])
        #expect(result.0 == 0, "Actual run-checks.sh must expose bounded pending metadata before releasing the held unit lane: \(result.1)")
    }
    @Test func pendingUnitProgressContainsOnlyASafeTestIdentifier() async throws {
        let result = try await execute(["--require-safe-identity"])
        #expect(result.0 == 0, "Held unit test identity is visible without publishing its private log payload: \(result.1)")
    }
    @Test func interruptedRunnerCleansItsOwnedProgressReaderAndMocks() async throws {
        let result = try await execute(["--interrupt-control", "--require-safe-identity"])
        #expect(result.0 == 0, "Actual shell interruption leaves no owned monitor or mock processes: \(result.1)")
    }
    @Test func reusedLogDirectoryDoesNotHideThisRunsHeldUnitLane() async throws {
        let result = try await execute(["--stale-completion-control", "--require-safe-identity"])
        #expect(result.0 == 0, "Only current lane-owned completion markers are refreshed; unrelated files survive: \(result.1)")
    }
    @Test(arguments: [false, true]) func completedAndFailedLanesPreserveFinalReportsAndCleanup(_ failed: Bool) async throws {
        let result = try await execute([failed ? "--failed-lane-control" : "--completed-control"])
        #expect(result.0 == 0, "Actual runner's exit status, completed report and owned mock cleanup remain intact: \(result.1)")
    }
}
#endif
