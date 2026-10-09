import Foundation

/// The sidebar's Organize menu: how the chat list is grouped and filtered, and nothing else.
/// Gateway actions live in the Gateway switcher, the macOS Gateway menu and ⌘K (#955).
public enum SidebarOrganizeMenu {
    public enum Item: String, CaseIterable, Sendable, Identifiable {
        case organization, showArchived, showAutomations, showSlashCommands, newGroup

        public var id: String { self.rawValue }

        public var title: String {
            switch self {
            case .organization: L("Organize")
            case .showArchived: L("Show Archived")
            case .showAutomations: L("Show Automations")
            case .showSlashCommands: L("Show Slash Commands")
            case .newGroup: L("New Group…")
            }
        }
    }

    /// New Group… only makes sense when the list is grouped by group or by server.
    public static func items(organization: SidebarOrganization) -> [Item] {
        var items: [Item] = [.organization, .showArchived, .showAutomations, .showSlashCommands]
        if organization == .group || organization == .servers { items.append(.newGroup) }
        return items
    }
}
