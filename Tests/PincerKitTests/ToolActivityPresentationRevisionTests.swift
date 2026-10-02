import Foundation
import Testing
@testable import PincerKit

@Suite("Tool activity presentation revisions")
struct ToolActivityPresentationRevisionTests {
    @Test func equalReconstructionAndCopiesHaveStableSemanticIdentity() {
        let original = Self.tool(id: "revision-equality", status: 200)
        let reconstructed = Self.tool(id: "revision-equality", status: 200)
        let copy = original

        #expect(original.presentationCacheRevision != reconstructed.presentationCacheRevision,
                "independently made values have distinct cache revisions")
        #expect(copy.presentationCacheRevision == original.presentationCacheRevision,
                "a value copy preserves the revision")
        #expect(original == reconstructed && original.hashValue == reconstructed.hashValue,
                "cache revision is excluded from semantic equality and hashing")
        #expect(Set([original, reconstructed]).count == 1)

        var changed = copy
        changed.details = ["status": 404]
        #expect(changed.presentationCacheRevision != copy.presentationCacheRevision,
                "changing presentation details rotates the cache revision")
        #expect(changed != copy)
        #expect(ToolCallPresentation.make(changed).output?.status == "404")
    }

    @Test func equalToolSnapshotsKeepTheirTranscriptEntryIdentity() {
        let one = Self.tool(id: "revision-row", status: 200)
        let two = Self.tool(id: "revision-row", status: 200)
        var firstTurn = AssistantTurn(id: "same-turn", timestamp: Date(timeIntervalSince1970: 10))
        var secondTurn = firstTurn
        firstTurn.tools = [one]
        secondTurn.tools = [two]

        #expect(one.presentationCacheRevision != two.presentationCacheRevision)
        #expect(TranscriptEntry.assistant(firstTurn) == TranscriptEntry.assistant(secondTurn),
                "independent cache tokens do not make transcript rows semantically different")
    }

    private static func tool(id: String, status: Int) -> ToolActivity {
        ToolActivity(id: id, name: "web_fetch", arguments: #"{"url":"https://example.com/page"}"#,
                     result: "page", details: ["status": .number(Double(status))], isError: false, isRunning: false)
    }
}
