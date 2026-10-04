#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor ChatExportCompletedGate {
    var entered = false, finished = false, open = false
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { held = continuation }
        }
        finished = true
    }
    func release() { open = true; held?.resume(); held = nil }
}
@MainActor @Suite("Chat text Export worker ownership", .timeLimit(.minutes(2)))
struct ChatTextExportWorkerTests {
    @Test func excludedOptionsAndUnsupportedPDFRemainExact() async throws {
        let items = await Task.detached {
            [ChatItem(id: "assistant", role: .assistant, blocks: [.thinking("PRIVATE THOUGHT"),
                .toolCall(id: "tool", name: "exec", arguments: "{}"), .text("Visible reply")])]
        }.value
        let header = TranscriptExport.Header(title: "Options", exportedAt: Date(timeIntervalSince1970: 0))
        let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
        preparation.probe = probe
        for format in [TranscriptExport.Format.markdown, .plainText] {
            let output = try #require(await preparation.prepare(items, format: format, options: .init(), header: header))
            let text = try #require(String(data: output.data, encoding: .utf8))
            #expect(text.contains("Visible reply") && !text.contains("PRIVATE THOUGHT") && !text.contains("exec"))
        }
        let before = probe.snapshot()
        let pdf = await preparation.prepare(items, format: .pdf, options: .init(), header: header)
        let after = probe.snapshot()
        #expect(pdf == nil && before.workerFormats == 2 && before.workerEncodes == 2)
        #expect(after.workerFormats == before.workerFormats && after.workerEncodes == before.workerEncodes)
        #expect(after.mainFormats == 0 && after.mainEncodes == 0)
    }
    @Test func canceledConsumerAwaitsActualCompletedWorkerWithoutPublishing() async throws {
        let gate = ChatExportCompletedGate()
        let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
        preparation.probe = probe; preparation.afterPreparation = { await gate.hold() }
        let task = Task {
            await preparation.prepare([ChatItem(id: "reply", role: .assistant, blocks: [.text("Completed text")])],
                                      format: .plainText, options: .init(), header: .init(title: "Held"))
        }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await gate.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield()
            }
        } catch { task.cancel(); await gate.release(); _ = await task.value; throw error }
        task.cancel(); await gate.release()
        let result = await task.value, finished = await gate.finished
        #expect(result == nil && finished)
        let counts = probe.snapshot()
        #expect(counts.mainFormats == 0 && counts.mainEncodes == 0 && counts.workerFormats == 1 && counts.workerEncodes == 1)
    }
}
#endif
