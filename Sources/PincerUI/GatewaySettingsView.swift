import PincerKit
import SwiftUI

/// Gateway Settings: the Gateway's own config and plugins, edited over the Gateway protocol.
/// Opened from the sidebar menu; one per Gateway.
struct GatewaySettingsView: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var navigation = NavigationPath()
    @State private var addingPlugin = false
    @State private var editingRaw = false

    private var settings: GatewaySettingsStore { self.gateway.settings }

    var body: some View {
        NavigationStack(path: self.$navigation) {
            Form {
                if !self.settings.canEdit { self.accessSection }
                SettingsFeedback()
                self.statusSection
                self.settingsSection
                self.pluginsSection
            }
            .formStyle(.grouped)
            .navigationTitle("\(self.gateway.profile.name) Settings")
            .navigationDestination(for: GatewaySettingsRoute.self) { route in
                switch route {
                case let .object(path):
                    ConfigObjectForm(path: path, title: self.title(for: path))
                case let .plugin(id):
                    PluginDetailView(pluginId: id, pop: { if !self.navigation.isEmpty { self.navigation.removeLast() } })
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { self.dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await self.settings.load() } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .disabled(self.settings.isLoading)
                }
            }
            .overlay {
                if self.settings.isLoading, !self.settings.hasLoaded { ProgressView("Loading settings…") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
        #endif
        .task {
            self.settings.clearFeedback()
            await self.settings.load()
        }
        .pluginConfirmation(self.settings, isActive: !self.addingPlugin)
        .sheet(isPresented: self.$addingPlugin) { AddPluginSheet() }
        .sheet(isPresented: self.$editingRaw) { RawConfigEditor() }
    }

    private func title(for path: [String]) -> String {
        self.settings.schema?.field(at: path, value: self.settings.value(at: path))?.label
            ?? path.last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Settings"
    }

    // MARK: Sections

    @ViewBuilder private var accessSection: some View {
        Section {
            if self.gateway.profile.manageSettings {
                Label("This Gateway hasn't given Pincer admin access yet.", systemImage: "lock.fill")
                Text("Approve this device's upgraded access on the Gateway host, then reconnect:")
                    .font(.callout).foregroundStyle(.secondary)
                Text("openclaw devices list\nopenclaw devices approve <requestId>")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Button("Reconnect") { self.gateway.stop(); self.gateway.start() }
            } else {
                Label("Read-only", systemImage: "lock.fill")
                Text("Pincer connects without admin rights, so it can show these settings but not change them. Allow it to manage this Gateway to edit settings and plugins. The Gateway host will need to approve this device again.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Allow Managing Settings…") {
                    var profile = self.gateway.profile
                    profile.manageSettings = true
                    self.app.update(profile, secret: profile.secret, credentialsChanged: false)
                    self.dismiss()
                }
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        let settings = self.settings
        if settings.hasLoaded {
            Section("Status") {
                if let path = settings.path {
                    LabeledContent("Config file") {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if settings.isValid {
                    Label("Config is valid", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Config has problems", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    ForEach(settings.issues) { IssueRow(issue: $0) }
                }
                ForEach(settings.warnings) { warning in
                    Label(warning.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var settingsSection: some View {
        let settings = self.settings
        if settings.hasLoaded {
            Section {
                let schema = settings.schema ?? .open
                ForEach(schema.fields(at: [], value: settings.config).filter { $0.kind == .object }) { field in
                    NavigationLink(value: GatewaySettingsRoute.object(field.path)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.label)
                                if let help = field.help {
                                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        } icon: {
                            Image(systemName: Self.symbol(for: field.key))
                        }
                    }
                    .badge(settings.issues(under: field.path).count)
                }
                Button("Edit Raw Config…") { self.editingRaw = true }
                    .disabled(settings.raw == nil)
            } header: {
                Text("Settings")
            } footer: {
                if settings.raw == nil {
                    Text("The Gateway didn't send the raw config file, so it can only be edited field by field here.")
                }
            }
        }
    }

    @ViewBuilder private var pluginsSection: some View {
        let settings = self.settings
        if settings.hasLoaded {
            Section {
                if !settings.pluginsSupported {
                    Text("This Gateway doesn't support managing plugins remotely. Update OpenClaw to manage plugins here.")
                        .foregroundStyle(.secondary)
                } else if settings.plugins.isEmpty {
                    Text("No plugins installed.").foregroundStyle(.secondary)
                }
                ForEach(settings.plugins) { plugin in
                    NavigationLink(value: GatewaySettingsRoute.plugin(plugin.id)) {
                        PluginRow(plugin: plugin)
                    }
                }
                if settings.pluginsSupported {
                    Button("Add Plugin…") { self.addingPlugin = true }
                        .disabled(!settings.canEdit)
                }
            } header: {
                Text("Plugins")
            }
        }
    }

    static func symbol(for key: String) -> String {
        switch key {
        case "gateway": "server.rack"
        case "agents": "person.2"
        case "channels": "bubble.left.and.bubble.right"
        case "tools": "wrench.and.screwdriver"
        case "plugins": "puzzlepiece.extension"
        case "models", "providers": "cpu"
        case "skills": "sparkles"
        case "session", "sessions": "text.bubble"
        case "hooks": "link"
        case "cron", "automations": "clock"
        case "logging", "diagnostics": "doc.text.magnifyingglass"
        case "ui": "paintbrush"
        case "browser": "globe"
        case "memory": "brain"
        case "secrets", "auth": "key"
        default: "gearshape"
        }
    }
}

struct PluginRow: View {
    let plugin: PluginInfo
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(self.plugin.enabled ? self.theme.color(.agentAvatar) : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.plugin.name)
                if let description = self.plugin.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(self.plugin.statusLabel)
                .font(.caption)
                .foregroundStyle(self.plugin.hasError ? .red : self.plugin.needsSetup ? .orange : .secondary)
        }
    }
}

/// One plugin: turn it on or off, fill in its settings and credentials, or remove it.
struct PluginDetailView: View {
    let pluginId: String
    let pop: () -> Void
    @Environment(GatewayStore.self) private var gateway
    @State private var confirmRemove = false

    private var settings: GatewaySettingsStore { self.gateway.settings }

    var body: some View {
        if let plugin = self.settings.plugin(self.pluginId) {
            ConfigObjectForm(path: plugin.configPath, title: plugin.name,
                             credentials: self.settings.credentials[plugin.id] ?? []) {
                self.header(plugin)
            }
            .task { await self.settings.loadCredentials(for: plugin) }
        } else {
            ContentUnavailableView("Plugin removed", systemImage: "puzzlepiece.extension")
        }
    }

    @ViewBuilder private func header(_ plugin: PluginInfo) -> some View {
        Section {
            if let description = plugin.description { Text(description) }
            Toggle("Enabled", isOn: Binding(
                get: { plugin.enabled },
                set: { value in Task { await self.settings.setEnabled(plugin, value) } }))
                .disabled(!self.settings.canEdit || self.settings.isSaving)
            LabeledContent("Status", value: plugin.statusLabel)
            if let version = plugin.version { LabeledContent("Version", value: version) }
            if let origin = plugin.origin { LabeledContent("Source", value: plugin.packageName.map { "\(origin) · \($0)" } ?? origin) }
            if let error = plugin.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if plugin.needsSetup {
                Label("Fill in the required settings below to finish setting up this plugin.", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
            }
        }
        if plugin.removable {
            Section {
                Button("Remove Plugin", role: .destructive) { self.confirmRemove = true }
                    .disabled(!self.settings.canEdit || self.settings.isSaving)
                    .confirmationDialog("Remove \(plugin.name)?", isPresented: self.$confirmRemove) {
                        Button("Remove", role: .destructive) {
                            Task {
                                await self.settings.uninstall(plugin)
                                if self.settings.plugin(plugin.id) == nil { self.pop() }
                            }
                        }
                    } message: {
                        Text("The plugin is uninstalled from the Gateway and its settings are removed.")
                    }
            }
        }
    }
}

struct AddPluginSheet: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var source = PluginSource.clawhub
    @State private var spec = ""
    @State private var enable = true

    private var settings: GatewaySettingsStore { self.gateway.settings }

    var body: some View {
        NavigationStack {
            Form {
                SettingsFeedback()
                Section {
                    Picker("Source", selection: self.$source) {
                        ForEach(PluginSource.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Plugin", text: self.$spec, prompt: Text(self.source.prompt))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(self.install)
                    Toggle("Turn on after installing", isOn: self.$enable)
                } footer: {
                    Text("The Gateway downloads and installs the plugin itself. Only install plugins you trust: they run on your Gateway host.")
                }
                if self.settings.isSaving {
                    Section { ProgressView("Installing…") }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Plugin")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install", action: self.install)
                        .disabled(self.spec.nilIfBlank == nil || self.settings.isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .onAppear { self.settings.clearFeedback() }
        .pluginConfirmation(self.settings, isActive: true, onConfirmed: { self.dismissIfInstalled() })
    }

    private func install() {
        Task {
            if await self.settings.install(from: self.source, spec: self.spec, enable: self.enable) { self.dismiss() }
        }
    }

    private func dismissIfInstalled() {
        if self.settings.lastError == nil, self.settings.writeIssues.isEmpty, self.settings.lastOutcome != nil { self.dismiss() }
    }
}

/// The whole config file as text, saved with `config.apply`.
struct RawConfigEditor: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var settings: GatewaySettingsStore { self.gateway.settings }

    var body: some View {
        NavigationStack {
            Form {
                SettingsFeedback()
                Section {
                    TextEditor(text: self.$text)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .frame(minHeight: 320)
                } footer: {
                    Text("Secrets show as \(JSONValue.redactedSentinel). Leave them as they are to keep them. Saving replaces the whole config, and the Gateway checks it first.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Raw Config")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await self.settings.saveRaw(self.text) { self.dismiss() } }
                    }
                    .disabled(self.text == self.settings.raw || self.settings.isSaving || !self.settings.canEdit)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
        .onAppear {
            self.settings.clearFeedback()
            self.text = self.settings.raw ?? ""
        }
    }
}

extension View {
    /// Asks before plugin changes the Gateway wants confirmed (new capabilities, unverified packages).
    func pluginConfirmation(_ settings: GatewaySettingsStore, isActive: Bool,
                            onConfirmed: @escaping () -> Void = {}) -> some View {
        let binding = Binding(
            get: { isActive && settings.pendingConfirmation != nil },
            set: { if !$0 { settings.pendingConfirmation = nil } })
        return self.alert("Confirm Plugin Change", isPresented: binding, presenting: settings.pendingConfirmation) { confirmation in
            Button("Cancel", role: .cancel) { settings.pendingConfirmation = nil }
            Button("Allow") {
                Task {
                    await settings.confirm(confirmation)
                    onConfirmed()
                }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
