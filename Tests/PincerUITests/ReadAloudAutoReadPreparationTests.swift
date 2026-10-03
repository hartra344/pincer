import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
private final class HeldAutoReadSpeaker: ReadAloudLocalSpeaking {
    private(set) var spokenTexts: [String] = []
    private var completion: CheckedContinuation<Bool, Never>?

    func speak(_ text: String, voice: String?, rate: Float) async -> Bool {
        self.spokenTexts.append(text)
        return await withCheckedContinuation { self.completion = $0 }
    }

    func stop() {
        self.completion?.resume(returning: false)
        self.completion = nil
    }
}

@MainActor
private final class SilentAutoReadPlayer: ReadAloudClipPlaying {
    func play(_: TTSClip) async -> Bool { false }
    func stop() {}
}

@MainActor
@Suite("Read Aloud enabled callback preparation", .serialized)
struct ReadAloudAutoReadPreparationTests {
    @Test func acceptedFinalReplyIsNormalizedOnceOnMainAndPlayedOnce() async {
        let scratch = ScratchDefaults()
        let sessionKey = "agent:probe:auto-read-preparation-\(UUID().uuidString)"
        let itemID = "auto-read-preparation-\(UUID().uuidString)"
        let reply = "The accepted reply has the selected content."
        let profile = GatewayProfile(name: "Auto-read probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: sessionKey)
        let speaker = HeldAutoReadSpeaker()
        scratch.defaults.set(ReadAloudSettings.sourceDevice, forKey: ReadAloudSettings.sourceKey)
        let controller = ReadAloudController(
            clipPlayer: SilentAutoReadPlayer(), localSpeaker: speaker, defaults: scratch.defaults)
        let state = ReadAloudChatState(controller: controller)
        SpeechText.resetSpeakabilityDebugStats(tracking: itemID)
        defer {
            state.unbind()
            controller.stop()
            SpeechText.unregisterSpeakabilityDebugStats(tracking: itemID)
            scratch.remove()
        }

        state.bind(chat: chat, gateway: gateway)
        state.installAutoReadCallback()
        chat.handleChat([
            "runId": .string("run-\(UUID().uuidString)"),
            "sessionKey": .string(sessionKey),
            "state": .string("final"),
        ])
        chat.handleSessionMessage([
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": .string(reply)]],
                "__openclaw": ["id": .string(itemID)],
            ],
        ])

        let speakerStarted = await eventually {
            speaker.spokenTexts.count == 1
                && chat.items.contains { $0.id == itemID && $0.plainText == reply }
                && controller.activeMessageId == itemID
        }
        #expect(speakerStarted, "the production callback reaches the injected device speaker")
        #expect(chat.items.contains { $0.id == itemID && $0.plainText == reply })
        #expect(controller.activeMessageId == itemID,
                "the accepted final event still starts playback for its message")
        #expect(speaker.spokenTexts == [reply], "playback receives the normalized reply exactly once")

        let stats = SpeechText.speakabilityDebugStats(for: itemID)
        #expect(stats.mainThreadNormalizations == 1,
                "Kit keeps its synchronous eligibility check while the UI callback uses prepared text")
    }
}
