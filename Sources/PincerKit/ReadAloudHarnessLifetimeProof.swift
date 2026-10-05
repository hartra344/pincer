#if DEBUG && os(macOS)
import Foundation
import Darwin

package struct ReadAloudHarnessLifetimeEvidence: Sendable {
    package let retainedPassed: Bool
    package let releasedPassed: Bool
    package let retainedStatus: Int32
    package let releasedStatus: Int32
    package let diagnostics: String
}

/// Runs only the actual private Harness child; never invokes a broad test command.
package func readAloudHarnessLifetimeProof() async throws -> ReadAloudHarnessLifetimeEvidence {
    guard ProcessInfo.processInfo.environment["PINCER_READ_ALOUD_LIFETIME_CHILD"] == nil else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { @Sendable in
        do {
        let evidence = try { () throws -> ReadAloudHarnessLifetimeEvidence in
        let lookup = Process(), pipe = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "swift"]
        lookup.standardOutput = pipe; lookup.standardError = FileHandle.nullDevice
        func finish(_ process: Process, seconds: Double) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                guard kill(process.processIdentifier, SIGTERM) == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                let stop = Date().addingTimeInterval(3)
                while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning {
                    guard kill(process.processIdentifier, SIGKILL) == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                    let killed = Date().addingTimeInterval(3)
                    while process.isRunning && Date() < killed { Thread.sleep(forTimeInterval: 0.01) }
                }
            }
            guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
            process.waitUntilExit()
        }
        try lookup.run()
        try finish(lookup, seconds: 5)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard lookup.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        let swift = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let helper = swift.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
        let kit = root.appendingPathComponent(".build/debug/PincerKitTests.xctest/Contents/MacOS/PincerKitTests")
        let aggregate = root.appendingPathComponent(".build/debug/PincerPackageTests.xctest/Contents/MacOS/PincerPackageTests")
        let bundle = FileManager.default.isExecutableFile(atPath: kit.path) ? kit : aggregate
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: bundle.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        func child(_ mode: String) throws -> (Int32, Bool, String) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-lifetime-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = dir.appendingPathComponent("output.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing", "--filter", "ReadAloudControllerTests/actualHarnessLifetimeChild"]
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["PINCER_READ_ALOUD_LIFETIME_CHILD"] = mode
            env["PINCER_DEV_NAMESPACE"] = "lifetime-" + UUID().uuidString
            env["PINCER_KEYCHAIN"] = "memory"
            process.environment = env; process.standardOutput = handle; process.standardError = handle
            try process.run()
            try finish(process, seconds: 45)
            try handle.synchronize()
            let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
            let summaryPattern = #"Test run with 1 test(?: in 1 suite)? passed[^\n]*"#
            let summaries = try NSRegularExpression(pattern: summaryPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let functionPattern = #"Test [^\n]*actualHarnessLifetimeChild[^\n]* passed[^\n]*"#
            let functions = try NSRegularExpression(pattern: functionPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let passed = process.terminationReason == .exit && process.terminationStatus == 0
                && text.components(separatedBy: "PINCER_LIFETIME_CHILD_BEGIN").count == 2
                && text.components(separatedBy: "PINCER_LIFETIME_CHILD_COMPLETE").count == 2
                && summaries == 1 && functions == 1
            return (process.terminationStatus, passed, String(text.suffix(16_384)))
        }
        let retained = try child("retained")
        guard retained.1 else { return ReadAloudHarnessLifetimeEvidence(retainedPassed: false, releasedPassed: false, retainedStatus: retained.0, releasedStatus: -1, diagnostics: retained.2) }
        let released = try child("released")
        return ReadAloudHarnessLifetimeEvidence(retainedPassed: retained.1, releasedPassed: released.1, retainedStatus: retained.0, releasedStatus: released.0, diagnostics: released.2)
        }()
        continuation.resume(returning: evidence)
        } catch { continuation.resume(throwing: error) }
        }
    }
}
#endif
