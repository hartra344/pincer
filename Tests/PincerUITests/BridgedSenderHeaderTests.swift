import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// A parsed bridged sender should remain visible in the actual transcript row header.
@MainActor
@Suite("Bridged transcript sender header")
struct BridgedSenderHeaderTests {
    @Test func bridgedNameReachesHeaderAndAccessibilityWhileLocalRowsKeepOwner() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Bridge", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
        let key = "agent:main:telegram:dm:maya"
        let context = TranscriptContext(
            gateway: gateway,
            disclosure: TranscriptDisclosure(),
            agent: AgentSummary(id: "main", name: "Main"),
            sessionKey: key,
            previewImage: { _ in },
            saveFile: { _, _ in },
            chat: gateway.chat(for: key))
        let builder = TranscriptLayoutBuilder(context: context, settings: .current(for: context))

        let bridgedPayload: JSONValue = [
            "role": "user",
            "senderLabel": "Maya Chen (0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0)",
            "content": [["type": "text", "text": "The lab sensor is noisy."]],
            "__openclaw": [
                "id": "telegram-maya-1",
                "transport": ["channel": "telegram", "messageId": "telegram-maya-1"],
            ],
        ]
        let bridged = try #require(ChatItem(bridgedPayload, fallbackIndex: 0))
        #expect(bridged.channelSenderName == "Maya Chen", "the actual Gateway parser extracts the bridged sender")
        #expect(bridged.senderName(you: Owner.displayName, agent: context.agent.name, agents: gateway.agents) == "Maya Chen")

        let bridgedLayout = builder.layout(.entry(.user(bridged)), width: 600)
        let bridgedHeader = try #require(self.header(in: bridgedLayout))
        #expect(bridgedHeader.name == "Maya Chen")
        #expect(bridgedLayout.accessibilityLabel.hasPrefix("Maya Chen"),
                "VoiceOver should identify the same named sender shown in the row header")

        let local = ChatItem(id: "local-draft", role: .user, blocks: [.text("A local message")], timestamp: nil)
        let localLayout = builder.layout(.entry(.user(local)), width: 600)
        #expect(try #require(self.header(in: localLayout)).name == Owner.displayName,
                "messages without a bridged sender retain the owner's display name")
        #expect(localLayout.accessibilityLabel.hasPrefix(L("You")))
    }

    private func header(in layout: TranscriptRowLayout) -> TranscriptPart.Header? {
        layout.parts.compactMap { placed -> TranscriptPart.Header? in
            if case let .header(header) = placed.part { return header }
            return nil
        }.first
    }
}
