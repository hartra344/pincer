#if DEBUG && os(macOS)
import Foundation
import Darwin

package struct ReadAloudHarnessLifetimeEvidence: Sendable {
    package let retainedPassed: Bool
    package let releasedPassed: Bool
    package let retainedStatus: Int32
    package let releasedStatus: Int32
}

/// Runs only the actual private Harness child; never invokes a broad test command.
package func readAloudHarnessLifetimeProof() async throws -> ReadAloudHarnessLifetimeEvidence {
    guard ProcessInfo.processInfo.environment["PINCER_READ_ALOUD_LIFETIME_CHILD"] == nil else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try await Task.detached(priority: .utility) {
        let lookup = Process(), pipe = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "swift"]
        lookup.standardOutput = pipe; lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        guard lookup.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        let swift = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let helper = swift.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
        let kit = root.appendingPathComponent(".build/debug/PincerKitTests.xctest/Contents/MacOS/PincerKitTests")
        let aggregate = root.appendingPathComponent(".build/debug/PincerPackageTests.xctest/Contents/MacOS/PincerPackageTests")
        let bundle = FileManager.default.isExecutableFile(atPath: kit.path) ? kit : aggregate
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: bundle.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        func child(_ mode: String) throws -> (Int32, Bool) {
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
            let deadline = Date().addingTimeInterval(45)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                process.terminate()
                let stop = Date().addingTimeInterval(3)
                while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try handle.synchronize()
            let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
            let passed = process.terminationReason == .exit && process.terminationStatus == 0
                && text.contains("PINCER_LIFETIME_CHILD_BEGIN") && text.contains("PINCER_LIFETIME_CHILD_COMPLETE")
                && text.contains("with 1 test passed")
            return (process.terminationStatus, passed)
        }
        let retained = try child("retained")
        guard retained.1 else { return ReadAloudHarnessLifetimeEvidence(retainedPassed: false, releasedPassed: false, retainedStatus: retained.0, releasedStatus: -1) }
        let released = try child("released")
        return ReadAloudHarnessLifetimeEvidence(retainedPassed: retained.1, releasedPassed: released.1, retainedStatus: retained.0, releasedStatus: released.0)
    }.value
}
#endif
