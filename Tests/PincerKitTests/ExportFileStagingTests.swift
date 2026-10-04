#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Export temporary file staging", .timeLimit(.minutes(2)))
struct ExportFileStagingTests {
    @Test func actualTemporaryDirectoryAndWriteRunOffMain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-staging-\(UUID())", isDirectory: true)
        let data = await Task.detached { Data("Exact UTF8 é\nlast line".utf8) }.value
        let staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
        staging.probe = probe
        do {
            let first = try #require(await staging.prepare(name: "Chat.txt", data: data))
            let second = try #require(await staging.prepare(name: "Chat.txt", data: data))
            let actual = try await Task.detached { try Data(contentsOf: first) }.value
            let other = try await Task.detached { try Data(contentsOf: second) }.value
            #expect(first.lastPathComponent == "Chat.txt" && second.lastPathComponent == "Chat.txt")
            #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
            #expect(first.deletingLastPathComponent().deletingLastPathComponent() == root)
            #expect(actual == data && other == data && !actual.isEmpty)
            let counts = probe.snapshot()
            #expect(counts.mainDirectories == 0 && counts.mainWrites == 0)
            #expect(counts.workerDirectories == 2 && counts.workerWrites == 2)
        } catch { await Task.detached { try? FileManager.default.removeItem(at: root) }.value; throw error }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
    @Test func realDirectoryAndWriteFailuresReturnNoFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-export-failure-\(UUID())", isDirectory: true)
        do {
            let blocking = root.appendingPathComponent("file")
            try await Task.detached {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data([1]).write(to: blocking)
            }.value
            let directoryFailure = ExportFileStaging(root: blocking), firstProbe = ExportFileStagingProbe()
            directoryFailure.probe = firstProbe
            let noDirectory = await directoryFailure.prepare(name: "Chat.txt", data: Data([2]))
            #expect(noDirectory == nil)
            #expect(firstProbe.snapshot().mainDirectories + firstProbe.snapshot().workerDirectories == 1)
            #expect(firstProbe.snapshot().mainWrites + firstProbe.snapshot().workerWrites == 0)
            let writeFailure = ExportFileStaging(root: root), secondProbe = ExportFileStagingProbe()
            writeFailure.probe = secondProbe
            let noFile = await writeFailure.prepare(name: "missing/Chat.txt", data: Data([2]))
            #expect(noFile == nil)
            #expect(secondProbe.snapshot().mainWrites + secondProbe.snapshot().workerWrites == 1)
        } catch { await Task.detached { try? FileManager.default.removeItem(at: root) }.value; throw error }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
#endif
