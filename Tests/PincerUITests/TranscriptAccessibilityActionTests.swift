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

    func renderer() -> (TranscriptRenderer, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
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
