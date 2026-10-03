import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Reply preview preparation")
struct ReplyPreviewPreparationTests {
    @Test(.timeLimit(.minutes(2))) func actualReplyTargetNeverNormalizesLargeSingleLineOnMain() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply test", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        let id = UUID().uuidString
        var item = ChatItem(id: "local-id", role: .assistant,
                            blocks: [.text("Disk status " + String(repeating: "a", count: 200_000))])
        item.transcriptId = id
        ReplyPreviewDebugProbe.reset(tracking: id)
        defer { ReplyPreviewDebugProbe.unregister(tracking: id) }
        chat.items = [item]
        chat.rebuild(itemsChanged: true)
        await chat.waitForReplyPreviewPreparation()

        let target = try #require(chat.replyTarget(for: id, you: "You", agent: "Claw"))
        #expect(target.messageId == id)
        #expect(target.senderLabel == "Claw" && target.isAssistant)
        #expect(ReplyPreviewDebugProbe.stats(for: id).mainThreadNormalizations == 0,
                "The actual replyTarget path must not join or normalize the message text on Main")
        #expect(target.preview.count <= 280)
        #expect(target.preview.utf8.count <= 2_048)
        #expect(target.preview.hasPrefix("Disk status"))
    }

    @Test(.timeLimit(.minutes(2))) func exactIDProbePositiveControlRecordsMainNormalization() {
        let id = UUID().uuidString
        ReplyPreviewDebugProbe.reset(tracking: id)
        defer { ReplyPreviewDebugProbe.unregister(tracking: id) }
        ReplyPreviewDebugProbe.recordNormalization(for: id)
        #expect(ReplyPreviewDebugProbe.stats(for: id).mainThreadNormalizations == 1)
        #expect(ReplyPreviewDebugProbe.stats(for: id).offMainNormalizations == 0)
    }

    @Test(.timeLimit(.minutes(2))) func replyMetadataPreservesUserSenderAndTranscriptIdentity() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply metadata", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        var item = ChatItem(id: "local-user", role: .user, blocks: [.text("  A short question  ")])
        item.transcriptId = "user-transcript"
        chat.items = [item]
        chat.rebuild(itemsChanged: true)
        await chat.waitForReplyPreviewPreparation()
        let target = try #require(chat.replyTarget(for: "user-transcript", you: "You", agent: "Claw"))
        #expect(target.messageId == "user-transcript" && target.senderLabel == "You" && !target.isAssistant)
        #expect(target.preview == "A short question")
        #expect(chat.replyTarget(for: "local-user", you: "You", agent: "Claw") == nil)
        #expect(chat.replyTarget(for: "missing", you: "You", agent: "Claw") == nil)
    }
}
