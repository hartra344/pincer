#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2))) struct PaletteSearchPreparationTests {
    private func item(_ id: String, _ title: String, section: PaletteItem.Section = .chats) -> PaletteItem {
        PaletteItem(id: id, title: title, symbol: "x", section: section, action: .command(id))
    }
    @Test func actualRankingRunsOffMainAndPreservesCompleteMatching() async {
        let items = [item("late", "Plans Café"), item("exact", "Café"), item("other", "Paper digest")]
        let probe = PaletteSearchProbe()
        let result = await PaletteSearchDiagnostics.$probe.withValue(probe) {
            await PaletteSearchPreparation.prepare(items, query: "cafe", page: .root, gatewaySelected: false)
        }
        #expect(result.map(\.id) == ["exact", "late"])
        let counts = probe.counts
        #expect(counts.main == [0, 0, 0] && counts.worker.allSatisfy { $0 > 0 })
        let tail = await PaletteSearchPreparation.prepare(items, query: "plans cafe", page: .models, gatewaySelected: false)
        #expect(tail.map(\.id) == ["late"])
        let subsequence = await PaletteSearchPreparation.prepare(items, query: "pprd", page: .models, gatewaySelected: false)
        #expect(subsequence.map(\.id) == ["other"])
        let blank = await PaletteSearchPreparation.prepare(items, query: "", page: .models, gatewaySelected: false)
        #expect(blank.map(\.id) == ["late", "exact", "other"])
        let none = await PaletteSearchPreparation.prepare(items, query: "unmatched", page: .root, gatewaySelected: false)
        #expect(none.isEmpty)
    }
    @Test func actualRootModelsAndMessagesKeepTheirPartitionPolicy() async {
        let chats = (0..<85).map { item("c\($0)", "Chat \($0)") }
        let marks = (0..<12).map { item("b\($0)", "Bookmark \($0)", section: .bookmarks) }
        let root = await PaletteSearchPreparation.prepare(chats, bookmarks: marks, query: "", page: .root, gatewaySelected: false)
        #expect(root.map(\.id) == (0..<80).map { "c\($0)" } + (0..<10).map { "b\($0)" })
        let models = await PaletteSearchPreparation.prepare(chats, bookmarks: marks, query: "", page: .models, gatewaySelected: false)
        #expect(models.map(\.id) == (0..<80).map { "c\($0)" })
        let messages = await PaletteSearchPreparation.prepare(chats, query: "unmatched", page: .messages, gatewaySelected: false)
        #expect(messages.map(\.id) == (0..<85).map { "c\($0)" })
        let tail = await PaletteSearchPreparation.prepare(chats, query: "Chat 84", page: .models, gatewaySelected: false)
        #expect(tail.map(\.id) == ["c84"])
        let command = await PaletteSearchPreparation.prepare([], query: "needle", page: .root, gatewaySelected: true, shortcut: "CUSTOM")
        #expect(command.count == 1)
        #expect(command.first?.id == "command:searchMessages" && command.first?.title == "Search Messages for “needle”" && command.first?.shortcut == "CUSTOM")
        #expect(command.first?.action == .searchMessages("needle"))
        let matched = [PaletteItem(id: "keyword", title: "First", symbol: "x", keywords: ["needle"], section: .chats, action: .command("keyword")),
                       PaletteItem(id: "subtitle", title: "Second", subtitle: "needle", symbol: "x", section: .chats, action: .command("subtitle"))]
        let ties = await PaletteSearchPreparation.prepare(matched, query: "needle", page: .models, gatewaySelected: false)
        #expect(ties.map(\.id) == ["keyword", "subtitle"])
    }
}
#endif
