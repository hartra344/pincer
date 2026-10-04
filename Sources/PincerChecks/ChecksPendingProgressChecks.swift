import Foundation

@MainActor func runChecksPendingProgressChecks() async {
    #if os(macOS)
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test_checks_pending_progress.py")
    let result = await Task.detached {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--require-safe-identity"]
        process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (Int32(-1), String(describing: error)) }
    }.value
    check(result.0 == 0, "actual runner exposes bounded pending lane metadata with unchanged completion/status/cleanup: \(result.1)")
    #endif
}
