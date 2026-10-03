import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #349 per-message VoiceOver actions and #269 the streaming reply's spoken label.
@MainActor
@Suite("Transcript accessibility actions")
struct TranscriptAccessibilityActionTests {
    @Test func threeMessagesGetNumberedActionsForEach() {
        let names = TranscriptRowAccessibilityAction.perMessageActionNames(messageCount: 3, bookmarked: [false, true, false],
                                                                          reactions: true)
        for part in 1...3 {
            #expect(names.contains("Reply, part \(part) of 3"), "\(names)")
            #expect(names.contains("Copy Link, part \(part) of 3"), "\(names)")
            #expect(names.contains("Add Reaction, part \(part) of 3"), "\(names)")
        }
        #expect(names.filter { $0.hasPrefix("Reply") }.count == 3)
        #expect(names.contains("Bookmark, part 1 of 3") && names.contains("Remove Bookmark, part 2 of 3"))
    }

    @Test func singleMessageNamesAreUnchanged() {
        let names = TranscriptRowAccessibilityAction.perMessageActionNames(messageCount: 1, bookmarked: [false], reactions: true)
        #expect(names.contains("Reply") && names.contains("Copy Link") && names.contains("Bookmark") && names.contains("Add Reaction"))
        #expect(!names.contains { $0.contains("part") })
        let marked = TranscriptRowAccessibilityAction.perMessageActionNames(messageCount: 1, bookmarked: [true], reactions: false)
        #expect(marked.contains("Remove Bookmark") && !marked.contains("Add Reaction"))
    }

    func renderer(reply: @escaping (String) -> Void = { _ in }) -> (TranscriptRenderer, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key),
                                        reply: reply)
        return (TranscriptRenderer(context: context), scratch)
    }

    @Test func multiMessageTurnLayoutHasOneAnchorPerMessage() {
        let (renderer, scratch) = self.renderer()
        defer { scratch.remove() }
        var turn = AssistantTurn(id: "multi", timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["One.", "Two.", "Three."]
        turn.textIds = ["m1", "m2", "m3"]
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: 500)
        #expect(layout.messages.map(\.id) == ["m1", "m2", "m3"])
    }

    @Test func renderedPartActionsIdentifyTheirMessageWithoutChangingTargets() async {
        var replyTargets: [String] = []
        let (renderer, scratch) = self.renderer { replyTargets.append($0) }
        defer { scratch.remove() }
        var turn = AssistantTurn(id: "multi", timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["ALPHA-OPEN: First distinctive opening.", "BETA-OPEN: Second distinctive opening."]
        turn.textIds = ["message-alpha", "message-beta"]
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: 500)
        let sources = layout.messages.compactMap(\.openingExcerptSource)
        let excerptsReady = await eventually(timeout: .seconds(3)) {
            sources.count == 2 && sources.allSatisfy { MessagePartExcerptCache.shared.excerpt(for: $0) != nil }
        }
        #expect(excerptsReady, "The actual renderer path should prepare both bounded opening excerpts off-main")
        let anchor = PView(frame: CGRect(x: 0, y: 0, width: 500, height: layout.height))
        let actions = TranscriptRowAccessibilityAction.actions(for: layout, actions: renderer, anchor: anchor)
        let replies = actions.filter { $0.name.hasPrefix("Reply") }

        #expect(layout.messages.map(\.id) == ["message-alpha", "message-beta"])
        #expect(replies.count == 2)
        #expect(replies.map(\.name).map { $0.contains("part 1 of 2") ? 1 : 2 } == [1, 2])
        #expect(replies.contains { $0.name.contains("ALPHA-OPEN") }
                && replies.contains { $0.name.contains("BETA-OPEN") }, "Reply actions should identify each message's opening: \(replies.map(\.name))")
        replies.forEach { $0.perform() }
        #expect(replyTargets == ["message-alpha", "message-beta"])

        var single = AssistantTurn(id: "single", timestamp: Date(timeIntervalSince1970: 2))
        single.text = ["SINGLE-OPEN: Keep the existing single-message action label."]
        single.textIds = ["message-single"]
        let singleLayout = renderer.layout(for: .entry(.assistant(single)), width: 500)
        let singleActions = TranscriptRowAccessibilityAction.actions(
            for: singleLayout,
            actions: renderer,
            anchor: PView(frame: CGRect(x: 0, y: 0, width: 500, height: singleLayout.height))
        )
        let singleReply = singleActions.first { $0.name.hasPrefix("Reply") }
        #expect(singleReply?.name == "Reply")
        singleReply?.perform()
        #expect(replyTargets == ["message-alpha", "message-beta", "message-single"])
    }

    @Test func streamingLabelStartsWithTheReplysFirstWords() {
        let (renderer, scratch) = self.renderer()
        defer { scratch.remove() }
        var turn = AssistantTurn(id: "live-run_x", timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["Opening sentence here. " + String(repeating: "filler words go on. ", count: 400) + "FINAL-TAIL"]
        turn.isStreaming = true
        let label = renderer.layout(for: .entry(.assistant(turn)), width: 500).accessibilityLabel
        #expect(label.contains("Responding"), "\(label)")
        #expect(label.contains("Opening sentence here."), "\(label.prefix(200))")
        #expect(!label.contains("FINAL-TAIL"))
        #expect(label.count < 400)
    }

    @Test func committedLabelIsUnchanged() {
        let (renderer, scratch) = self.renderer()
        defer { scratch.remove() }
        var turn = AssistantTurn(id: "done", timestamp: Date(timeIntervalSince1970: 1))
        turn.text = ["Whole reply, start to FINAL-TAIL"]
        let label = renderer.layout(for: .entry(.assistant(turn)), width: 500).accessibilityLabel
        #expect(label.contains("FINAL-TAIL"))
    }
}
