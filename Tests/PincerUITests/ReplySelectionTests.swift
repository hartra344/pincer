import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Reply selection identity")
struct ReplySelectionTests {
    @Test(.timeLimit(.minutes(2))) func actualBeginReplyKeepsFocusIdentityWhenPreviewCompletes() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Reply UI", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        defer { gateway.stop() }
        let chat = ChatStore(sessionKey: "main", agentId: nil, gateway: gateway, headless: true)
        var item = ChatItem(id: "local", role: .assistant, blocks: [.text("Prepared reply " + String(repeating: "x", count: 100_000))])
        item.transcriptId = "reply-ui-message"
        chat.items = [item]
        chat.rebuild(itemsChanged: true)

        chat.beginReply(to: "reply-ui-message", agentName: "Claw")
        let selected = try #require(chat.replyTarget)
        #expect(selected.messageId == "reply-ui-message")
        await chat.waitForReplyPreviewPreparation()
        #expect(chat.replyTarget?.selectionID == selected.selectionID,
                "Preview publication must not look like a new composer focus selection")
        #expect(chat.replyTarget?.preview.hasPrefix("Prepared reply") == true)
        chat.beginReply(to: "reply-ui-message", agentName: "Claw")
        #expect(chat.replyTarget?.selectionID != selected.selectionID,
                "An explicit same-message reselect is a new user operation")
        chat.replyTarget = nil
        await chat.waitForReplyPreviewPreparation()
        #expect(chat.replyTarget == nil)
    }
}
