import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Forwarded transcript VoiceOver author")
struct ForwardedVoiceOverAuthorTests {
    @Test func forwardedAgentIsNamedOnceWithoutChangingVisibleMarker() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Bridge", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
        let key = "agent:main:main"
        let context = TranscriptContext(
            gateway: gateway,
            disclosure: TranscriptDisclosure(),
            agent: AgentSummary(id: "main", name: "Main"),
            sessionKey: key,
            previewImage: { _ in },
            saveFile: { _, _ in },
            chat: gateway.chat(for: key))
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))

        let payload: JSONValue = [
            "role": "assistant",
            "content": [["type": "text", "text": "The lab sensor is noisy."]],
            "provenance": [
                "kind": "inter_session",
                "sourceTool": "sessions_send",
                "sourceSessionKey": "agent:kiko:main",
            ],
            "senderSession": ["sessionKey": "agent:kiko:main", "agentId": "kiko"],
            "__openclaw": ["id": "forwarded-kiko", "runId": "run-1"],
        ]
        let item = try #require(ChatItem(payload, fallbackIndex: 0))
        let turn = try #require(TranscriptBuilder.build([item]).compactMap { entry -> AssistantTurn? in
            if case let .assistant(turn) = entry { return turn }
            return nil
        }.first)
        let layout = builder.layout(.entry(.assistant(turn)), width: 600)
        let header = try #require(layout.parts.compactMap { placed -> TranscriptPart.Header? in
            if case let .header(header) = placed.part { return header }
            return nil
        }.first)

        #expect(turn.sender?.displayName(agents: gateway.agents) == "Kiko",
                "the test uses the actual parsed Gateway sender attribution")
        #expect(header.name == "Kiko")
        #expect(header.badge == "from Kiko’s chat", "the visible forwarded marker remains descriptive")
        #expect(layout.accessibilityLabel.hasPrefix("Kiko, forwarded,"),
                "VoiceOver should identify a forwarded sender without repeating their name")

        var ordinary = AssistantTurn(id: "ordinary", timestamp: nil)
        ordinary.text = ["A normal reply."]
        let ordinaryLayout = builder.layout(.entry(.assistant(ordinary)), width: 600)
        #expect(ordinaryLayout.accessibilityLabel.hasPrefix("Main,"),
                "messages written by the receiving agent keep their normal author")
        #expect(!ordinaryLayout.accessibilityLabel.contains("forwarded"))
    }
}
