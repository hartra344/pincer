import Foundation
import PincerKit

/// #478 palette ordering on synthetic rows and on the demo's real chats and commands.
@MainActor
func checkPaletteSearchOrdering() {
    func row(_ id: String, _ title: String, _ section: PaletteItem.Section) -> PaletteItem {
        PaletteItem(id: id, title: title, symbol: "x", section: section, action: .command(id))
    }
    let ranked = [row("dictate", "Dictate Message", .commands), row("toggle", "Toggle Dictation", .commands)]
    check(CommandPalette.addingSearchMessages(to: ranked, query: "dict", gatewaySelected: true).map(\.id)
          == ["dictate", "command:searchMessages", "toggle"], "a command starting with the query ranks above Search Messages")
    check(CommandPalette.addingSearchMessages(to: [ranked[1]], query: "dict", gatewaySelected: true).first?.id == "command:searchMessages",
          "no title prefix: Search Messages stays first")
    check(CommandPalette.titleStartsWith(ranked[0], query: "DICT") && !CommandPalette.titleStartsWith(ranked[0], query: "message"),
          "titleStartsWith is a case-insensitive title prefix")
}

@MainActor
func runDemoSearchTrackChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let connected = await waitFor("demo for the search track") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo for the search track connected")
    defer { gateway.stop() }
    guard connected else { return }
    let chats = CommandPalette.chatItems(gateways: [gateway], selectedGatewayId: gateway.id)
    let query = String((chats.first?.title ?? "ab").prefix(3))
    let ranked = PaletteMatcher.rank(chats, query: query)
    let items = CommandPalette.addingSearchMessages(to: ranked, query: query, gatewaySelected: true)
    let searchIndex = items.firstIndex { $0.id == "command:searchMessages" }
    let lastPrefix = items.lastIndex { CommandPalette.titleStartsWith($0, query: query) && $0.section != .commands } ?? -1
    check(searchIndex != nil && searchIndex! > lastPrefix, "demo: Search Messages sits below every chat whose title starts with “\(query)”")
}
