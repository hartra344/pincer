import Foundation

/// How the Gateway Settings sidebar is arranged: labeled groups, each row with a one-line subtitle.
/// Pure, so the grouping and what each Gateway's capabilities show can be tested without UI.
public enum GatewaySettingsSidebar {
    public enum Group: String, CaseIterable, Sendable {
        /// Connection, above the labeled groups.
        case top
        case status
        case activity
        case peopleAndDevices
        case security
        case configure
        case advanced

        /// The section header; the top group has none.
        public var title: String? {
            switch self {
            case .top: nil
            case .status: L("Status")
            case .activity: L("Activity")
            case .peopleAndDevices: L("People & Devices")
            case .security: L("Security")
            case .configure: L("Configure")
            case .advanced: L("Advanced")
            }
        }
    }

    /// What this Gateway supports, which decides the conditional rows.
    public struct Capabilities: Hashable, Sendable {
        public var skills: Bool
        public var sessions: Bool
        public var voice: Bool
        public var nodes: Bool
        public var plugins: Bool
        public var mcpServers: Bool
        /// The config has loaded: the curated pages, Plugins, MCP Servers and Advanced need it.
        public var configLoaded: Bool
        /// The curated pages (`SettingsCatalog.pages` ids) that have something to show.
        public var pageIds: [String]

        public init(skills: Bool = false, sessions: Bool = false, voice: Bool = false, nodes: Bool = false,
                    plugins: Bool = false, mcpServers: Bool = false, configLoaded: Bool = false, pageIds: [String] = []) {
            self.skills = skills
            self.sessions = sessions
            self.voice = voice
            self.nodes = nodes
            self.plugins = plugins
            self.mcpServers = mcpServers
            self.configLoaded = configLoaded
            self.pageIds = pageIds
        }

        /// Everything shown, for tests and checks.
        public static let all = Capabilities(skills: true, sessions: true, voice: true, nodes: true, plugins: true,
                                             mcpServers: true, configLoaded: true,
                                             pageIds: SettingsCatalog.pages.map(\.id))
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public let destination: SettingsDestination
        public let title: String
        public let subtitle: String
        public let symbol: String
        public var id: SettingsDestination { self.destination }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public let group: Group
        public let rows: [Row]
        public var id: Group { self.group }
    }

    /// The curated pages in Configure's order; any page not listed here follows them.
    static let configureOrder = [SettingsCatalog.agentsPageId, "channels", "tools", "skills", "sessions", "voice",
                                 "automation", "plugins", "mcpServers", "gateway"]

    /// The sidebar's sections, in order, without empty ones.
    public static func sections(_ capabilities: Capabilities) -> [Section] {
        Group.allCases.compactMap { group in
            let rows = self.destinations(in: group, capabilities).compactMap(self.row)
            return rows.isEmpty ? nil : Section(group: group, rows: rows)
        }
    }

    static func destinations(in group: Group, _ capabilities: Capabilities) -> [SettingsDestination] {
        switch group {
        case .top:
            return [.connection]
        case .status:
            return [.overview, .health, .channelStatus, .logs]
        case .activity:
            return (capabilities.sessions ? [.sessions] : []) + [.approvals, .usage]
        case .peopleAndDevices:
            return [.pairing, .devices]
        case .security:
            return [.execPolicy] + (capabilities.nodes ? [.nodes] : [])
        case .configure:
            let pages = capabilities.configLoaded ? capabilities.pageIds : []
            var slots: [String: SettingsDestination] = [:]
            for id in pages { slots[id] = .page(id) }
            if capabilities.skills { slots["skills"] = .skills }
            if capabilities.voice { slots["voice"] = .voice }
            if capabilities.configLoaded, capabilities.plugins { slots["plugins"] = .plugins }
            if capabilities.configLoaded, capabilities.mcpServers { slots["mcpServers"] = .mcpServers }
            let ordered = self.configureOrder.compactMap { slots[$0] }
            let rest = pages.filter { !self.configureOrder.contains($0) }.map { SettingsDestination.page($0) }
            return ordered + rest
        case .advanced:
            return capabilities.configLoaded ? [.allSettings, .raw] : []
        }
    }

    /// The group a destination is listed under.
    public static func group(of destination: SettingsDestination) -> Group {
        Group.allCases.first { self.destinations(in: $0, .all).contains(destination) } ?? .configure
    }

    public static func row(_ destination: SettingsDestination) -> Row? {
        let (title, subtitle, symbol): (String, String, String)
        switch destination {
        case .connection: (title, subtitle, symbol) = (L("Connection"), L("How this device connects"), "network")
        case .overview: (title, subtitle, symbol) = (L("Overview"), L("Version, status and config file"), "info.circle")
        case .health: (title, subtitle, symbol) = (L("Health"), L("Status, channels, clients and restart"), "heart.text.square")
        case .channelStatus:
            (title, subtitle, symbol) = (L("Channel Status"), L("Is each channel account connected?"), "antenna.radiowaves.left.and.right")
        case .logs: (title, subtitle, symbol) = (L("Gateway Logs"), L("A live tail of the Gateway's log"), "doc.text.magnifyingglass")
        case .sessions: (title, subtitle, symbol) = (L("Sessions"), L("Every session, to archive or branch"), "rectangle.stack")
        case .approvals: (title, subtitle, symbol) = (L("Approval History"), L("Past approval decisions"), "checkmark.shield")
        case .usage: (title, subtitle, symbol) = (L("Usage"), L("Tokens, cost and quotas"), "chart.bar.xaxis")
        case .pairing:
            (title, subtitle, symbol) = (L("Message Requests"), L("People waiting to message your agents"), "person.badge.key")
        case .devices:
            (title, subtitle, symbol) = (L("Operator Devices"), L("Apps signed in to this Gateway"), "laptopcomputer.and.iphone")
        case .execPolicy:
            (title, subtitle, symbol) = (L("Command Policy"), L("Which commands agents may run"), "lock.shield")
        case .nodes: (title, subtitle, symbol) = (L("Nodes"), L("Machines that run commands for your agents"), "cpu")
        case .skills: (title, subtitle, symbol) = (L("Skills"), L("Installed skills and ClawHub"), "wand.and.stars")
        case .voice: (title, subtitle, symbol) = (L("Voice"), L("How replies are read aloud"), "speaker.wave.2")
        case .plugins: (title, subtitle, symbol) = (L("Plugins"), L("Extensions the Gateway loads"), "puzzlepiece.extension")
        case .mcpServers:
            (title, subtitle, symbol) = ("MCP Servers", L("External tools your agents can call"), "point.3.connected.trianglepath.dotted")
        case .allSettings: (title, subtitle, symbol) = (L("All Settings"), L("Every setting, by config section"), "list.bullet.rectangle")
        case .raw: (title, subtitle, symbol) = (L("Raw Config"), L("The config file as JSON"), "curlybraces")
        case let .page(id):
            guard let page = SettingsCatalog.page(id) else { return nil }
            (title, subtitle, symbol) = (page.title, self.pageSubtitle(id), page.symbol)
        }
        return Row(destination: destination, title: title, subtitle: subtitle, symbol: symbol)
    }

    static func pageSubtitle(_ id: String) -> String {
        switch id {
        case SettingsCatalog.agentsPageId: L("Agents, defaults and models")
        case "channels": L("Where agents can be reached")
        case "tools": L("What agents are allowed to use")
        case "sessions": L("Session and message behavior")
        case "automation": L("Heartbeat, cron and hooks")
        case "gateway": L("Port, auth and reload")
        default: L("Gateway configuration")
        }
    }
}

extension GatewayStore {
    /// What this Gateway's sidebar shows. `pageIds` are the curated pages with something to show,
    /// which needs the schema, so the caller decides.
    public func settingsSidebarCapabilities(pageIds: [String]) -> GatewaySettingsSidebar.Capabilities {
        GatewaySettingsSidebar.Capabilities(
            skills: self.supportsSkills,
            sessions: self.supportsSessionManager,
            voice: self.voice.supportsStatus,
            nodes: self.devices.nodesSupported,
            plugins: self.settings.pluginsSupported,
            mcpServers: self.supportsMCPServers,
            configLoaded: self.settings.hasLoaded,
            pageIds: self.settings.hasLoaded ? pageIds : [])
    }
}
