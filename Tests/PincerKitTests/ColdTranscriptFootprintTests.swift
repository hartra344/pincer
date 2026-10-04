import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Bounded cold transcript footprint")
struct ColdTranscriptFootprintTests {
    @Test func ordinaryParagraphsAndWidthRemainMeaningful() {
        let item = ChatItem(role: .user, blocks: [.text("First"), .text("Second")])
        let result = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: 20)
        #expect(result.lines == 3 && result.hasRawText && !result.incomplete)
        #expect(result.inspectedBytes == 11 && result.metadataVisits == 2)
        let text = String(repeating: "Sentence ", count: 50)
        let row = TranscriptEntry.user(ChatItem(role: .user, blocks: [.text(text)]))
        #expect(ColdTranscriptFootprint.estimate(row, charactersPerLine: 20).lines > ColdTranscriptFootprint.estimate(row, charactersPerLine: 70).lines)
        #expect(!ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: [.text("")])), charactersPerLine: 20).hasRawText)
        #expect(ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: [.text(""), .text("")])), charactersPerLine: 20).hasRawText,
                "joined separators contribute raw content without assembling a string")
    }
    @Test func sharedByteAndMetadataBudgetsIncludeReactionLookups() async {
        let pieces = await Task.detached { (0..<8).map { _ in String(repeating: "a\n", count: 20_000) } }.value
        var turn = AssistantTurn(id: "bounded", timestamp: nil)
        turn.text = pieces
        turn.textIds = (0..<100).map { "text-\($0)" }
        var lookups = 0
        let result = ColdTranscriptFootprint.estimate(.assistant(turn), charactersPerLine: 30) { _ in lookups += 1; return true }
        #expect(result.inspectedBytes == ColdTranscriptFootprint.byteLimit)
        #expect(result.metadataVisits == ColdTranscriptFootprint.visitLimit && lookups == 56)
        #expect(result.incomplete && result.lines.isFinite && result.extraHeight > 0)
        let blocks = Array(repeating: ContentBlock.text("tiny"), count: 1000)
        let many = ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: blocks)), charactersPerLine: 30)
        #expect(many.metadataVisits == 64 && many.inspectedBytes == 256 && many.incomplete)
    }
    @Test func foreignAndGiantGraphemeNeverRequireFullMaterialization() async throws {
        let sources = await Task.detached { () -> (String, String) in
            (NSString(string: String(repeating: "\u{2003}", count: 20_000) + "Answer") as String,
             "a" + String(repeating: "\u{301}", count: 100_000))
        }.value
        try #require(!sources.0.isContiguousUTF8, "real foreign NSString fixture")
        let foreign = ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: [.text(sources.0)])), charactersPerLine: 30)
        #expect(foreign.inspectedBytes == 0 && foreign.incomplete && foreign.hasRawText && foreign.lines.isFinite)
        let giant = ColdTranscriptFootprint.estimate(.user(ChatItem(role: .user, blocks: [.text(sources.1)])), charactersPerLine: 30)
        #expect(giant.inspectedBytes <= 16 * 1024 && giant.incomplete && giant.lines.isFinite)
    }
    @Test func reactionEligibilityFollowsBoundedIdentifierAdmission() async throws {
        let foreign = await Task.detached { NSString(string: String(repeating: "\u{2003}", count: 20_000)) as String }.value
        try #require(!foreign.isContiguousUTF8)
        let oversized = "a" + String(repeating: "\u{301}", count: 1000)
        for id in [foreign, oversized] {
            var item = ChatItem(role: .user, blocks: [.text("Hello")])
            item.transcriptId = id
            var lookups = 0
            let estimate = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: 30) { _ in
                lookups += 1; return true
            }
            #expect(estimate.incomplete && estimate.metadataVisits == 2 && lookups == 0)
        }
        for id in ["pending:short", "committed-short"] {
            var item = ChatItem(role: .user, blocks: [.text("Hello")])
            item.transcriptId = id
            var lookups = 0
            let estimate = ColdTranscriptFootprint.estimate(.user(item), charactersPerLine: 30) { key in
                #expect(key == id); lookups += 1; return true
            }
            #expect(!estimate.incomplete && estimate.metadataVisits == 2)
            #expect(lookups == (id == "pending:short" ? 0 : 1))
            #expect(estimate.reactionCount == lookups)
        }
    }

}
