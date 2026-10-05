#if DEBUG && os(macOS)
import Foundation
import Darwin

package struct LiveReplyCandidateFixtureEvidence: Sendable {
    package let ordinaryPassed: Bool
    package let heldQualified: Bool
    package let heldCompletedAsFailedTest: Bool
    package let ordinaryStatus: Int32
    package let heldStatus: Int32
    package let diagnostics: String
}

/// Runs only the actual selected Kit live-candidate ownership child; no substitute queue algorithm.
package func liveReplyCandidateFixtureProof() async throws -> LiveReplyCandidateFixtureEvidence {
    guard ProcessInfo.processInfo.environment["PINCER_LIVE_CANDIDATE_CHILD"] == nil else {
        throw CocoaError(.validationMissingMandatoryProperty)
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { @Sendable in
        do {
        let evidence = try { () throws -> LiveReplyCandidateFixtureEvidence in
        let overallDeadline = ContinuousClock.now + .seconds(100)
        func start(_ process: Process) throws {
            guard ContinuousClock.now < overallDeadline else { throw CocoaError(.executableRuntimeMismatch) }
            try process.run()
        }
        let lookup = Process(), pipe = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "swift"]
        lookup.standardOutput = pipe; lookup.standardError = FileHandle.nullDevice
        func finish(_ process: Process, seconds: Double) throws {
            let deadline = min(ContinuousClock.now + .seconds(seconds), overallDeadline)
            while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
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
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-live-candidate-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = dir.appendingPathComponent("output.txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = python
            process.arguments = [root.appendingPathComponent("scripts/checks-unit-command.py").path, helper.path, "--test-bundle-path", bundle.path, "--testing-library", "swift-testing", "--filter", "LiveReplyPreparationQueueTests/actualCandidateReadinessChild"]
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            let inheritedFrameworks = env["DYLD_FRAMEWORK_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            env["DYLD_FRAMEWORK_PATH"] = frameworks.path + (inheritedFrameworks.map { ":" + $0 } ?? "")
            let inheritedLibraries = env["DYLD_LIBRARY_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            env["DYLD_LIBRARY_PATH"] = libraries.path + (inheritedLibraries.map { ":" + $0 } ?? "")
            env["PINCER_LIVE_CANDIDATE_CHILD"] = mode
            env["PINCER_DEV_NAMESPACE"] = "live-candidate-" + UUID().uuidString
            env["PINCER_KEYCHAIN"] = "memory"
            env["CHECKS_LOG_DIR"] = dir.path
            // Bound this isolated real candidate boundary control to 30 seconds.
            env["CHECKS_UNIT_TIMEOUT_SECONDS"] = "30"
            // Inherit the runner backtrace policy: actual trap qualification requires the boundary frame.
            let bootstrap = "import os,runpy,sys; os.environ['DYLD_FRAMEWORK_PATH']=sys.argv[1]; os.environ['DYLD_LIBRARY_PATH']=sys.argv[2]; sys.argv=sys.argv[3:]; runpy.run_path(sys.argv[0],run_name='__main__')"
            process.arguments = ["-c", bootstrap, env["DYLD_FRAMEWORK_PATH"]!, env["DYLD_LIBRARY_PATH"]!] + (process.arguments ?? [])
            process.environment = env; process.standardOutput = handle; process.standardError = handle
            try start(process)
            try finish(process, seconds: 75)
            try handle.synchronize()
            let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
            let summaryPattern = #"Test run with 1 test(?: in 1 suite)? passed[^\n]*"#
            let summaries = try NSRegularExpression(pattern: summaryPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let functionPattern = #"Test [^\n]*actualCandidateReadinessChild[^\n]* passed[^\n]*"#
            let functions = try NSRegularExpression(pattern: functionPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let metadata = (try? Data(contentsOf: dir.appendingPathComponent("unit-command-exit.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let marker = "PINCER_LIVE_CANDIDATE_CHILD_PID="
            let pid = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix(marker) }.flatMap { Int($0.dropFirst(marker.count)) }
            let oneEntry = (pid ?? 0) > 0 && text.components(separatedBy: marker).count == 2
            let oneRun = text.components(separatedBy: "Test run started.").count == 2
            let passed = oneRun && process.terminationReason == .exit && process.terminationStatus == 0 && oneEntry
                && text.contains("PINCER_LIVE_CANDIDATE_CHILD_COMPLETE=" + mode) && summaries == 1 && functions == 1
            let jsonMarker = "PINCER_LIVE_CANDIDATE_CHILD_EVIDENCE="
            let jsonLines = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(jsonMarker) }
            let payload = jsonLines.count == 1 ? (try? JSONSerialization.jsonObject(with: Data(jsonLines[0].dropFirst(jsonMarker.count).utf8)) as? [String: Any]) : nil
            let fields = ["heldActualWorker", "actualTaskCaptured", "offMain", "safetyDidNotExpire"]
            let ordinary = mode == "ordinary"
            let prerequisites = payload?["mode"] as? String == mode && payload?["prerequisites"] as? Bool == true
                && (ordinary ? (payload?["ordinaryPassed"] as? Bool == true && payload?["cleanupControlPassed"] as? Bool == true)
                    : (fields.allSatisfy { payload?[$0] as? Bool == true }
                        && payload?["activeCount"] as? Int == 1 && payload?["pendingCount"] as? Int == 0
                        && payload?["completionCount"] as? Int == 0 && payload?["readiness"] as? Bool == false
                        && (payload?["retainedBytes"] as? Int ?? 0) > 0
                        && payload?["retainedBytes"] as? Int == payload?["expectedRetainedBytes"] as? Int))
            let failedPattern = #"Test run with 1 test(?: in 1 suite)? failed[^\n]*"#
            let failedRuns = try NSRegularExpression(pattern: failedPattern).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let own = oneRun && oneEntry && pid == (metadata?["ownedPid"] as? Int) && (metadata?["timedOut"] as? Bool) == false
            let readinessIssue = text.contains("recorded an issue") && text.contains("Expectation failed: ready")
            let indexFatal = text.contains("Index out of range") && text.contains("initialCandidateOrder")
            let trapped = process.terminationReason == .exit && process.terminationStatus == 133 && own
                && metadata?["ownedReturnCode"] as? Int == -5 && readinessIssue && indexFatal
            let complete = text.components(separatedBy: "PINCER_LIVE_CANDIDATE_CHILD_COMPLETE=" + mode).count == 2
            // Only a normal failed child can prove its actual held task drained. A trap
            // cannot execute cleanup and never qualifies this separate completion contract.
            let drainMarker = "PINCER_LIVE_CANDIDATE_CHILD_DRAIN="
            let drainLines = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(drainMarker) }
            let drain = drainLines.count == 1 ? (try? JSONSerialization.jsonObject(with: Data(drainLines[0].dropFirst(drainMarker.count).utf8)) as? [String: Any]) : nil
            let drainBeforeComplete = text.range(of: drainMarker).flatMap { start in
                text.range(of: "PINCER_LIVE_CANDIDATE_CHILD_COMPLETE=" + mode).map { start.lowerBound < $0.lowerBound }
            } ?? false
            let callbackMatchesInput = (payload?["ownerID"] as? String).flatMap(UUID.init(uuidString:)) != nil
                && (payload?["itemID"] as? String)?.isEmpty == false
                && payload?["generation"] as? Int == 7 && payload?["sequence"] as? Int == 1
                && drain?["callbackOwnerID"] as? String == payload?["ownerID"] as? String
                && drain?["callbackItemID"] as? String == payload?["itemID"] as? String
                && drain?["callbackGeneration"] as? Int == payload?["generation"] as? Int
                && drain?["callbackSequence"] as? Int == payload?["sequence"] as? Int
            let actualHeldDrain = drainBeforeComplete && drain?["mode"] as? String == "held"
                && drain?["capturedTaskAwaited"] as? Bool == true && drain?["callbackCount"] as? Int == 1
                && callbackMatchesInput && drain?["speakable"] as? Bool == true
                && drain?["queueIdle"] as? Bool == true && drain?["activeCount"] as? Int == 0
                && drain?["pendingCount"] as? Int == 0 && drain?["retainedBytes"] as? Int == 0
                && drain?["safetyDidNotExpire"] as? Bool == true
            let normalFailure = process.terminationReason == .exit && process.terminationStatus == 1 && own
                && metadata?["ownedReturnCode"] as? Int == 1 && failedRuns == 1 && complete && readinessIssue && actualHeldDrain
            let qualified = ordinary ? passed && complete && prerequisites : prerequisites && (trapped || normalFailure)
            return (process.terminationStatus, ordinary ? qualified : qualified && normalFailure, String(text.suffix(16_384)), qualified)
        }
        let ordinary = try child("ordinary")
        guard ordinary.1 else { return LiveReplyCandidateFixtureEvidence(ordinaryPassed: false, heldQualified: false, heldCompletedAsFailedTest: false, ordinaryStatus: ordinary.0, heldStatus: -1, diagnostics: ordinary.2) }
        let held = try child("held")
        return LiveReplyCandidateFixtureEvidence(ordinaryPassed: true, heldQualified: held.3, heldCompletedAsFailedTest: held.1, ordinaryStatus: ordinary.0, heldStatus: held.0, diagnostics: held.2)
        }()
        continuation.resume(returning: evidence)
        } catch { continuation.resume(throwing: error) }
        }
    }
}
#endif
