import Foundation
import PincerKit

/// #955: Gateway Settings' sidebar in labeled groups with subtitles, with every page reachable once.
@MainActor
func runGatewaySettingsSidebarOfflineChecks() {
    let sections = GatewaySettingsSidebar.sections(.all)
    let shown = sections.flatMap { $0.rows.map(\.destination) }
    check(sections.map(\.group) == GatewaySettingsSidebar.Group.allCases,
          "gateway settings sidebar: Status, Activity, People & Devices, Security, Configure, Advanced in order")
    check(Set(shown).count == shown.count, "gateway settings sidebar: every page appears exactly once")
    check(sections.flatMap(\.rows).allSatisfy { !$0.subtitle.isEmpty }, "gateway settings sidebar: every row has a subtitle")
    check(sections.flatMap(\.rows).contains { $0.destination == .pairing && $0.title == "Message Requests" }
          && sections.flatMap(\.rows).contains { $0.destination == .devices && $0.title == "Operator Devices" },
          "gateway settings sidebar: Message Requests and Operator Devices are renamed")
    let bare = GatewaySettingsSidebar.sections(.init()).flatMap { $0.rows.map(\.destination) }
    check(![.skills, .sessions, .voice, .nodes, .plugins, .mcpServers, .allSettings, .raw].contains { bare.contains($0) },
          "gateway settings sidebar: unsupported pages are hidden")
    check(SettingsCatalog.destinations(matching: "pairing requests").first?.destination == .pairing,
          "gateway settings sidebar: search still finds Message Requests by its old name")
}

/// Live (#955): against the mock, every page the Gateway supports is in the sidebar exactly once.
@MainActor
func runLiveGatewaySettingsSidebarChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(GatewayProfile(name: "Mock", url: url, authMode: .token), secret: token)
    let connected = await waitFor("sidebar connection", timeout: 25) { gateway.state.isConnected }
    check(connected, "gateway settings sidebar: the mock connects")
    guard connected else { return }
    // Gateway Settings loads the config when it opens.
    await gateway.settings.load()
    let loaded = gateway.settings.hasLoaded
    check(loaded, "gateway settings sidebar: the config loads")
    guard loaded else { return }
    let capabilities = gateway.settingsSidebarCapabilities(pageIds: SettingsCatalog.pages.map(\.id))
    let shown = GatewaySettingsSidebar.sections(capabilities).flatMap { $0.rows.map(\.destination) }
    check(Set(shown).count == shown.count, "gateway settings sidebar (live): no page appears twice")
    let expected: [(SettingsDestination, Bool)] = [
        (.skills, gateway.supportsSkills), (.sessions, gateway.supportsSessionManager),
        (.voice, gateway.voice.supportsStatus), (.nodes, gateway.devices.nodesSupported),
        (.mcpServers, gateway.supportsMCPServers), (.plugins, gateway.settings.pluginsSupported),
    ]
    check(expected.allSatisfy { shown.contains($0.0) == $0.1 },
          "gateway settings sidebar (live): conditional pages follow what the Gateway supports")
    check([.connection, .pairing, .devices, .allSettings, .raw].allSatisfy { shown.contains($0) },
          "gateway settings sidebar (live): Message Requests, Operator Devices and Advanced are listed")
}
