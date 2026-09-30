import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway reactions")
struct GatewayReactionsTests {
    static func summary(_ emoji: String, _ ids: [(String, String?)]) -> ReactionSummary {
        ReactionSummary(emoji: emoji, identities: ids.map { ReactionIdentity(id: $0.0, label: $0.1) })
    }

    // MARK: Parsing

    @Test func parsesSummariesAndMaps() {
        let list = ReactionSummary.parse(Fixtures.json(#"""
        [{"emoji":"👍","count":2,"identities":[{"id":"me","label":"Me"},{"id":"u2","label":"Sam"}]},
         {"emoji":"","identities":[{"id":"x"}]},{"identities":[]},
         {"emoji":"🎉","identities":[{"id":"","label":"nobody"},{"id":"u3"}]}]
        """#))
        #expect(list == [Self.summary("👍", [("me", "Me"), ("u2", "Sam")]), Self.summary("🎉", [("u3", nil)])])
        let map = ReactionSummary.parseMap(Fixtures.json(#"{"m1":[{"emoji":"👍","identities":[{"id":"me"}]}],"m2":[],"m3":"bad"}"#))
        #expect(map == ["m1": [Self.summary("👍", [("me", nil)])]])
        #expect(ReactionSummary.parse(nil).isEmpty && ReactionSummary.parseMap(nil).isEmpty)
    }

    // MARK: Groups

    @Test func groupsMergeAgentAndShared() {
        let shared = [Self.summary("👍", [("me", "Me"), ("u2", "Sam"), ("u3", nil), ("u4", "  ")]),
                      Self.summary("🎉", [("u2", "Sam")])]
        let groups = Reactions.groups(agent: ["👍", "✅"], agentName: "Claw", shared: shared, selfId: "me")
        #expect(groups == [
            ReactionGroup(emoji: "👍", actors: [.agent("Claw"), .you, .person("Sam"), .person("Someone")]),
            ReactionGroup(emoji: "✅", actors: [.agent("Claw")]),
            ReactionGroup(emoji: "🎉", actors: [.person("Sam")]),
        ])
    }

    @Test func nilSelfIdNeverMatchesYou() {
        let groups = Reactions.groups(agent: [], agentName: "Claw", shared: [Self.summary("👍", [("me", "Me")])], selfId: nil)
        #expect(groups == [ReactionGroup(emoji: "👍", actors: [.person("Me")])])
        #expect(Reactions.mine(in: [Self.summary("👍", [("me", nil)])], selfId: nil).isEmpty)
    }

    @Test func mineListsOnlyYourEmoji() {
        let shared = [Self.summary("👍", [("u2", nil), ("me", nil)]), Self.summary("🎉", [("u2", nil)]), Self.summary("✅", [("me", nil)])]
        #expect(Reactions.mine(in: shared, selfId: "me") == ["👍", "✅"])
    }

    // MARK: Optimistic update

    @Test func applyingAddsAndRemoves() {
        var list: [ReactionSummary] = []
        list = Reactions.applying("👍", remove: false, to: list, selfId: "me")
        #expect(list == [Self.summary("👍", [("me", nil)])])
        list = Reactions.applying("👍", remove: false, to: list, selfId: "me")
        #expect(list.count == 1 && list[0].identities.count == 1, "adding twice doesn't duplicate")
        let other = [Self.summary("👍", [("u2", "Sam")])]
        let joined = Reactions.applying("👍", remove: false, to: other, selfId: "me", label: "Me")
        #expect(joined == [Self.summary("👍", [("u2", "Sam"), ("me", "Me")])])
        #expect(Reactions.applying("👍", remove: true, to: joined, selfId: "me") == other)
        #expect(Reactions.applying("👍", remove: true, to: other, selfId: "me") == other, "removing what you never added is a no-op")
        #expect(Reactions.applying("🎉", remove: true, to: other, selfId: "me") == other)
        #expect(Reactions.applying("👍", remove: true, to: list, selfId: "me").isEmpty, "the last identity drops the emoji")
    }

    @Test func setParamsCarrySessionAndRemove() {
        let base: [String: JSONValue] = ["sessionKey": "agent:main:main", "agentId": "main"]
        let add = Reactions.setParams(sessionParams: base, messageId: "m1", emoji: "👍", remove: false)
        #expect(add["sessionKey"]?.text == "agent:main:main" && add["messageId"]?.text == "m1" && add["emoji"]?.text == "👍")
        #expect(add["remove"] == nil)
        #expect(Reactions.setParams(sessionParams: base, messageId: "m1", emoji: "👍", remove: true)["remove"]?.bool == true)
    }

    // MARK: Errors

    @Test func classifiesFallbackErrors() {
        func rpc(_ code: String, _ message: String) -> Error { GatewayError.rpc(code: code, message: message, details: nil) }
        #expect(Reactions.isGatewayReactionsUnavailable(rpc("INVALID_REQUEST", "identified reaction author required")))
        #expect(Reactions.isGatewayReactionsUnavailable(rpc("FORBIDDEN", "role can't react")))
        #expect(Reactions.isGatewayReactionsUnavailable(rpc("INVALID_REQUEST", "unknown method: session.reactions.set")))
        #expect(!Reactions.isGatewayReactionsUnavailable(rpc("INVALID_REQUEST", "unknown message")))
        #expect(!Reactions.isGatewayReactionsUnavailable(rpc("UNAVAILABLE", "try later")))
        #expect(!Reactions.isGatewayReactionsUnavailable(GatewayError.timeout("session.reactions.set")))
        #expect(Reactions.isUnknownMessage(rpc("INVALID_REQUEST", "Unknown message: m9")))
        #expect(!Reactions.isUnknownMessage(rpc("INVALID_REQUEST", "identified reaction author required")))
        #expect(!Reactions.isUnknownMessage(GatewayError.timeout("x")))
    }

    // MARK: Events on a chat

    @MainActor
    func chat() -> (ChatStore, GatewayStore, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile.demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        return (gateway.chat(for: "agent:main:main"), gateway, scratch)
    }

    static func event(_ key: String = "agent:main:main", message: String, emoji: String = "👍", reactions: String,
                      sessionId: String? = nil) -> JSONValue
    {
        let sid = sessionId.map { #""sessionId":"\#($0)","# } ?? ""
        return Fixtures.json(#"{"sessionKey":"\#(key)",\#(sid)"messageId":"\#(message)","emoji":"\#(emoji)","action":"added","reactions":\#(reactions)}"#)
    }

    @MainActor @Test func eventReplacesThatMessagesReactionsWholesale() {
        let (chat, _, scratch) = self.chat()
        defer { scratch.remove() }
        chat.handleReactionEvent(Self.event(message: "m1", reactions: #"[{"emoji":"👍","identities":[{"id":"u2","label":"Sam"}]}]"#))
        chat.handleReactionEvent(Self.event(message: "m2", reactions: #"[{"emoji":"🎉","identities":[{"id":"u2"}]}]"#))
        #expect(chat.sharedReactions["m1"] == [Self.summary("👍", [("u2", "Sam")])])
        chat.handleReactionEvent(Self.event(message: "m1", reactions: #"[{"emoji":"✅","identities":[{"id":"me"}]}]"#))
        #expect(chat.sharedReactions["m1"] == [Self.summary("✅", [("me", nil)])], "replaced, not merged")
        #expect(chat.sharedReactions["m2"] != nil, "other messages are untouched")
        chat.handleReactionEvent(Self.event(message: "m1", reactions: "[]"))
        #expect(chat.sharedReactions["m1"] == nil, "an empty aggregate clears the message")
    }

    @MainActor @Test func eventWithoutMessageIdOrForOtherSessionIsIgnored() {
        let (chat, _, scratch) = self.chat()
        defer { scratch.remove() }
        chat.reactionSync.sessionId = "sid-1"
        chat.handleReactionEvent(Fixtures.json(#"{"sessionKey":"agent:main:main","reactions":[{"emoji":"👍","identities":[{"id":"u2"}]}]}"#))
        chat.handleReactionEvent(Self.event(message: "m1", reactions: #"[{"emoji":"👍","identities":[{"id":"u2"}]}]"#, sessionId: "sid-other"))
        #expect(chat.sharedReactions.isEmpty)
        chat.handleReactionEvent(Self.event(message: "m1", reactions: #"[{"emoji":"👍","identities":[{"id":"u2"}]}]"#, sessionId: "sid-1"))
        #expect(chat.sharedReactions["m1"]?.count == 1)
    }

    @MainActor @Test func eventsDuringInFlightListAreRecordedToWinOverTheSnapshot() {
        let (chat, _, scratch) = self.chat()
        defer { scratch.remove() }
        chat.reactionSync.isListing = true
        chat.handleReactionEvent(Self.event(message: "m1", reactions: #"[{"emoji":"👍","identities":[{"id":"u2"}]}]"#))
        chat.handleReactionEvent(Self.event(message: "m2", reactions: "[]"))
        #expect(chat.reactionSync.eventUpdates["m1"]?.count == 1 && chat.reactionSync.eventUpdates["m2"] == [])
        #expect(chat.reactionSync.revisions["m1"] == 1)
        chat.reactionSync.isListing = false
        chat.handleReactionEvent(Self.event(message: "m3", reactions: #"[{"emoji":"👍","identities":[{"id":"u2"}]}]"#))
        #expect(chat.reactionSync.eventUpdates["m3"] == nil, "events outside a list aren't kept")
    }

    @MainActor @Test func groupsUseGatewayOnlyWhenChatSynced() {
        let (chat, _, scratch) = self.chat()
        defer { scratch.remove() }
        chat.sharedReactions["m1"] = [Self.summary("👍", [("me", "Me")])]
        #expect(!chat.usesGatewayReactions, "unconnected gateway → prefs path")
        #expect(!chat.reactionGroups(for: "m1", agentName: "Claw").contains { $0.actors.contains(.person("Me")) })
    }
}
