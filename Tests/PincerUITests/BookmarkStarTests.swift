import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// A bookmarked message shows a filled star in its footer (#384), and VoiceOver says so.
@MainActor
@Suite("Bookmark star")
struct BookmarkStarTests {
    let scratch = ScratchDefaults()
    let key = "agent:t:main"

    func footers(_ layout: TranscriptRowLayout) -> [TranscriptPart.Footer] {
        layout.parts.compactMap { if case let .footer(footer) = $0.part { footer } else { nil } }
    }

    @Test func bookmarkedMessagesShowAStar() throws {
        defer { self.scratch.remove() }
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: UIFixtures.identity())
        let store = BookmarkStore.shared(gatewayId: gateway.id)
        defer { store.removeAll() }
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: self.key))
        var item = ChatItem(id: "local-1", role: .user, blocks: [.text("Where did we leave the lantern?")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        item.transcriptId = "msg-42"
        func layout() -> TranscriptRowLayout {
            TranscriptLayoutBuilder(context: context, settings: .current(for: context))
                .layout(.entry(.user(item)), width: 600)
        }

        let plain = layout()
        #expect(self.footers(plain).map(\.isBookmarked) == [false])
        #expect(!plain.accessibilityLabel.contains("Bookmarked"))

        store.add(Bookmark(sessionKey: self.key, messageId: "msg-42", preview: "Where did we leave the lantern?"))
        let starred = layout()
        #expect(starred.decoration.bookmarks == ["msg-42"])
        #expect(starred.decoration != plain.decoration, "a bookmark change relays out the row")
        #expect(self.footers(starred).map(\.isBookmarked) == [true])
        #expect(starred.accessibilityLabel.contains("Bookmarked"))
        #expect(starred.height == plain.height, "the star sits in the footer, so the row keeps its height")

        // Another chat's bookmark with the same id doesn't count.
        store.remove(sessionKey: self.key, messageId: "msg-42")
        store.add(Bookmark(sessionKey: "agent:t:other", messageId: "msg-42", preview: ""))
        #expect(self.footers(layout()).map(\.isBookmarked) == [false])
    }
}
