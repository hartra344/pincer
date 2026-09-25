import PincerKit
import SwiftUI

/// Channel list for one Gateway: categories (agents or groups), channels (sessions) and
/// threads (subagent sessions).
struct ChannelList: View {
    @Environment(GatewayStore.self) private var gateway
    let editConnection: () -> Void
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var newSessionAgent: String?
    @State private var renaming: SessionRow?
    @State private var showingSettings = false
    @State private var expandedThreads: Set<String> = []
    @AppStorage("pincer.showSubagentRuns") private var showSubagentRuns = false
    @State private var prompt: TextPrompt?
    /// Chat being dragged in the sidebar, used to highlight only drops that would move it.
    @State private var draggingKey: String?
    /// Drop-zone element id → section id, for every zone the drag is currently over.
    @State private var dropHovers: [String: String] = [:]

    var body: some View {
        @Bindable var gateway = self.gateway
        List(selection: $gateway.selectedKey) {
            ConnectionStatusRow()
            ForEach(self.gateway.sections(search: self.search)) { section in
                let highlighted = self.isDropHighlighted(section)
                Section(isExpanded: self.expansion(section.id)) {
                    ForEach(section.channels) { channel in
                        let expanded = self.expandedThreads.contains(channel.row.key)
                        ChannelRow(
                            row: channel.row,
                            threads: channel.threads,
                            threadsExpanded: expanded,
                            showSubagentRuns: self.showSubagentRuns,
                            toggleThreads: {
                                if expanded { self.expandedThreads.remove(channel.row.key) }
                                else { self.expandedThreads.insert(channel.row.key) }
                            })
                            .tag(channel.row.key)
                            .contextMenu { self.menu(for: channel.row) }
                            .chatDragSource {
                                self.draggingKey = channel.row.key
                                return NSItemProvider(object: channel.row.key as NSString)
                            }
                            .groupDropZone(self, section: section, element: "row:\(channel.row.key)")
                            .listRowBackground(highlighted ? Color.accentColor.opacity(0.12) : nil)
                        ForEach(self.visibleThreads(channel, expanded: expanded)) { thread in
                            ChannelRow(row: thread, isThread: true)
                                .tag(thread.key)
                                .contextMenu { self.menu(for: thread) }
                                .groupDropZone(self, section: section, element: "row:\(thread.key)")
                                .listRowBackground(highlighted ? Color.accentColor.opacity(0.12) : nil)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        if let emoji = section.emoji {
                            Text(emoji)
                        } else if case let .server(server) = section.kind {
                            Image(systemName: ChannelRow.symbol(server.provider))
                        } else if case .group = section.kind {
                            Image(systemName: "chevron.down.square").imageScale(.small)
                        } else if case .automations = section.kind {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text(section.title)
                        if section.unreadCount > 0, self.collapsed.contains(section.id) {
                            Text("\(section.unreadCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        if section.agentId != nil || self.gateway.organization == .recent {
                            Button {
                                self.newSessionAgent = section.agentId ?? self.gateway.defaultAgentId
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("New chat")
                        }
                    }
                    .padding(.horizontal, highlighted ? 4 : 0)
                    .background(highlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .groupDropZone(self, section: section, element: "header:\(section.id)")
                    .contextMenu { self.headerMenu(for: section) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: self.$search, placement: .sidebar, prompt: "Find a chat")
        .navigationTitle(self.gateway.profile.name)
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Organize", selection: $gateway.organization) {
                        ForEach(SidebarOrganization.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle("Show Archived", isOn: $gateway.showArchived)
                    Divider()
                    Button("Edit Connection…", action: self.editConnection)
                    Button("Reconnect") { self.gateway.stop(); self.gateway.start() }
                } label: {
                    Label("Organize", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem {
                Button {
                    self.newSessionAgent = self.gateway.defaultAgentId
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!self.gateway.state.isConnected)
            }
        }
        .sheet(item: self.$newSessionAgent) { agentId in
            NewSessionSheet(initialAgentId: agentId)
        }
        .sheet(item: self.$renaming) { row in
            RenameSheet(row: row)
        }
        .sheet(item: self.$prompt) { prompt in
            TextPromptSheet(prompt: prompt)
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
        .refreshable { await self.gateway.refreshSessions() }
    }

    // MARK: Drag and drop between groups

    fileprivate func isDropHighlighted(_ section: SidebarSection) -> Bool {
        guard let key = self.draggingKey, self.dropHovers.values.contains(section.id) else { return false }
        return self.gateway.groupDropValue(for: key, onto: section) != nil
    }

    fileprivate func setDropHover(_ targeted: Bool, element: String, section: SidebarSection) {
        if targeted { self.dropHovers[element] = section.id } else { self.dropHovers[element] = nil }
    }

    fileprivate func drop(_ keys: [String], onto section: SidebarSection) -> Bool {
        self.draggingKey = nil
        self.dropHovers = [:]
        let moves = keys.filter { self.gateway.groupDropValue(for: $0, onto: section) != nil }
        guard !moves.isEmpty else { return false }
        Task {
            for key in moves { await self.gateway.moveToGroup(key, droppedOn: section) }
        }
        return true
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !self.collapsed.contains(id) },
            set: { expanded in
                if expanded { self.collapsed.remove(id) } else { self.collapsed.insert(id) }
            })
    }

    /// Subagent threads stay tucked under their parent unless running, selected, or expanded.
    private func visibleThreads(_ channel: SidebarChannel, expanded: Bool) -> [SessionRow] {
        // Like Discord, helper runs live inside the conversation (as "Open run" on their tool call)
        // unless the sidebar is set to list them.
        if !self.showSubagentRuns {
            return channel.threads.filter { !$0.isSubagent || $0.key == self.gateway.selectedKey }
        }
        if expanded { return channel.threads }
        return channel.threads.filter { !$0.isSubagent || $0.hasActiveRun || $0.key == self.gateway.selectedKey }
    }

    @ViewBuilder
    private func headerMenu(for section: SidebarSection) -> some View {
        switch section.kind {
        case let .server(server):
            Button("Rename Server…", systemImage: "pencil") {
                self.prompt = TextPrompt(title: "Rename Server", field: "Name", initial: section.title) { name in
                    self.gateway.renameServer(server, to: name)
                }
            }
        case let .group(name):
            Button("Rename Group…", systemImage: "pencil") {
                self.prompt = TextPrompt(title: "Rename Group", field: "Name", initial: name) { newName in
                    let value = newName.trimmingCharacters(in: .whitespaces)
                    Task {
                        for channel in section.channels {
                            await self.gateway.patch(channel.row.key, ["category": value.isEmpty ? .null : .string(value)])
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func menu(for row: SessionRow) -> some View {
        Button(row.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
            Task { await self.gateway.patch(row.key, ["pinned": .bool(!row.isPinned)]) }
        }
        Button(row.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: "circle.fill") {
            Task { await self.gateway.patch(row.key, ["unread": .bool(!row.isUnread)]) }
        }
        Button("Rename…", systemImage: "pencil") { self.renaming = row }
        Menu("Move to Group", systemImage: "folder") {
            ForEach(self.gateway.groupNames, id: \.self) { name in
                Button(name) { Task { await self.gateway.patch(row.key, ["category": .string(name)]) } }
            }
            if !self.gateway.groupNames.isEmpty { Divider() }
            Button("New Group…") {
                self.prompt = TextPrompt(title: "New Group", field: "Name", initial: "") { name in
                    let value = name.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    Task { await self.gateway.patch(row.key, ["category": .string(value)]) }
                }
            }
            if row.category != nil {
                Button("Remove from Group") { Task { await self.gateway.patch(row.key, ["category": .null]) } }
            }
        }
        Menu("Color", systemImage: "paintpalette") {
            ForEach(["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink"], id: \.self) { color in
                Button(color.capitalized) { Task { await self.gateway.patch(row.key, ["color": .string(color)]) } }
            }
            Divider()
            Button("None") { Task { await self.gateway.patch(row.key, ["color": .null]) } }
        }
        ReasoningMenu(row: row)
        if !row.isMain {
            Divider()
            Button(row.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
                Task { await self.gateway.patch(row.key, ["archived": .bool(!row.isArchived)]) }
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

private extension View {
    // Drag and drop between groups is macOS-only. On iOS, a SwiftUI List never delivers drops
    // from its own rows to row, header, or ForEach drop destinations, and `onMove` can't cross
    // sections, so iOS uses the "Move to Group" context menu instead.

    /// Makes a sidebar row draggable. Uses `.itemProvider`, not `.onDrag`: on macOS `.onDrag`
    /// swallows the mouse-down, so clicks to select a chat lag or get lost.
    @ViewBuilder
    func chatDragSource(_ provider: @escaping () -> NSItemProvider) -> some View {
        #if os(macOS)
        self.itemProvider { provider() }
        #else
        self
        #endif
    }

    /// Accepts chats dragged from the sidebar and moves them into `section`'s group.
    @ViewBuilder
    func groupDropZone(_ list: ChannelList, section: SidebarSection, element: String) -> some View {
        #if os(macOS)
        self.dropDestination(for: String.self) { keys, _ in
            list.drop(keys, onto: section)
        } isTargeted: { targeted in
            list.setDropHover(targeted, element: element, section: section)
        }
        #else
        self
        #endif
    }
}

private struct ChannelRow: View {
    let row: SessionRow
    var isThread = false
    var threads: [SessionRow] = []
    var threadsExpanded = false
    var showSubagentRuns = true
    var toggleThreads: () -> Void = {}
    @Environment(GatewayStore.self) private var gateway

    private var runningSubagents: Int { self.subagents.filter(\.hasActiveRun).count }

    private var subagents: [SessionRow] { self.threads.filter(\.isSubagent) }

    private var hiddenUnreadThreads: Int {
        self.threadsExpanded ? 0 : self.subagents.filter { $0.isUnread && !$0.hasActiveRun }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            if self.isThread {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
            self.icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(self.row.title)
                        .fontWeight(self.row.isUnread && !self.row.isSubagent ? .semibold : .regular)
                        .foregroundStyle(self.row.isSubagent ? .secondary : .primary)
                        .lineLimit(1)
                    if self.row.isPinned, !self.isThread {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if let preview = self.row.preview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if self.showSubagentRuns, !self.subagents.isEmpty {
                Button(action: self.toggleThreads) {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                        Text("\(self.subagents.count)")
                        Image(systemName: self.threadsExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption2)
                    .foregroundStyle(self.hiddenUnreadThreads > 0 ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(self.threadsExpanded ? "Hide subagent runs" : "Show \(self.subagents.count) subagent runs")
            }
            if self.row.hasActiveRun || (!self.showSubagentRuns && self.runningSubagents > 0) {
                ProgressView().controlSize(.mini)
                    .help(self.row.hasActiveRun ? "Working" : "\(self.runningSubagents) helper runs working")
            } else if self.row.isUnread, !self.row.isSubagent {
                Circle().fill(.primary).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            } else if let date = self.row.activityDate {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(self.row.isArchived ? .secondary : .primary)
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        let tint = Theme.color(named: self.row.color) ?? .secondary
        if self.isThread {
            Image(systemName: self.row.isSubagent ? "sparkles" : "bubble.left.and.text.bubble.right").foregroundStyle(tint)
        } else if self.row.isAutomation {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(tint)
        } else if self.row.isSlashCommands {
            Image(systemName: "command").foregroundStyle(tint)
        } else if self.row.server != nil, !self.row.isChannelThread {
            Image(systemName: "number").foregroundStyle(tint)
                .help("\(self.row.server?.provider.capitalized ?? "Server") channel")
        } else if let origin = self.row.channel?.lowercased(), origin == "discord" || origin == "slack" || origin == "telegram" || origin == "imessage" || origin == "whatsapp" {
            Image(systemName: Self.symbol(origin)).foregroundStyle(tint)
                .help("From \(origin.capitalized)")
        } else if self.row.isMain {
            Image(systemName: "house").foregroundStyle(tint)
        } else {
            Image(systemName: "number").foregroundStyle(tint)
        }
    }

    static func symbol(_ origin: String) -> String {
        switch origin {
        case "imessage": "message"
        case "whatsapp", "telegram": "paperplane"
        default: "bubble.left.and.bubble.right"
        }
    }
}

private struct ConnectionStatusRow: View {
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        switch self.gateway.state {
        case .connected, .idle:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case let .reconnecting(attempt, delay, reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("Reconnecting in \(delay)s (attempt \(attempt))", systemImage: "arrow.triangle.2.circlepath")
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
                            _ = await self.gateway.createSession(agentId: self.agentId, label: self.label, category: self.group)
                            self.dismiss()
                        }
                    }
                    .disabled(self.creating || self.agentId.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
        .onAppear { self.agentId = self.initialAgentId }
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


struct TextPrompt: Identifiable {
    let id = UUID()
    let title: String
    let field: String
    let initial: String
    let onSave: (String) -> Void
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
