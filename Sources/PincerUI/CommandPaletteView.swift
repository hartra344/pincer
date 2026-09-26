import PincerKit
import SwiftUI

/// ⌘K: jump to a chat, start a chat with an agent, or run a command, all from the keyboard.
/// Type to filter, ↑/↓ to move, Return to run, Esc to go back or close.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    /// iOS: Settings is a sheet owned by the presenter.
    var openAppSettings: () -> Void = {}
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    @Environment(\.openAutomations) private var openAutomations
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @AppStorage(ThinkingDisplay.storageKey) private var thinkingDisplay = ThinkingDisplay.defaultValue
    @State private var query = ""
    @State private var page = Page.root
    @State private var selection: String?
    @FocusState private var focused: Bool

    enum Page { case root, models }

    private enum Command: String {
        case back, forward, nextUnread, changeModel, togglePin, toggleThinking, appSettings, gatewaySettings, automations
    }

    private var gateway: GatewayStore? { self.app.selectedGateway }
    private var row: SessionRow? { self.gateway.flatMap { gateway in gateway.selectedKey.flatMap { gateway.sessions[$0] } } }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: self.page == .models ? "cpu" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(self.page == .models ? "Choose a model…" : "Jump to a chat or run a command…", text: self.$query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$focused)
                    .onSubmit { self.runSelection(in: results) }
                    .onKeyPress(.upArrow) { self.move(-1, in: results); return .handled }
                    .onKeyPress(.downArrow) { self.move(1, in: results); return .handled }
                    .onKeyPress(.escape) { self.escape(); return .handled }
                    .onKeyPress(.delete) {
                        guard self.page == .models, self.query.isEmpty else { return .ignored }
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
            if results.isEmpty {
                Text(self.page == .models && self.gateway?.loadingModelCatalogs.isEmpty == false ? "Loading models…" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                self.list(results)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear { self.focused = true }
        .onChange(of: self.query) { self.selection = nil }
        .task(id: self.page) {
            guard self.page == .models, let gateway = self.gateway, let row = self.row else { return }
            await gateway.loadModels(agentId: row.agentId)
        }
    }

    private func list(_ results: [PaletteItem]) -> some View {
        let showsSections = self.query.trimmingCharacters(in: .whitespaces).isEmpty && self.page == .root
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        if showsSections, index == 0 || results[index - 1].section != item.section {
                            Text(item.section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 2 : 10)
                                .padding(.bottom, 2)
                        }
                        self.row(item, selected: item.id == self.currentSelection(in: results))
                            .id(item.id)
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

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        Button {
            self.run(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? .primary : .secondary)
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
        .onHover { if $0 { self.selection = item.id } }
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
        }
        return Array(PaletteMatcher.rank(items, query: self.query).prefix(80))
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
            ]
        }
        return items
    }

    // MARK: Keyboard

    private func currentSelection(in results: [PaletteItem]) -> String? {
        if let selection, results.contains(where: { $0.id == selection }) { return selection }
        return results.first(where: \.isEnabled)?.id
    }

    private func move(_ offset: Int, in results: [PaletteItem]) {
        guard !results.isEmpty else { return }
        let current = self.currentSelection(in: results).flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        self.selection = results[(current + offset + results.count) % results.count].id
    }

    private func runSelection(in results: [PaletteItem]) {
        guard let id = self.currentSelection(in: results), let item = results.first(where: { $0.id == id }) else { return }
        self.run(item)
    }

    private func escape() {
        if self.page == .models { self.show(.root) } else { self.close() }
    }

    private func show(_ page: Page) {
        self.page = page
        self.query = ""
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
        }
    }
}

/// Dims the window behind the palette; clicking outside closes it.
struct CommandPaletteOverlay: View {
    @Binding var isPresented: Bool
    var openAppSettings: () -> Void = {}

    var body: some View {
        if self.isPresented {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { self.isPresented = false }
                    .accessibilityHidden(true)
                CommandPaletteView(isPresented: self.$isPresented, openAppSettings: self.openAppSettings)
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
}

/// Go menu: palette, back/forward, and ⌘1–⌘9 for the selected Gateway's pinned chats.
struct GoCommands: Commands {
    let app: AppModel
    @FocusedValue(\.commandPalette) private var palette

    var body: some Commands {
        CommandMenu("Go") {
            Button("Command Palette…") { self.palette?.wrappedValue.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(self.palette == nil)
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
