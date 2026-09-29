import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #430: Export Chat builds a non-empty file with the whole history, not just the loaded window.
@MainActor
@Suite("Chat export", .serialized)
struct ChatExportTests {
    let key = "agent:main:export"
    let total = 300

    func items() -> [ChatItem] {
        (0..<self.total).map { n in
            var item = ChatItem(id: "m\(n)", role: n.isMultiple(of: 2) ? .user : .assistant,
                                blocks: [.text("message \(n)")], timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
            item.transcriptId = item.id
            return item
        }
    }

    /// A chat restored from the cache with only its newest window in memory.
    func windowedChat(root: URL, scratch: ScratchDefaults) async -> (ChatStore, GatewayStore) {
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = root
        await TranscriptCache.save(TranscriptCache.Snapshot(items: self.items(), complete: true),
                                   gatewayId: gateway.id, sessionKey: self.key, root: root)
        await TranscriptCache.flush(gatewayId: gateway.id, root: root)
        let chat = ChatStore(sessionKey: self.key, agentId: nil, gateway: gateway)
        chat.windowLimit = 40
        await chat.restoreFromCache()
        chat.hasLoaded = true
        return (chat, gateway)
    }

    @Test(arguments: [TranscriptExport.Format.markdown, .plainText, .pdf])
    func buildsTheWholeHistory(format: TranscriptExport.Format) async throws {
        let scratch = ScratchDefaults()
        let root = FileManager.default.temporaryDirectory.appending(path: "pincer-export-\(UUID().uuidString)")
        let (chat, gateway) = await self.windowedChat(root: root, scratch: scratch)
        defer {
            chat.stopCaching()
            TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: root)
            try? FileManager.default.removeItem(at: root)
            scratch.remove()
        }
        #expect(chat.items.count < self.total && chat.hasOlderItems, "only the window is loaded")

        let header = TranscriptExport.Header(title: "Trip: plans/ideas", agentName: "Scout")
        let file = try #require(await ChatExportBuilder.build(chat: chat, format: format, options: .init(), header: header))
        #expect(!file.data.isEmpty)
        #expect(file.name == "Trip- plans-ideas.\(format.fileExtension)")
        #expect(file.contentType.preferredFilenameExtension == format.fileExtension)
        if format != .pdf {
            let text = try #require(String(data: file.data, encoding: .utf8))
            #expect(text.contains("message 0") && text.contains("message \(self.total - 1)"), "oldest and newest messages")
        } else {
            #expect(file.data.starts(with: Data("%PDF".utf8)))
        }
    }
}
