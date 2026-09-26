import PincerKit
import SwiftUI

// MARK: Overview

/// Gateway Settings → Command Policy: which commands agents may run on the Gateway host and
/// when they ask (`exec.approvals.get` / `exec.approvals.set`). Its draft is separate from the config's.
struct ExecPolicyPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    private var model: ExecPolicyModel { self.gateway.execPolicy }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        ExecPolicyStates(model: model, connected: connected) {
            Form {
                ExecPolicyHeader(model: model)
                self.defaults(model, connected: connected)
                self.recent(model)
                self.agents(model)
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Command Policy")
        .execPolicyChrome()
        .task(id: connected) {
            if connected { await model.loadIfNeeded() }
        }
    }

    private func defaults(_ model: ExecPolicyModel, connected: Bool) -> some View {
        Section {
            Label(model.defaultsMode.summary, systemImage: ExecPolicyUI.symbol(model.defaultsMode))
                .font(.callout.weight(.medium))
            ForEach(ExecPolicyField.allCases) { field in
                ExecPolicyControl(model: model, field: field, agent: nil)
            }
        } header: {
            Text("Defaults for all agents")
        } footer: {
            ExecPolicyFooter(model: model, connected: connected)
        }
    }

    @ViewBuilder private func recent(_ model: ExecPolicyModel) -> some View {
        let recent = model.recentlyAllowed
        if !recent.isEmpty {
            Section("Recently allowed") {
                ForEach(recent) { item in
                    NavigationLink(value: SettingsRoute.execAgent(item.agentId)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.entry.pattern)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(self.recentDetail(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func recentDetail(_ item: ExecRecentEntry) -> String {
        let agent = ExecPolicyUI.agentTitle(item.agentId, gateway: self.gateway)
        guard let used = item.entry.lastUsedAt else { return agent }
        return "\(agent) · \(used.formatted(.relative(presentation: .named)))"
    }

    private func agents(_ model: ExecPolicyModel) -> some View {
        Section("Agents") {
            ForEach(model.agentRows(agents: self.gateway.agents)) { row in
                NavigationLink(value: SettingsRoute.execAgent(row.id)) {
                    ExecAgentRowView(row: row)
                }
            }
        }
    }
}

private struct ExecAgentRowView: View {
    let row: ExecAgentRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.row.title)
                Text(self.row.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !self.row.isCurrentAgent {
                    Text("Not a current agent")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if self.row.badgeCount > 0 {
                Text("\(self.row.badgeCount)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(.secondary)
                    .background(.secondary.opacity(0.15), in: Capsule())
                    .accessibilityLabel("\(self.row.badgeCount) allowed")
            }
        }
    }
}

// MARK: Agent

/// One agent's policy overrides, allowlist and tool grants (`SettingsRoute.execAgent`).
struct ExecAgentPage: View {
    let agentId: String
    @Environment(GatewayStore.self) private var gateway
    @State private var editing = false

    private var model: ExecPolicyModel { self.gateway.execPolicy }

    var body: some View {
        let model = self.model
        let connected = self.gateway.state.isConnected
        ExecPolicyStates(model: model, connected: connected) {
            Form {
                ExecPolicyHeader(model: model, showsSubtitle: false)
                self.policy(model, connected: connected)
                self.commands(model, editable: self.editable(model, connected: connected))
                self.tools(model, editable: self.editable(model, connected: connected))
            }
            .formStyle(.grouped)
        }
        .navigationTitle(ExecPolicyUI.agentTitle(self.agentId, gateway: self.gateway))
        .execPolicyChrome()
        .toolbar {
            if model.snapshot != nil, self.hasEntries(model) {
                ToolbarItem {
                    Button(self.editing ? "Done" : "Edit") { withAnimation { self.editing.toggle() } }
                        .disabled(!self.editable(model, connected: connected))
                }
            }
        }
        .task(id: connected) {
            if connected { await model.loadIfNeeded() }
        }
    }

    private func editable(_ model: ExecPolicyModel, connected: Bool) -> Bool {
        model.canWrite && connected && !model.isSaving
    }

    private func hasEntries(_ model: ExecPolicyModel) -> Bool {
        !model.draft.allowlist(self.agentId).isEmpty || !model.draft.mcpTools(self.agentId).isEmpty
    }

    private func policy(_ model: ExecPolicyModel, connected: Bool) -> some View {
        let known = self.agentId == ExecApprovalsFile.wildcardAgent || self.gateway.agents.contains { $0.id == self.agentId }
        return Section {
            Label(model.mode(agent: self.agentId).summary, systemImage: ExecPolicyUI.symbol(model.mode(agent: self.agentId)))
                .font(.callout.weight(.medium))
            ForEach(ExecPolicyField.allCases) { field in
                ExecPolicyControl(model: model, field: field, agent: self.agentId)
            }
            Button("Use Defaults for Everything") { model.useDefaults(agent: self.agentId) }
                .disabled(model.draft.overrides(self.agentId).isEmpty || !self.editable(model, connected: connected))
        } header: {
            if self.agentId == ExecApprovalsFile.wildcardAgent {
                Text("Applies to every agent")
            } else if !known {
                Text("Not a current agent")
            } else {
                Text("Policy")
            }
        } footer: {
            ExecPolicyFooter(model: model, connected: connected)
        }
    }

    private func commands(_ model: ExecPolicyModel, editable: Bool) -> some View {
        let entries = model.draft.allowlist(self.agentId)
        return Section("Allowed Commands") {
            if entries.isEmpty {
                Text("No allowed commands. When you choose **Always allow** on an approval, the command is added here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                ExecRemovableRow(editing: self.editing, editable: editable,
                                 remove: { model.removeAllowlistEntry(agent: self.agentId, at: entry.index) }) {
                    ExecAllowlistRow(entry: entry)
                }
            }
            .onDelete(perform: editable ? { offsets in
                for index in offsets.sorted(by: >) { model.removeAllowlistEntry(agent: self.agentId, at: index) }
            } : nil)
        }
    }

    private func tools(_ model: ExecPolicyModel, editable: Bool) -> some View {
        let grants = model.draft.mcpTools(self.agentId)
        return Section("Allowed Tools") {
            if grants.isEmpty {
                Text("No allowed tools. When you choose **Always allow** on a tool approval, the tool is added here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(grants) { grant in
                ExecRemovableRow(editing: self.editing, editable: editable,
                                 remove: { model.removeMcpTool(agent: self.agentId, at: grant.index) }) {
                    ExecToolRow(grant: grant)
                }
            }
            .onDelete(perform: editable ? { offsets in
                for index in offsets.sorted(by: >) { model.removeMcpTool(agent: self.agentId, at: index) }
            } : nil)
        }
    }
}

/// A row that can be removed: a Remove button in edit mode, a context menu, and ⌫ on macOS.
private struct ExecRemovableRow<Content: View>: View {
    let editing: Bool
    let editable: Bool
    let remove: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if self.editing {
                Button(role: .destructive, action: self.remove) {
                    Label("Remove", systemImage: "minus.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(!self.editable)
                .help("Remove")
            }
            self.content
        }
        .contextMenu {
            Button("Remove", systemImage: "trash", role: .destructive, action: self.remove)
                .disabled(!self.editable)
        }
        #if os(macOS)
        .focusable(self.editable)
        .onDeleteCommand { if self.editable { self.remove() } }
        #endif
    }
}

private struct ExecAllowlistRow: View {
    let entry: ExecAllowlistEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.entry.pattern)
                    .font(.body.monospaced())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if self.entry.isAllowAlways {
                    ExecTag("Always allow")
                }
            }
            if let command = self.entry.commandText {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let argPattern = self.entry.argPattern {
                Text("Arguments: \(argPattern)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let used = self.entry.lastUsedAt {
                Text("Last used \(used.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    #if os(macOS)
                    .help(self.entry.lastUsedCommand ?? "")
                    #endif
                #if os(iOS)
                if let command = self.entry.lastUsedCommand {
                    Text(command)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                #endif
            }
        }
        .padding(.vertical, 1)
    }
}

private struct ExecToolRow: View {
    let grant: ExecMcpToolGrant

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.grant.title)
                    .font(.body.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if self.grant.source == "allow-always" { ExecTag("Always allow") }
            }
            let dates = [
                self.grant.addedAt.map { "Added \($0.formatted(date: .abbreviated, time: .omitted))" },
                self.grant.lastUsedAt.map { "Last used \($0.formatted(.relative(presentation: .named)))" },
            ].compactMap(\.self)
            if !dates.isEmpty {
                Text(dates.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }
}

private struct ExecTag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(self.text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.15), in: Capsule())
    }
}

// MARK: Controls

/// One of the four policy settings, for Defaults (`agent` nil) or an agent. The first option
/// inherits: "Gateway default (…)", "Same as defaults (…)" or "Same as All agents (…)".
private struct ExecPolicyControl: View {
    let model: ExecPolicyModel
    let field: ExecPolicyField
    let agent: String?
    @Environment(GatewayStore.self) private var gateway

    private enum Choice: Hashable {
        case inherit
        case value(JSONValue)
    }

    var body: some View {
        let current = self.model.value(self.field, agent: self.agent)
        let options = self.options(current: current)
        Picker(selection: Binding(
            get: { current.map(Choice.value) ?? .inherit },
            set: { choice in
                switch choice {
                case .inherit: self.model.set(self.field, nil, agent: self.agent)
                case let .value(value): self.model.set(self.field, value, agent: self.agent)
                }
            }
        )) {
            Text(self.inheritLabel).tag(Choice.inherit)
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(Choice.value(option.value))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.field.label)
                Text(self.field.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.menu)
        .disabled(!self.model.canWrite || !self.gateway.state.isConnected || self.model.isSaving)
    }

    /// The known options, plus the saved and current values when Pincer doesn't know them.
    private func options(current: JSONValue?) -> [ExecPolicyField.Option] {
        let saved = self.model.savedValue(self.field, agent: self.agent)
        var options = self.field.options
        for value in [saved, current].compactMap(\.self) where !options.contains(where: { $0.value == value }) {
            options.append(ExecPolicyField.Option(value, self.field.label(for: value)))
        }
        return options
    }

    private var inheritLabel: String {
        if self.agent == nil {
            return self.model.gatewayDefault(self.field).map { "Gateway default (\(self.field.label(for: $0)))" }
                ?? "Gateway default"
        }
        guard let agent = self.agent else { return "Same as defaults" }
        let source = self.model.inheritsFromWildcard(self.field, agent: agent) ? "All agents" : "defaults"
        return self.model.inheritedValue(self.field, agent: agent).map { "Same as \(source) (\(self.field.label(for: $0)))" }
            ?? "Same as \(source)"
    }
}

// MARK: Shared pieces

/// Loading, needs-admin, unsupported, offline and error states around the page content.
private struct ExecPolicyStates<Content: View>: View {
    let model: ExecPolicyModel
    let connected: Bool
    @ViewBuilder let content: Content
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        if !self.model.supported {
            ContentUnavailableView("Command Policy Isn't Available", systemImage: "lock.slash",
                                   description: Text("This gateway can't share its command policy. Update OpenClaw to manage it here."))
        } else if self.model.needsAdmin {
            ContentUnavailableView {
                Label("Needs Full Management", systemImage: "lock.shield")
            } description: {
                Text(ExecPolicy.needsAdminMessage)
            } actions: {
                Button("Open Connection") { self.navigator.destination = .connection }
            }
        } else if self.model.snapshot != nil {
            self.content
        } else if !self.connected, !self.model.loadState.isRunning {
            ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Connect to the gateway to see its command policy."))
        } else if let error = self.model.loadState.error {
            ContentUnavailableView {
                Label("Couldn't Load Command Policy", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await self.model.load() } }
            }
        } else {
            ProgressView()
        }
    }
}

/// The subtitle and any banner (rejected save, conflict, other error).
private struct ExecPolicyHeader: View {
    let model: ExecPolicyModel
    var showsSubtitle = true
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        if self.showsSubtitle || self.model.banner != nil {
            Section {
                if self.showsSubtitle {
                    Text("Which commands your agents can run on the Gateway host, and when they have to ask.")
                        .foregroundStyle(.secondary)
                }
                if let banner = self.model.banner {
                    self.banner(banner)
                }
            }
        }
    }

    @ViewBuilder private func banner(_ banner: ExecPolicyBanner) -> some View {
        switch banner {
        case .conflict:
            Label(banner.message, systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .rejected:
            Label(banner.message, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .notice:
            Label(banner.message, systemImage: "lock")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case let .failed(_, retrySave):
            VStack(alignment: .leading, spacing: 6) {
                Label(banner.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                // A reload keeps unsaved edits, so it can't help while there are some.
                if retrySave || !self.model.hasChanges {
                Button("Try Again") {
                    Task {
                        if retrySave {
                            await self.model.save(agentNames: ExecPolicyUI.agentNames(self.gateway))
                        } else {
                            await self.model.load()
                        }
                    }
                }
                .disabled(!self.gateway.state.isConnected)
                }
            }
        }
    }
}

private struct ExecPolicyFooter: View {
    let model: ExecPolicyModel
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = self.model.snapshot, !snapshot.exists {
                Text("The Gateway has no policy file yet and uses its defaults. Saving creates \(snapshot.path ?? "the policy file").")
            }
            if !self.connected {
                Text("Not connected.")
            }
        }
    }
}

enum ExecPolicyUI {
    @MainActor
    static func agentNames(_ gateway: GatewayStore) -> [String: String] {
        Dictionary(gateway.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// "🔭 Scout", "All agents", or the id.
    @MainActor
    static func agentTitle(_ id: String, gateway: GatewayStore) -> String {
        if id == ExecApprovalsFile.wildcardAgent { return "All agents" }
        guard let agent = gateway.agents.first(where: { $0.id == id }) else { return id }
        return agent.emoji.map { "\($0) \(agent.name)" } ?? agent.name
    }

    static func symbol(_ mode: ExecPolicyMode) -> String {
        switch mode {
        case .deny: "nosign"
        case .allowlist: "list.bullet.rectangle"
        case .full: "exclamationmark.shield"
        case .ask: "questionmark.bubble"
        }
    }
}

// MARK: Toolbar

extension View {
    /// Save and Revert for the Command Policy draft, and the read-only lock.
    func execPolicyChrome() -> some View { self.modifier(ExecPolicyChrome()) }
}

private struct ExecPolicyChrome: ViewModifier {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    func body(content: Content) -> some View {
        let model = self.gateway.execPolicy
        let connected = self.gateway.state.isConnected
        let canSave = model.hasChanges && !model.isSaving && model.canWrite && connected
        content
            .toolbar {
                if model.snapshot != nil {
                    #if os(macOS)
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !model.canWrite {
                            self.readOnly
                        }
                        Button("Revert") { model.revert() }
                            .disabled(!model.hasChanges || model.isSaving)
                            .help("Discard your changes to the command policy")
                        Button("Save") { self.save(model) }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!canSave)
                            .help("Save the command policy to the Gateway")
                    }
                    #else
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSaving {
                            ProgressView()
                        } else if !model.canWrite {
                            self.readOnly
                        } else {
                            Button("Save") { self.save(model) }
                                .disabled(!canSave)
                        }
                    }
                    if model.hasChanges {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button("Revert", role: .destructive) { model.revert() }
                                .disabled(model.isSaving)
                            Spacer()
                        }
                    }
                    #endif
                }
            }
    }

    private var readOnly: some View {
        Button { self.navigator.destination = .connection } label: {
            Label("Read Only", systemImage: "lock")
                .labelStyle(.titleAndIcon)
        }
        .help(self.gateway.execPolicy.readOnlyReason ?? "")
    }

    private func save(_ model: ExecPolicyModel) {
        let names = ExecPolicyUI.agentNames(self.gateway)
        Task { await model.save(agentNames: names) }
    }
}
