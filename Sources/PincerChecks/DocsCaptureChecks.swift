import Foundation

/// Exercises the app packager with fake Apple tools, so this stays fast and never starts a build.
@MainActor
func runDocsCaptureIsolationChecks() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "scripts/test_docs_capture_isolation.py"]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        check(process.terminationStatus == 0,
              "docs capture packaging uses isolated staging without real build tools\n\(log)")
    } catch {
        check(false, "docs capture isolation harness starts (\(error.localizedDescription))")
    }
}
