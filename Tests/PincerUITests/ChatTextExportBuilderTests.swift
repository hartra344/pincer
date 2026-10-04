#if DEBUG
import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite("Actual chat text export builder", .timeLimit(.minutes(2)))
struct ChatTextExportBuilderTests {
    @Test(arguments: [TranscriptExport.Format.markdown, .plainText])
    func actualBuilderUsesOffMainTextPreparation(format: TranscriptExport.Format) async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        gateway.start(); gateway.reconnectIfNeeded(); defer { gateway.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || !gateway.bootstrapped {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        let chat = gateway.chat(for: "agent:main:dashboard:tool-cards")
        let items = try #require(await chat.exportItems())
        try #require(!items.isEmpty)
        let header = TranscriptExport.Header(title: "MCP servers", agentName: "Claw", exportedAt: Date(timeIntervalSince1970: 0))
        let options = TranscriptExport.Options(includeThinking: true, includeToolCalls: true)
        let expected = await Task.detached {
            Data((format == .markdown ? TranscriptExport.markdown(items, header: header, options: options)
                  : TranscriptExport.plainText(items, header: header, options: options)).utf8)
        }.value
        let preparation = ChatTextExportPreparation(), probe = ChatTextExportProbe()
        preparation.probe = probe
        let file = try #require(await ChatExportBuilder.build(chat: chat, format: format, options: options, header: header, preparation: preparation))
        #expect(file.data == expected && !file.data.isEmpty && file.name == "MCP servers.\(format.fileExtension)")
        let counts = probe.snapshot()
        #expect(counts.mainFormats == 0 && counts.mainEncodes == 0)
        #expect(counts.workerFormats == 1 && counts.workerEncodes == 1)
    }
}
#endif
