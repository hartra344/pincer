import Foundation
import Observation
import Testing
@testable import PincerKit
@testable import PincerUI

/// Gateway reactions (`session.reactions.*`) reach the rows: the estimate counts their chips, and the
/// decoration observation fires when they change.
@MainActor
@Suite("Shared reactions rows")
struct SharedReactionsRowTests {
    let scratch = ScratchDefaults()
    let key = "agent:t:main"

    @Test func sharedReactionsCountForEstimatesAndAreObserved() {
        defer { self.scratch.remove() }
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: self.scratch.defaults, identity: UIFixtures.identity())
        let chat = gateway.chat(for: self.key)
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: self.key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: chat)
        #expect(!context.hasReactions("m1"))

        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking {
            _ = chat.sharedReactions
            _ = chat.reactionSelfId
        } onChange: { flag.fired = true }
        chat.sharedReactions = ["m1": [ReactionSummary(emoji: "👍", identities: [ReactionIdentity(id: "u2", label: "Sam")])]]
        #expect(flag.fired, "a change to sharedReactions is observable")
        #expect(context.hasReactions("m1") == ReactionFeature.isEnabled)
        #expect(!context.hasReactions("m2"))
    }
}
