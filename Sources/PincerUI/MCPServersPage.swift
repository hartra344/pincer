import PincerKit
import SwiftUI

// Gateway Settings → MCP Servers: the servers in `mcp.servers` with their live status, plus the
// detail page for one server. Edits go into the shared settings draft (Review & Save); reconnect
// and OAuth sign-in happen right away.

// MARK: Status text

/// How a server's status reads in the list and the detail page.
struct MCPStatusText {
    enum Tone { case good, warning, bad, neutral }

    let title: String
    let detail: String?
    let tone: Tone

    var color: Color {
        switch self.tone {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }

    init(_ status: MCPServerStatus) {
        let auth = status.auth
        switch status.state {
        case .unsaved: (self.title, self.detail, self.tone) = (L("Not Saved"), nil, .warning)
        case .disabled: (self.title, self.detail, self.tone) = (L("Disabled"), nil, .neutral)
        case .invalid: (self.title, self.detail, self.tone) = (L("Invalid Config"), nil, .bad)
        case .unknown: (self.title, self.detail, self.tone) = (L("Status Unknown"), nil, .neutral)
        case .connected:
            let count = status.toolCount
            let title = switch count {
            case nil: L("Connected")
            case 1?: L("Connected · 1 tool")
            case let count?: L("Connected · \(count) tools")
            }
            (self.title, self.detail, self.tone) = (title, nil, .good)
        default:
            if status.needsSignIn {
                (self.title, self.detail, self.tone) = (auth?.isExpired == true ? L("Sign-In Expired") : L("Needs Sign-In"),
                                                        auth?.isExpired == true ? status.lastError : nil, .warning)
            } else if auth?.state == .pendingAuthorization {
                (self.title, self.detail, self.tone) = (L("Waiting for Sign-In…"), nil, .warning)
            } else {
                switch status.state {
                case .connecting: (self.title, self.detail, self.tone) = (L("Connecting…"), nil, .neutral)
                case .idle: (self.title, self.detail, self.tone) = (L("Idle"), nil, .neutral)
                case .backoff:
                    let title = status.nextRetryAt.map { L("Retrying \($0.formatted(.relative(presentation: .numeric)))") } ?? L("Retrying…")
                    (self.title, self.detail, self.tone) = (title, status.lastError, .bad)
                default: (self.title, self.detail, self.tone) = (L("Error"), status.lastError, .bad)
                }
            }
        }
    }
}

struct MCPStatusLabel: View {
    let status: MCPServerStatus

    var body: some View {
        let text = MCPStatusText(self.status)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Circle().fill(text.color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(text.title).foregroundStyle(text.color == .green ? .primary : text.color)
            }
            if let detail = text.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
        .font(.caption)
    }
}

// MARK: Helpers

/// Who signs a server in.
enum MCPSignInKind: Equatable {
    /// Not an OAuth server.
    case none
    /// One sign-in for the Gateway, done from here.
    case shared
    /// Each person connects from chat.
    case perRequester
    /// Uses a saved auth profile.
    case profile(String)
}

extension MCPServer {
    var signInKind: MCPSignInKind {
        guard self.usesOAuth else { return .none }
        if self.oauthIdentity == "per-requester" { return .perRequester }
        if let profile = self.oauthAuthProfileId, !profile.isEmpty { return .profile(profile) }
        return .shared
    }
}

extension MCPServersModel {
    /// Whether any server needs a look (an error or a sign-in), for the sidebar dot.
    var needsAttention: Bool {
        self.servers.contains { server in
            let status = self.status(for: server.name)
            return status.state == .error || status.state == .backoff
                || (server.signInKind == .shared && status.needsSignIn)
        }
    }

    /// Why Reconnect and sign-in can't run yet: they act on the saved server, not the draft.
    func actionBlock(_ name: String) -> String? {
        guard let server = self.server(name) else { return nil }
        if self.isNew(name) || self.isChanged(name) { return L("Save your changes first.") }
        if !server.enabled { return L("Turn on and save first.") }
        return nil
    }

    /// Why Test Connection can't run yet: it tests the saved server, so unsaved edits don't count.
    func probeBlock(_ name: String) -> String? {
        self.isNew(name) || self.isChanged(name) ? L("Save your changes first.") : nil
    }

    /// Servers removed in the draft but still saved on the Gateway.
    func removedServers(in settings: GatewaySettingsModel) -> [MCPServer] {
        (settings.savedValue(at: MCPServers.path)?.object ?? [:]).keys
            .filter { self.isRemoved($0) }
            .compactMap { self.savedServer($0) }
    }
}

/// The `openclaw` commands for Gateways that can't sign in remotely.
private func mcpLoginCommand(_ name: String) -> String { "openclaw mcp login \(name)" }
private func mcpLogoutCommand(_ name: String) -> String { "openclaw mcp logout \(name)" }

extension GatewayStore {
    /// "Scout" for "As seen by Scout's main session".
    fileprivate var defaultAgentTitle: String {
        self.agents.first { $0.id == self.defaultAgentId }?.title ?? self.defaultAgentId
    }
}

// MARK: Server actions

/// The actions on one server, shared by the list's context menu and swipe actions.
private struct MCPServerActions: View {
    let server: MCPServer
    let model: MCPServersModel
    let flow: MCPSignInFlow
    let edit: () -> Void
    let remove: () -> Void
    let signOut: () -> Void

    var body: some View {
        let name = self.server.name
        let status = self.model.status(for: name)
        let block = self.model.actionBlock(name)
        let ready = self.model.canEdit && block == nil && !self.model.operation(for: name).isRunning
        if self.model.canEdit {
            Button(L("Edit…"), systemImage: "pencil", action: self.edit)
        }
        if self.model.supportsReconnect {
            Button(L("Reconnect"), systemImage: "arrow.clockwise") { Task { await self.model.reconnect(name) } }
                .disabled(!ready)
        }
        if self.server.signInKind == .shared, self.model.supportsOAuth {
            if status.auth?.state == .authorized {
                Button(L("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right", action: self.signOut)
                    .disabled(!ready)
            } else {
                Button(status.auth?.isExpired == true ? L("Sign In Again") : L("Sign In"), systemImage: "person.badge.key") {
                    Task { await self.flow.start(name, model: self.model) }
                }
                .disabled(!ready || self.flow.isSigningIn(name))
            }
        }
        Button(L("Copy Name"), systemImage: "doc.on.doc") { Clipboard.copy(name) }
        if self.model.canEdit {
            Divider()
            Button(L("Remove…"), systemImage: "trash", role: .destructive, action: self.remove)
        }
    }
}

// MARK: List page

struct MCPServersPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var editor: MCPEditorTarget?
    @State private var removing: String?
    @State private var signingOut: String?
    @State private var flow = MCPSignInFlow()

    var body: some View {
        let model = self.gateway.mcp
        let connected = self.gateway.state.isConnected
        Group {
            if !connected, !model.hasConfig {
                ContentUnavailableView(L("Not Connected"), systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the Gateway to see MCP servers.", bundle: .module))
            } else {
                self.list(model, connected: connected)
            }
        }
        .navigationTitle(L("MCP Servers"))
        .toolbar {
            if model.canEdit {
                ToolbarItem {
                    Button { self.editor = MCPEditorTarget(draft: MCPServerDraft()) } label: {
                        Label(L("Add Server"), systemImage: "plus")
                    }
                    .disabled(!model.hasConfig)
                    .help(L("Add an MCP server"))
                }
            }
            ToolbarItem {
                Button { Task { await model.load() } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(!connected || model.loadState.isRunning)
            }
        }
        .sheet(item: self.$editor) { target in
            MCPServerEditor(draft: target.draft)
                .environment(self.gateway)
        }
        .confirmationDialog(L("Remove \(self.removing ?? "")?"), isPresented: Binding(
            get: { self.removing != nil }, set: { if !$0 { self.removing = nil } }), titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                if let name = self.removing { model.remove(name) }
                self.removing = nil
            }
        } message: {
            Text("The server is removed when you save your changes.", bundle: .module)
        }
        .mcpSignOutConfirmation(self.$signingOut, model: model)
        .mcpSignIn(self.flow, model: model)
        .task(id: connected) { if connected { await model.load() } }
    }

    private func list(_ model: MCPServersModel, connected: Bool) -> some View {
        let removed = model.removedServers(in: self.gateway.settings)
        let rows = (model.servers + removed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return GatewaySettingsForm {
            if !model.canEdit {
                Section { FullManagementBadge { self.navigator.destination = .connection } }
            }
            if let message = self.flow.message {
                Section {
                    HStack {
                        Label(message, systemImage: "info.circle")
                        Spacer()
                        Button(L("Dismiss")) { self.flow.message = nil }.buttonStyle(.borderless)
                    }
                }
            }
            if rows.isEmpty, !model.pluginServers.isEmpty {
                Section {
                    Text("No servers configured on this Gateway.", bundle: .module).foregroundStyle(.secondary)
                    if model.canEdit {
                        Button(L("Add Server")) { self.editor = MCPEditorTarget(draft: MCPServerDraft()) }
                    }
                }
            }
            if rows.isEmpty, model.pluginServers.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L("No MCP Servers"), systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Add a server to give your agents more tools.", bundle: .module)
                    } actions: {
                        if model.canEdit {
                            Button(L("Add Server")) { self.editor = MCPEditorTarget(draft: MCPServerDraft()) }
                        }
                    }
                }
            } else if !rows.isEmpty {
                Section {
                    ForEach(rows) { server in
                        if model.isRemoved(server.name) {
                            self.removedRow(server, model: model)
                        } else {
                            self.row(server, model: model)
                        }
                    }
                    if let error = model.loadState.error, connected {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                } footer: {
                    self.footer(model, rows: rows)
                }
            }
            self.pluginSection(model)
        }
    }

    @ViewBuilder private func pluginSection(_ model: MCPServersModel) -> some View {
        if !model.pluginServers.isEmpty {
            Section {
                ForEach(model.pluginServers) { server in
                    MCPPluginServerRow(server: server, status: model.status(for: server)) {
                        self.navigator.go(to: SettingsLocation(destination: .plugins, routes: [.plugin(server.pluginId)]))
                    }
                }
            } header: {
                Text("From Plugins", bundle: .module)
            } footer: {
                Text("Managed by plugins. Change them in each plugin's settings.", bundle: .module)
            }
        }
    }

    private func removedRow(_ server: MCPServer, model: MCPServersModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(server.name).strikethrough().foregroundStyle(.secondary)
                Text("Will Be Removed", bundle: .module).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            Button(L("Undo")) { model.undoRemove(server.name) }.buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ server: MCPServer, model: MCPServersModel) -> some View {
        let status = model.status(for: server.name)
        let edited = model.isChanged(server.name) && !model.isNew(server.name)
        return HStack {
            NavigationLink(value: SettingsRoute.mcpServer(server.name)) {
                HStack {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(server.name)
                            if edited {
                                Text("Edited", bundle: .module).font(.caption2).foregroundStyle(.tint)
                            }
                        }
                        Text(server.transport?.title ?? L("Unknown transport"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if status.state != .unknown {
                        MCPStatusLabel(status: status).frame(maxWidth: 220, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Toggle(L("Enabled"), isOn: Binding(
                get: { server.enabled }, set: { model.setEnabled(server.name, $0) }))
                .labelsHidden()
                .disabled(!model.canEdit)
        }
        .contextMenu { self.actions(server, model: model) }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            if model.canEdit {
                Button(L("Remove"), role: .destructive) { self.removing = server.name }
            }
        }
        .swipeActions(edge: .leading) {
            if model.canEdit {
                Button(server.enabled ? L("Turn Off") : L("Turn On")) { model.setEnabled(server.name, !server.enabled) }
                    .tint(server.enabled ? .gray : .green)
            }
        }
        #endif
    }

    private func actions(_ server: MCPServer, model: MCPServersModel) -> some View {
        MCPServerActions(server: server, model: model, flow: self.flow,
                         edit: { self.editor = MCPEditorTarget(draft: MCPServerDraft(server: server)) },
                         remove: { self.removing = server.name },
                         signOut: { self.signingOut = server.name })
    }

    @ViewBuilder private func footer(_ model: MCPServersModel, rows: [MCPServer]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Server changes are saved with Review & Save. Reconnect and sign-in happen right away.", bundle: .module)
            switch model.statusSource {
            case .live: EmptyView()
            case .session: Text("Status is as seen by \(self.gateway.defaultAgentTitle)'s main session.", bundle: .module)
            case .none:
                Text("This Gateway doesn't report MCP status. Tools show up once an agent connects to the server.", bundle: .module)
            }
            if !model.supportsOAuth, rows.contains(where: { $0.signInKind == .shared }) {
                Text("This Gateway can't sign in from Pincer. Sign in on the Gateway host with `openclaw mcp login <name>`.", bundle: .module)
            }
        }
    }
}

extension View {
    /// "Sign out of x?" before `MCPServersModel.signOut` runs.
    func mcpSignOutConfirmation(_ name: Binding<String?>, model: MCPServersModel) -> some View {
        self.confirmationDialog(L("Sign out of \(name.wrappedValue ?? "")?"), isPresented: Binding(
            get: { name.wrappedValue != nil }, set: { if !$0 { name.wrappedValue = nil } }), titleVisibility: .visible) {
            Button(L("Sign Out"), role: .destructive) {
                if let server = name.wrappedValue { Task { await model.signOut(server) } }
                name.wrappedValue = nil
            }
        } message: {
            Text("Agents lose its tools until someone signs in again.", bundle: .module)
        }
    }
}

/// A read-only row for a server a plugin declares. Tapping opens the plugin.
private struct MCPPluginServerRow: View {
    let server: PluginMCPServer
    let status: MCPServerStatus?
    let open: () -> Void

    var body: some View {
        Button(action: self.open) {
            HStack {
                self.details
                Spacer()
                self.badges
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("Opens the \(self.pluginTitle) plugin"))
        .contextMenu {
            Button(L("Open Plugin"), systemImage: "puzzlepiece.extension", action: self.open)
            Button(L("Copy Name"), systemImage: "doc.on.doc") { Clipboard.copy(self.server.name) }
        }
    }

    private var pluginTitle: String { self.server.pluginName ?? self.server.pluginId }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(self.server.name)
            Text(L("\(self.pluginTitle) plugin"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var badges: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
            if !self.server.isAvailable {
                Text("Unavailable", bundle: .module).font(.caption).foregroundStyle(.orange)
            } else if let status = self.status, status.state != .unknown {
                MCPStatusLabel(status: status)
            } else if let auth = self.server.auth {
                MCPAuthBadge(auth: auth)
            }
        }
    }
}

/// "Signed in" / "Needs Sign-In" for a plugin server's auth.
struct MCPAuthBadge: View {
    let auth: MCPAuthStatus

    var body: some View {
        let signedIn = self.auth.state == .authorized
        Label(self.title, systemImage: signedIn ? "checkmark.seal.fill" : "person.badge.key")
            .font(.caption)
            .foregroundStyle(signedIn ? .green : .orange)
    }

    private var title: String {
        switch self.auth.state {
        case .authorized: L("Signed in")
        case .pendingAuthorization: L("Waiting for Sign-In…")
        default: self.auth.isExpired ? L("Sign-In Expired") : L("Needs Sign-In")
        }
    }
}

// MARK: Detail page

struct MCPServerPage: View {
    let name: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.openURL) private var openURL
    @State private var editor: MCPEditorTarget?
    @State private var confirmRemove = false
    @State private var signingOut: String?
    @State private var pasting = false
    @State private var flow = MCPSignInFlow()
    @State private var probe = MCPProbeState()

    var body: some View {
        let model = self.gateway.mcp
        if model.isRemoved(self.name) {
            GatewaySettingsForm {
                Section {
                    Label(L("Will Be Removed"), systemImage: "trash").foregroundStyle(.orange)
                    Button(L("Undo")) { model.undoRemove(self.name) }
                } footer: {
                    Text("The server is removed when you save your changes.", bundle: .module)
                }
            }
            .navigationTitle(self.name)
        } else if let server = model.server(self.name) {
            let status = model.status(for: server.name)
            let operation = model.operation(for: server.name)
            ScrollViewReader { proxy in
            GatewaySettingsForm {
                if !model.canEdit {
                    Section { FullManagementBadge { self.navigator.destination = .connection } }
                }
                self.statusSection(server, status: status, model: model, operation: operation)
                if server.usesOAuth { self.accountSection(server, status: status, model: model, operation: operation) }
                self.toolsSection(server, status: status, model: model)
                self.configSection(server)
                self.actionsSection(server, status: status, model: model, operation: operation)
            }
            .onChange(of: self.probe.result) { _, result in
                guard result != nil else { return }
                Task {
                    await Task.yield()
                    withAnimation { proxy.scrollTo(MCPScrollTarget.resultID, anchor: .bottom) }
                }
            }
            }
            .navigationTitle(server.name)
            .sheet(item: self.$editor) { target in
                MCPServerEditor(draft: target.draft)
                    .environment(self.gateway)
            }
            .sheet(isPresented: self.$pasting) {
                MCPPasteCodeSheet { await self.flow.complete(pasted: $0, model: model) }
            }
            .confirmationDialog(L("Remove \(server.name)?"), isPresented: self.$confirmRemove, titleVisibility: .visible) {
                Button(L("Remove"), role: .destructive) {
                    model.remove(server.name)
                    if self.navigator.path.last == .mcpServer(server.name) { self.navigator.path.removeLast() }
                }
            } message: {
                Text("The server is removed when you save your changes.", bundle: .module)
            }
            .mcpSignIn(self.flow, model: model)
            .onChange(of: status.auth?.state) { self.flow.reconcile(server.name, state: status.auth?.state) }
            .task(id: self.gateway.state.isConnected) { if self.gateway.state.isConnected { await model.load() } }
            // A sign-in moved to the browser outlives the page; the Gateway's event or the attempt's expiry ends it.
            .onDisappear { if !self.flow.handedOff { Task { await self.flow.cancel(model: model) } } }
        } else {
            ContentUnavailableView(L("Server Removed"), systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func statusSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                               operation: OperationState) -> some View {
        Section {
            HStack {
                Toggle(L("Enabled"), isOn: Binding(
                    get: { server.enabled }, set: { model.setEnabled(server.name, $0) }))
                if operation.isRunning { ProgressView().controlSize(.small) }
            }
            .disabled(!model.canEdit)
            if status.state != .unknown {
                LabeledContent(L("Status")) { MCPStatusLabel(status: status) }
            }
            if let error = MCPStatusText(status).detail {
                Button(L("Copy Error"), systemImage: "doc.on.doc") { Clipboard.copy(error) }
            }
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            if model.isChanged(server.name) {
                Label(model.isNew(server.name) ? L("Not saved yet.") : L("Edited. Not saved yet."), systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.tint)
            }
        } footer: {
            switch model.statusSource {
            case .live: EmptyView()
            case .session: Text("Status is as seen by \(self.gateway.defaultAgentTitle)'s main session.", bundle: .module)
            case .none:
                Text("This Gateway doesn't report MCP status. Tools show up once an agent connects to the server.", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func accountSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                                operation: OperationState) -> some View {
        let block = model.actionBlock(server.name)
        let auth = status.auth
        Section {
            switch server.signInKind {
            case .perRequester:
                Text("Each person connects from chat the first time an agent uses this server.", bundle: .module)
                    .foregroundStyle(.secondary)
            case let .profile(id):
                Text("Signs in with auth profile \(id).", bundle: .module).foregroundStyle(.secondary)
            default:
                self.sharedAccount(server, status: status, model: model, operation: operation, block: block)
            }
            if server.signInKind != .none, server.signInKind != .shared, auth?.state == .authorized {
                Label(auth?.account.map { L("Signed in as \($0)") } ?? L("Signed in"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Account", bundle: .module)
        } footer: {
            if server.signInKind == .shared, let block, model.supportsOAuth {
                Text(block)
            }
        }
    }

    @ViewBuilder
    private func sharedAccount(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                               operation: OperationState, block: String?) -> some View {
        let auth = status.auth
        let ready = model.canEdit && block == nil && !operation.isRunning
        if let message = self.flow.message {
            Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
        }
        if !model.supportsOAuth {
            self.commandRow(L("Sign in on the Gateway host:"), mcpLoginCommand(server.name))
            if auth?.state == .authorized {
                self.commandRow(L("Sign out on the Gateway host:"), mcpLogoutCommand(server.name))
            }
        } else if auth?.state == .authorized {
            Label(auth?.account.map { L("Signed in as \($0)") } ?? L("Signed in"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let expiresAt = auth?.expiresAt {
                Text("Expires \(expiresAt.formatted(.relative(presentation: .named)))", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Sign Out"), role: .destructive) { self.signingOut = server.name }
                .disabled(!ready)
                .mcpSignOutConfirmation(self.$signingOut, model: model)
        } else if self.flow.waiting?.server == server.name {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for Sign-In…", bundle: .module).foregroundStyle(.secondary)
            }
            Button(L("Open in Browser"), systemImage: "safari") { self.flow.openInBrowser(self.openURL) }
            Button(L("Paste Code or URL…"), systemImage: "doc.on.clipboard") { self.pasting = true }
            Button(L("Cancel"), role: .cancel) { Task { await self.flow.cancel(model: model) } }
        } else {
            if self.flow.message == nil {
                Text(auth?.isExpired == true ? L("Your sign-in expired.") : L("Not signed in."))
                    .foregroundStyle(.secondary)
            }
            Button(auth?.isExpired == true ? L("Sign In Again") : L("Sign In"), systemImage: "person.badge.key") {
                Task { await self.flow.start(server.name, model: model) }
            }
            .disabled(!ready || self.flow.isSigningIn(server.name))
        }
        if model.supportsOAuth, !model.canEdit || self.flow.fallbackServer == server.name {
            self.commandRow(L("Or sign in on the Gateway host:"), mcpLoginCommand(server.name))
        }
    }

    private func commandRow(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(command).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Button(L("Copy"), systemImage: "doc.on.doc") { Clipboard.copy(command) }
                    .labelStyle(.iconOnly)
                    .help(L("Copy command"))
            }
        }
    }

    private func toolsSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel) -> some View {
        Section {
            if let count = status.toolCount {
                LabeledContent(L("Tools"), value: String(count))
            }
            if status.tools.isEmpty {
                if status.toolCount == nil {
                    Text("Tools show up once the server is connected.", bundle: .module).foregroundStyle(.secondary)
                }
            } else {
                ForEach(status.tools, id: \.self) { tool in
                    Text(tool).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if server.enabled, !model.isNew(server.name), model.statusSource != .none, status.toolCount != 0 {
                NavigationLink {
                    AgentToolsPage(agentId: self.gateway.defaultAgentId, mcpServer: server.name)
                } label: {
                    Label(L("Open in Tools Inspector"), systemImage: "wrench.and.screwdriver")
                }
            }
        }
    }

    private func configSection(_ server: MCPServer) -> some View {
        Section {
            LabeledContent(L("Transport"), value: server.transport?.title ?? L("Unknown"))
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(server.transport?.isRemote == true ? L("URL") : L("Command"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(server.urlIsRedacted ? L("•••• (saved)") : server.launchSummary)
                    .font(.callout.monospaced()).textSelection(.enabled)
            }
            if let cwd = server.cwd, !cwd.isEmpty { LabeledContent(L("Working folder"), value: cwd) }
            if !server.env.isEmpty {
                LabeledContent(L("Environment"), value: server.env.map(\.key).joined(separator: ", "))
            }
            if !server.headers.isEmpty {
                LabeledContent(L("Headers"), value: server.headers.map(\.key).joined(separator: ", "))
            }
        } header: {
            Text("Configuration", bundle: .module)
        } footer: {
            Text("Other settings for this server are kept. Edit them in Raw Config.", bundle: .module)
        }
    }

    private func actionsSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                                operation: OperationState) -> some View {
        let block = model.actionBlock(server.name)
        return Section {
            if model.canEdit {
                Button(L("Edit…"), systemImage: "pencil") {
                    self.editor = MCPEditorTarget(draft: MCPServerDraft(server: server))
                }
            }
            if model.supportsReconnect {
                Button(L("Reconnect"), systemImage: "arrow.clockwise") { Task { await model.reconnect(server.name) } }
                    .disabled(operation.isRunning || block != nil || !model.canEdit)
            }
            if model.supportsProbe { self.testRows(server, model: model, block: model.probeBlock(server.name)) }
            if model.canEdit {
                Button(L("Remove Server…"), role: .destructive) { self.confirmRemove = true }
            }
        } footer: {
            if model.supportsReconnect, let block, !(model.supportsProbe && block == model.probeBlock(server.name)) {
                Text(block)
            }
        }
    }

    @ViewBuilder private func testRows(_ server: MCPServer, model: MCPServersModel, block: String?) -> some View {
        MCPTestConnectionRows(state: self.probe, disabledReason: block, signInHint: L("Use Sign In on this page, then test again.")) {
            self.probe = MCPProbeState(running: true)
            Task { self.probe = MCPProbeState(result: await model.probe(name: server.name, timeoutMs: 15000)) }
        }
    }
}
