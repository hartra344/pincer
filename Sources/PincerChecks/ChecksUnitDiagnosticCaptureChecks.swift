import Foundation

@MainActor func runUnitDiagnosticCaptureChecks() async {
    #if os(macOS)
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test_checks_unit_diagnostics.py")
    let result = await Task.detached {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (Int32(-1), String(describing: error)) }
    }.value
    check(result.0 == 0, "actual owned sampler completion and denied-signal reporting: \(result.1)")
    #endif
}
