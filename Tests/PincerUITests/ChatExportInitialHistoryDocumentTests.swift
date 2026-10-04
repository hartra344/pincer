import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite(.timeLimit(.minutes(2)))
struct ChatExportInitialHistoryDocumentTests {
    @Test(arguments: [TranscriptExport.Format.markdown, .plainText])
    func unavailableInitialHistoryDoesNotCreateHeaderOnlyFile(format: TranscriptExport.Format) async {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline", url: "ws://127.0.0.1:1", authMode: .none), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil
        let chat = gateway.chat(for: "agent:main:missing")
        defer { chat.stopCaching(); gateway.stop(); scratch.remove() }
        let file = await ChatExportBuilder.build(chat: chat, format: format, options: .init(), header: .init(title: "Missing chat", agentName: "Main"))
        #expect(!chat.hasLoaded && chat.items.isEmpty)
        #expect(file == nil)
    }
}
