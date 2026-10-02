import Foundation
@testable import PincerKit
@testable import PincerUI
import Testing

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
        state.chat = chat
        state.gateway = gateway
        SpeechText.resetSpeakabilityDebugStats(tracking: id)

        let enabled = await eventually { state.isEnabled }
        #expect(enabled, "the existing command remains available for assistant prose")
        #expect(state.lastReply?.id == id, "the command still targets the newest speakable reply")
        #expect(state.isEnabled && state.isEnabled, "repeated menu/shortcut validation stays enabled")
        #expect(SpeechText.speakabilityDebugStats.mainThreadNormalizations == 0,
                "menu and hardware-shortcut validation must consume prepared readiness instead of parsing a reply on main")
    }
}
