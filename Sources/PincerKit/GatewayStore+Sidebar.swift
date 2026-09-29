import Foundation
import Observation

/// Sidebar grouping, like Discord categories.
public enum SidebarOrganization: String, CaseIterable, Identifiable, Sendable {
    case servers
    case agent
    case group
    case recent

    public var id: String { self.rawValue }
    public var label: String {
        switch self {
        case .servers: L("By server")
        case .agent: L("By agent")
        case .group: L("By group")
        case .recent: L("Recent")
        }
    }
}

public struct SidebarChannel: Identifiable, Hashable, Sendable {
    public let row: SessionRow
    public var threads: [SessionRow]
    public var id: String { self.row.key }
}

public struct SidebarSection: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case agent(String)
        case server(ChatServer)
        case group(String)
        case agentGroup(agent: String, group: String)
        case automations
        case other
    }

    public let id: String
    public let title: String
    public let emoji: String?
    public var channels: [SidebarChannel]
    public let kind: Kind
    /// Groups nested in an agent section (by-agent mode).
    public var subsections: [SidebarSection]
    /// How many of `channels` come before `subsections`; the rest come after.
    public var leadingChannelCount: Int

    public var agentId: String? {
        switch self.kind {
        case let .agent(id), let .agentGroup(id, _): id
        default: nil
        }
    }

    public var groupName: String? {
        switch self.kind {
        case let .group(name), let .agentGroup(_, name): name
        default: nil
        }
    }

    /// Channels in display order: leading, then each subsection's, then the rest.
    public var allChannels: [SidebarChannel] {
        let leading = min(self.leadingChannelCount, self.channels.count)
        return Array(self.channels[..<leading]) + self.subsections.flatMap(\.allChannels) + Array(self.channels[leading...])
    }

    public var unreadCount: Int {
        self.channels.filter { $0.row.isUnread }.count + self.subsections.reduce(0) { $0 + $1.unreadCount }
    }

    public init(id: String, title: String, emoji: String?, channels: [SidebarChannel], kind: Kind,
                subsections: [SidebarSection] = [], leadingChannelCount: Int = 0) {
        self.subsections = subsections
        self.leadingChannelCount = leadingChannelCount
        self.id = id
        self.title = title
        self.emoji = emoji
        self.channels = channels
        self.kind = kind
    }
}

extension GatewayStore {
    // MARK: Sidebar

    public func agent(_ id: String) -> AgentSummary {
        self.agents.first { $0.id == id } ?? AgentSummary(id: id, name: id == "main" ? "Main" : id.capitalized)
    }

    /// Visible rows, pinned then main chats then most recent. Cached until the rows or `showArchived` change.
    var sortedRows: [SessionRow] {
        let sessions = self.sessions
        let showArchived = self.showArchived
        if let cached = self.sortedRowsCache { return cached }
        // Sort keys are read from each row's JSON once, not on every comparison.
        let rows = sessions.values
            .filter { showArchived || !$0.isArchived }
            .map { (row: $0, pinned: $0.isPinned, main: $0.isMain, activity: $0.activityMs, key: $0.key) }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                if lhs.main != rhs.main { return lhs.main }
                if lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
                return lhs.key < rhs.key
            }
            .map(\.row)
        self.sortedRowsCache = rows
        return rows
    }

    /// Subagent runs are the agent's own work; their parent chat carries the result.
    public var totalUnread: Int {
        self.sessions.values.filter { $0.isUnread && !$0.isArchived && !$0.isSubagent && !self.isHiddenInSidebar($0) }.count
    }

    /// Automation and slash-command sessions stay out of the sidebar unless opted in; the open chat always shows.
    public func isHiddenInSidebar(_ row: SessionRow) -> Bool {
        guard row.key != self.selectedKey else { return false }
        return (row.isAutomation && !self.showAutomations) || (row.isSlashCommands && !self.showSlashCommands)
    }

    func loadConfiguredServerNames() async {
        guard let result = try? await self.connection.request("config.get", [:], timeout: 15) else { return }
        let config = result["resolved"] ?? result["config"] ?? result["parsed"] ?? .null
        var names: [String: String] = [:]
        for (_, channel) in config["channels"]?.object ?? [:] {
            for (id, guild) in channel["guilds"]?.object ?? [:] {
                if let name = (guild["name"]?.text ?? guild["slug"]?.text.map(Self.humanizedSlug))?.nilIfEmpty {
                    names[id] = name
                }
            }
        }
        self.configuredServerNames = names
    }

    static func humanizedSlug(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public func displayName(for server: ChatServer) -> String {
        if let override = self.serverNameOverrides[server.id] { return override }
        if let name = server.name ?? self.configuredServerNames[server.id] { return name }
        let named = self.sessions.values.lazy.compactMap(\.server).first { $0.id == server.id && $0.name != nil }
        return named?.name ?? server.displayName
    }

    public func renameServer(_ server: ChatServer, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        self.serverNameOverrides[server.id] = value
        Task { await self.push(self.syncedMap(Self.serverNamesPref), server.id, value) }
    }

    // MARK: Chat icons

    /// The SF Symbol chosen for a chat, if any. Callers still validate it for the running OS.
    public func customIcon(for key: String) -> String? { self.chatIcons[key] }

    /// Sets (or with `nil`, clears) a chat's icon on every device.
    public func setIcon(_ symbol: String?, for key: String) {
        let value = symbol?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.chatIcons[key] != value else { return }
        self.chatIcons[key] = value
        Task { await self.push(self.syncedMap(Self.chatIconsPref), key, value) }
    }

    // MARK: Chat colors

    /// The custom color picked for a chat, if any. It wins over the session's named `color`.
    public func customColor(for key: String) -> String? { self.chatColors[key] }

    /// Sets (or with `nil`, clears) a chat's custom color on every device.
    public func setColor(_ hex: String?, for key: String) {
        let value = hex?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.chatColors[key] != value else { return }
        self.chatColors[key] = value
        Task { await self.push(self.syncedMap(Self.chatColorsPref), key, value) }
    }

    public func sections(search: String = "") -> [SidebarSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let hidden = query.isEmpty ? Set(self.sortedRows.filter(self.isHiddenInSidebar).map(\.key)) : []
        let rows = self.sortedRows.filter { row in
            guard query.isEmpty else {
                return row.title.lowercased().contains(query) || (row.preview?.lowercased().contains(query) ?? false)
            }
            // Threads of a hidden session go with it rather than surfacing at the top level.
            return row.key == self.selectedKey
                || (!hidden.contains(row.key) && !row.parentCandidates.contains(where: hidden.contains))
        }
        // Subagent sessions become threads under their parent, one level deep.
        let keys = Set(rows.map(\.key))
        var threads: [String: [SessionRow]] = [:]
        var topLevel: [SessionRow] = []
        for row in rows {
            if query.isEmpty, let parent = row.parentCandidates.first(where: keys.contains) {
                threads[parent, default: []].append(row)
            } else {
                topLevel.append(row)
            }
        }
        let channels = topLevel.map { SidebarChannel(row: $0, threads: threads[$0.key] ?? []) }

        switch self.organization {
        case .recent:
            return [SidebarSection(id: "recent", title: "Recent", emoji: nil, channels: channels, kind: .other)]
        case .agent:
            return self.agentSections(channels, nestGroups: true)
        case .group:
            var sections = self.groupSections(channels.filter { $0.row.category != nil }, includeEmpty: query.isEmpty)
            let ungrouped = channels.filter { $0.row.category == nil }
            if !ungrouped.isEmpty {
                sections.append(SidebarSection(id: "group:", title: "Ungrouped", emoji: nil, channels: ungrouped, kind: .other))
            }
            return sections
        case .servers:
            // Agent chats first, then each chat server with its uncategorized channels,
            // then groups, which play the role of Discord categories.
            let grouped = channels.filter { $0.row.category != nil }
            let serverChannels = channels.filter { $0.row.category == nil && $0.row.server != nil }
            let automations = channels.filter { $0.row.category == nil && $0.row.server == nil && $0.row.isAutomation }
            let rest = channels.filter { $0.row.category == nil && $0.row.server == nil && !$0.row.isAutomation }
            var sections = self.agentSections(rest)
            var servers: [ChatServer] = []
            var byServer: [String: [SidebarChannel]] = [:]
            for channel in serverChannels {
                guard let server = channel.row.server else { continue }
                if byServer[server.id] == nil { servers.append(server) }
                byServer[server.id, default: []].append(channel)
            }
            for server in servers.sorted(by: { self.displayName(for: $0) < self.displayName(for: $1) }) {
                sections.append(SidebarSection(
                    id: "server:\(server.provider):\(server.id)",
                    title: self.displayName(for: server),
                    emoji: nil,
                    channels: Self.channelOrder(byServer[server.id] ?? []),
                    kind: .server(server)))
            }
            sections += self.groupSections(Self.channelOrder(grouped), includeEmpty: query.isEmpty)
            if !automations.isEmpty {
                sections.append(SidebarSection(id: Self.automationsSectionId, title: "Automations", emoji: nil,
                                               channels: Self.channelOrder(automations), kind: .automations))
            }
            return sections
        }
    }

    /// The `category` value that dropping chat `key` onto `section` should set (`.null` removes
    /// it from its group), or `nil` when that drop wouldn't move the chat anywhere.
    public func groupDropValue(for key: String, onto section: SidebarSection) -> JSONValue? {
        guard let row = self.sessions[key], !row.isSubagent else { return nil }
        switch section.kind {
        case let .group(name):
            return row.category == name ? nil : .string(name)
        case .other where section.id == "group:":
            return row.category == nil ? nil : .null
        case let .agentGroup(agent, name):
            return row.agentId != agent || row.category == name ? nil : .string(name)
        case let .agent(id) where self.organization == .agent:
            return row.agentId == id && row.category != nil ? .null : nil
        case .server, .agent, .automations:
            // By server: a grouped chat can go back to the section it lives in without a group.
            guard self.organization == .servers, row.category != nil,
                  Self.ungroupedHome(of: row) == section.kind else { return nil }
            return .null
        case .other:
            return nil
        }
    }

    /// Returns true if the drop changed a chat's group.
    @discardableResult
    public func moveToGroup(_ key: String, droppedOn section: SidebarSection) async -> Bool {
        guard let value = self.groupDropValue(for: key, onto: section) else { return false }
        if let name = section.groupName {
            await self.moveChat(key, toGroup: name, before: nil)
            return true
        }
        if let old = self.sessions[key]?.category { self.registerGroups([old]) }
        if self.chatPositions[key] != nil {
            self.chatPositions[key] = nil
            Task { await self.push(self.syncedMap(Self.chatOrderPref), key, nil) }
        }
        await self.patch(key, ["category": value])
        return true
    }

    private static func ungroupedHome(of row: SessionRow) -> SidebarSection.Kind {
        if let server = row.server { return .server(server) }
        if row.isAutomation { return .automations }
        return .agent(row.agentId)
    }

    private func agentSections(_ channels: [SidebarChannel], nestGroups: Bool = false) -> [SidebarSection] {
        let grouped = Dictionary(grouping: channels, by: { $0.row.agentId })
        let order = self.agents.map(\.id) + grouped.keys.filter { id in !self.agents.contains { $0.id == id } }.sorted()
        return order.compactMap { agentId in
            guard let channels = grouped[agentId], !channels.isEmpty else { return nil }
            let agent = self.agent(agentId)
            if nestGroups {
                let home = channels.filter { $0.row.isMain }
                let rest = channels.filter { !$0.row.isMain }
                let pinned = rest.filter { $0.row.category == nil && $0.row.isPinned }
                let leading = home + pinned
                let byGroup = Dictionary(grouping: rest.filter { $0.row.category != nil }, by: { $0.row.category ?? "" })
                let subsections = self.groupNames.compactMap { name -> SidebarSection? in
                    guard let members = byGroup[name], !members.isEmpty else { return nil }
                    return SidebarSection(id: "agent:\(agentId)/group:\(name)", title: name, emoji: nil,
                                          channels: self.arranged(members), kind: .agentGroup(agent: agentId, group: name))
                }
                return SidebarSection(id: "agent:\(agentId)", title: agent.name, emoji: agent.emoji,
                                      channels: leading + rest.filter { $0.row.category == nil && !$0.row.isPinned },
                                      kind: .agent(agentId), subsections: subsections, leadingChannelCount: leading.count)
            }
            return SidebarSection(id: "agent:\(agentId)", title: agent.name, emoji: agent.emoji, channels: channels, kind: .agent(agentId))
        }
    }

    /// One section per group, in the catalog's order. Empty groups stay until they're deleted;
    /// chats arranged by hand come first in their order, the rest keep the order they came in.
    private func groupSections(_ channels: [SidebarChannel], includeEmpty: Bool) -> [SidebarSection] {
        let grouped = Dictionary(grouping: channels, by: { $0.row.category ?? "" })
        return self.groupNames.compactMap { name in
            let members = grouped[name] ?? []
            guard includeEmpty || !members.isEmpty else { return nil }
            return SidebarSection(id: "group:\(name)", title: name, emoji: nil, channels: self.arranged(members), kind: .group(name))
        }
    }

    private func arranged(_ channels: [SidebarChannel]) -> [SidebarChannel] {
        let positioned = channels.compactMap { channel in self.chatPositions[channel.id].flatMap(Int.init).map { (channel, $0) } }
        let rest = channels.filter { self.chatPositions[$0.id].flatMap(Int.init) == nil }
        return positioned.sorted { $0.1 < $1.1 }.map(\.0) + rest
    }

    /// Stable, name-ordered channels like a Discord server; pinned first.
    private static func channelOrder(_ channels: [SidebarChannel]) -> [SidebarChannel] {
        channels.sorted { lhs, rhs in
            if lhs.row.isPinned != rhs.row.isPinned { return lhs.row.isPinned }
            let order = lhs.row.title.localizedCaseInsensitiveCompare(rhs.row.title)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.row.activityMs > rhs.row.activityMs
        }
    }

    /// Debug aid: `PINCER_DUMP_SESSIONS=/path.json` writes routing/naming fields only (no message text).
    func dumpSessionShapesIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PINCER_DUMP_SESSIONS"] else { return }
        let fields = ["key", "kind", "label", "displayName", "derivedTitle", "autoLabel", "groupChannel", "space", "subject",
                      "chatType", "channel", "lastChannel", "category", "parentSessionKey", "spawnedBy", "isMain",
                      "createdVia", "spawnDepth", "parentSessionId", "forkedFromParent"]
        let rows: [JSONValue] = self.sessions.values.sorted { $0.key < $1.key }.map { row in
            var object: [String: JSONValue] = [:]
            for field in fields { if let value = row.raw[field] { object[field] = value } }
            if let origin = row.raw["origin"]?.object {
                object["origin"] = .object(origin.filter { ["label", "provider", "surface", "chatType", "threadId", "nativeChannelId"].contains($0.key) })
            }
            return .object(object)
        }
        if let data = try? JSONEncoder().encode(JSONValue.array(rows)) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Groups

    /// Every group in display order: the catalog, then any category a chat has that isn't in it.
    public var groupNames: [String] {
        let catalog = self.usesGroupCatalog
            ? self.groupCatalog
            : self.groupPositions.sorted { lhs, rhs in
                let (l, r) = (Int(lhs.value) ?? .max, Int(rhs.value) ?? .max)
                return l != r ? l < r : lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }.map(\.key)
        let known = Set(catalog)
        let extra = Set(self.sessions.values.compactMap(\.category)).subtracting(known)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return catalog + extra
    }

    /// The SF Symbol chosen for a group, if any. Callers still validate it for the running OS.
    public func groupIcon(for name: String) -> String? { self.groupIcons[name] }

    public var collapsedSections: Set<String> {
        var ids = Set(self.sectionCollapse.filter(\.value).keys)
        if self.sectionCollapse[Self.automationsSectionId] == nil { ids.insert(Self.automationsSectionId) }
        return ids
    }

    public func setSectionCollapsed(_ id: String, _ collapsed: Bool) {
        guard self.collapsedSections.contains(id) != collapsed else { return }
        self.sectionCollapse[id] = collapsed
    }

    static let automationsSectionId = "automations"

    /// Sets (or with `nil`, clears) a group's icon on every device.
    public func setGroupIcon(_ symbol: String?, for name: String) {
        let value = symbol?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard self.groupIcons[name] != value else { return }
        self.groupIcons[name] = value
        Task { await self.push(self.syncedMap(Self.groupIconsPref), name, value) }
    }

    /// Carries a group's icon over to its new name (or drops it with `nil`).
    private func moveGroupIcon(from name: String, to newName: String?) {
        guard let icon = self.groupIcons[name] else { return }
        var changes: [String: String?] = [name: String?.none]
        if let newName, self.groupIcons[newName] == nil { changes[newName] = icon }
        for (key, value) in changes { self.groupIcons[key] = value }
        Task { await self.push(self.syncedMap(Self.groupIconsPref), changes) }
    }

    /// Whether groups live in the gateway's catalog. Gateways that don't list their methods get a try.
    var usesGroupCatalog: Bool {
        guard !self.groupCatalogUnsupported else { return false }
        let methods = self.hello?.methods ?? []
        return methods.isEmpty || methods.contains("sessions.groups.put")
    }

    func loadGroups() async {
        if self.usesGroupCatalog {
            do {
                let result = try await self.connection.request("sessions.groups.list", [:], timeout: 15)
                self.applyGroupCatalog(result)
                return
            } catch GatewayError.rpc {
                self.groupCatalogUnsupported = true
            } catch {
                return
            }
        }
        await self.pull(self.syncedMap(Self.groupsPref))
        // Chats already in a group keep it listed once they leave it.
        self.registerGroups(Set(self.sessions.values.compactMap(\.category)))
    }

    private func applyGroupCatalog(_ result: JSONValue) {
        guard let groups = result["groups"]?.array else { return }
        let names = groups.enumerated().compactMap { index, group -> (String, Int)? in
            guard let name = group["name"]?.text?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
            return (name, group["position"]?.int ?? index)
        }
        let ordered = names.sorted { $0.1 < $1.1 }.map(\.0)
        if ordered != self.groupCatalog { self.groupCatalog = ordered }
    }

    /// Adds groups to the fallback list so they stay after their last chat leaves.
    private func registerGroups(_ names: Set<String>) {
        guard !self.usesGroupCatalog else { return }
        let missing = names.subtracting(self.groupPositions.keys).sorted()
        guard !missing.isEmpty else { return }
        let next = (self.groupPositions.values.compactMap { Int($0) }.max() ?? -1) + 1
        let changes = Dictionary(uniqueKeysWithValues: missing.enumerated().map { ($1, String(next + $0)) })
        self.groupPositions.merge(changes) { $1 }
        Task { await self.push(self.syncedMap(Self.groupsPref), changes) }
    }

    /// Replaces the group order; with the catalog this is also how groups are created.
    private func setGroupOrder(_ names: [String]) async -> Bool {
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            self.groupCatalog = names
            do {
                let result = try await self.connection.request("sessions.groups.put", ["names": .array(names.map(JSONValue.string))], timeout: 15)
                self.applyGroupCatalog(result)
                return true
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return false
            }
        }
        var changes: [String: String?] = [:]
        for (index, name) in names.enumerated() where self.groupPositions[name] != String(index) {
            changes[name] = String(index)
        }
        for name in self.groupPositions.keys where !names.contains(name) {
            changes[name] = .some(nil)
        }
        for (name, value) in changes { self.groupPositions[name] = value }
        await self.push(self.syncedMap(Self.groupsPref), changes)
        return true
    }

    /// Creates an empty group at the end. Returns false if the name is empty or already taken.
    @discardableResult
    public func createGroup(_ name: String) async -> Bool {
        let value = name.trimmingCharacters(in: .whitespaces)
        let names = self.groupNames
        guard !value.isEmpty, !names.contains(value) else { return false }
        return await self.setGroupOrder(names + [value])
    }

    /// Moves a group before another one (`nil` moves it to the end).
    public func moveGroup(_ name: String, before: String?) async {
        var names = self.groupNames
        guard names.contains(name), name != before else { return }
        names.removeAll { $0 == name }
        let index = before.flatMap { names.firstIndex(of: $0) } ?? names.count
        names.insert(name, at: index)
        guard names != self.groupNames else { return }
        _ = await self.setGroupOrder(names)
    }

    /// Renames a group; its chats move with it.
    public func renameGroup(_ name: String, to newName: String) async {
        let value = newName.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != name else { return }
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            if self.groupCatalog.contains(value) {
                self.groupCatalog.removeAll { $0 == name }
            } else {
                self.groupCatalog = self.groupCatalog.map { $0 == name ? value : $0 }
            }
            do {
                let result = try await self.connection.request("sessions.groups.rename", ["name": .string(name), "to": .string(value)], timeout: 30)
                self.applyGroupCatalog(result)
                self.moveGroupIcon(from: name, to: value)
                return
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return
            }
        }
        self.moveGroupIcon(from: name, to: value)
        var changes: [String: String?] = [name: String?.none]
        if self.groupPositions[value] == nil { changes[value] = self.groupPositions[name] ?? String(self.groupPositions.count) }
        for (key, change) in changes { self.groupPositions[key] = change }
        Task { await self.push(self.syncedMap(Self.groupsPref), changes) }
        for key in self.memberKeys(of: name) {
            await self.patch(key, ["category": .string(value)])
        }
    }

    /// Deletes a group. Its chats stay, without a group.
    public func deleteGroup(_ name: String) async {
        if self.usesGroupCatalog {
            let previous = self.groupCatalog
            self.groupCatalog.removeAll { $0 == name }
            do {
                let result = try await self.connection.request("sessions.groups.delete", ["name": .string(name)], timeout: 30)
                self.applyGroupCatalog(result)
                self.moveGroupIcon(from: name, to: nil)
                return
            } catch {
                self.groupCatalog = previous
                self.lastError = error.localizedDescription
                await self.loadGroups()
                return
            }
        }
        self.groupPositions[name] = nil
        Task { await self.push(self.syncedMap(Self.groupsPref), name, nil) }
        self.moveGroupIcon(from: name, to: nil)
        for key in self.memberKeys(of: name) {
            await self.patch(key, ["category": .null])
        }
    }

    private func memberKeys(of group: String) -> [String] {
        self.sessions.values.filter { $0.category == group }.map(\.key)
    }

    /// Chats of a group in the order the sidebar shows them.
    public func groupOrder(_ name: String) -> [String] {
        let rows = self.sortedRows.filter { $0.category == name && !$0.isSubagent }
        let channels = rows.map { SidebarChannel(row: $0, threads: []) }
        return self.arranged(self.organization == .servers ? Self.channelOrder(channels) : channels).map(\.row.key)
    }

    /// Puts a chat in a group before another of its chats (`nil` puts it last), moving it
    /// there first if it's in another group.
    public func moveChat(_ key: String, toGroup name: String, before: String?) async {
        guard let row = self.sessions[key], !row.isSubagent, key != before else { return }
        var order = self.groupOrder(name).filter { $0 != key }
        let index = before.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(key, at: index)
        var changes: [String: String?] = [:]
        for (position, key) in order.enumerated() where self.chatPositions[key] != String(position) {
            changes[key] = String(position)
        }
        for (key, value) in changes { self.chatPositions[key] = value }
        Task { await self.push(self.syncedMap(Self.chatOrderPref), changes) }
        if row.category != name {
            self.registerGroups(Set([name] + (row.category.map { [$0] } ?? [])))
            await self.patch(key, ["category": .string(name)])
        }
    }
}
