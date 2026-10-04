#if DEBUG && os(iOS)
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite("Actual iOS Export file staging", .timeLimit(.minutes(2)))
struct ExportFileStagingCallerTests {
    func exerciseActualSharedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-ui-staging-\(UUID())", isDirectory: true)
        let data = await Task.detached { Data("Actual Export file\né\n".utf8) }.value
        let staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
        staging.probe = probe
        do {
            let first = try #require(await SharedFile.write(name: "Export.txt", data: data, staging: staging))
            let second = try #require(await SharedFile.write(name: "Export.txt", data: data, staging: staging))
            let bytes = try await Task.detached { try Data(contentsOf: first.url) }.value
            #expect(bytes == data && !bytes.isEmpty && first.url.lastPathComponent == "Export.txt")
            #expect(first.id != second.id && first.url.deletingLastPathComponent() != second.url.deletingLastPathComponent())
            let counts = probe.snapshot()
            #expect(counts.mainDirectories == 0 && counts.mainWrites == 0)
            #expect(counts.workerDirectories == 2 && counts.workerWrites == 2)
        } catch { await Task.detached { try? FileManager.default.removeItem(at: root) }.value; throw error }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2)))
    func exportSharedFileUsesActualOffMainStaging() async throws {
        try await ExportFileStagingCallerTests().exerciseActualSharedFile()
    }
}
#endif
