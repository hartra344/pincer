#if DEBUG && os(macOS)
import Foundation
import Darwin

package struct SoloSessionBudgetCoverage: Sendable {
    package let status: Int32
    package let diagnostics: String
    package let existingPerfControlsPassed: Bool
    package let actualSessionTimingPrinted: Bool
    package let actualSessionCounterControlsPassed: Bool
    package let actualSessionBudgetObserved: Bool
}

/// Observe the actual prebuilt solo mode; no copied benchmark or invented timing is involved.
package func inspectSoloSessionBudgetCoverage(executable: URL) async throws -> SoloSessionBudgetCoverage {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do { continuation.resume(returning: try inspectSoloSessionBudgetSynchronously(executable: executable)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func inspectSoloSessionBudgetSynchronously(executable: URL) throws -> SoloSessionBudgetCoverage {
    let child = Process()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("solo-budget-output-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("output.txt")
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    child.executableURL = executable
    child.arguments = ["--perf-smoke", "--skip-perf-budgets"]
    var environment = ProcessInfo.processInfo.environment
    environment["PINCER_KEYCHAIN"] = "memory"
    environment["PINCER_DEV_NAMESPACE"] = "solo-session-budget-" + UUID().uuidString
    child.environment = environment
    child.standardOutput = output
    child.standardError = output
    try child.run()
    func waitForStop(seconds: Double) -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while child.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !child.isRunning
    }
    if !waitForStop(seconds: 30) {
        // Signal only the current owned Process while it is still running. Never wait forever
        // after a denied signal, and never use a saved PID after observing completion.
        if child.isRunning, kill(child.processIdentifier, SIGTERM) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        if !waitForStop(seconds: 3) {
            if child.isRunning, kill(child.processIdentifier, SIGKILL) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
            guard waitForStop(seconds: 3) else { throw CocoaError(.executableRuntimeMismatch) }
        }
    }
    child.waitUntilExit()
    try output.synchronize()
    let data = try Data(contentsOf: file)
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
    // Never forward arbitrary child output: retain canonical control labels and numeric
    // observations only, bounded to 16 lines / 2 KiB. The source uses the protected shared writer.
    var diagnosticLines = ["source: actual perf-smoke / protected shared transcript writer"]
    let labels = controls.map { String($0.dropFirst(2)) }
    for label in labels {
        if lines.contains("✓ " + label) { diagnosticLines.append("PASS " + label) }
        else if lines.contains(where: { $0.hasPrefix("✗ " + label + " (line") || $0 == "✗ " + label }) {
            diagnosticLines.append("FAIL " + label)
        } else { diagnosticLines.append("MISSING " + label) }
    }
    let numericPrefixes = [
        "· perf smoke: 2 × 5k messages saved and indexed in",
        "· perf smoke: selective query, median of 5:",
        "· perf smoke: append to a 5k chat saved and indexed in",
        "✗ cancelling one search doesn't interrupt another, larger index (",
        "✓ cancelling one search doesn't interrupt another, larger index (",
        "ms/event at 300 sessions (N=50): row change+sections=",
    ]
    let numberPattern = try NSRegularExpression(pattern: #"-?[0-9]+(?:\.[0-9]+)?"#)
    for (index, prefix) in numericPrefixes.enumerated() {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { continue }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let numbers = numberPattern.matches(in: line, range: range).prefix(16).compactMap { match in
            Range(match.range, in: line).map { String(line[$0]) }
        }
        diagnosticLines.append("observation[\(index)] numeric values: " + numbers.joined(separator: ","))
    }
    let diagnostics = String(diagnosticLines.prefix(16).joined(separator: "\n").prefix(2048))
    return SoloSessionBudgetCoverage(status: child.terminationStatus, diagnostics: diagnostics,
        existingPerfControlsPassed: controls.allSatisfy { lines.contains($0) },
        actualSessionTimingPrinted: lines.contains {
            $0.hasPrefix("ms/event at 300 sessions (N=50): row change+sections=") &&
            $0.contains("no-op event+sections=") && $0.contains("sections alone=")
        },
        actualSessionCounterControlsPassed:
            lines.contains { $0.hasPrefix("✓ isRunning invalidates only on run start (") } &&
            lines.contains("✓ sessionRow does not invalidate while streaming (0)") &&
            lines.contains("✓ identical sessions write does not invalidate"),
        actualSessionBudgetObserved: lines.contains {
            $0.hasPrefix("· sessions row event stays under 50 ms at 300 sessions") &&
            $0.contains("--skip-perf-budgets")
        })
}
#endif
