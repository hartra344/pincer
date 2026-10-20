import Foundation
@testable import PincerKit
@testable import PincerUI

/// Fixtures shared by the AppKit (`TranscriptPremeasureTests`) and UIKit (`TranscriptUIKitHostedTests`) premeasure hosts.
@MainActor
enum PremeasureProbe {
    static func assistant(_ id: String, text: String, streaming: Bool = false, at n: Int) -> TranscriptRow {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(n))
        var turn = AssistantTurn(id: id, timestamp: stamp)
        turn.text = [text]
        turn.textTimestamps = [stamp]
        turn.textModelNames = [nil]
        turn.textIds = [id]
        turn.isStreaming = streaming
        return .entry(.assistant(turn))
    }

    /// The transcript context of a never-connected probe gateway.
    static func context() -> TranscriptContext {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Probe", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:probe:main"
        return TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                 agent: AgentSummary(id: "probe", name: "Probe"), sessionKey: key,
                                 previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
    }
}
