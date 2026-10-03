import Foundation
@testable import PincerKit
@testable import PincerUI
import Testing

@MainActor
@Suite("Cold transcript height estimates")
struct ColdTranscriptHeightEstimateTests {
    @Test(arguments: [false, true])
    func actualControllerColdEstimateDoesNotJoinOrScanFullText(assistant: Bool) async {
        let pieces = await Task.detached {
            (0..<8).map { _ in String(repeating: "Readable text\n", count: 20_000) }
        }.value
        let row: TranscriptRow
        if assistant {
            var turn = AssistantTurn(id: "cold-height-assistant", timestamp: nil)
            turn.text = pieces
            row = .entry(.assistant(turn))
        } else {
            row = .entry(.user(ChatItem(id: "cold-height-user", role: .user,
                blocks: pieces.map { .text($0) }, timestamp: nil)))
        }

        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = TranscriptListControllerTests().make(scratch)
        ColdTranscriptHeightEstimateProbe.register(row.id)
        defer { ColdTranscriptHeightEstimateProbe.remove(row.id) }
        _ = controller.accept([row], contextChanged: false)
        let height = controller.height(at: 0, width: 360)
        #expect(height.isFinite && height > 0)
        let cost = ColdTranscriptHeightEstimateProbe.snapshot(row.id)
        #expect(cost.operations > 0, "observe the real cold estimate boundary")
        #expect(cost.inputBytes <= 16 * 1024, "cold geometry must inspect bounded text")
        #expect(cost.metadataVisits <= 64)
        #expect(cost.joinedSources == 0, "cold geometry must not join message text")
        #expect(controller.height(at: 0, width: 360) == height)
        #expect(ColdTranscriptHeightEstimateProbe.snapshot(row.id) == cost, "cache hit performs no text work")
    }

    @Test func actualControllerModerateEstimateRespondsToWidth() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (narrow, _, _) = TranscriptListControllerTests().make(scratch)
        let (wide, _, _) = TranscriptListControllerTests().make(scratch)
        let row = TranscriptListControllerTests.user(901, text: String(repeating: "Readable sentence. ", count: 50))
        _ = narrow.accept([row], contextChanged: false)
        _ = wide.accept([row], contextChanged: false)
        let small = narrow.height(at: 0, width: 240)
        let large = wide.height(at: 0, width: 640)
        #expect(small.isFinite && large.isFinite && large > 0)
        #expect(small > large)
    }

    @Test func actualPremeasureCanReplaceColdEstimateWithoutChangingReaderAnchor() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = TranscriptListControllerTests().make(scratch)
        let row = TranscriptListControllerTests.user(902, text: "A measured paragraph with real text.")
        _ = controller.accept([row], contextChanged: false)
        controller.anchor = .row(row.id, 12)
        _ = controller.height(at: 0, width: 360)
        let driver = controller.premeasure
        let job = try #require(driver.split([0], all: controller.rows, width: 360,
                                            renderer: controller.renderer).offload.first)
        let result = await TranscriptPremeasurer.shared.measureWithin(
            5, jobs: [job], env: controller.renderer.textEnvironment, epoch: driver.epoch)
        #expect(result.count == 1)
        #expect(!driver.adopt(result, width: 360, epoch: driver.epoch.current).isEmpty)
        let layout = controller.renderer.layout(for: row, width: 360)
        #expect(layout.height.isFinite && layout.height > 0)
        #expect(controller.anchor == .row(row.id, 12))
    }
    @Test(arguments: ["many-blocks", "foreign", "giant-grapheme"])
    func actualControllerFallbackSourcesStayBounded(_ kind: String) async throws {
        let blocks = await Task.detached { () -> [ContentBlock] in
            switch kind {
            case "many-blocks": return Array(repeating: .text("Small paragraph"), count: 1000)
            case "foreign": return [.text(NSString(string: String(repeating: "\u{2003}", count: 30_000) + "Answer") as String)]
            default: return [.text("a" + String(repeating: "\u{301}", count: 100_000))]
            }
        }.value
        if kind == "foreign", case let .text(text) = blocks[0] { try #require(!text.isContiguousUTF8) }
        let row = TranscriptRow.entry(.user(ChatItem(id: "cold-\(kind)", role: .user, blocks: blocks)))
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let (controller, _, _) = TranscriptListControllerTests().make(scratch)
        ColdTranscriptHeightEstimateProbe.register(row.id)
        defer { ColdTranscriptHeightEstimateProbe.remove(row.id) }
        _ = controller.accept([row], contextChanged: false)
        let height = controller.height(at: 0, width: 360)
        let cost = ColdTranscriptHeightEstimateProbe.snapshot(row.id)
        #expect(height.isFinite && height > 0 && cost.operations > 0)
        #expect(cost.joinedSources == 0 && cost.inputBytes <= 16 * 1024 && cost.metadataVisits <= 64)
        if kind == "foreign" { #expect(cost.inputBytes == 0) }
        #expect(controller.height(at: 0, width: 360) == height)
        #expect(ColdTranscriptHeightEstimateProbe.snapshot(row.id) == cost)
    }

}
