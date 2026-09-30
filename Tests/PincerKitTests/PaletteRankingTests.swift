import Foundation
import Testing
@testable import PincerKit

/// #478: a command whose title starts with the query outranks "Search Messages for “q”".
@Suite("Palette ranking")
struct PaletteRankingTests {
    func row(_ id: String, _ title: String, _ section: PaletteItem.Section) -> PaletteItem {
        PaletteItem(id: id, title: title, symbol: "x", section: section, action: .command(id))
    }

    @Test func titlePrefixCommandBeatsSearchMessages() {
        let ranked = [row("dictate", "Dictate Message", .commands), row("other", "Edit Dictionary", .commands)]
        let ids = CommandPalette.addingSearchMessages(to: ranked, query: "dict", gatewaySelected: true).map(\.id)
        #expect(ids == ["dictate", "command:searchMessages", "other"])
    }

    @Test func prefixMatchIsCaseAndDiacriticInsensitive() {
        let ranked = [row("cafe", "Café Mode", .commands)]
        let ids = CommandPalette.addingSearchMessages(to: ranked, query: "CAFE", gatewaySelected: true).map(\.id)
        #expect(ids == ["cafe", "command:searchMessages"])
    }

    @Test func titleStartsWithHelper() {
        #expect(CommandPalette.titleStartsWith(row("d", "Dictate Message", .commands), query: "dict"))
        #expect(CommandPalette.titleStartsWith(row("d", "Dictate Message", .commands), query: " DICT "))
        #expect(!CommandPalette.titleStartsWith(row("d", "Dictate Message", .commands), query: "message"))
    }

    @Test func chatsStayAboveAndNonPrefixCommandsStayBelow() {
        let ranked = [row("chat", "Dictionary chat", .chats), row("dictate", "Dictate Message", .commands),
                      row("loose", "Toggle dictation", .commands)]
        let ids = CommandPalette.addingSearchMessages(to: ranked, query: "dict", gatewaySelected: true).map(\.id)
        #expect(ids == ["chat", "dictate", "command:searchMessages", "loose"])
    }

    @Test func noPrefixMatchKeepsSearchFirst() {
        let ranked = [row("loose", "Toggle dictation", .commands)]
        let ids = CommandPalette.addingSearchMessages(to: ranked, query: "dict", gatewaySelected: true).map(\.id)
        #expect(ids == ["command:searchMessages", "loose"])
    }

    @Test func bookmarkStartingWithTheQueryDoesNotOutrankSearch() {
        let ranked = [row("loose", "Toggle dictation", .commands), row("mark", "Dictate this note tomorrow", .bookmarks)]
        let ids = CommandPalette.addingSearchMessages(to: ranked, query: "dict", gatewaySelected: true).map(\.id)
        #expect(ids == ["command:searchMessages", "loose", "mark"])
    }
}
