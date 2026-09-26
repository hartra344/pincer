import PincerKit
import SwiftUI

/// ⌘K: jump to a chat, start a chat with an agent, run a command, or search messages (⇧⌘F),
/// all from the keyboard. Type to filter, ↑/↓ to move, Return to run, Esc to go back or close.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    /// iOS: Settings is a sheet owned by the presenter.
    var openAppSettings: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.openAutomations) private var openAutomations
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @AppStorage(ThinkingDisplay.storageKey) private var thinkingDisplay = ThinkingDisplay.defaultValue
    @State private var query: String
    @State private var page: Page
    /// The page was reached from the root page, so Esc goes back there instead of closing.
    @State private var cameFromRoot = false
    @State private var messages: MessageResults?
    @State private var searchingMessages = false
    @State private var selection: String?
    @FocusState private var focused: Bool
    #if os(macOS)
    @State private var keyMonitor: Any?
    @State private var host = HostWindow()
    /// Pointer location at the last arrow-key move; hovers without the pointer moving come from scrolling.
    @State private var keyboardMoveMouseLocation: CGPoint?
    #endif

    enum Page { case root, models, messages }

    /// The latest message search, which Gateway it was on, and its rows, built once per search
    /// rather than on every render (hover, arrow keys, typing).
    private struct MessageResults {
        let gatewayId: UUID
        let results: MessageSearch.Results
        let items: [PaletteItem]
        /// Highlighted snippet text by item id.
        let snippets: [String: AttributedString]
    }

    /// Everything a message search depends on; a change runs it again.
    private struct MessageSearchKey: Equatable {
        let query: String
        let gatewayId: UUID?
        let building: Bool
    }

    init(isPresented: Binding<Bool>, page: Page = .root, query: String = "", openAppSettings: @escaping () -> Void = {}) {
        self._isPresented = isPresented
        self._page = State(initialValue: page)
        self._query = State(initialValue: query)
        self.openAppSettings = openAppSettings
    }

    private enum Command: String {
        case back, forward, nextUnread, changeModel, togglePin, toggleThinking, appSettings, gatewaySettings, automations, approvalHistory, execPolicy, usage, sessionUsage
    }

    private var gateway: GatewayStore? { self.app.selectedGateway }
    private var row: SessionRow? { self.gateway.flatMap { gateway in gateway.selectedKey.flatMap { gateway.sessions[$0] } } }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: self.fieldSymbol)
                    .foregroundStyle(.secondary)
                TextField(self.placeholder, text: self.$query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$focused)
                    .onSubmit { self.runSelection(in: results) }
                    .onKeyPress(.upArrow) { self.move(-1, in: results); return .handled }
                    .onKeyPress(.downArrow) { self.move(1, in: results); return .handled }
                    .onKeyPress(.escape) { self.escape(); return .handled }
                    .onKeyPress(.delete) {
                        guard self.page != .root, self.query.isEmpty else { return .ignored }
                        self.show(.root)
                        return .handled
                    }
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Command palette")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if self.page == .messages {
                self.messagesPage(results)
            } else if results.isEmpty {
                Text(self.page == .models && self.gateway?.loadingModelCatalogs.isEmpty == false ? "Loading models…" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                self.list(results)
            }
        }
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        #if os(macOS)
        .background(HostWindowReader(host: self.host))
        #endif
        .onAppear {
            #if os(macOS)
            self.installKeyMonitor()
            // An AppKit first responder (the composer) keeps focus unless it's resigned first.
            DispatchQueue.main.async {
                self.host.window?.makeFirstResponder(nil)
                self.focused = true
            }
            #else
            self.focused = true
            #endif
        }
        #if os(macOS)
        .onDisappear { self.removeKeyMonitor() }
        #endif
        .onChange(of: self.query) { self.selection = nil }
        .task(id: self.page) {
            guard self.page == .models, let gateway = self.gateway, let row = self.row else { return }
            await gateway.loadModels(agentId: row.agentId)
        }
        .task(id: self.page == .messages ? self.messageSearchKey : nil) {
            await self.searchMessages()
        }
    }

    private var fieldSymbol: String {
        switch self.page {
        case .root: "magnifyingglass"
        case .models: "cpu"
        case .messages: "text.magnifyingglass"
        }
    }

    private var placeholder: String {
        switch self.page {
        case .root: "Jump to a chat or run a command…"
        case .models: "Choose a model…"
        case .messages: "Search messages in \(self.gateway?.profile.name ?? "this Gateway")…"
        }
    }

    // MARK: Messages

    private var messageSearchKey: MessageSearchKey {
        var building = false
        if case .building = self.gateway?.messageIndexProgress { building = true }
        return MessageSearchKey(query: TranscriptSearch.normalized(self.query), gatewayId: self.gateway?.id, building: building)
    }

    /// Searches after a short pause; typing again (or switching Gateways) cancels it.
    private func searchMessages() async {
        guard self.page == .messages else {
            self.searchingMessages = false
            return
        }
        let key = self.messageSearchKey
        guard let gateway, MessageSearch.ftsQuery(key.query) != nil else {
            self.messages = nil
            self.searchingMessages = false
            return
        }
        if self.messages?.gatewayId != gateway.id { self.messages = nil }
        self.searchingMessages = true
        try? await Task.sleep(for: .milliseconds(120))
        // Cancelled: a newer search (or leaving the page) took over, and owns `searchingMessages`.
        guard !Task.isCancelled else { return }
        var results: MessageSearch.Results?
        for attempt in 0 ..< 2 {
            do {
                results = try await gateway.searchMessages(key.query)
                break
            } catch {
                // Not cancelled itself: another window's search interrupted this one. Try once more.
                guard !Task.isCancelled else { return }
                if attempt == 0 { continue }
            }
        }
        guard !Task.isCancelled else { return }
        self.searchingMessages = false
        guard let results else { return }
        let items = CommandPalette.messageItems(results, gateway: gateway)
        var snippets: [String: AttributedString] = [:]
        for item in items {
            if let snippet = item.snippet { snippets[item.id] = self.snippetText(snippet) }
        }
        self.messages = MessageResults(gatewayId: gateway.id, results: results, items: items, snippets: snippets)
    }

    /// The messages page's notice for the current state, when it has one instead of results.
    private func messageNotice(hasResults: Bool) -> (text: String, hint: String?)? {
        guard let gateway else { return ("Select a Gateway to search its messages.", nil) }
        let query = TranscriptSearch.normalized(self.query)
        let name = gateway.profile.name
        if gateway.messageIndexProgress == .unavailable {
            return ("Message search needs the transcript cache, which is turned off.", nil)
        }
        if query.isEmpty {
            return ("Search messages in every chat on \(name).", "Matches words from their start; case and accents are ignored.")
        }
        if query.count < MessageSearch.minimumQueryLength { return ("Type at least 2 characters.", nil) }
        if !gateway.state.isConnected, gateway.sessions.isEmpty { return ("Connect to \(name) to search messages.", nil) }
        if self.messages?.results.failed == true { return ("Message search is unavailable right now.", nil) }
        if hasResults { return nil }
        if self.searchingMessages { return ("Searching…", nil) }
        return ("No messages match “\(query)”.", nil)
    }

    @ViewBuilder
    private func messagesPage(_ results: [PaletteItem]) -> some View {
        let notice = self.messageNotice(hasResults: !results.isEmpty)
        if case let .building(done, total) = self.gateway?.messageIndexProgress,
           TranscriptSearch.normalized(self.query).count >= MessageSearch.minimumQueryLength
        {
            Label("Indexing chats… \(done) of \(total) — results may be incomplete", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        if let notice {
            VStack(spacing: 4) {
                Text(notice.text)
                if let hint = notice.hint { Text(hint).font(.caption) }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
        } else {
            self.list(results)
        }
    }

    private func list(_ results: [PaletteItem]) -> some View {
        let showsSections = self.query.trimmingCharacters(in: .whitespaces).isEmpty && self.page == .root
        let current = self.currentSelection(in: results)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        if showsSections, index == 0 || results[index - 1].section != item.section {
                            self.header(item.section.title, first: index == 0)
                        }
                        if item.isHeader {
                            self.header(item.title, first: index == 0)
                                .id(item.id)
                        } else {
                            self.row(item, selected: item.id == current)
                                .id(item.id)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .onChange(of: self.selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func header(_ title: String, first: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, first ? 2 : 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// A message result's text with the matches highlighted the way Find in Chat does.
    private func snippetText(_ snippet: MessageSearch.Snippet) -> AttributedString {
        let marked = NSMutableAttributedString(string: snippet.text)
        for range in snippet.highlights where NSMaxRange(range) <= marked.length {
            marked.addAttribute(.backgroundColor, value: TranscriptColors.findMatch, range: range)
        }
        #if os(macOS)
        return (try? AttributedString(marked, including: \.appKit)) ?? AttributedString(snippet.text)
        #else
        return (try? AttributedString(marked, including: \.uiKit)) ?? AttributedString(snippet.text)
        #endif
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            self.run(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? .primary : .secondary)
                if let snippet = item.snippet {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            if let shortcut = item.shortcut {
                                Text(shortcut).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(self.messages?.snippets[item.id] ?? self.snippetText(snippet))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let shortcut = item.shortcut {
                        Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.45)
        .onHover { hovering in
            guard hovering else { return }
            #if os(macOS)
            if let location = self.keyboardMoveMouseLocation {
                guard NSEvent.mouseLocation != location else { return }
                self.keyboardMoveMouseLocation = nil
            }
            #endif
            self.selection = item.id
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Items

    private var results: [PaletteItem] {
        let items: [PaletteItem]
        switch self.page {
        case .root:
            items = CommandPalette.chatItems(gateways: self.app.gateways, selectedGatewayId: self.app.selectedGatewayId,
                                             recent: self.app.history.recent)
                + CommandPalette.newChatItems(gateway: self.gateway)
                + self.commandItems
                + CommandPalette.gatewayItems(gateways: self.app.gateways, selectedGatewayId: self.app.selectedGatewayId)
        case .models:
            guard let gateway, let row else { return [] }
            items = CommandPalette.modelItems(gateway: gateway, row: row)
        case .messages:
            guard let gateway, let messages, messages.gatewayId == gateway.id else { return [] }
            return messages.items
        }
        let ranked = Array(PaletteMatcher.rank(items, query: self.query).prefix(80))
        guard self.page == .root else { return ranked }
        return CommandPalette.addingSearchMessages(to: ranked, query: self.query, gatewaySelected: self.gateway != nil)
    }

    private var commandItems: [PaletteItem] {
        func item(_ command: Command, _ title: String, _ symbol: String, keywords: [String] = [],
                  shortcut: String? = nil, subtitle: String? = nil, enabled: Bool = true) -> PaletteItem
        {
            PaletteItem(id: "command:\(command.rawValue)", title: title, subtitle: subtitle, symbol: symbol, keywords: keywords,
                        shortcut: shortcut, section: .commands, action: .command(command.rawValue), isEnabled: enabled)
        }
        var items: [PaletteItem] = []
        if let row {
            items.append(item(.changeModel, "Change Model…", "cpu", keywords: ["switch", "llm"],
                              subtitle: row.modelRef.map(ModelRef.shortName) ?? self.gateway?.defaultModelRef.map(ModelRef.shortName),
                              enabled: !row.isModelSelectionLocked))
            items.append(item(.togglePin, row.isPinned ? "Unpin Chat" : "Pin Chat", row.isPinned ? "pin.slash" : "pin"))
        }
        let showsThinking = self.thinkingDisplay != .none
        items += [
            item(.toggleThinking, showsThinking ? "Hide Thinking Steps" : "Show Thinking Steps", "brain.head.profile",
                 keywords: ["toggle", "reasoning", "tools"], subtitle: "Now: \(self.thinkingDisplay.label)"),
            item(.back, "Go Back", "chevron.backward", keywords: ["previous", "history"], shortcut: "⌘[",
                 enabled: self.app.canGoBack),
            item(.forward, "Go Forward", "chevron.forward", keywords: ["next", "history"], shortcut: "⌘]",
                 enabled: self.app.canGoForward),
            item(.nextUnread, "Next Unread Chat", "circle.badge", keywords: ["unread"], shortcut: "⌥⇧↓",
                 enabled: self.app.totalUnread > 0),
            item(.appSettings, "Open Settings…", "gearshape", keywords: ["preferences"], shortcut: "⌘,"),
        ]
        if self.gateway != nil {
            items += [
                item(.gatewaySettings, "Gateway Settings…", "server.rack", keywords: ["config"], shortcut: "⇧⌘,"),
                item(.automations, "Automations…", "clock", keywords: ["cron", "jobs", "schedule"]),
                item(.approvalHistory, "Approval History…", "checkmark.shield",
                     keywords: ["approvals", "audit", "log", "exec", "plugin", "decisions"]),
                item(.execPolicy, "Command Policy…", "lock.shield",
                     keywords: ["exec", "allowlist", "always allow", "approval policy", "ask", "security", "commands"]),
                item(.usage, "Usage & Cost…", "chart.bar.xaxis",
                     keywords: ["usage", "cost", "tokens", "spend", "billing", "quota", "rate limit", "budget"]),
            ]
            if row != nil {
                items.append(item(.sessionUsage, "Session Usage…", "chart.bar", keywords: ["usage", "cost", "tokens", "session"]))
            }
        }
        return items
    }

    // MARK: Keyboard

    private func currentSelection(in results: [PaletteItem]) -> String? {
        if let selection, results.contains(where: { $0.id == selection && !$0.isHeader }) { return selection }
        return results.first(where: \.isSelectable)?.id
    }

    private func move(_ offset: Int, in results: [PaletteItem]) {
        let results = results.filter { !$0.isHeader }
        guard !results.isEmpty else { return }
        let current = self.currentSelection(in: results).flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        self.selection = results[(current + offset + results.count) % results.count].id
        #if os(macOS)
        self.keyboardMoveMouseLocation = NSEvent.mouseLocation
        #endif
    }

    #if os(macOS)
    /// The text field's field editor swallows ↑/↓ before `onKeyPress` sees them, so catch them here.
    private func installKeyMonitor() {
        guard self.keyMonitor == nil else { return }
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = self.host.window, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 126: self.move(-1, in: self.results)
            case 125: self.move(1, in: self.results)
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        self.keyMonitor = nil
    }
    #endif

    private func runSelection(in results: [PaletteItem]) {
        guard let id = self.currentSelection(in: results), let item = results.first(where: { $0.id == id }) else { return }
        self.run(item)
    }

    private func escape() {
        switch self.page {
        case .root: self.close()
        case .models: self.show(.root)
        case .messages: if self.cameFromRoot { self.show(.root) } else { self.close() }
        }
    }

    private func show(_ page: Page, query: String = "") {
        self.cameFromRoot = self.page == .root && page != .root || self.cameFromRoot && page != .root
        self.page = page
        self.query = query
        self.selection = nil
    }

    private func close() {
        self.isPresented = false
    }

    // MARK: Actions

    private func run(_ item: PaletteItem) {
        guard item.isEnabled else { return }
        switch item.action {
        case let .openChat(target):
            self.close()
            self.app.open(target)
        case let .newChat(gatewayId, agentId):
            self.close()
            guard let gateway = self.app.gateways.first(where: { $0.id == gatewayId }) else { return }
            Task {
                if let key = await gateway.createSession(agentId: agentId, label: nil) {
                    self.app.open(Notifier.Target(gatewayId: gatewayId, sessionKey: key))
                }
            }
        case let .selectGateway(id):
            self.close()
            self.app.selectedGatewayId = id
        case let .setModel(ref):
            self.close()
            guard let gateway, let row else { return }
            Task { await gateway.setModel(row.key, to: ref) }
        case let .command(raw):
            guard let command = Command(rawValue: raw) else { return }
            self.run(command)
        case let .searchMessages(query):
            self.show(.messages, query: query)
        case let .openMessage(target, query, match):
            self.close()
            self.app.open(target, find: query, match: match)
        case let .findInChat(target, query):
            self.close()
            self.app.open(target, find: query, match: nil)
        }
    }

    private func run(_ command: Command) {
        if command == .changeModel {
            self.show(.models)
            return
        }
        self.close()
        switch command {
        case .changeModel:
            break
        case .back:
            self.app.goBack()
        case .forward:
            self.app.goForward()
        case .nextUnread:
            self.app.selectNextUnread()
        case .togglePin:
            guard let gateway, let row else { return }
            Task { await gateway.patch(row.key, ["pinned": .bool(!row.isPinned)]) }
        case .toggleThinking:
            self.thinkingDisplay = self.thinkingDisplay == .none ? ThinkingDisplay.defaultValue : .none
        case .appSettings:
            #if os(macOS)
            self.openSettings()
            #else
            self.openAppSettings()
            #endif
        case .gatewaySettings:
            if let gateway { self.openGatewaySettings(gateway) }
        case .automations:
            if let gateway { self.openAutomations(gateway) }
        case .approvalHistory:
            if let gateway { self.openGatewaySettings(gateway, at: .approvals) }
        case .execPolicy:
            if let gateway { self.openGatewaySettings(gateway, at: .execPolicy) }
        case .usage:
            if let gateway { self.openGatewaySettings(gateway, at: .usage) }
        case .sessionUsage:
            if let gateway, let row { self.openGatewaySettings.sessionUsage(gateway, key: row.key, agentId: row.agentId) }
        }
    }
}

#if os(macOS)
private final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView { Probe(host: self.host) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let host: HostWindow
        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.host.window = self.window
        }
    }
}
#endif

/// The palette on screen, and the page and query it opened with.
struct PaletteRequest: Equatable {
    let id = UUID()
    var page = CommandPaletteView.Page.root
    var query = ""
}

/// Opens the palette's messages page searching for a query (⇧⌘F, the sidebar's "Search messages").
struct SearchMessagesAction {
    var open: @MainActor (String) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ query: String = "") { self.open(query) }
}

extension EnvironmentValues {
    @Entry var searchMessages = SearchMessagesAction()
}

/// Dims the window behind the palette; clicking outside closes it.
struct CommandPaletteOverlay: View {
    @Binding var request: PaletteRequest?
    var openAppSettings: () -> Void = {}

    var body: some View {
        if let request {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { self.request = nil }
                    .accessibilityHidden(true)
                CommandPaletteView(isPresented: Binding(get: { self.request != nil }, set: { if !$0 { self.request = nil } }),
                                   page: request.page, query: request.query, openAppSettings: self.openAppSettings)
                    .id(request.id)
                    .padding(.top, 72)
                    .padding(.horizontal, 16)
            }
            .transition(.opacity)
        }
    }
}

extension FocusedValues {
    /// The key window's command palette, so ⌘K only opens it there.
    @Entry var commandPalette: Binding<Bool>?
    /// Opens the key window's palette on message search (⇧⌘F); nil without a Gateway.
    @Entry var searchMessages: SearchMessagesAction?
}

/// Go menu: palette, back/forward, and ⌘1–⌘9 for the selected Gateway's pinned chats.
struct GoCommands: Commands {
    let app: AppModel
    @FocusedValue(\.commandPalette) private var palette
    @FocusedValue(\.searchMessages) private var searchMessages
    #if os(macOS)
    /// Commands live in the app's scenes, so this can open a main window even when none has
    /// existed since launch; Quick Capture uses it for Send & Open and Open in Pincer.
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some Commands {
        #if os(macOS)
        let _ = (QuickCaptureController.shared.openWindow = self.openWindow)
        #endif
        CommandMenu("Go") {
            Button("Command Palette…") { self.palette?.wrappedValue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(self.palette == nil)
            Button("Search Messages…") { self.searchMessages?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(self.palette == nil || self.searchMessages == nil || self.app.selectedGateway == nil)
            #if os(macOS)
            Button(QuickCaptureController.shared.menuTitle) {
                QuickCaptureController.shared.show()
            }
            #endif
            Divider()
            Button("Back") { self.app.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!self.app.canGoBack)
            Button("Forward") { self.app.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!self.app.canGoForward)
            let pinned = self.app.selectedGateway?.pinnedChats.prefix(9) ?? []
            if !pinned.isEmpty {
                Divider()
                Section("Pinned Chats") {
                    ForEach(Array(pinned.enumerated()), id: \.element.key) { index, row in
                        Button(row.title) { self.app.openPinned(index + 1) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
        }
    }
}
