import Foundation

// MARK: Back / forward

/// Browser-style back/forward over visited chats. `visit` records a new location and clears the
/// forward stack; `goBack`/`goForward` skip locations that no longer exist.
public struct ChatHistory<Location: Hashable>: Sendable where Location: Sendable {
    public private(set) var current: Location?
    public private(set) var backStack: [Location] = []
    public private(set) var forwardStack: [Location] = []
    public let limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    public var canGoBack: Bool { !self.backStack.isEmpty }
    public var canGoForward: Bool { !self.forwardStack.isEmpty }

    /// Most recently visited first, without duplicates or the current location.
    public var recent: [Location] {
        var seen: Set<Location> = self.current.map { [$0] } ?? []
        return self.backStack.reversed().filter { seen.insert($0).inserted }
    }

    public mutating func visit(_ location: Location) {
        guard location != self.current else { return }
        if let current { self.backStack.append(current) }
        if self.backStack.count > self.limit { self.backStack.removeFirst(self.backStack.count - self.limit) }
        self.forwardStack.removeAll()
        self.current = location
    }

    public mutating func goBack(where isValid: (Location) -> Bool = { _ in true }) -> Location? {
        guard let target = Self.popValid(&self.backStack, isValid) else { return nil }
        if let current { self.forwardStack.append(current) }
        self.current = target
        return target
    }

    public mutating func goForward(where isValid: (Location) -> Bool = { _ in true }) -> Location? {
        guard let target = Self.popValid(&self.forwardStack, isValid) else { return nil }
        if let current { self.backStack.append(current) }
        self.current = target
        return target
    }

    /// Drops locations that no longer exist, e.g. after a Gateway is removed.
    public mutating func prune(keeping isValid: (Location) -> Bool) {
        self.backStack.removeAll { !isValid($0) }
        self.forwardStack.removeAll { !isValid($0) }
        if let current, !isValid(current) { self.current = nil }
    }

    private static func popValid(_ stack: inout [Location], _ isValid: (Location) -> Bool) -> Location? {
        while let last = stack.popLast() {
            if isValid(last) { return last }
        }
        return nil
    }
}

// MARK: Palette items

public struct PaletteItem: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case openChat(Notifier.Target)
        case newChat(gatewayId: UUID, agentId: String)
        case selectGateway(UUID)
        case setModel(String?)
        /// A command the UI defines and runs (settings, thinking display, …).
        case command(String)
    }

    public enum Section: Int, Comparable, Sendable {
        case chats, newChat, commands, models

        public var title: String {
            switch self {
            case .chats: "Chats"
            case .newChat: "New Chat"
            case .commands: "Commands"
            case .models: "Models"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String
    /// Extra words the item also matches on (agent, channel, gateway names…).
    public let keywords: [String]
    public let shortcut: String?
    public let section: Section
    public let action: Action
    public let isEnabled: Bool

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, keywords: [String] = [],
                shortcut: String? = nil, section: Section, action: Action, isEnabled: Bool = true)
    {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
        self.section = section
        self.action = action
        self.isEnabled = isEnabled
    }
}

// MARK: Matching

/// Fuzzy matching for the palette: every query word has to appear in the title or keywords,
/// either as a substring or as an in-order subsequence (`nwcr` → "New Chat with Research").
public enum PaletteMatcher {
    public static func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let words = Self.words(query)
        guard !words.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item in Self.score(item, words: words).map { (item, $0, index) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    public static func score(_ item: PaletteItem, query: String) -> Int? {
        Self.score(item, words: Self.words(query))
    }

    /// Scores `query` against one string, or `nil` when it doesn't match.
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(Self.normalized(query))
        let haystack = Array(Self.normalized(text))
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }
        if let start = Self.firstIndex(of: needle, in: haystack) {
            var score = 1000 - min(start, 200)
            if start == 0 { score += 500 } else if Self.isWordStart(haystack, start) { score += 300 }
            if needle.count == haystack.count { score += 200 }
            return score
        }
        // In-order subsequence; word starts and runs of adjacent characters score higher.
        var score = 100
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            if Self.isWordStart(haystack, found) { score += 30 }
            if found == previous + 1 { score += 15 }
            score -= min(found - position, 10)
            previous = found
            position = found + 1
        }
        return max(score, 1)
    }

    private static func score(_ item: PaletteItem, words: [String]) -> Int? {
        guard !words.isEmpty else { return 0 }
        var total = 0
        for word in words {
            let title = Self.score(word, in: item.title).map { $0 * 2 }
            let keyword = item.keywords.compactMap { Self.score(word, in: $0) }.max()
            let subtitle = item.subtitle.flatMap { Self.score(word, in: $0) }
            guard let best = [title, keyword, subtitle].compactMap(\.self).max() else { return nil }
            total += best
        }
        return total
    }

    private static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordStart(_ text: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = text[index - 1]
        return !(before.isLetter || before.isNumber)
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }
}

// MARK: Chats

extension GatewayStore {
    /// Pinned chats in the order the sidebar shows them, for ⌘1–⌘9.
    public var pinnedChats: [SessionRow] {
        self.sections().flatMap { $0.channels.map(\.row) }.filter { $0.isPinned && !$0.isArchived }
    }
}

public enum CommandPalette {
    /// Chats across every Gateway: recently visited first, then the selected Gateway's chats in
    /// sidebar order, then the other Gateways'. Subagent runs are left out, like the sidebar does
    /// by default. `include` leaves out more rows, and `order` replaces the sidebar order.
    @MainActor
    public static func chatItems(gateways: [GatewayStore], selectedGatewayId: UUID?,
                                 recent: [Notifier.Target] = [],
                                 include: (SessionRow) -> Bool = { _ in true },
                                 order: ((GatewayStore) -> [SessionRow])? = nil) -> [PaletteItem]
    {
        let multiple = gateways.count > 1
        let byId = Dictionary(uniqueKeysWithValues: gateways.map { ($0.id, $0) })
        var seen: Set<Notifier.Target> = []
        var items: [PaletteItem] = []
        let pinnedIndex = gateways.first { $0.id == selectedGatewayId }.map { gateway in
            Dictionary(gateway.pinnedChats.prefix(9).enumerated().map { ($1.key, $0) }) { first, _ in first }
        } ?? [:]

        func add(_ row: SessionRow, in gateway: GatewayStore) {
            let target = Notifier.Target(gatewayId: gateway.id, sessionKey: row.key)
            guard !row.isSubagent, !row.isArchived, include(row), seen.insert(target).inserted else { return }
            let agent = gateway.agent(row.agentId)
            var subtitle = [agent.name]
            if let origin = row.originLabel { subtitle.append(origin) }
            if multiple { subtitle.append(gateway.profile.name) }
            items.append(PaletteItem(
                id: "chat:\(gateway.id.uuidString):\(row.key)",
                title: row.title,
                subtitle: subtitle.joined(separator: " · "),
                symbol: row.isPinned ? "pin" : row.isAutomation ? "clock" : "bubble.left",
                keywords: [agent.name, gateway.profile.name, row.channelName, row.category].compactMap(\.self),
                shortcut: gateway.id == selectedGatewayId ? pinnedIndex[row.key].map { "⌘\($0 + 1)" } : nil,
                section: .chats,
                action: .openChat(target)))
        }

        for target in recent {
            guard let gateway = byId[target.gatewayId], let row = gateway.sessions[target.sessionKey] else { continue }
            add(row, in: gateway)
        }
        let ordered = gateways.sorted { lhs, _ in lhs.id == selectedGatewayId }
        for gateway in ordered {
            for row in order?(gateway) ?? gateway.sortedRows { add(row, in: gateway) }
        }
        return items
    }

    /// "New Chat with …" for each agent on the selected Gateway, while it's connected.
    @MainActor
    public static func newChatItems(gateway: GatewayStore?) -> [PaletteItem] {
        guard let gateway, gateway.state.isConnected else { return [] }
        let agents = gateway.agents.isEmpty ? [gateway.agent(gateway.defaultAgentId)] : gateway.agents
        return agents.map { agent in
            PaletteItem(
                id: "new:\(gateway.id.uuidString):\(agent.id)",
                title: "New Chat with \(agent.name)",
                subtitle: agent.id == gateway.defaultAgentId ? "Default agent" : nil,
                symbol: "square.and.pencil",
                keywords: [agent.id, "agent", "start", "create"],
                section: .newChat,
                action: .newChat(gatewayId: gateway.id, agentId: agent.id))
        }
    }

    /// Other saved Gateways to switch to.
    @MainActor
    public static func gatewayItems(gateways: [GatewayStore], selectedGatewayId: UUID?) -> [PaletteItem] {
        guard gateways.count > 1 else { return [] }
        return gateways.filter { $0.id != selectedGatewayId }.map { gateway in
            PaletteItem(
                id: "gateway:\(gateway.id.uuidString)",
                title: "Switch to \(gateway.profile.name)",
                symbol: "server.rack",
                keywords: ["gateway", "server"],
                section: .commands,
                action: .selectGateway(gateway.id))
        }
    }

    /// The models page: the agent's default, then every model it can use.
    @MainActor
    public static func modelItems(gateway: GatewayStore, row: SessionRow) -> [PaletteItem] {
        let defaultTitle = gateway.defaultModelRef.map { "Default (\(ModelRef.shortName($0)))" } ?? "Default"
        // Same rule as the toolbar's model picker; older Gateways don't send `modelOverrideSource`.
        let followsDefault = row.raw["modelOverrideSource"] != nil
            ? row.modelOverrideSource == nil
            : row.modelRef == nil || row.modelRef == gateway.defaultModelRef
        let current = followsDefault ? nil : row.modelRef
        var items = [PaletteItem(
            id: "model:default", title: defaultTitle, subtitle: current == nil ? "Current" : nil,
            symbol: current == nil ? "checkmark" : "cpu", keywords: ["default", "reset"],
            section: .models, action: .setModel(nil))]
        for model in gateway.modelCatalogs[row.agentId] ?? [] {
            let isCurrent = model.ref == current
            items.append(PaletteItem(
                id: "model:\(model.ref)", title: model.displayName,
                subtitle: isCurrent ? "\(model.provider) · Current" : model.provider,
                symbol: isCurrent ? "checkmark" : "cpu", keywords: [model.ref, model.provider],
                section: .models, action: .setModel(model.ref),
                isEnabled: model.isAvailable && model.manualSelectionAllowed))
        }
        return items
    }
}
