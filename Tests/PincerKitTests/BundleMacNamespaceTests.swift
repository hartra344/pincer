#if os(macOS)
import Foundation
import Testing

@Suite("SwiftPM Mac bundle namespace")
struct BundleMacNamespaceTests {
    @Test func generatedBundleMetadataKeepsDevelopmentStorageIsolated() async throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test_bundle_mac_namespace.py")
        let result = try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        #expect(result.0 == 0, "The actual bundler fixture failed:\n\(result.1)")
    }
}
#endif
