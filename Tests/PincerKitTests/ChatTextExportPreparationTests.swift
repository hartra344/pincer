#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Chat text export preparation", .timeLimit(.minutes(2)))
struct ChatTextExportPreparationTests {
    @Test(arguments: [TranscriptExport.Format.markdown, .plainText])
    func exactTextExportPreparationRunsOffMain(format: TranscriptExport.Format) async throws {
        let items = await Task.detached {
            [ChatItem(id: "user", role: .user, blocks: [.text("Hello\nworld")]),
             ChatItem(id: "assistant", role: .assistant, blocks: [.thinking("Consider it"), .text("Reply é")])]
        }.value
        let header = TranscriptExport.Header(title: "Plans/ideas", agentName: "Scout", exportedAt: Date(timeIntervalSince1970: 0))
        let options = TranscriptExport.Options(includeThinking: true, includeToolCalls: true)
        let expected = await Task.detached {
            Data((format == .markdown ? TranscriptExport.markdown(items, header: header, options: options)
                  : TranscriptExport.plainText(items, header: header, options: options)).utf8)
        }.value
        let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
        preparation.probe = probe
        let output = try #require(await preparation.prepare(items, format: format, options: options, header: header))
        #expect(output.data == expected && !output.data.isEmpty)
        #expect(output.name == "Plans-ideas.\(format.fileExtension)")
        let counts = probe.snapshot()
        #expect(counts.mainFormats == 0 && counts.mainEncodes == 0)
        #expect(counts.workerFormats == 1 && counts.workerEncodes == 1)
    }
}
#endif
