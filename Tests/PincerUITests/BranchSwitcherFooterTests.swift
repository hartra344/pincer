import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// The `‹ 2 / 2 ›` switcher sits in the footer of the message where branches fork, and never changes a row's height.
@MainActor
@Suite("Branch switcher footer")
struct BranchSwitcherFooterTests {
    let scratch = ScratchDefaults()
    let key = "agent:t:main"

    @Test func anchorFooterCarriesTheBranchPositionWithoutChangingHeight() throws {
        defer { self.scratch.remove() }
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: self.key)
        var first = ChatItem(id: "local-1", role: .user, blocks: [.text("Where is the lantern?")],
                             timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        first.transcriptId = "msg-1"
        var last = ChatItem(id: "local-2", role: .user, blocks: [.text("Try again")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_100))
        last.transcriptId = "msg-2"
        chat.items = [first, last]
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))
        func footer(_ item: ChatItem) -> (TranscriptPart.Footer, CGFloat)? {
            let layout = builder.layout(.entry(.user(item)), width: 600)
            for placed in layout.parts {
                if case let .footer(footer) = placed.part { return (footer, placed.frame.height) }
            }
            return nil
        }

        let plain = try #require(footer(last))
        #expect(plain.0.branch == nil && chat.branchAnchorId == nil)

        chat.branches = [SessionBranch(leafEntryId: "a", headline: "one", messageCount: 2, active: false),
                         SessionBranch(leafEntryId: "b", headline: "two", messageCount: 2, active: true)]
        #expect(chat.branchAnchorId == "msg-2")
        let anchor = try #require(footer(last))
        #expect(anchor.0.branch?.number == 2 && anchor.0.branch?.count == 2)
        #expect(anchor.1 == plain.1, "the switcher lives in the footer row, which keeps its height")
        #expect(try #require(footer(first)).0.branch == nil, "only the last user message carries it")
        #expect(builder.decoration(for: .entry(.user(last))) != builder.decoration(for: .entry(.user(first))))
    }
}
