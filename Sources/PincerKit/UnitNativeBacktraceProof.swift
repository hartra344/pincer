#if DEBUG && os(macOS)
import Foundation
import Darwin

package struct UnitNativeBacktraceEvidence: Sendable {
    package let ordinaryPassed: Bool
    package let crashBacktracePassed: Bool
    package let crashOwnedStatus: Bool
    package let ordinaryStatus: Int32
    package let crashStatus: Int32
    package let diagnostics: String
}

/// Runs only the actual owned Swift child; never invokes a broad test command.
package func unitNativeBacktraceProof() async throws -> UnitNativeBacktraceEvidence {
    guard ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"] == nil else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { @Sendable in
        do {
        let evidence = try { () throws -> UnitNativeBacktraceEvidence in
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
        let platformLookup = Process(), platformPipe = Pipe()
        platformLookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        platformLookup.arguments = ["--sdk", "macosx", "--show-sdk-platform-path"]
        platformLookup.standardOutput = platformPipe; platformLookup.standardError = FileHandle.nullDevice
        try platformLookup.run()
        try finish(platformLookup, seconds: 5)
        let platformData = platformPipe.fileHandleForReading.readDataToEndOfFile()
        guard platformLookup.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        let platform = URL(fileURLWithPath: String(decoding: platformData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let frameworks = platform.appendingPathComponent("Developer/Library/Frameworks")
        guard FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("XCTest.framework").path) else {
            throw CocoaError(.executableNotLoadable)
        }
        let kit = root.appendingPathComponent(".build/debug/PincerKitTests.xctest/Contents/MacOS/PincerKitTests")
        let aggregate = root.appendingPathComponent(".build/debug/PincerPackageTests.xctest/Contents/MacOS/PincerPackageTests")
        let bundle = FileManager.default.isExecutableFile(atPath: kit.path) ? kit : aggregate
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.isExecutableFile(atPath: bundle.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        let libraries = platform.appendingPathComponent("Developer/usr/lib")
        guard FileManager.default.fileExists(atPath: libraries.appendingPathComponent("libXCTestSwiftSupport.dylib").path) else {
            throw CocoaError(.executableNotLoadable)
        }
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        guard let python = pathEntries.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("python3") })
            .first(where: { $0.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CocoaError(.executableNotLoadable)
        }
        func child(_ mode: String) throws -> (Int32, Bool, String, Bool) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-backtrace-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = dir.appendingPathComponent("output.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = python
            process.arguments = [root.appendingPathComponent("scripts/checks-unit-command.py").path, helper.path, "--test-bundle-path", bundle.path, "--testing-library", "swift-testing", "--filter", "UnitNativeBacktraceProofTests/actualOwnedSwiftCrashChild"]
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            let inheritedFrameworks = env["DYLD_FRAMEWORK_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            env["DYLD_FRAMEWORK_PATH"] = frameworks.path + (inheritedFrameworks.map { ":" + $0 } ?? "")
            let inheritedLibraries = env["DYLD_LIBRARY_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            env["DYLD_LIBRARY_PATH"] = libraries.path + (inheritedLibraries.map { ":" + $0 } ?? "")
            env["PINCER_NATIVE_BACKTRACE_CHILD"] = mode
            env["PINCER_DEV_NAMESPACE"] = "backtrace-" + UUID().uuidString
            env["PINCER_KEYCHAIN"] = "memory"
            env["CHECKS_LOG_DIR"] = dir.path
            env["CHECKS_UNIT_TIMEOUT_SECONDS"] = "15"
            env["SWIFT_BACKTRACE"] = nil
            process.environment = env; process.standardOutput = handle; process.standardError = handle
            try process.run()
            try finish(process, seconds: 75)
            try handle.synchronize()
            let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
            let summaryPattern = #"Test run with 1 test(?: in 1 suite)? passed[^\n]*"#
            let summaries = try NSRegularExpression(pattern: summaryPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let functionPattern = #"Test [^\n]*actualOwnedSwiftCrashChild[^\n]* passed[^\n]*"#
            let functions = try NSRegularExpression(pattern: functionPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let passed = process.terminationReason == .exit && process.terminationStatus == 0
                && text.components(separatedBy: "PINCER_NATIVE_BACKTRACE_CHILD_BEGIN").count == 2
                && text.components(separatedBy: "PINCER_NATIVE_BACKTRACE_CHILD_COMPLETE").count == 2
                && summaries == 1 && functions == 1
            let metadata = (try? Data(contentsOf: dir.appendingPathComponent("unit-command-exit.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let crash = mode == "crash"
            let pid = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("PINCER_NATIVE_CRASH_PID=") }.flatMap { Int($0.dropFirst("PINCER_NATIVE_CRASH_PID=".count)) }
            let ownedPid = metadata?["ownedPid"] as? Int
            let crashStatus = process.terminationStatus == 139 && (metadata?["ownedReturnCode"] as? Int) == -11 && (pid ?? 0) > 0 && (ownedPid ?? 0) > 0 && pid == ownedPid
                && text.components(separatedBy: "PINCER_NATIVE_CRASH_PID=").count == 2
                && text.components(separatedBy: "PINCER_NATIVE_BACKTRACE_CHILD_BEGIN").count == 2
            let crashEvidence = text.contains("Signal 11") && text.contains("pincerOwnedSwiftCrashFrameForTesting")
            return (process.terminationStatus, crash ? crashStatus && crashEvidence : passed, String(text.suffix(16_384)), crashStatus)
        }
        let ordinary = try child("ordinary")
        guard ordinary.1 else { return UnitNativeBacktraceEvidence(ordinaryPassed: false, crashBacktracePassed: false, crashOwnedStatus: false, ordinaryStatus: ordinary.0, crashStatus: -1, diagnostics: ordinary.2) }
        let crashed = try child("crash")
        return UnitNativeBacktraceEvidence(ordinaryPassed: ordinary.1, crashBacktracePassed: crashed.1, crashOwnedStatus: crashed.3, ordinaryStatus: ordinary.0, crashStatus: crashed.0, diagnostics: crashed.2)
        }()
        continuation.resume(returning: evidence)
        } catch { continuation.resume(throwing: error) }
        }
    }
}
#endif
