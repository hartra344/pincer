#if DEBUG && os(iOS)
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

private actor SharedFileFirstWriteGate {
    var entered = false, firstURL: URL?
    private var visits = 0, open = false
    private var held: CheckedContinuation<Void, Never>?
    func holdFirst(_ url: URL?) async {
        visits += 1
        guard visits == 1 else { return }
        firstURL = url; entered = true
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { held = continuation }
        }
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor private func exerciseSharedFileRequestOwnership(cancelLatest: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-ui-staging-owner-\(UUID())", isDirectory: true)
    let gate = SharedFileFirstWriteGate(), staging = ExportFileStaging(root: root), probe = ExportFileStagingProbe()
    staging.probe = probe; staging.afterWrite = { await gate.holdFirst($0) }
    let preparation = SharedFilePreparation(staging: staging)
    var published: [PincerUI.SharedFile] = []
    var actual: Task<Void, Never>?
    do {
        preparation.request(name: "Old.txt", data: Data([1])) { if let file = $0 { published.append(file) } }
        actual = try #require(preparation.actualTask)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await gate.entered) {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        let oldURL = try #require(await gate.firstURL)
        preparation.request(name: "Intermediate.txt", data: Data([2])) { if let file = $0 { published.append(file) } }
        preparation.request(name: "Latest.txt", data: Data([3])) { if let file = $0 { published.append(file) } }
        #expect(preparation.pendingCount == 1 && published.isEmpty && probe.snapshot().workerWrites == 1)
        if cancelLatest { preparation.cancel() }
        await gate.release(); await actual?.value; await preparation.waitForIdle()
        let oldRemoved = await Task.detached { !FileManager.default.fileExists(atPath: oldURL.deletingLastPathComponent().path) }.value
        #expect(oldRemoved && preparation.pendingCount == 0)
        if cancelLatest {
            #expect(published.isEmpty && probe.snapshot().workerWrites == 1)
        } else {
            #expect(published.count == 1)
            let latest = try #require(published.first)
            let bytes = try await Task.detached { try Data(contentsOf: latest.url) }.value
            #expect(latest.url.lastPathComponent == "Latest.txt" && bytes == Data([3]))
            #expect(probe.snapshot().workerWrites == 2 && probe.snapshot().workerDirectories == 2)
        }
        #expect(probe.snapshot().mainDirectories == 0 && probe.snapshot().mainWrites == 0)
    } catch {
        preparation.cancel(); await gate.release(); await actual?.value; await preparation.waitForIdle()
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
        throw error
    }
    await Task.detached { try? FileManager.default.removeItem(at: root) }.value
}
extension TranscriptUIKitHostedTests {
    @Test(.timeLimit(.minutes(2))) func exportSharedFilePublishesLatestAfterActualWorkerCompletion() async throws {
        try await exerciseSharedFileRequestOwnership(cancelLatest: false)
    }
    @Test(.timeLimit(.minutes(2))) func exportSharedFileDisappearanceCancelsPendingPublication() async throws {
        try await exerciseSharedFileRequestOwnership(cancelLatest: true)
    }
}
#endif
