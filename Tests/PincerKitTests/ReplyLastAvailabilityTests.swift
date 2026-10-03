import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Reply Last availability", .serialized)
struct ReplyLastAvailabilityTests {
    private func item(_ id: String, role: ChatRole = .assistant, blocks: [ContentBlock]) -> ChatItem {
        var item = ChatItem(id: id, role: role, blocks: blocks)
        item.transcriptId = id
        return item
    }
    @Test func actualAvailabilityDoesNotNormalizeLargeMultiblockTextOnMain() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "reply-last-causal", agentId: nil, gateway: gateway, headless: true)
        let id = UUID().uuidString
        let blocks = await Task.detached { [ContentBlock.text(""), .text(String(repeating: " ", count: 1_048_576)),
                                           .text(String(repeating: "x", count: 1_048_576))] }.value
        chat.items = [self.item(id, blocks: blocks)]
        ReplyLastAvailabilityDebugProbe.reset(tracking: id)
        defer { ReplyLastAvailabilityDebugProbe.unregister(tracking: id) }
        #expect(chat.latestReplyableId == id, "content after a giant whitespace block remains eligible")
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: id).mainNormalizations == 0,
                "actual Reply Last validation must not join and trim 2 MiB on Main")
    }
    @Test func actualEligibilityPreservesEmptyWhitespaceUserAndToolSemantics() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: "reply-last-controls", agentId: nil, gateway: gateway, headless: true)
        let base = self.item("base", blocks: [.text("Answer")])
        for blocks: [ContentBlock] in [[], [.text("")], [.text(" \n\t")], [.toolCall(id: "tool", name: "read", arguments: nil)],
            [.image(ImageRef(artifactId: nil, base64: nil, url: "https://example.com/image.png", mimeType: "image/png", alt: nil, width: nil, height: nil))]] {
            chat.items = [base, self.item("empty", blocks: blocks)]
            #expect(chat.latestReplyableId == "base")
        }
        chat.items = [base, self.item("user", role: .user, blocks: [])]
        #expect(chat.latestReplyableId == "user", "committed users remain replyable without text")
        chat.items = [base, self.item("tool", role: .toolResult, blocks: [.text("Result")])]
        #expect(chat.latestReplyableId == "base")
        chat.items = []
        #expect(chat.latestReplyableId == nil)
    }
    @Test func observerIsBoundedAndUnregisteredIDsStaySilent() async {
        let ids = (0..<20).map { "probe-\(UUID().uuidString)-\($0)" }
        defer { for id in ids { ReplyLastAvailabilityDebugProbe.unregister(tracking: id) } }
        for id in ids { ReplyLastAvailabilityDebugProbe.reset(tracking: id) }
        #expect(ReplyLastAvailabilityDebugProbe.trackedCount <= 16)
        let tracked = ids[0]
        await Task.detached { ReplyLastAvailabilityDebugProbe.record(tracking: tracked) }.value
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: tracked).offMainNormalizations == 1)
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: tracked).mainNormalizations == 0)
        let absent = UUID().uuidString
        ReplyLastAvailabilityDebugProbe.record(tracking: absent)
        #expect(ReplyLastAvailabilityDebugProbe.stats(for: absent).mainNormalizations == 0)
    }
}
