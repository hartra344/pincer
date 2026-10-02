import Foundation
@testable import PincerKit
@testable import PincerUI
import Testing

private actor HeldReplyPreparation {
    private let heldMessageID: String
    private var starts: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(heldMessageID: String) { self.heldMessageID = heldMessageID }

    func prepare(_ items: [ChatItem]) async -> SpeechText.PreparedReply? {
        let newestID = items.last?.id ?? "empty"
        self.starts.append(newestID)
        if newestID == self.heldMessageID {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return SpeechText.latestSpeakableReply(in: items)
    }

    func waitUntilHeld() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while self.continuation == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.continuation != nil
    }

    func releaseHeld() { self.continuation?.resume(); self.continuation = nil }
    var startCount: Int { self.starts.count }
}

@MainActor
private final class CommandTestSpeaker: ReadAloudLocalSpeaking {
    func speak(_ text: String, voice: String?, rate: Float) async -> Bool { true }
    func stop() {}
}

@MainActor
private final class CommandTestClips: ReadAloudClipPlaying {
    func play(_ clip: TTSClip) async -> Bool { true }
    func stop() {}
}

/// The macOS menu and invisible iPad hardware-shortcut button both evaluate this actual state.
@MainActor
@Suite("Read Last Reply command readiness", .serialized)
struct ReadAloudCommandReadinessTests {
    @Test func commandValidationDoesNotNormalizeTranscriptBodiesOnMain() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Command probe", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: "agent:probe:command-readiness")
        let id = "command-readiness-\(UUID().uuidString)"
        let prose = String(repeating: "## Answer\nA **finished reply** with [a source](https://docs.example/guide).\n\n", count: 80)
        chat.items = [ChatItem(id: id, role: .assistant, blocks: [.text(prose)])]
        let state = ReadAloudChatState()
        SpeechText.resetSpeakabilityDebugStats(tracking: id)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: id) }
        state.bind(chat: chat, gateway: gateway)

        let enabled = await eventually { state.isEnabled }
        #expect(enabled, "the existing command remains available for assistant prose")
        #expect(state.lastReply?.id == id, "the command still targets the newest speakable reply")
        #expect(state.isEnabled && state.isEnabled, "repeated menu/shortcut validation stays enabled")
        let stats = SpeechText.speakabilityDebugStats(for: id)
        #expect(stats.mainThreadNormalizations == 0,
                "menu and hardware-shortcut validation must consume prepared readiness instead of parsing a reply on main")
        #expect(stats.offMainNormalizations >= 1, "readiness was actually prepared on a worker")
        state.unbind()
    }

    @Test func sameIDEditsAndChatSwitchesReplacePreparedReplyAndPlaybackUsesIt() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Command probe", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: "agent:probe:command-same-id")
        let itemID = "command-same-id-\(UUID().uuidString)"
        chat.items = [ChatItem(id: itemID, role: .assistant, blocks: [.text("First body")])]
        let playback = ReadAloudController(clipPlayer: CommandTestClips(), localSpeaker: CommandTestSpeaker(), defaults: scratch.defaults)
        let state = ReadAloudChatState(controller: playback)
        SpeechText.resetSpeakabilityDebugStats(tracking: itemID)
        defer { SpeechText.unregisterSpeakabilityDebugStats(tracking: itemID) }
        state.bind(chat: chat, gateway: gateway)
        let firstReady = await eventually { state.lastReply?.text == "First body" }
        #expect(firstReady)

        chat.items = [ChatItem(id: itemID, role: .assistant, blocks: [.text("Edited body")])]
        let editReady = await eventually { state.lastReply?.text == "Edited body" }
        #expect(editReady, "an edited body under the same ID replaces its prepared text")
        let debugStats = SpeechText.speakabilityDebugStats(for: itemID)
        #expect(debugStats.mainThreadNormalizations == 0)
        #expect(debugStats.offMainNormalizations >= 2, "both same-ID bodies were prepared off the UI thread")
        state.toggleLastReply()
        #expect(playback.activeMessageId == itemID, "the command starts from the already prepared item")
        playback.stop()

        chat.onFinalAssistantReplyOwner = state
        chat.onFinalAssistantReply = { _ in }
        let other = gateway.chat(for: "agent:probe:command-other-chat")
        let otherID = "command-other-\(UUID().uuidString)"
        other.items = [ChatItem(id: otherID, role: .assistant, blocks: [.text("Other chat reply")])]
        state.bind(chat: other, gateway: gateway)
        #expect(chat.onFinalAssistantReply == nil && chat.onFinalAssistantReplyOwner == nil,
                "switching chats removes only this state's old auto-read callback")
        let switched = await eventually { state.lastReply?.id == otherID }
        #expect(switched, "a chat switch cannot publish a result from the previous transcript")
        chat.items = [ChatItem(id: itemID, role: .assistant, blocks: [.text("Stale former chat" )])]
        await Task.yield()
        #expect(state.lastReply?.id == otherID)

        let foreignOwner = NSObject()
        other.onFinalAssistantReplyOwner = foreignOwner
        other.onFinalAssistantReply = { _ in }
        state.bind(chat: chat, gateway: gateway)
        #expect(other.onFinalAssistantReplyOwner === foreignOwner && other.onFinalAssistantReply != nil,
                "switching chats preserves a callback owned by another window")
        state.unbind()
    }

    @Test func canceledPreparationCoalescesToLatestTranscriptSnapshot() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Command probe", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: "agent:probe:command-coalesce")
        let heldID = "held-\(UUID().uuidString)"
        let gate = HeldReplyPreparation(heldMessageID: heldID)
        chat.items = [ChatItem(id: heldID, role: .assistant, blocks: [.text("Old body")])]
        let state = ReadAloudChatState(prepareReply: { items in await gate.prepare(items) })
        state.bind(chat: chat, gateway: gateway)
        let held = await gate.waitUntilHeld()
        #expect(held, "the first snapshot is held on the worker")

        let newestID = "newest-\(UUID().uuidString)"
        chat.items = [ChatItem(id: newestID, role: .assistant, blocks: [.text("Newest body")])]
        #expect(state.lastReply?.id == nil, "stale readiness clears immediately while the worker catches up")
        await gate.releaseHeld()
        let newestReady = await eventually { state.lastReply?.id == newestID }
        #expect(newestReady, "completion of canceled work drains the coalesced newest snapshot")
        let startCount = await gate.startCount
        #expect(startCount == 2, "only one canceled scan and one latest scan are started")
        state.unbind()
    }
}
