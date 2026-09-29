import PincerKit
import SwiftUI

struct PluginsPage: View {
    @Environment(GatewayStore.self) private var gateway
    @State private var adding = false

    var body: some View {
        let settings = self.gateway.settings
        GatewaySettingsForm {
            Section {
                if !settings.pluginsSupported {
                    Text("This Gateway doesn't support managing plugins remotely. Update OpenClaw to manage plugins here.", bundle: .module)
                        .foregroundStyle(.secondary)
                } else if settings.plugins.isEmpty {
                    Text("No plugins installed.", bundle: .module).foregroundStyle(.secondary)
                }
                ForEach(settings.plugins) { plugin in
                    NavigationLink(value: SettingsRoute.plugin(plugin.id)) { PluginRow(plugin: plugin) }
                }
            } footer: {
                Text("Plugins run on your Gateway host. Turning one on or off, installing or removing it happens right away.", bundle: .module)
            }
        }
        .navigationTitle(L("Plugins"))
        .toolbar {
            if settings.pluginsSupported {
                ToolbarItem {
                    Button { self.adding = true } label: { Label(L("Add Plugin"), systemImage: "plus") }
                        .disabled(!settings.canEdit)
                        .help(L("Install a plugin on the Gateway"))
                }
            }
        }
        .sheet(isPresented: self.$adding) {
            AddPluginSheet()
                .environment(self.gateway)
        }
        .pluginConfirmation(settings, isActive: !self.adding)
    }
}

struct PluginRow: View {
    let plugin: PluginInfo
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(self.plugin.enabled ? self.theme.color(.agentAvatar) : .secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
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

/// One plugin: turn it on or off and remove it (right away), and edit its settings and
/// credentials (with the other unsaved changes).
struct PluginPage: View {
    let pluginId: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmRemove = false

    var body: some View {
        let settings = self.gateway.settings
        if let plugin = settings.plugin(self.pluginId) {
            let operation = settings.operation(for: plugin.id)
            GatewaySettingsForm {
                Section {
                    if let description = plugin.description { Text(description) }
                    HStack {
                        Toggle(L("Enabled"), isOn: Binding(
                            get: { plugin.enabled },
                            set: { value in Task { await settings.setEnabled(plugin, value) } }))
                        if operation.isRunning { ProgressView().controlSize(.small) }
                    }
                    .disabled(!settings.canEdit || operation.isRunning)
                    if let error = operation.error {
                        Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                    LabeledContent(L("Status"), value: plugin.statusLabel)
                    if let version = plugin.version { LabeledContent(L("Version"), value: version) }
                    if let origin = plugin.origin {
                        LabeledContent(L("Source"), value: plugin.packageName.map { "\(origin) · \($0)" } ?? origin)
                    }
                    if let error = plugin.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if plugin.needsSetup {
                        Label(L("Fill in the required settings below, then save, to finish setting up this plugin."),
                              systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.orange)
                    }
                }
                if settings.shows(.object(plugin.configPath)) || !(settings.credentials[plugin.id] ?? []).isEmpty {
                    ObjectSections(path: plugin.configPath, title: "Settings",
                                   credentials: settings.credentials[plugin.id] ?? [])
                }
                if plugin.removable {
                    Section {
                        Button(L("Remove Plugin…"), role: .destructive) { self.confirmRemove = true }
                            .disabled(!settings.canEdit || operation.isRunning)
                    }
                }
            }
            .navigationTitle(plugin.name)
            .task { await settings.loadCredentials(for: plugin) }
            .onDisappear { settings.clearOperation(plugin.id) }
            .confirmationDialog(L("Remove \(plugin.name)?"), isPresented: self.$confirmRemove) {
                Button(L("Remove"), role: .destructive) {
                    Task {
                        if await settings.uninstall(plugin), self.navigator.path.last == .plugin(plugin.id) {
                            self.navigator.path.removeLast()
                        }
                    }
                }
            } message: {
                Text("The plugin is uninstalled from the Gateway and its settings are removed. This happens right away.", bundle: .module)
            }
        } else {
            ContentUnavailableView(L("Plugin Removed"), systemImage: "puzzlepiece.extension")
        }
    }
}

struct AddPluginSheet: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var source = PluginSource.clawhub
    @State private var spec = ""
    @State private var enable = true

    private var settings: GatewaySettingsModel { self.gateway.settings }

    var body: some View {
        let operation = self.settings.operation(for: GatewaySettingsModel.installKey)
        NavigationStack {
            Form {
                Section {
                    Picker(L("Source"), selection: self.$source) {
                        ForEach(PluginSource.allCases) { Text($0.label).tag($0) }
                    }
                    TextField(L("Plugin"), text: self.$spec, prompt: Text(self.source.prompt))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(self.install)
                    Toggle(L("Turn on after installing"), isOn: self.$enable)
                } footer: {
                    Text("The Gateway downloads and installs the plugin itself. Only install plugins you trust: they run on your Gateway host.", bundle: .module)
                }
                if operation.isRunning {
                    Section { ProgressView("Installing…") }
                }
                if let error = operation.error {
                    Section { Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Add Plugin"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Install"), action: self.install)
                        .disabled(self.spec.nilIfBlank == nil || operation.isRunning)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .onAppear { self.settings.clearOperation(GatewaySettingsModel.installKey) }
        .pluginConfirmation(self.settings, isActive: true, onConfirmed: { installed in
            if installed { self.dismiss() }
        })
    }

    private func install() {
        Task {
            if await self.settings.install(from: self.source, spec: self.spec, enable: self.enable) { self.dismiss() }
        }
    }
}

extension View {
    /// Asks before plugin changes the Gateway wants confirmed (new capabilities, unverified packages).
    func pluginConfirmation(_ settings: GatewaySettingsModel, isActive: Bool,
                            onConfirmed: @escaping (Bool) -> Void = { _ in }) -> some View {
        let binding = Binding(
            get: { isActive && settings.pendingConfirmation != nil },
            set: { if !$0 { settings.pendingConfirmation = nil } })
        return self.alert(L("Confirm Plugin Change"), isPresented: binding, presenting: settings.pendingConfirmation) { confirmation in
            Button(L("Cancel"), role: .cancel) { settings.pendingConfirmation = nil }
            Button(L("Allow")) {
                Task { onConfirmed(await settings.confirm(confirmation)) }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
