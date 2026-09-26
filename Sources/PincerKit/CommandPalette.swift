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
        /// Opens the messages page searching for this.
        case searchMessages(String)
        /// Opens a chat with Find in Chat on this message.
        case openMessage(Notifier.Target, query: String, match: TranscriptSearch.Match)
        /// Opens a chat with Find in Chat showing `query`, its newest match selected.
        case findInChat(Notifier.Target, query: String)
    }

    public enum Section: Int, Comparable, Sendable {
        case chats, newChat, commands, models, messages

        public var title: String {
            switch self {
            case .chats: "Chats"
            case .newChat: "New Chat"
            case .commands: "Commands"
            case .models: "Models"
            case .messages: "Messages"
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
    /// A heading over the rows after it (a chat's message results); never selected.
    public let isHeader: Bool
    /// A message result's text, with the matches to highlight.
    public let snippet: MessageSearch.Snippet?
    /// When a message result was sent.
    public let date: Date?

    /// Can be moved to and run.
    public var isSelectable: Bool { self.isEnabled && !self.isHeader }

    public init(id: String, title: String, subtitle: String? = nil, symbol: String, keywords: [String] = [],
                shortcut: String? = nil, section: Section, action: Action, isEnabled: Bool = true,
                isHeader: Bool = false, snippet: MessageSearch.Snippet? = nil, date: Date? = nil)
    {
        self.isHeader = isHeader
        self.snippet = snippet
        self.date = date
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

    /// "Search Messages for “q”" on the root page, once the query is long enough to search.
    public static func searchMessagesItem(query: String) -> PaletteItem? {
        let query = TranscriptSearch.normalized(query)
        guard query.count >= MessageSearch.minimumQueryLength else { return nil }
        return PaletteItem(
            id: "command:searchMessages", title: "Search Messages for “\(query)”", symbol: "text.magnifyingglass",
            shortcut: "⇧⌘F", section: .commands, action: .searchMessages(query))
    }

    /// Ranked root-page results with "Search Messages for “q”" right after the last chat (first
    /// when no chat matches), so Return on a query that names no chat searches messages.
    public static func addingSearchMessages(to ranked: [PaletteItem], query: String, gatewaySelected: Bool) -> [PaletteItem] {
        guard gatewaySelected, let item = self.searchMessagesItem(query: query) else { return ranked }
        var items = ranked
        let position = items.lastIndex { $0.section == .chats }.map { $0 + 1 } ?? 0
        items.insert(item, at: position)
        return items
    }

    /// The messages page: per chat, a header, its newest matches, and "More matches in …" when
    /// there are more than shown.
    @MainActor
    public static func messageItems(_ results: MessageSearch.Results, gateway: GatewayStore,
                                    now: Date = Date(), calendar: Calendar = .current) -> [PaletteItem]
    {
        let prefix = gateway.id.uuidString
        var items: [PaletteItem] = []
        for chat in results.chats {
            let target = Notifier.Target(gatewayId: gateway.id, sessionKey: chat.sessionKey)
            items.append(PaletteItem(
                id: "messages:chat:\(prefix):\(chat.sessionKey)",
                title: chat.isArchived ? "\(chat.title) · Archived" : chat.title,
                symbol: "bubble.left", section: .messages, action: .openChat(target), isHeader: true))
            for message in chat.messages {
                items.append(PaletteItem(
                    id: "message:\(prefix):\(chat.sessionKey):\(message.hit.entryId):\(message.hit.section)",
                    title: message.sender,
                    symbol: message.hit.role == .user ? "person" : "sparkle",
                    shortcut: message.hit.timestamp.map { MessageSearch.dateLabel($0, now: now, calendar: calendar) },
                    section: .messages,
                    action: .openMessage(target, query: results.query, match: message.match),
                    snippet: message.snippet,
                    date: message.hit.timestamp))
            }
            if chat.hasMore {
                items.append(PaletteItem(
                    id: "messages:more:\(prefix):\(chat.sessionKey)",
                    title: "More matches in \(chat.title)…", symbol: "ellipsis",
                    section: .messages, action: .findInChat(target, query: results.query)))
            }
        }
        return items
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
