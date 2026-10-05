import Foundation

@MainActor func runChecksPendingProgressChecks() async {
    await checkActualRunner(arguments: ["--require-safe-identity"])
}

@MainActor func runUnitTerminalCompletionChecks() async {
    await checkActualRunner(arguments: ["--unit-start-only-control"])
    await checkActualRunner(arguments: ["--completed-control"])
}

@MainActor private func checkActualRunner(arguments: [String]) async {
    #if os(macOS)
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/test_checks_pending_progress.py")
    let result = await Task.detached {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch { return (Int32(-1), String(describing: error)) }
    }.value
    check(result.0 == 0, "actual runner verifies requested completion/status/cleanup control \(arguments): \(result.1)")
    #endif
}
