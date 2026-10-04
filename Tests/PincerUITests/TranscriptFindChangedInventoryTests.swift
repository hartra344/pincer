import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Transcript Find refreshed inventory", .timeLimit(.minutes(2)))
struct TranscriptFindChangedInventoryTests {
    func row(_ id: String) -> TranscriptEntry {
        .user(ChatItem(id: id, role: .user, blocks: [.text("ordinary needle message")], timestamp: Date(timeIntervalSince1970: 1)))
    }
    func ready(_ find: TranscriptFind) async throws {
        while find.isSearching {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
    @Test(arguments: [true, false]) func actualNavigationSurvivesInsertionOrRemoval(insert: Bool) async throws {
        let find = TranscriptFind()
        defer { find.dismiss() }
        let rows = [self.row("a"), self.row("b"), self.row("c")]
        let first = TranscriptSearch.Match(entryId: rows[0].id, section: .message(0), occurrence: 0)
        find.update(entries: rows, reasoningOff: false)
        find.present(query: "needle", select: first)
        try await self.ready(find)
        try #require(find.matches.count == 3 && find.currentMatch == first)
        find.update(entries: insert ? [self.row("inserted")] + rows : [rows[0], rows[2]], reasoningOff: false)
        try #require(find.isSearching)
        find.next()
        try #require(find.currentMatch?.entryId == rows[1].id)
        try await self.ready(find)
        #expect(find.currentMatch?.entryId == (insert ? rows[1].id : rows[2].id))
        #expect(find.current == (insert ? 2 : 1))
    }
}
