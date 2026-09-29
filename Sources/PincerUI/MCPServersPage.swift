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
                (self.title, self.detail, self.tone) = (auth?.isExpired == true ? L("Sign-In Expired") : L("Needs Sign-In"), nil, .warning)
            } else if auth?.state == .pendingAuthorization {
                (self.title, self.detail, self.tone) = (L("Waiting for Sign-In…"), nil, .warning)
            } else {
                switch status.state {
                case .connecting: (self.title, self.detail, self.tone) = (L("Connecting…"), nil, .neutral)
                case .idle: (self.title, self.detail, self.tone) = (L("Idle"), nil, .neutral)
                case .backoff:
                    let title = status.nextRetryAt.map { L("Retrying at \($0.formatted(date: .omitted, time: .shortened))") } ?? L("Retrying…")
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

extension MCPServersModel {
    /// Whether any server needs a look (an error or a sign-in), for the sidebar dot.
    var needsAttention: Bool {
        self.servers.contains { server in
            let status = self.status(for: server.name)
            return status.state == .error || status.state == .backoff || status.needsSignIn
        }
    }
}

/// The `openclaw` command for a server on hosts whose Gateway can't sign in remotely.
private func mcpLoginCommand(_ name: String) -> String { "openclaw mcp login \(name)" }
private func mcpLogoutCommand(_ name: String) -> String { "openclaw mcp logout \(name)" }

// MARK: Server actions

/// The actions on one server, shared by the list's context menu and swipe actions.
private struct MCPServerActions: View {
    let server: MCPServer
    let model: MCPServersModel
    let flow: MCPSignInFlow
    let edit: () -> Void
    let remove: () -> Void
    let showTools: () -> Void

    var body: some View {
        let status = self.model.status(for: self.server.name)
        let busy = self.model.operation(for: self.server.name).isRunning
        Button(L("Edit…"), systemImage: "pencil", action: self.edit)
            .disabled(!self.model.canEdit)
        if self.model.supportsReconnect, self.server.enabled, status.state != .unsaved {
            Button(L("Reconnect"), systemImage: "arrow.clockwise") {
                Task { await self.model.reconnect(self.server.name) }
            }
            .disabled(busy)
        }
        if self.server.usesOAuth, self.model.supportsOAuth, status.state != .unsaved {
            if status.auth?.state == .authorized {
                Button(L("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await self.model.signOut(self.server.name) }
                }
                .disabled(busy)
            } else {
                Button(status.auth?.isExpired == true ? L("Sign In Again") : L("Sign In"), systemImage: "person.badge.key") {
                    Task { await self.flow.start(self.server.name, model: self.model) }
                }
                .disabled(busy || self.flow.isSigningIn(self.server.name))
            }
        }
        Button(L("Show Tools"), systemImage: "wrench.and.screwdriver", action: self.showTools)
        Divider()
        Button(L("Remove…"), systemImage: "trash", role: .destructive, action: self.remove)
            .disabled(!self.model.canEdit)
    }
}

// MARK: List page

struct MCPServersPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var editor: MCPEditorTarget?
    @State private var removing: String?
    @State private var flow = MCPSignInFlow()

    var body: some View {
        let model = self.gateway.mcp
        let connected = self.gateway.state.isConnected
        GatewaySettingsForm {
            if !model.canEdit {
                Section { FullManagementBadge { self.navigator.destination = .connection } }
            }
            Section {
                if model.servers.isEmpty {
                    Text("No MCP servers yet. Add one to give your agents more tools.", bundle: .module)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.servers) { server in
                    self.row(server, model: model)
                }
                if let error = model.loadState.error, connected {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } footer: {
                self.footer(model)
            }
        }
        .navigationTitle(L("MCP Servers"))
        .toolbar {
            ToolbarItem {
                Button { self.editor = MCPEditorTarget(draft: MCPServerDraft()) } label: {
                    Label(L("Add Server"), systemImage: "plus")
                }
                .disabled(!model.canEdit)
                .help(L("Add an MCP server"))
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
        .mcpSignIn(self.flow, model: model)
        .task(id: connected) { if connected { await model.load() } }
    }

    private func row(_ server: MCPServer, model: MCPServersModel) -> some View {
        let status = model.status(for: server.name)
        return HStack {
            NavigationLink(value: SettingsRoute.mcpServer(server.name)) {
                HStack {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(server.name)
                            if model.isChanged(server.name) {
                                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.tint)
                                    .accessibilityLabel(L("Unsaved changes"))
                            }
                        }
                        Text(server.transport?.title ?? L("Unknown transport"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    MCPStatusLabel(status: status).frame(maxWidth: 220, alignment: .trailing)
                }
            }
            Toggle(L("Enabled"), isOn: Binding(
                get: { server.enabled }, set: { model.setEnabled(server.name, $0) }))
                .labelsHidden()
                .disabled(!model.canEdit)
        }
        .contextMenu { self.actions(server, model: model) }
        .swipeActions(edge: .trailing) {
            Button(L("Remove"), role: .destructive) { self.removing = server.name }
                .disabled(!model.canEdit)
            Button(L("Edit")) { self.editor = MCPEditorTarget(draft: MCPServerDraft(server: server)) }
                .tint(.accentColor)
                .disabled(!model.canEdit)
        }
    }

    private func actions(_ server: MCPServer, model: MCPServersModel) -> some View {
        MCPServerActions(server: server, model: model, flow: self.flow,
                         edit: { self.editor = MCPEditorTarget(draft: MCPServerDraft(server: server)) },
                         remove: { self.removing = server.name },
                         showTools: { self.navigator.path.append(.mcpServer(server.name)) })
    }

    @ViewBuilder private func footer(_ model: MCPServersModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("MCP servers give agents extra tools. Adding, editing or removing a server is saved with your other settings; reconnecting and signing in happen right away.", bundle: .module)
            if !model.supportsLiveStatus {
                Text("This Gateway doesn't report MCP status. Tools show up once an agent connects to the server.", bundle: .module)
            }
            if !model.supportsOAuth, model.servers.contains(where: \.usesOAuth) {
                Text("This Gateway can't sign in from Pincer. Sign in on the Gateway host with `openclaw mcp login <name>`.", bundle: .module)
            }
            if !model.supportsReconnect {
                Text("This Gateway can't reconnect servers from Pincer. Changes apply when you save.", bundle: .module)
            }
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
    @State private var flow = MCPSignInFlow()

    var body: some View {
        let model = self.gateway.mcp
        if let server = model.server(self.name) {
            let status = model.status(for: server.name)
            let operation = model.operation(for: server.name)
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
            .navigationTitle(server.name)
            .sheet(item: self.$editor) { target in
                MCPServerEditor(draft: target.draft)
                    .environment(self.gateway)
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
            .onDisappear { Task { await self.flow.cancel(model: model) } }
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
            LabeledContent(L("Status")) { MCPStatusLabel(status: status) }
            if let error = operation.error {
                Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        } footer: {
            if !model.supportsLiveStatus {
                Text("This Gateway doesn't report MCP status. Tools show up once an agent connects to the server.", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func accountSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                                operation: OperationState) -> some View {
        Section {
            if model.supportsOAuth, status.state != .unsaved {
                let auth = status.auth
                if auth?.state == .authorized {
                    Label(auth?.account.map { L("Signed in as \($0)") } ?? L("Signed in"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button(L("Sign Out"), role: .destructive) { Task { await model.signOut(server.name) } }
                        .disabled(operation.isRunning || !model.canEdit)
                } else if self.flow.waiting?.server == server.name {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Sign-In…", bundle: .module).foregroundStyle(.secondary)
                    }
                    Button(L("Open in Browser"), systemImage: "safari") { self.flow.openInBrowser(self.openURL) }
                    Button(L("Cancel Sign-In"), role: .cancel) { Task { await self.flow.cancel(model: model) } }
                } else {
                    Text(auth?.isExpired == true ? L("Your sign-in expired.") : L("Not signed in."))
                        .foregroundStyle(.secondary)
                    Button(auth?.isExpired == true ? L("Sign In Again") : L("Sign In"), systemImage: "person.badge.key") {
                        Task { await self.flow.start(server.name, model: model) }
                    }
                    .disabled(operation.isRunning || self.flow.isSigningIn(server.name) || !model.canEdit)
                }
            } else {
                self.commandRow(L("Sign in on the Gateway host:"), mcpLoginCommand(server.name))
                if status.auth?.state == .authorized {
                    self.commandRow(L("Sign out on the Gateway host:"), mcpLogoutCommand(server.name))
                }
            }
        } header: {
            Text("Account", bundle: .module)
        } footer: {
            if let identity = server.oauthIdentity {
                Text(identity == "per-requester"
                     ? L("Each person signs in separately.")
                     : L("One sign-in is shared by everyone using this Gateway."))
            }
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
            NavigationLink {
                AgentToolsPage(agentId: self.gateway.defaultAgentId, mcpServer: server.name)
            } label: {
                Label(L("Open in Tools Inspector"), systemImage: "wrench.and.screwdriver")
            }
        } header: {
            Text("Tools", bundle: .module)
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
        }
    }

    private func actionsSection(_ server: MCPServer, status: MCPServerStatus, model: MCPServersModel,
                                operation: OperationState) -> some View {
        Section {
            Button(L("Edit…"), systemImage: "pencil") {
                self.editor = MCPEditorTarget(draft: MCPServerDraft(server: server))
            }
            .disabled(!model.canEdit)
            if model.supportsReconnect {
                Button(L("Reconnect"), systemImage: "arrow.clockwise") { Task { await model.reconnect(server.name) } }
                    .disabled(operation.isRunning || !server.enabled || status.state == .unsaved)
            }
            Button(L("Remove Server…"), role: .destructive) { self.confirmRemove = true }
                .disabled(!model.canEdit)
        }
    }
}
