import Testing
@testable import PincerKit

/// #955: Gateway Settings' sidebar in labeled groups, each row with a subtitle.
@Suite("Gateway Settings sidebar")
struct GatewaySettingsSidebarTests {
    private func destinations(_ capabilities: GatewaySettingsSidebar.Capabilities) -> [SettingsDestination] {
        GatewaySettingsSidebar.sections(capabilities).flatMap { $0.rows.map(\.destination) }
    }

    @Test func groupsInOrder() {
        let groups = GatewaySettingsSidebar.sections(.all).map(\.group)
        #expect(groups == [.top, .status, .activity, .peopleAndDevices, .security, .configure, .advanced])
        #expect(GatewaySettingsSidebar.sections(.all).first?.group.title == nil)
    }

    @Test func everyDestinationExactlyOnce() {
        let shown = self.destinations(.all)
        #expect(Set(shown).count == shown.count)
        let fixed: [SettingsDestination] = [.connection, .overview, .health, .approvals, .logs, .execPolicy, .skills,
                                            .sessions, .mcpServers, .usage, .voice, .pairing, .channelStatus, .devices,
                                            .nodes, .plugins, .allSettings, .raw]
        let pages = SettingsCatalog.pages.map { SettingsDestination.page($0.id) }
        #expect(Set(shown) == Set(fixed + pages))
    }

    @Test func groupMembership() {
        func rows(_ group: GatewaySettingsSidebar.Group) -> [SettingsDestination] {
            GatewaySettingsSidebar.sections(.all).first { $0.group == group }?.rows.map(\.destination) ?? []
        }
        #expect(rows(.top) == [.connection])
        #expect(rows(.status) == [.overview, .health, .channelStatus, .logs])
        #expect(rows(.activity) == [.sessions, .approvals, .usage])
        #expect(rows(.peopleAndDevices) == [.pairing, .devices])
        #expect(rows(.security) == [.execPolicy, .nodes])
        #expect(rows(.configure) == [.page("agents"), .page("channels"), .page("tools"), .skills, .page("sessions"),
                                     .voice, .page("automation"), .plugins, .mcpServers, .page("gateway")])
        #expect(rows(.advanced) == [.allSettings, .raw])
    }

    @Test func conditionalRowsHideWithoutSupport() {
        let bare = self.destinations(GatewaySettingsSidebar.Capabilities())
        #expect(bare == [.connection, .overview, .health, .channelStatus, .logs, .approvals, .usage, .pairing,
                         .devices, .execPolicy])
        // Plugins, MCP Servers and the curated pages wait for the config.
        let unloaded = GatewaySettingsSidebar.Capabilities(skills: true, voice: true, plugins: true, mcpServers: true,
                                                           pageIds: ["gateway"])
        let configure = GatewaySettingsSidebar.sections(unloaded).first { $0.group == .configure }?.rows.map(\.destination)
        #expect(configure == [.skills, .voice])
    }

    @Test func renamedAndEveryRowHasASubtitle() {
        let rows = GatewaySettingsSidebar.sections(.all).flatMap(\.rows)
        #expect(rows.first { $0.destination == .pairing }?.title == "Message Requests")
        #expect(rows.first { $0.destination == .devices }?.title == "Operator Devices")
        #expect(rows.allSatisfy { !$0.subtitle.isEmpty && !$0.title.isEmpty })
        #expect(GatewaySettingsSidebar.group(of: .nodes) == .security)
    }

    @Test func searchFindsTheNewAndOldNames() {
        #expect(SettingsCatalog.destinations(matching: "message requests").map(\.destination) == [.pairing])
        #expect(SettingsCatalog.destinations(matching: "pairing requests").map(\.destination) == [.pairing])
        #expect(SettingsCatalog.destinations(matching: "operator devices").map(\.destination) == [.devices])
    }
}
