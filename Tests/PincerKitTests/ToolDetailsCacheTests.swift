import Foundation
import Testing
@testable import PincerKit

/// `ChatItem.toolDetails` (#37) in the transcript cache: kept across a save/load, and v5 files
/// written before it existed are migrated (#168): edit cards fall back to the tool's arguments
/// without calling an overwrite a new file.
@Suite("Tool details in the transcript cache")
struct ToolDetailsCacheTests {
    static let writeArgs = #"{"path":"src/a.ts","content":"one\ntwo\n"}"#

    static func items(details: String?) -> [ChatItem] {
        let detailsField = details.map { #","details":\#($0)"# } ?? ""
        return [
            ChatItem(Fixtures.json("""
            {"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"write","arguments":\(Self.writeArgs)}],
             "__openclaw":{"id":"a1"}}
            """), fallbackIndex: 0)!,
            ChatItem(Fixtures.json("""
            {"role":"toolResult","toolCallId":"c1","toolName":"write","isError":false,
             "content":[{"type":"text","text":"Successfully wrote 8 bytes to src/a.ts"}]\(detailsField),"__openclaw":{"id":"r1"}}
            """), fallbackIndex: 1)!,
        ]
    }

    static func tool(_ items: [ChatItem]) -> ToolActivity? {
        TranscriptBuilder.build(items).lazy.compactMap { entry -> ToolActivity? in
            if case let .assistant(turn) = entry { return turn.tools.first }
            return nil
        }.first
    }

    static let overwrite = #"{"changed":true,"created":false,"diff":"- 1 old\n+ 1 one\n+ 2 two","patch":"--- a","firstChangedLine":1}"#

    @Test func toolDetailsSurviveTheCache() throws {
        let items = Self.items(details: Self.overwrite)
        #expect(items[1].toolDetails == .object(["changed": true, "created": false, "diff": "- 1 old\n+ 1 one\n+ 2 two"]),
                "only the keys a diff reads are kept")
        let data = try JSONEncoder().encode(TranscriptCache.Snapshot(items: items, complete: true))
        let (snapshot, outcome) = TranscriptCache.decode(data)
        #expect(outcome == .loaded)
        let loaded = try #require(snapshot?.items)
        #expect(loaded == items)
        #expect(loaded[1].toolDetails == items[1].toolDetails)
        let edit = try #require(Self.tool(loaded)?.fileEdit)
        #expect(edit.additions == 2 && edit.deletions == 1, "the cached receipt's diff is shown")
    }

    @Test func itemsWithoutToolDetailsOmitTheKey() throws {
        let data = try JSONEncoder().encode(Self.items(details: nil)[1])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["toolDetails"] == nil)
    }

    @Test func v5FileWithoutToolDetailsFallsBackToArguments() throws {
        // A v5 snapshot saved before `toolDetails` existed: the key is simply missing.
        let items = Self.items(details: Self.overwrite)
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TranscriptCache.Snapshot(version: 5, items: items, complete: true))) as? [String: Any])
        var rows = try #require(json["items"] as? [[String: Any]])
        for index in rows.indices { rows[index].removeValue(forKey: "toolDetails") }
        json["items"] = rows
        let (snapshot, outcome) = TranscriptCache.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(outcome == .migrated(from: 5) && !outcome.discarded, "v5 without the field is migrated (#168)")
        let loaded = try #require(snapshot?.items)
        #expect(loaded[1].toolDetails == TranscriptCache.unknownToolDetails)
        let edit = try #require(Self.tool(loaded)?.fileEdit)
        #expect(edit.files.first?.operation == .update && edit.additions == 2 && edit.deletionsBound == .unknown
                && edit.statusLabel == "Written", "without the receipt, the write is diffed from its arguments, not as a new file")
    }
}
