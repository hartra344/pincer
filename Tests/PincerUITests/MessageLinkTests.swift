import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// "Copy Link" on a message (#136): the row hands the same id Reply uses to `copyLink`, and the link
/// it makes opens the chat with a jump to that message.
@MainActor
@Suite("Message links")
struct MessageLinkTests {
    let scratch = ScratchDefaults()
    let key = "agent:t:main"

    func renderer(copied: @escaping (String) -> Void) -> (TranscriptRenderer, GatewayStore) {
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: UIFixtures.identity())
        var context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: self.key))
        context.copyLink = copied
        return (TranscriptRenderer(context: context), gateway)
    }

    @Test func copyLinkActionPassesTheMessageId() throws {
        defer { self.scratch.remove() }
        var copied: [String] = []
        let (renderer, _) = self.renderer { copied.append($0) }
        var item = ChatItem(id: "local-1", role: .user, blocks: [.text("Where did we leave the lantern?")],
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        item.transcriptId = "msg-42"
        let layout = renderer.layout(for: .entry(.user(item)), width: 600)
        #expect(layout.message(at: nil) == "msg-42")

        let actions = TranscriptRowAccessibilityAction.actions(for: layout, actions: renderer, anchor: PView())
        let copyLink = try #require(actions.first { $0.name == "Copy Link" })
        copyLink.perform()
        #expect(copied == ["msg-42"])
        renderer.copyLink(to: "msg-7")
        #expect(copied == ["msg-42", "msg-7"])
    }

    @Test func linkOpensTheChatAtTheMessage() throws {
        defer { self.scratch.remove() }
        let app = AppModel(defaults: self.scratch.defaults)
        let gateway = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
        defer { app.remove(gateway.id) }
        let url = CopyChatLinkButton.link(app: app, gateway: gateway, sessionKey: self.key, messageId: "msg-42")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.scheme == PincerRoute.scheme && components.host == "open")
        #expect(components.queryItems?.first { $0.name == "message" }?.value == "msg-42")
        let route = try #require(PincerRoute.parse(url))
        #expect(route.resolve(in: app.gateways, verifySession: false)
            == .openChat(Notifier.Target(gatewayId: gateway.id, sessionKey: self.key), messageId: "msg-42"))
        let chatOnly = CopyChatLinkButton.link(app: app, gateway: gateway, sessionKey: self.key)
        #expect(!chatOnly.absoluteString.contains("message="))
    }
}
