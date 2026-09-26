import PincerKit
import SwiftUI

/// Channel list for one Gateway: categories (agents or groups), channels (sessions) and
/// threads (subagent sessions). The list itself is native (`SidebarList`); this view owns the
/// search, toolbar and sheets around it.
struct ChannelList: View {
    @Environment(GatewayStore.self) private var gateway
    let editConnection: () -> Void
    /// Called when the reader picks a chat, so compact layouts can show it.
    var openChat: () -> Void = {}
    @State private var search = ""
    @State private var newChat: NewChatRequest?
    @State private var renaming: SessionRow?
    @State private var changingIcon: SessionRow?
    @State private var changingGroupIcon: String?
    @State private var pickingColor: SessionRow?
    @State private var showingSettings = false
    @State private var showingGatewaySettings = false
    @State private var expandedThreads: Set<String> = []
    @AppStorage("pincer.showSubagentRuns") private var showSubagentRuns = false
    @AppStorage("pincer.showMessagePreviews") private var showMessagePreviews = true
    @Environment(\.appTheme) private var theme
    @State private var prompt: TextPrompt?
    @State private var confirmation: ConfirmPrompt?

    var body: some View {
        @Bindable var gateway = self.gateway
        VStack(spacing: 0) {
            #if os(macOS)
            // `.searchable(placement: .sidebar)` only shows up above a SwiftUI List on macOS.
            SidebarSearchField(text: self.$search, prompt: "Find a chat")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            #endif
            ConnectionStatusRow()
            SidebarList(
                model: SidebarModel.build(gateway: self.gateway, search: self.search, collapsed: self.gateway.collapsedSections,
                                          expandedThreads: self.expandedThreads, showSubagentRuns: self.showSubagentRuns,
                                          showPreviews: self.showMessagePreviews),
                selectedKey: self.gateway.selectedKey,
                gateway: self.gateway,
                actions: self.actions,
                theme: self.theme)
        }
        #if os(iOS)
        .searchable(text: self.$search, placement: .sidebar, prompt: "Find a chat")
        #endif
        .navigationTitle(self.gateway.profile.name)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Organize", selection: $gateway.organization) {
                        ForEach(SidebarOrganization.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Show Archived", isOn: $gateway.showArchived)
                    if self.gateway.organization == .group || self.gateway.organization == .servers {
                        Button("New Group…") { SidebarMenus.newGroup(gateway: self.gateway, actions: self.actions) }
                            .disabled(!self.gateway.state.isConnected)
                    }
                    Divider()
                    Button("Gateway Settings…") { self.showingGatewaySettings = true }
                        .disabled(!self.gateway.state.isConnected)
                    Button("Edit Connection…", action: self.editConnection)
                    Button("Reconnect") { self.gateway.stop(); self.gateway.start() }
                } label: {
                    Label("Organize", systemImage: Theme.filterSymbol)
                }
            }
            ToolbarItem {
                Button {
                    self.newChat = NewChatRequest(agentId: self.gateway.defaultAgentId)
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!self.gateway.state.isConnected)
            }
        }
        .sheet(item: self.$newChat) { request in
            NewSessionSheet(initialAgentId: request.agentId, initialGroup: request.group, onCreated: self.openChat)
        }
        .sheet(item: self.$renaming) { row in
            RenameSheet(row: row)
        }
        .sheet(item: self.$changingIcon) { row in
            IconPickerSheet(row: row)
        }
        .sheet(item: self.$changingGroupIcon) { group in
            GroupIconPickerSheet(group: group)
        }
        .sheet(item: self.$pickingColor) { row in
            ChatColorSheet(row: row)
        }
        .sheet(item: self.$prompt) { prompt in
            TextPromptSheet(prompt: prompt)
        }
        .sheet(isPresented: self.$showingGatewaySettings) {
            GatewaySettingsView()
        }
        .confirmationDialog(self.confirmation?.title ?? "", isPresented: Binding(
            get: { self.confirmation != nil }, set: { if !$0 { self.confirmation = nil } }
        ), titleVisibility: .visible, presenting: self.confirmation) { confirmation in
            Button(confirmation.action, role: .destructive, action: confirmation.onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { self.showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: self.$showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.showingSettings = false } } }
            }
        }
        #endif
    }

    private var actions: SidebarActions {
        SidebarActions(
            select: { key in
                self.gateway.selectedKey = key
                self.openChat()
            },
            newChat: { self.newChat = NewChatRequest(agentId: $0) },
            newChatInGroup: { self.newChat = NewChatRequest(agentId: self.gateway.defaultAgentId, group: $0) },
            rename: { self.renaming = $0 },
            changeIcon: { self.changingIcon = $0 },
            changeGroupIcon: { self.changingGroupIcon = $0 },
            pickColor: { self.pickingColor = $0 },
            prompt: { self.prompt = $0 },
            confirm: { self.confirmation = $0 },
            toggleThreads: { key in
                if self.expandedThreads.contains(key) { self.expandedThreads.remove(key) } else { self.expandedThreads.insert(key) }
            },
            setCollapsed: { id, collapsed in self.gateway.setSectionCollapsed(id, collapsed) },
            refresh: { await self.gateway.refreshSessions() })
    }
}

struct NewChatRequest: Identifiable {
    let id = UUID()
    let agentId: String
    var group: String?
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

private struct ConnectionStatusRow: View {
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        switch self.gateway.state {
        case .connected, .idle:
            EmptyView()
        default:
            self.status
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var status: some View {
        switch self.gateway.state {
        case .connected, .idle:
            EmptyView()
        case .connecting:
            self.connectingLabel
        case let .reconnecting(attempt, _, _) where !self.gateway.hasConnected && attempt <= 1:
            // A single failed first attempt (network still coming up at launch) isn't worth alarming about.
            self.connectingLabel
        case let .reconnecting(attempt, delay, reason):
            VStack(alignment: .leading, spacing: 2) {
                if self.gateway.hasConnected {
                    Label("Reconnecting in \(delay)s (attempt \(attempt))", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Can't reach Gateway · retrying in \(delay)s", systemImage: "antenna.radiowaves.left.and.right.slash")
                }
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Retry now") { self.gateway.reconnectIfNeeded() }.buttonStyle(.borderless)
            }
            .foregroundStyle(.orange)
        case let .awaitingPairing(requestId, deviceId):
            PairingStatusRow(requestId: requestId, deviceId: deviceId)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
        }
    }

    private var connectingLabel: some View {
        Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
    }
}

/// On iPhone the split view's detail column (which hosts `PairingView`) isn't on screen, so the
/// approval command would be unreachable. The row opens it in a sheet, automatically when compact.
private struct PairingStatusRow: View {
    let requestId: String?
    let deviceId: String
    @Environment(GatewayStore.self) private var gateway
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var showing = false

    var body: some View {
        Button {
            self.showing = true
        } label: {
            Label("Waiting for approval on the Gateway host", systemImage: "lock.shield").foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: self.$showing) {
            NavigationStack {
                ScrollView { PairingView(requestId: self.requestId, deviceId: self.deviceId) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { self.showing = false }
                        }
                    }
            }
            .environment(self.gateway)
        }
        .onAppear {
            #if os(iOS)
            if self.sizeClass == .compact { self.showing = true }
            #endif
        }
    }
}

struct NewSessionSheet: View {
    let initialAgentId: String
    var initialGroup: String?
    var onCreated: () -> Void = {}
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var agentId = ""
    @State private var label = ""
    @State private var group = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Agent", selection: self.$agentId) {
                    ForEach(self.gateway.agents) { agent in
                        Text("\(agent.emoji.map { "\($0) " } ?? "")\(agent.name)").tag(agent.id)
                    }
                }
                TextField("Name", text: self.$label, prompt: Text("e.g. Kitchen remodel"))
                TextField("Group", text: self.$group, prompt: Text("Optional"))
                if !self.gateway.groupNames.isEmpty {
                    Picker("Existing group", selection: self.$group) {
                        Text("None").tag("")
                        ForEach(self.gateway.groupNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        self.creating = true
                        Task {
                            let key = await self.gateway.createSession(agentId: self.agentId, label: self.label, category: self.group)
                            self.dismiss()
                            if key != nil { self.onCreated() }
                        }
                    }
                    .disabled(self.creating || self.agentId.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
        .onAppear {
            self.agentId = self.initialAgentId
            if let group = self.initialGroup { self.group = group }
        }
    }
}

struct RenameSheet: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: self.$label)
            }
            .formStyle(.grouped)
            .navigationTitle("Rename Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = self.label.trimmingCharacters(in: .whitespaces)
                        Task {
                            await self.gateway.patch(self.row.key, ["label": value.isEmpty ? .null : .string(value)])
                            self.dismiss()
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 140)
        #endif
        .onAppear { self.label = self.row.raw["label"]?.string ?? "" }
    }
}

/// Icon picker for a chat; the pick syncs to every device through the gateway.
struct IconPickerSheet: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        SymbolPickerSheet(
            current: ChannelRowStyle.customSymbol(for: self.row, gateway: self.gateway),
            defaultSymbol: ChannelRowStyle.defaultSymbol(for: self.row, isThread: self.row.isSubagent),
            tint: ChannelRowStyle.color(for: self.row, gateway: self.gateway) ?? .secondary,
            hasCustom: self.gateway.customIcon(for: self.row.key) != nil
        ) { symbol in
            self.gateway.setIcon(symbol, for: self.row.key)
        }
    }
}

/// Icon picker for a group's header; the pick syncs to every device through the gateway.
struct GroupIconPickerSheet: View {
    let group: String
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        SymbolPickerSheet(
            current: SymbolCatalog.symbol(for: self.gateway.groupIcon(for: self.group)),
            defaultSymbol: ChannelRowStyle.headerSymbol(for: .group(self.group)) ?? "folder",
            tint: .secondary,
            hasCustom: self.gateway.groupIcon(for: self.group) != nil
        ) { symbol in
            self.gateway.setGroupIcon(symbol, for: self.group)
        }
    }
}

/// Searchable grid of curated SF Symbols. `onPick(nil)` means go back to the default.
struct SymbolPickerSheet: View {
    let current: String?
    let defaultSymbol: String
    let tint: Color
    let hasCustom: Bool
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                let categories = SymbolCatalog.search(self.search)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 48), spacing: 6)], spacing: 6) {
                    ForEach(categories) { category in
                        Section {
                            ForEach(category.symbols, id: \.self) { symbol in
                                self.cell(symbol)
                            }
                        } header: {
                            Text(category.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 10)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                if categories.isEmpty {
                    ContentUnavailableView.search(text: self.search)
                }
            }
            .searchable(text: self.$search, prompt: "Search symbols")
            .navigationTitle("Change Icon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Use Default") {
                        self.onPick(nil)
                        self.dismiss()
                    }
                    .disabled(!self.hasCustom)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 440, idealHeight: 520)
        #endif
    }

    private func cell(_ symbol: String) -> some View {
        let selected = symbol == (self.current ?? self.defaultSymbol)
        return Button {
            self.onPick(symbol)
            self.dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(self.tint)
                .frame(width: 40, height: 40)
                .background(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol)
    }
}

struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    let field: String
    let initial: String
    let onSave: (String) -> Void
}

struct ConfirmPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: String
    let onConfirm: () -> Void
}

struct TextPromptSheet: View {
    let prompt: TextPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(self.prompt.field, text: self.$value)
                    .onSubmit(self.save)
            }
            .formStyle(.grouped)
            .navigationTitle(self.prompt.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: self.save) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 140)
        #endif
        .onAppear { self.value = self.prompt.initial }
    }

    private func save() {
        self.prompt.onSave(self.value)
        self.dismiss()
    }
}

/// Any color for a chat's icon, beyond OpenClaw's named ones. Syncs through the gateway's prefs.
struct ChatColorSheet: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var color = Color.accentColor

    private var symbol: String {
        ChannelRowStyle.customSymbol(for: self.row, gateway: self.gateway)
            ?? ChannelRowStyle.defaultSymbol(for: self.row, isThread: self.row.isSubagent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: self.symbol)
                            .font(.title2)
                            .foregroundStyle(self.color)
                            .frame(width: 32)
                        Text(self.row.title)
                            .lineLimit(1)
                    }
                    ColorPicker("Color", selection: self.$color, supportsOpacity: false)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Chat Color")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let hex = self.color.rgbHex { self.gateway.setColor(hex, for: self.row.key) }
                        self.dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 360, height: 200)
        #endif
        .onAppear {
            if let current = ChannelRowStyle.color(for: self.row, gateway: self.gateway) { self.color = current }
        }
    }
}
