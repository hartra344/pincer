import Foundation
import Testing
@testable import PincerKit

/// Messages the Gateway marks `display: false` (Talk consult prompts) never reach the chat (#973).
@MainActor
struct TalkHiddenRecordTests {
    static let hidden: JSONValue = ["role": "user", "content": [["type": "text", "text": "consult prompt"]], "display": false,
                                    "provenance": ["kind": "internal_system"], "__openclaw": ["id": "hidden-1"]]
    static let visible: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "Hello"]], "__openclaw": ["id": "visible-1"]]
    static let shownExplicitly: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "Shown"]], "display": true,
                                             "__openclaw": ["id": "shown-1"]]

    @Test func helperOnlyHidesExplicitFalse() {
        #expect(Self.hidden.isHiddenFromChat)
        #expect(!Self.visible.isHiddenFromChat && !Self.shownExplicitly.isHiddenFromChat)
        let stringy: JSONValue = ["display": "false"]
        let missing: JSONValue = ["role": "user"]
        #expect(!stringy.isHiddenFromChat && !missing.isHiddenFromChat)
    }

    @Test func historyParsingSkipsHiddenRecords() {
        let items = ChatStore.parse(Array([Self.hidden, Self.visible, Self.shownExplicitly] as [JSONValue]))
        #expect(items.map(\.id) == ["visible-1", "shown-1"])
    }

    @Test func rewindPointsSkipHiddenUserRecords() {
        let visibleUser: JSONValue = ["role": "user", "content": "real question", "__openclaw": ["id": "user-1"]]
        let points = SessionRewindPoint.points(history: ["messages": [Self.hidden, visibleUser]])
        #expect(points.count == 1 && points.first?.id == "user-1")
    }

    @Test func liveSessionMessageIsDroppedWithoutReload() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline hidden", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let chat = ChatStore(sessionKey: "agent:main:main", agentId: "main", gateway: gateway)
        chat.handleSessionMessage(["message": Self.hidden])
        #expect(chat.items.isEmpty && chat.reloadTask == nil && !chat.stale)
        chat.handleSessionMessage(["message": Self.visible])
        #expect(await eventually { chat.items.map(\.id) == ["visible-1"] })
        chat.handleSessionMessage(["message": Self.hidden])
        #expect(chat.items.map(\.id) == ["visible-1"])
    }

    static let reply: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "Calendar is clear"]], "__openclaw": ["id": "reply-1"]]
    static let laterReply: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "Later"]], "__openclaw": ["id": "reply-2"]]
    static let question: JSONValue = ["role": "user", "content": "real question", "__openclaw": ["id": "user-1"]]

    @Test func historyMarksRepliesToHiddenPrompts() {
        let items = ChatStore.parse([Self.question, Self.visible, Self.hidden, Self.reply])
        #expect(items.map(\.id) == ["user-1", "visible-1", "reply-1"])
        #expect(items[1].followsHiddenPrompt != true && items[2].followsHiddenPrompt == true)
        let reset = ChatStore.parse([Self.hidden, Self.question, Self.laterReply])
        #expect(reset.last?.followsHiddenPrompt != true, "a visible user message resets the flag")
    }

    @Test func liveReplyAfterHiddenPromptCannotBeRegenerated() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "Offline regen", url: "ws://127.0.0.1:9", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let chat = ChatStore(sessionKey: "agent:main:main", agentId: "main", gateway: gateway)
        chat.handleSessionMessage(["message": Self.question])
        chat.handleSessionMessage(["message": Self.hidden])
        chat.handleSessionMessage(["message": Self.reply])
        #expect(await eventually { chat.items.map(\.id) == ["user-1", "reply-1"] })
        #expect(chat.items.last?.followsHiddenPrompt == true)
        #expect(!chat.canRegenerate("reply-1"))
        chat.handleSessionMessage(["message": ["role": "user", "content": "another", "__openclaw": ["id": "user-2"]]])
        chat.handleSessionMessage(["message": Self.laterReply])
        #expect(await eventually { chat.items.last?.id == "reply-2" })
        #expect(chat.items.last?.followsHiddenPrompt != true, "a visible user message resets the live flag")
    }
}
