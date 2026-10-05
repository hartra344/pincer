#if DEBUG && os(macOS)
import Foundation

package struct SoloSessionBudgetCoverage: Sendable {
    package let status: Int32
    package let existingPerfControlsPassed: Bool
    package let actualSessionTimingPrinted: Bool
    package let actualSessionBudgetPassed: Bool
}

/// Observe the actual prebuilt solo mode; no copied benchmark or invented timing is involved.
package func inspectSoloSessionBudgetCoverage(executable: URL) async throws -> SoloSessionBudgetCoverage {
    try await Task.detached {
        let child = Process(), output = Pipe()
        child.executableURL = executable
        child.arguments = ["--perf-smoke"]
        var environment = ProcessInfo.processInfo.environment
        environment["PINCER_KEYCHAIN"] = "memory"
        environment["PINCER_DEV_NAMESPACE"] = "solo-session-budget-" + UUID().uuidString
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let terminate: @Sendable () -> Void = { if child.isRunning { child.terminate() } }
        let timeout = DispatchWorkItem(block: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let controls = [
            "✓ perf smoke: build under the absolute ceiling",
            "✓ perf smoke: selective query results",
            "✓ perf smoke: selective query under the absolute ceiling",
            "✓ perf smoke: appended message indexed",
            "✓ perf smoke: append under the absolute ceiling",
            "✓ perf smoke: append rewrites ≤ 1/5 of the bytes and fewer files than the full save",
        ]
        return SoloSessionBudgetCoverage(status: child.terminationStatus,
            existingPerfControlsPassed: controls.allSatisfy { lines.contains($0) },
            actualSessionTimingPrinted: lines.contains {
                $0.hasPrefix("ms/event at 300 sessions (N=50): row change+sections=") &&
                $0.contains("no-op event+sections=") && $0.contains("sections alone=")
            },
            actualSessionBudgetPassed: lines.contains("✓ sessions row event stays under 50 ms at 300 sessions"))
    }.value
}
#endif
