import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Transcript Find selection ownership", .timeLimit(.minutes(2)))
struct TranscriptFindSelectionOwnershipTests {
    func entries() -> [TranscriptEntry] {
        (0..<3).map { .user(ChatItem(id: "find-\($0)", role: .user, blocks: [.text("ordinary needle message")], timestamp: Date(timeIntervalSince1970: 1))) }
    }
    func ready(_ find: TranscriptFind) async throws {
        while find.isSearching {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
    @Test(arguments: [true, false])
    func refreshCannotUndoActualNavigation(forward: Bool) async throws {
        let find = TranscriptFind()
        defer { find.dismiss() }
        find.update(entries: self.entries(), reasoningOff: false)
        find.present(query: "needle", select: nil)
        try await self.ready(find)
        try #require(find.matches.count == 3)
        let old = try #require(find.currentMatch)
        find.update(entries: self.entries(), reasoningOff: false)
        try #require(find.isSearching)
        if forward { find.next() } else { find.previous() }
        let selected = try #require(find.currentMatch)
        try #require(selected != old)
        try await self.ready(find)
        #expect(find.currentMatch == selected)
    }
    @Test func ordinaryRefreshAndNavigationAfterCompletion() async throws {
        let find = TranscriptFind()
        defer { find.dismiss() }
        let rows = self.entries()
        let preferred = TranscriptSearch.Match(entryId: rows[1].id, section: .message(0), occurrence: 0)
        find.update(entries: rows, reasoningOff: false)
        find.present(query: "needle", select: preferred)
        try await self.ready(find)
        try #require(find.currentMatch == preferred)
        find.update(entries: rows, reasoningOff: false)
        try await self.ready(find)
        #expect(find.currentMatch == preferred)
        find.next()
        #expect(find.currentMatch?.entryId == rows[2].id)
        find.update(entries: Array(rows.prefix(2)), reasoningOff: false)
        try await self.ready(find)
        #expect(find.currentMatch?.entryId == rows[1].id)
    }
}
