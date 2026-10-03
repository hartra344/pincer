import Darwin
import Foundation

private struct BundleLocationHarnessResult: Sendable {
    var status: Int32
    var timedOut: Bool
    var outputWasTruncated: Bool
    var output: String
}

private func runBundleHarness(script: URL) -> BundleLocationHarnessResult {
    let outputLimit = 32 * 1024
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script.path]
    process.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
    process.standardOutput = pipe
    process.standardError = pipe.fileHandleForWriting

    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        return BundleLocationHarnessResult(status: -1, timedOut: false, outputWasTruncated: false,
                                           output: "Could not configure bounded bundle harness output")
    }

    do {
        try process.run()
    } catch {
        return BundleLocationHarnessResult(status: -1, timedOut: false, outputWasTruncated: false,
                                           output: "Could not start bundle harness: \(error)")
    }

    var bytes = Data()
    var outputWasTruncated = false
    var reachedEOF = false
    func drainAvailableOutput() {
        guard !reachedEOF else { return }
        for _ in 0..<8 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let available = outputLimit - bytes.count
                if available > 0 { bytes.append(contentsOf: buffer.prefix(min(count, available))) }
                if count > max(available, 0) { outputWasTruncated = true }
            } else if count == 0 {
                reachedEOF = true
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            } else {
                reachedEOF = true
                return
            }
        }
    }

    let deadline = ContinuousClock.now + .seconds(30)
    while process.isRunning && ContinuousClock.now < deadline {
        drainAvailableOutput()
        Thread.sleep(forTimeInterval: 0.025)
    }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
        let terminationDeadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < terminationDeadline {
            drainAvailableOutput()
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            // The PID is the child launched above and is still reported running, so it cannot
            // have been recycled. Never signal a process group or any unrelated process.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killDeadline = ContinuousClock.now + .seconds(2)
            while process.isRunning && ContinuousClock.now < killDeadline {
                drainAvailableOutput()
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }

    try? pipe.fileHandleForWriting.close()
    if !process.isRunning { process.waitUntilExit() }
    let finalDrainDeadline = ContinuousClock.now + .milliseconds(100)
    while !reachedEOF && ContinuousClock.now < finalDrainDeadline {
        drainAvailableOutput()
        if !reachedEOF { Thread.sleep(forTimeInterval: 0.005) }
    }
    try? pipe.fileHandleForReading.close()
    return BundleLocationHarnessResult(status: process.isRunning ? -1 : process.terminationStatus,
                                       timedOut: timedOut, outputWasTruncated: outputWasTruncated,
                                       output: String(decoding: bytes, as: UTF8.self))
}

/// Runs the actual fake-tool bundle harness in isolation; no Xcode or Apple build tools are used.
@MainActor
func runBundleLocationPurposeChecks() async {
    let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/test_bundle_mac_namespace.py")
    let result = await Task.detached(priority: .utility) { runBundleHarness(script: script) }.value

    check(!result.timedOut, "macOS bundle purpose harness completes within 30 seconds")
    check(!result.outputWasTruncated, "macOS bundle purpose harness output stays within 32 KiB")
    check(result.status == 0, "macOS bundle contains the configured location purpose string\n\(result.output)")
}
