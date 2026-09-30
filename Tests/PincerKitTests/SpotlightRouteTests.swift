import Foundation
import Testing
@testable import PincerKit

/// #53: a tapped Spotlight result hands its identifier back as a URL, which opens the chat.
@MainActor
@Suite("Spotlight routes")
struct SpotlightRouteTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)

    func session(_ key: String) -> SessionRow {
        SessionRow(.object(["key": .string(key), "label": .string("Chat"), "lastActivityAt": 1000]))!
    }

    @Test(arguments: ["agent:main:dashboard:plain", "agent:main:telegram:group:-100 1", "agent:main:dashboard:a&b=c#d%e+f/é"])
    func identifierOpensThatChat(key: String) throws {
        let app = AppModel(defaults: self.scratch.defaults)
        let store = app.add(self.profile, secret: nil)
        store.setSession(self.session(key), for: key)
        store.setSession(self.session("agent:main:dashboard:other"), for: "agent:main:dashboard:other")
        defer { app.remove(store.id); self.scratch.remove() }

        let entries = Spotlight.entries(gatewayId: store.id, gatewayURL: store.profile.url, gatewayHost: store.gatewayHost,
                                        sessions: Array(store.sessions.values), includeMessages: false)
        let entry = try #require(entries.first { $0.sessionKey == key })
        let url = try #require(URL(string: entry.id))
        #expect(PincerRoute.parse(url)?.sessionKey == key)

        let resolution = app.open(url: url)
        #expect(resolution == .openChat(Notifier.Target(gatewayId: store.id, sessionKey: key), messageId: nil))
        #expect(app.selectedGatewayId == store.id && store.selectedKey == key)
        #expect(app.routeNotice == nil)
    }

    @Test func messageLinkLeavesAJumpForThatChat() throws {
        let app = AppModel(defaults: self.scratch.defaults)
        let store = app.add(self.profile, secret: nil)
        let key = "agent:main:telegram:group:-100 1"
        store.setSession(self.session(key), for: key)
        defer { app.remove(store.id); self.scratch.remove() }

        let target = Notifier.Target(gatewayId: store.id, sessionKey: key)
        let route = PincerRoute(target: target, isDemo: false, messageId: "msg-42", gatewayURL: store.profile.url,
                                gatewayHost: store.gatewayHost)
        let url = try #require(URL(string: route.url.absoluteString))
        #expect(app.open(url: url) == .openChat(target, messageId: "msg-42"))
        #expect(app.messageJump?.target == target && app.messageJump?.messageId == "msg-42")
        #expect(app.takeMessageJump(for: Notifier.Target(gatewayId: store.id, sessionKey: "agent:main:other")) == nil)
        #expect(app.takeMessageJump(for: target)?.messageId == "msg-42")
        #expect(app.messageJump == nil)
    }
}
