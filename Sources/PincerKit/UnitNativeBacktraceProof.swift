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
    package let phases: [UnitNativePhaseEvidence]
}


/// Times are observed offsets, not exact SDK events. Missing observations stay nil.
package struct UnitNativePhaseEvidence: Codable, Sendable {
    package let mode: String
    package let launchMilliseconds: Int64
    package var pidMarkerMilliseconds: Int64?
    package var headerMilliseconds: Int64?
    package var frameMilliseconds: Int64?
    package var childExitMetadataMilliseconds: Int64?
    package var captureCompleteMetadataMilliseconds: Int64?
    package var wrapperExitMilliseconds: Int64?
    package var retainedFailureDirectory: String?
    package var artifactCopyError: Bool = false
    package var observationBudgetExhausted: Bool = false
    package var retentionManifest: [UnitNativeRetainedFile] = []
    package var skippedByFileLimit = 0
    package var ignoredFileCount = 0
    package var observationsFollowLaunch: Bool {
        let values = [pidMarkerMilliseconds, headerMilliseconds, frameMilliseconds,
                      childExitMetadataMilliseconds, captureCompleteMetadataMilliseconds,
                      wrapperExitMilliseconds].compactMap { $0 }
        return values.allSatisfy { $0 >= launchMilliseconds }
        // Independent bounded file reads need not observe separate event streams in order.
    }
}

package struct UnitNativeRetainedFile: Codable, Sendable {
    package let name: String
    package let sourceBytes: Int64?
    package let copiedBytes: Int
    package let truncated: Bool
    package let outcome: String
    package let errnoCode: Int32?
}

/// Bounded regular-file read; never follows a fixture-created symlink.
private func nativePhaseBytes(_ url: URL, offset: Int64 = 0, cap: Int) -> Data? {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    var bytes = [UInt8](repeating: 0, count: cap)
    let count = pread(fd, &bytes, cap, off_t(offset))
    guard count >= 0 else { return nil }
    return Data(bytes.prefix(count))
}

/// Runs only the actual owned Swift child; never invokes a broad test command.
package func unitNativeBacktraceProof(backtraceOverrideForTesting: String? = nil, retentionRootForTesting: URL? = nil) async throws -> UnitNativeBacktraceEvidence {
    guard ProcessInfo.processInfo.environment["PINCER_NATIVE_BACKTRACE_CHILD"] == nil else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { @Sendable in
        do {
        let evidence = try { () throws -> UnitNativeBacktraceEvidence in
        let origin = ContinuousClock.now
        let overallDeadline = origin + .seconds(100)
        var phases: [UnitNativePhaseEvidence] = []
        func milliseconds() -> Int64 {
            let elapsed = origin.duration(to: .now).components
            return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        }
        func start(_ process: Process) throws {
            guard ContinuousClock.now < overallDeadline else { throw CocoaError(.executableRuntimeMismatch) }
            try process.run()
        }
        let lookup = Process(), pipe = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "swift"]
        lookup.standardOutput = pipe; lookup.standardError = FileHandle.nullDevice
        func finish(_ process: Process, seconds: Double, observe: () -> Void = {}) throws {
            let deadline = min(ContinuousClock.now + .seconds(seconds), overallDeadline)
            while process.isRunning && ContinuousClock.now < deadline { observe(); Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning {
                guard kill(process.processIdentifier, SIGTERM) == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                let stop = ContinuousClock.now + .seconds(3)
                while process.isRunning && ContinuousClock.now < stop { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning {
                    guard kill(process.processIdentifier, SIGKILL) == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                    let killed = ContinuousClock.now + .seconds(3)
                    while process.isRunning && ContinuousClock.now < killed { Thread.sleep(forTimeInterval: 0.01) }
                }
            }
            guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
            process.waitUntilExit()
        }
        try start(lookup)
        try finish(lookup, seconds: 5)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard lookup.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        let swift = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let helper = swift.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper")
        let platformLookup = Process(), platformPipe = Pipe()
        platformLookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        platformLookup.arguments = ["--sdk", "macosx", "--show-sdk-platform-path"]
        platformLookup.standardOutput = platformPipe; platformLookup.standardError = FileHandle.nullDevice
        try start(platformLookup)
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
            // Hosted native symbolication took 19.46s; use the existing 30s diagnostic window.
            env["CHECKS_UNIT_TIMEOUT_SECONDS"] = "30"
            env["SWIFT_BACKTRACE"] = backtraceOverrideForTesting
            let bootstrap = "import os,runpy,sys; os.environ['DYLD_FRAMEWORK_PATH']=sys.argv[1]; os.environ['DYLD_LIBRARY_PATH']=sys.argv[2]; sys.argv=sys.argv[3:]; runpy.run_path(sys.argv[0],run_name='__main__')"
            process.arguments = ["-c", bootstrap, env["DYLD_FRAMEWORK_PATH"]!, env["DYLD_LIBRARY_PATH"]!] + (process.arguments ?? [])
            process.environment = env; process.standardOutput = handle; process.standardError = handle
            var phase = UnitNativePhaseEvidence(mode: mode, launchMilliseconds: milliseconds())
            var offset: Int64 = 0
            var carry = ""
            var readBudget = 8 * 1024 * 1024
            var nextPoll = ContinuousClock.now
            func observe() {
                guard ContinuousClock.now >= nextPoll else { return }
                nextPoll = .now + .milliseconds(200)
                guard readBudget > 0 else { phase.observationBudgetExhausted = true; return }
                if let data = nativePhaseBytes(output, offset: offset, cap: min(32_768, readBudget)) {
                    offset += Int64(data.count); readBudget -= data.count
                    let text = carry + String(decoding: data, as: UTF8.self)
                    let now = milliseconds()
                    if phase.pidMarkerMilliseconds == nil && text.contains("PINCER_NATIVE_CRASH_PID=") { phase.pidMarkerMilliseconds = now }
                    if phase.headerMilliseconds == nil && text.contains("Signal 11") { phase.headerMilliseconds = now }
                    if phase.frameMilliseconds == nil && text.contains("pincerOwnedSwiftCrashFrameForTesting") { phase.frameMilliseconds = now }
                    carry = String(text.suffix(512))
                }
                if let data = nativePhaseBytes(dir.appendingPathComponent("unit-command-exit.json"), cap: min(32_768, readBudget)), !data.isEmpty {
                    readBudget -= data.count
                    if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if phase.childExitMetadataMilliseconds == nil && value["ownedReturnCode"] != nil { phase.childExitMetadataMilliseconds = milliseconds() }
                        if phase.captureCompleteMetadataMilliseconds == nil,
                           let capture = value["reportCapture"] as? [String: Any],
                           let outcome = capture["outcome"] as? String, outcome != "pending" {
                            phase.captureCompleteMetadataMilliseconds = milliseconds()
                        }
                    }
                }
            }
            var accepted = false
            func retainFailure() {
            if let destination = retentionRootForTesting?.path ?? ProcessInfo.processInfo.environment["CHECKS_LOG_DIR"], !destination.isEmpty {
                do {
                    let retained = URL(fileURLWithPath: destination).appendingPathComponent("native-control-failure-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
                    // Reserve 64KiB for the bounded scalar phase/manifest JSON.
                    var copyBudget = 2 * 1024 * 1024 - 65_536
                    let allNames = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                    let names = allNames.filter {
                        $0 == "output.txt" || $0 == "unit-command-exit.json" || $0 == "unit-watchdog.json"
                            || $0.hasPrefix("unit-stack-") || $0.hasPrefix("unit-owned-report-")
                    }
                    phase.ignoredFileCount = allNames.count - names.count
                    phase.skippedByFileLimit = max(0, names.count - 16)
                    phase.retainedFailureDirectory = retained.path
                    for name in names.prefix(16) {
                        guard name.utf8.count <= 128 else {
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: "oversized-owned-name", sourceBytes: nil, copiedBytes: 0, truncated: false, outcome: "nameLimit", errnoCode: nil))
                            continue
                        }
                        guard copyBudget > 0 else {
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: nil, copiedBytes: 0, truncated: false, outcome: "totalByteLimit", errnoCode: nil))
                            continue
                        }
                        let fd = Darwin.open(dir.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                        guard fd >= 0 else {
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: nil, copiedBytes: 0, truncated: false, outcome: "openDenied", errnoCode: errno))
                            continue
                        }
                        defer { Darwin.close(fd) }
                        var info = stat()
                        let statResult = fstat(fd, &info)
                        guard statResult == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: nil, copiedBytes: 0, truncated: false, outcome: "notRegularOrStatFailed", errnoCode: statResult == 0 ? nil : errno))
                            continue
                        }
                        let cap = min(262_144, copyBudget)
                        var bytes = [UInt8](repeating: 0, count: cap)
                        let count = pread(fd, &bytes, cap, 0)
                        guard count >= 0 else {
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: Int64(info.st_size), copiedBytes: 0, truncated: false, outcome: "readFailed", errnoCode: errno))
                            continue
                        }
                        do {
                            try Data(bytes.prefix(count)).write(to: retained.appendingPathComponent(name), options: .atomic)
                            copyBudget -= count
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: Int64(info.st_size), copiedBytes: count, truncated: Int64(count) < info.st_size, outcome: "copied", errnoCode: nil))
                        } catch {
                            phase.artifactCopyError = true
                            phase.retentionManifest.append(UnitNativeRetainedFile(name: name, sourceBytes: Int64(info.st_size), copiedBytes: 0, truncated: false, outcome: "writeFailed", errnoCode: nil))
                        }
                    }
                    let metadata = try JSONEncoder().encode(phase)
                    guard metadata.count <= 65_536 else { phase.artifactCopyError = true; return }
                    try metadata.write(to: retained.appendingPathComponent("phases.json"), options: .atomic)
                } catch { phase.artifactCopyError = true }
            }
            }
            try start(process)
            defer { if !accepted { retainFailure() }; phases.append(phase) }
            try finish(process, seconds: 75, observe: observe)
            nextPoll = .now; observe()
            phase.wrapperExitMilliseconds = milliseconds()
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
            accepted = crash ? crashStatus && crashEvidence : passed
            return (process.terminationStatus, accepted, String(text.suffix(16_384)), crashStatus)
        }
        let ordinary = try child("ordinary")
        guard ordinary.1 else { return UnitNativeBacktraceEvidence(ordinaryPassed: false, crashBacktracePassed: false, crashOwnedStatus: false, ordinaryStatus: ordinary.0, crashStatus: -1, diagnostics: ordinary.2, phases: phases) }
        let crashed = try child("crash")
        return UnitNativeBacktraceEvidence(ordinaryPassed: ordinary.1, crashBacktracePassed: crashed.1, crashOwnedStatus: crashed.3, ordinaryStatus: ordinary.0, crashStatus: crashed.0, diagnostics: crashed.2, phases: phases)
        }()
        continuation.resume(returning: evidence)
        } catch { continuation.resume(throwing: error) }
        }
    }
}
#endif
