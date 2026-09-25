import PincerKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Flattened sidebar contents for the native lists: one group per section, each holding its
/// channels and the subagent threads shown under them.
struct SidebarModel: Equatable {
    struct Header: Equatable {
        let id: String
        let section: SidebarSection
        let isCollapsed: Bool
        /// Agent a new chat started from this header's + button goes to, if it has one.
        let newChatAgent: String?

        static func == (lhs: Header, rhs: Header) -> Bool {
            lhs.id == rhs.id && lhs.isCollapsed == rhs.isCollapsed && lhs.newChatAgent == rhs.newChatAgent
                && lhs.section.title == rhs.section.title && lhs.section.emoji == rhs.section.emoji
                && lhs.section.kind == rhs.section.kind && lhs.section.unreadCount == rhs.section.unreadCount
        }
    }

    struct Entry: Equatable {
        let id: String
        let row: SessionRow
        /// Custom SF Symbol (already checked for this OS), or `nil` for the default icon.
        let icon: String?
        let isThread: Bool
        let subagentCount: Int
        let runningSubagents: Int
        let hiddenUnreadThreads: Int
        let threadsExpanded: Bool
        let showSubagentRuns: Bool
    }

    struct Group: Equatable {
        let header: Header
        let entries: [Entry]
    }

    var groups: [Group] = []

    static func headerId(_ sectionId: String) -> String { "section:\(sectionId)" }
    static func entryId(_ key: String) -> String { "chat:\(key)" }

    @MainActor
    static func build(gateway: GatewayStore, search: String, collapsed: Set<String>,
                      expandedThreads: Set<String>, showSubagentRuns: Bool) -> SidebarModel
    {
        let selected = gateway.selectedKey
        var model = SidebarModel()
        for section in gateway.sections(search: search) {
            var entries: [Entry] = []
            for channel in section.channels {
                let expanded = expandedThreads.contains(channel.row.key)
                let subagents = channel.threads.filter(\.isSubagent)
                entries.append(Entry(
                    id: self.entryId(channel.row.key),
                    row: channel.row,
                    icon: ChannelRowStyle.customSymbol(for: channel.row, gateway: gateway),
                    isThread: false,
                    subagentCount: subagents.count,
                    runningSubagents: subagents.filter(\.hasActiveRun).count,
                    hiddenUnreadThreads: expanded ? 0 : subagents.filter { $0.isUnread && !$0.hasActiveRun }.count,
                    threadsExpanded: expanded,
                    showSubagentRuns: showSubagentRuns))
                // Like Discord, helper runs live inside the conversation (as "Open run" on their
                // tool call) unless the sidebar is set to list them.
                let visible: [SessionRow]
                if !showSubagentRuns {
                    visible = channel.threads.filter { !$0.isSubagent || $0.key == selected }
                } else if expanded {
                    visible = channel.threads
                } else {
                    visible = channel.threads.filter { !$0.isSubagent || $0.hasActiveRun || $0.key == selected }
                }
                for thread in visible {
                    entries.append(Entry(id: self.entryId(thread.key), row: thread,
                                         icon: ChannelRowStyle.customSymbol(for: thread, gateway: gateway), isThread: true, subagentCount: 0,
                                         runningSubagents: 0, hiddenUnreadThreads: 0, threadsExpanded: false,
                                         showSubagentRuns: showSubagentRuns))
                }
            }
            let newChatAgent = section.agentId ?? (gateway.organization == .recent ? gateway.defaultAgentId : nil)
            let header = Header(id: self.headerId(section.id), section: section,
                                isCollapsed: collapsed.contains(section.id), newChatAgent: newChatAgent)
            model.groups.append(Group(header: header, entries: entries))
        }
        return model
    }
}

/// Things the sidebar asks its SwiftUI owner to do (sheets and view state live there).
@MainActor
struct SidebarActions {
    var select: (String) -> Void
    var newChat: (String) -> Void
    var rename: (SessionRow) -> Void
    var changeIcon: (SessionRow) -> Void
    var prompt: (TextPrompt) -> Void
    var toggleThreads: (String) -> Void
    var setCollapsed: (String, Bool) -> Void
    var refresh: () async -> Void
}

// MARK: Row appearance

enum ChannelRowStyle {
    /// The chat's chosen icon: this app's synced pick first, then a session `icon` other
    /// OpenClaw clients set, if it maps to an SF Symbol available here.
    @MainActor
    static func customSymbol(for row: SessionRow, gateway: GatewayStore) -> String? {
        SymbolCatalog.symbol(for: gateway.customIcon(for: row.key)) ?? SymbolCatalog.symbol(for: row.icon)
    }

    static func symbol(for entry: SidebarModel.Entry) -> String {
        entry.icon ?? self.defaultSymbol(for: entry.row, isThread: entry.isThread)
    }

    static func defaultSymbol(for row: SessionRow, isThread: Bool) -> String {
        if isThread { return row.isSubagent ? "sparkles" : "bubble.left.and.text.bubble.right" }
        if row.isAutomation { return "clock.arrow.circlepath" }
        if row.isSlashCommands { return "command" }
        if row.server != nil, !row.isChannelThread { return "number" }
        if let origin = self.origin(of: row) { return self.symbol(origin) }
        if row.isMain { return "house" }
        return "number"
    }

    static func help(for row: SessionRow) -> String? {
        if row.server != nil, !row.isChannelThread { return "\(row.server?.provider.capitalized ?? "Server") channel" }
        if let origin = self.origin(of: row) { return "From \(origin.capitalized)" }
        return nil
    }

    private static func origin(of row: SessionRow) -> String? {
        guard let origin = row.channel?.lowercased(),
              ["discord", "slack", "telegram", "imessage", "whatsapp"].contains(origin) else { return nil }
        return origin
    }

    static func symbol(_ origin: String) -> String {
        switch origin {
        case "imessage": "message"
        case "whatsapp", "telegram": "paperplane"
        default: "bubble.left.and.bubble.right"
        }
    }

    static func headerSymbol(for kind: SidebarSection.Kind) -> String? {
        switch kind {
        case let .server(server): self.symbol(server.provider)
        case .group: "chevron.down.square"
        case .automations: "clock.arrow.circlepath"
        case .agent, .other: nil
        }
    }

    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    #if os(macOS)
    static func tint(for row: SessionRow) -> NSColor {
        Theme.color(named: row.color).map { NSColor($0) } ?? .secondaryLabelColor
    }
    #else
    static func tint(for row: SessionRow) -> UIColor {
        Theme.color(named: row.color).map { UIColor($0) } ?? .secondaryLabel
    }
    #endif
}

// MARK: Menus

/// A context menu described once and rendered as `NSMenu` or `UIMenu`.
indirect enum SidebarMenuItem {
    case action(String, image: String? = nil, checked: Bool = false, destructive: Bool = false, @MainActor () -> Void)
    case submenu(String, image: String? = nil, [SidebarMenuItem])
    case divider
}

@MainActor
enum SidebarMenus {
    static func chat(_ row: SessionRow, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        func patch(_ fields: [String: JSONValue]) {
            Task { await gateway.patch(row.key, fields) }
        }
        var groups: [SidebarMenuItem] = gateway.groupNames.map { name in
            .action(name) { patch(["category": .string(name)]) }
        }
        if !groups.isEmpty { groups.append(.divider) }
        groups.append(.action("New Group…") {
            actions.prompt(TextPrompt(title: "New Group", field: "Name", initial: "") { name in
                let value = name.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return }
                patch(["category": .string(value)])
            })
        })
        if row.category != nil {
            groups.append(.action("Remove from Group") { patch(["category": .null]) })
        }
        var colors: [SidebarMenuItem] = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"].map { color in
            .action(color.capitalized) { patch(["color": .string(color)]) }
        }
        colors += [.divider, .action("None") { patch(["color": .null]) }]

        var items: [SidebarMenuItem] = [
            .action(row.isPinned ? "Unpin" : "Pin", image: row.isPinned ? "pin.slash" : "pin") {
                patch(["pinned": .bool(!row.isPinned)])
            },
            .action(row.isUnread ? "Mark as Read" : "Mark as Unread", image: "circle.fill") {
                patch(["unread": .bool(!row.isUnread)])
            },
            .action("Rename…", image: "pencil") { actions.rename(row) },
            .action("Change Icon…", image: "face.smiling") { actions.changeIcon(row) },
        ]
        if gateway.customIcon(for: row.key) != nil {
            items.append(.action("Reset Icon", image: "arrow.uturn.backward") { gateway.setIcon(nil, for: row.key) })
        }
        items += [
            .submenu("Move to Group", image: "folder", groups),
            .submenu("Color", image: "paintpalette", colors),
            self.reasoning(row, gateway: gateway),
        ]
        if !row.isMain {
            items += [
                .divider,
                .action(row.isArchived ? "Unarchive" : "Archive", image: "archivebox") {
                    patch(["archived": .bool(!row.isArchived)])
                },
            ]
        }
        return items
    }

    static func reasoning(_ row: SessionRow, gateway: GatewayStore) -> SidebarMenuItem {
        .submenu("Gateway Reasoning", image: "brain", [("on", "Save & Stream"), ("stream", "Stream Only"), ("off", "Off")].map { value, label in
            .action(label, checked: row.reasoningLevel == value) {
                Task { await gateway.patch(row.key, ["reasoningLevel": .string(value)]) }
            }
        })
    }

    static func header(_ section: SidebarSection, gateway: GatewayStore, actions: SidebarActions) -> [SidebarMenuItem] {
        switch section.kind {
        case let .server(server):
            return [.action("Rename Server…", image: "pencil") {
                actions.prompt(TextPrompt(title: "Rename Server", field: "Name", initial: section.title) { name in
                    gateway.renameServer(server, to: name)
                })
            }]
        case let .group(name):
            return [.action("Rename Group…", image: "pencil") {
                actions.prompt(TextPrompt(title: "Rename Group", field: "Name", initial: name) { newName in
                    let value = newName.trimmingCharacters(in: .whitespaces)
                    Task {
                        for channel in section.channels {
                            await gateway.patch(channel.row.key, ["category": value.isEmpty ? .null : .string(value)])
                        }
                    }
                })
            }]
        default:
            return []
        }
    }
}

/// Pasteboard type for a chat dragged within the sidebar.
enum SidebarDrag {
    static let typeIdentifier = "chat.pincer.session-key"
}
