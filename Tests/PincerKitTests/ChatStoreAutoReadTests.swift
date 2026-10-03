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

    @Test func acceptedFinalSessionMessageIsNormalizedOnceWhenReadAloudIsEnabled() async {
        let (chat, recorder) = self.chat()
        let id = "accepted-final-reply-\(UUID().uuidString)"
        SpeechText.resetSpeakabilityDebugStats(tracking: id)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: id) }

        self.final(chat, "run-accepted-final")
        self.message(chat, id: id, text: "**A committed answer** with `details`.")

        #expect(await eventually { recorder.items.count == 1 && chat.items.contains { $0.id == id } })
        let committed = chat.items.first { $0.id == id }
        #expect(committed?.role == .assistant && committed?.isPending == false)
        #expect(recorder.items.map(\.id) == [id], "the successful final-reply callback receives the accepted item once")
        #expect(recorder.items.first?.plainText == committed?.plainText)

        let stats = SpeechText.speakabilityDebugStats(for: id)
        #expect(stats.mainThreadNormalizations + stats.offMainNormalizations >= 1,
                "the enabled final-reply path checks the accepted item's speakability")
    }

    @Test func acceptedFinalMessageWithoutReadAloudCallbackStillCommitsAndClearsWait() async {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        let chat = store.chat(for: Self.key)
        let id = "accepted-final-disabled-\(UUID().uuidString)"
        SpeechText.resetSpeakabilityDebugStats(tracking: id)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: id) }
        chat.noteRunSucceeded("run-disabled")
        #expect(!chat.awaitingFinalReply, "without a callback, success does not arm a future delivery")

        self.message(chat, id: id, text: "The reply remains in the transcript.")

        #expect(await eventually { chat.items.contains { $0.id == id } })
        #expect(chat.items.first { $0.id == id }?.plainText == "The reply remains in the transcript.")
        #expect(!chat.awaitingFinalReply, "the disabled path leaves no pending final-reply delivery")
        #expect(chat.onFinalAssistantReply == nil, "the disabled path has no playback callback installed")
        #expect(SpeechText.speakabilityDebugStats(for: id).mainThreadNormalizations == 0,
                "disabled Read Aloud must not parse the accepted reply on main")
    }

    @Test func thinkingPresenceIncludesEmptyBlocksAndExcludesOrdinaryText() throws {
        let (chat, _) = self.chat()
        chat.onFinalAssistantReply = nil
        self.message(chat, id: "ordinary-text", text: "No reasoning block.")
        #expect(!chat.sawThinking)
        #expect(chat.items.last?.hasThinkingContent == false)
        #expect(chat.items.last?.thinkingText == nil)

        // Preserve nil-versus-empty getter semantics for locally constructed transcript models.
        var emptyThinking = try #require(chat.items.last)
        emptyThinking.id = "empty-thinking"
        emptyThinking.transcriptId = "empty-thinking"
        emptyThinking.blocks = [.thinking("")]
        chat.items.append(emptyThinking)
        #expect(chat.sawThinking)
        #expect(chat.items.last?.hasThinkingContent == true)
        #expect(chat.items.last?.thinkingText == "", "actual text consumers retain the empty reasoning value")
    }

    @Test func acceptedThinkingMessagePresenceDoesNotJoinLongTextOnMain() {
        let (chat, _) = self.chat()
        chat.onFinalAssistantReply = nil
        let id = "accepted-thinking-presence-\(UUID().uuidString)"
        ChatItem.resetThinkingTextJoinProbe(tracking: id)
        defer { ChatItem.unregisterThinkingTextJoinProbe(tracking: id) }

        let longThinking = String(repeating: "thinking-token ", count: 8_000)
        chat.handleSessionMessage(["message": [
            "role": "assistant",
            "content": .array([
                ["type": "thinking", "thinking": .string(longThinking)],
                ["type": "thinking", "thinking": .string(longThinking)],
                ["type": "text", "text": .string("Committed reply")],
            ]),
            "__openclaw": ["id": .string(id)],
        ]])

        #expect(chat.sawThinking)
        #expect(chat.items.contains { $0.id == id })
        #expect(ChatItem.thinkingTextJoinProbeStats(for: id).mainThreadJoins == 0,
                "presence-only accepted-message and rebuild checks must not join the thinking payload")
    }

    @Test func uninstallingReadAloudDropsPreviouslyEligibleReply() {
        let (chat, recorder) = self.chat()
        self.message(chat, id: "prepared-before-uninstall", text: "This arrived with auto-read enabled.")
        #expect(chat.liveReplyCandidate?.id == "prepared-before-uninstall")
        chat.onFinalAssistantReply = nil
        #expect(chat.liveReplyCandidate == nil && !chat.awaitingFinalReply)
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        self.final(chat, "finished-after-uninstall")
        #expect(recorder.items.isEmpty, "reinstalling a callback must not resurrect discarded reply text")
    }

    @Test func reenabledReadAloudDoesNotReplayReplyObservedWhileDisabled() {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        let chat = store.chat(for: Self.key)
        let id = "accepted-final-disabled-before-enable-\(UUID().uuidString)"
        SpeechText.resetSpeakabilityDebugStats(tracking: id)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: id) }

        self.message(chat, id: id, text: "This arrived while Read Aloud was disabled.")
        #expect(chat.liveReplyCandidate == nil)
        self.final(chat, "run-disabled")
        #expect(!chat.awaitingFinalReply)

        let recorder = Recorder()
        chat.onFinalAssistantReply = { recorder.items.append($0) }
        self.final(chat, "run-disabled")

        #expect(recorder.items.isEmpty, "reenabling Read Aloud must not replay a disabled-period candidate")
        #expect(!chat.awaitingFinalReply, "replaying the disabled run's final event does not arm a stale wait")
        self.final(chat, "run-next")
        self.message(chat, id: "next-enabled-reply", text: "A fresh run's answer.")
        #expect(recorder.items.map(\.id) == ["next-enabled-reply"], "a later enabled run still delivers its own reply")
        let stats = SpeechText.speakabilityDebugStats(for: id)
        #expect(stats.mainThreadNormalizations == 0 && stats.offMainNormalizations == 0,
                "a reply received with no callback is discarded without speech normalization")
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
