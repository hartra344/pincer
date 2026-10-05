#if os(macOS)
import Foundation
import Testing

@Suite(.timeLimit(.minutes(2)))
struct ChecksUnitDiagnosticCaptureTests {
    @Test func actualDiagnosticCommandsRetainStacksAndSignalFailureEvidence() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test_checks_unit_diagnostics.py")
        let result = try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path]
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        #expect(result.0 == 0, "Actual owned diagnostic subprocess controls: \(result.1)")
    }
}
#endif
