import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Auto-read of a run's final reply")
struct ChatStoreAutoReadTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)
    static let key = "agent:research:main"

    func chat() -> (ChatStore, Recorder) {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        let chat = store.chat(for: Self.key)
        let recorder = Recorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        return (chat, recorder)
    }

    @MainActor final class Recorder { var items: [ChatItem] = [] }

    func message(_ chat: ChatStore, id: String, text: String? = nil, toolCall: Bool = false) {
        var blocks: [JSONValue] = []
        if let text { blocks.append(["type": "text", "text": .string(text)]) }
        if toolCall { blocks.append(["type": "toolCall", "id": "t1", "name": "exec", "arguments": [:]]) }
        chat.handleSessionMessage(["message": ["role": "assistant", "content": .array(blocks), "__openclaw": ["id": .string(id)]]])
    }

    func final(_ chat: ChatStore, _ runId: String, state: String = "final") {
        chat.handleChat(["runId": .string(runId), "sessionKey": .string(Self.key), "state": .string(state)])
    }

    @Test func speaksOnlyTheLastReplyWhenTheRunSucceeds() {
        let (chat, recorder) = self.chat()
        self.message(chat, id: "a1", text: "Let me check.", toolCall: true)
        self.message(chat, id: "a2", text: "Here is the answer.")
        #expect(recorder.items.isEmpty)
        self.final(chat, "r1")
        #expect(recorder.items.map(\.plainText) == ["Here is the answer."])
    }

    @Test func abortedRunSpeaksNothing() {
        let (chat, recorder) = self.chat()
        self.message(chat, id: "a1", text: "Half an answer")
        self.final(chat, "r1", state: "aborted")
        self.message(chat, id: "a2", text: "Later message")
        #expect(recorder.items.isEmpty)
    }

    @Test func replyArrivingAfterFinalIsSpoken() {
        let (chat, recorder) = self.chat()
        self.final(chat, "r1")
        self.message(chat, id: "a1", text: "Late but final.")
        #expect(recorder.items.count == 1)
    }

    @Test func runWithoutSpeakableTextDoesNotArmTheNextMessage() {
        let (chat, recorder) = self.chat()
        self.message(chat, id: "a1", toolCall: true)
        self.final(chat, "r1")
        // The next run starts; its streamed status clears the wait.
        chat.handleChat(["runId": "r2", "sessionKey": .string(Self.key), "state": "status", "phase": "thinking"])
        self.message(chat, id: "a2", text: "Intermediate text of the next run.")
        #expect(recorder.items.isEmpty)
    }
}
