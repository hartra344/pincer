import Foundation

/// A top-level place in Gateway Settings (a sidebar row).
public enum SettingsDestination: Hashable, Codable, Sendable {
    case connection
    case overview
    /// Approval History: past decisions on commands, plugins and system changes.
    case approvals
    /// Usage & cost: tokens, spend and provider quotas.
    case usage
    /// A curated page from `SettingsCatalog`, by id.
    case page(String)
    case plugins
    case allSettings
    case raw
}

/// A page pushed inside a destination.
public enum SettingsRoute: Hashable, Codable, Sendable {
    /// One object of the config, as a form.
    case object([String])
    /// A list of strings, edited row by row.
    case list([String])
    case plugin(String)
    /// One entry of Approval History, by approval id.
    case approval(String)
    /// One session's usage drill-down.
    case sessionUsage(key: String, agentId: String? = nil)
}

/// Where a setting lives in the UI: the sidebar row, the pages pushed on top, and the field.
public struct SettingsLocation: Hashable, Sendable {
    public let destination: SettingsDestination
    public let routes: [SettingsRoute]
    public let focus: [String]?

    public init(destination: SettingsDestination, routes: [SettingsRoute] = [], focus: [String]? = nil) {
        self.destination = destination
        self.routes = routes
        self.focus = focus
    }
}

/// A hand-arranged settings page. It only picks which parts of the config appear and how they
/// group: labels, help, validation and controls still come from the Gateway's schema, so a
/// setting behaves the same here as in All Settings.
public struct SettingsPage: Identifiable, Hashable, Sendable {
    public struct Section: Hashable, Sendable {
        public let title: String?
        public let footer: String?
        public let content: Content

        public init(_ title: String? = nil, footer: String? = nil, _ content: Content) {
            self.title = title
            self.footer = footer
            self.content = content
        }
    }

    public enum Content: Hashable, Sendable {
        /// The settings of one object, inline. Nested objects become links.
        case object([String])
        /// One row per entry of an object (channels, agents…), each opening its own page.
        case entries([String])
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let sections: [Section]

    public init(id: String, title: String, symbol: String, sections: [Section]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sections = sections
    }

    /// Paths shown inline as sections, which their parent section shouldn't also link to.
    public var inlinePaths: Set<[String]> {
        Set(self.sections.compactMap { if case let .object(path) = $0.content { path } else { nil } })
    }

    /// Top-level config keys this page covers.
    public var roots: Set<String> {
        Set(self.sections.compactMap {
            switch $0.content {
            case let .object(path), let .entries(path): path.first
            }
        })
    }
}

public enum SettingsCatalog {
    /// The curated pages, in sidebar order. Sections whose path isn't in the Gateway's schema or
    /// config are hidden, and so is a page left with none.
    public static let pages: [SettingsPage] = [
        SettingsPage(id: "gateway", title: "Gateway", symbol: "server.rack", sections: [
            .init(nil, .object(["gateway"])),
            .init("Authentication", .object(["gateway", "auth"])),
            .init("Reload", footer: "Hybrid applies what it can live and restarts the Gateway only when a change needs it.",
                  .object(["gateway", "reload"])),
        ]),
        SettingsPage(id: "agents", title: "Agents & Models", symbol: "person.2", sections: [
            .init("Defaults", footer: "Every agent uses these unless it overrides them.", .object(["agents", "defaults"])),
            .init("Agents", .entries(["agents", "entries"])),
            .init("Models", .object(["models"])),
        ]),
        SettingsPage(id: "channels", title: "Channels", symbol: "bubble.left.and.bubble.right", sections: [
            .init(nil, footer: "Where your agents can be reached, and who can message them.", .entries(["channels"])),
        ]),
        SettingsPage(id: "sessions", title: "Sessions & Messages", symbol: "text.bubble", sections: [
            .init("Sessions", .object(["session"])),
            .init("Messages", .object(["messages"])),
        ]),
        SettingsPage(id: "tools", title: "Tools & Skills", symbol: "wrench.and.screwdriver", sections: [
            .init("Tools", .object(["tools"])),
            .init("Skills", .object(["skills"])),
        ]),
        SettingsPage(id: "automation", title: "Automation", symbol: "clock", sections: [
            .init("Heartbeat", footer: "Periodic check-ins where the agent looks for work on its own.",
                  .object(["agents", "defaults", "heartbeat"])),
            .init("Cron", .object(["cron"])),
            .init("Hooks", .object(["hooks"])),
        ]),
    ]

    public static func page(_ id: String) -> SettingsPage? { self.pages.first { $0.id == id } }

    /// Where a setting (or an issue about it) is shown: on a curated page when one covers it,
    /// then under Plugins, otherwise in All Settings.
    public static func location(for path: [String], pages: [SettingsPage] = SettingsCatalog.pages) -> SettingsLocation {
        // Values inside lists are edited with their list.
        let path = path.firstIndex { Int($0) != nil }.map { Array(path.prefix($0)) } ?? path
        guard !path.isEmpty else { return SettingsLocation(destination: .overview) }
        let parent = Array(path.dropLast())
        var best: (length: Int, location: SettingsLocation)?
        for page in pages {
            for section in page.sections {
                let location: SettingsLocation
                let length: Int
                switch section.content {
                case let .object(root):
                    guard parent.starts(with: root) else { continue }
                    location = SettingsLocation(destination: .page(page.id),
                                                routes: self.objectRoutes(from: root, to: parent), focus: path)
                    length = root.count
                case let .entries(root):
                    guard parent.count >= root.count, parent.starts(with: root) else { continue }
                    location = SettingsLocation(destination: .page(page.id),
                                                routes: self.objectRoutes(from: root, to: parent), focus: path)
                    length = root.count
                }
                // A section inlined on its own page beats a link to it from its parent.
                if length > (best?.length ?? -1) { best = (length, location) }
            }
        }
        if let best { return best.location }
        if path.count >= 3, path[0] == "plugins", path[1] == "entries" {
            let config = ["plugins", "entries", path[2], "config"]
            let routes = [SettingsRoute.plugin(path[2])]
                + (parent.count > config.count && parent.starts(with: config) ? self.objectRoutes(from: config, to: parent) : [])
            return SettingsLocation(destination: .plugins, routes: routes, focus: path)
        }
        return SettingsLocation(destination: .allSettings, routes: self.objectRoutes(from: [], to: parent), focus: path)
    }

    /// One pushed page per object between `root` (shown already) and `target`.
    static func objectRoutes(from root: [String], to target: [String]) -> [SettingsRoute] {
        guard target.count > root.count else { return [] }
        return (root.count + 1...target.count).map { .object(Array(target.prefix($0))) }
    }
}
