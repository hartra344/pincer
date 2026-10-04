#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor ExportStagingCompletedGate {
    var entered = false, finished = false
    var url: URL?
    private var open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold(_ url: URL?) async {
        self.url = url; entered = true
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { held = continuation }
        }
        finished = true
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor @Suite("Export staging worker ownership", .timeLimit(.minutes(2)))
struct ExportFileStagingOwnershipTests {
    @Test func canceledConsumerAwaitsRealWriteThenRemovesOnlyItsUnusedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-staging-owner-\(UUID())", isDirectory: true)
        let keeper = root.appendingPathComponent("keep.txt")
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([9]).write(to: keeper)
        }.value
        let gate = ExportStagingCompletedGate(), staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
        staging.probe = probe; staging.afterWrite = { await gate.hold($0) }
        let task = Task { await staging.prepare(name: "Canceled.txt", data: Data([1, 2, 3])) }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await gate.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield()
            }
            let written = try #require(await gate.url)
            let before = try await Task.detached { try Data(contentsOf: written) }.value
            #expect(before == Data([1, 2, 3]))
            task.cancel(); await gate.release()
            let result = await task.value, finished = await gate.finished
            let state = await Task.detached {
                (!FileManager.default.fileExists(atPath: written.deletingLastPathComponent().path), try? Data(contentsOf: keeper))
            }.value
            #expect(result == nil && finished && state.0 && state.1 == Data([9]))
            let counts = probe.snapshot()
            #expect(counts.mainDirectories == 0 && counts.mainWrites == 0 && counts.workerDirectories == 1 && counts.workerWrites == 1)
        } catch {
            task.cancel(); await gate.release(); _ = await task.value
            await Task.detached { try? FileManager.default.removeItem(at: root) }.value
            throw error
        }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
    @Test func preCanceledPreparationAdmitsNoDirectoryOrWrite() async {
        let staging = ExportFileStaging(), probe = ExportFileStagingProbe(); staging.probe = probe
        let task = Task { await staging.prepare(name: "Never.txt", data: Data([1])) }
        task.cancel()
        let result = await task.value, counts = probe.snapshot()
        #expect(result == nil && counts.mainDirectories == 0 && counts.workerDirectories == 0 && counts.mainWrites == 0 && counts.workerWrites == 0)
    }
}
#endif
