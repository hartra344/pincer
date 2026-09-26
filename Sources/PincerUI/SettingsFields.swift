import PincerKit
import SwiftUI

/// Navigation state for one Gateway Settings window: the sidebar row, the pages pushed on
/// top of it, and a setting to scroll to and highlight.
@MainActor
@Observable
final class SettingsNavigator {
    var destination: SettingsDestination? {
        didSet { if !self.isJumping, oldValue != self.destination { self.path = [] } }
    }

    var path: [SettingsRoute] = []
    var focus: [String]?
    var isReviewing = false
    @ObservationIgnored private var isJumping = false

    init(destination: SettingsDestination?) {
        self.destination = destination
    }

    func go(to location: SettingsLocation) {
        self.isJumping = true
        self.destination = location.destination
        self.path = location.routes
        self.isJumping = false
        self.focus = location.focus
    }

    func go(to path: [String]) {
        self.go(to: SettingsCatalog.location(for: path))
    }
}

/// One setting: the control for its kind, its help, and whatever is wrong with it.
struct FieldRow: View {
    let field: ConfigField
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @Environment(\.appTheme) private var theme

    private var settings: GatewaySettingsModel { self.gateway.settings }

    var body: some View {
        let settings = self.settings
        let changed = settings.isChanged(self.field.path)
        let problem = settings.inputError(for: self.field)
            ?? (changed ? settings.validationProblems[self.field.id] : nil)
            ?? settings.issues(under: self.field.path).first?.message
        VStack(alignment: .leading, spacing: 4) {
            self.control
                .disabled(!settings.canEdit)
            if let help = self.field.help {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = self.field.signupURL {
                Link("Get a key", destination: url).font(.caption)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if changed {
                HStack(spacing: 6) {
                    Text("Edited").foregroundStyle(self.theme.accent)
                    Button("Revert") { self.settings.revert(self.field.path) }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
            }
        }
        .id(self.field.id)
        .listRowBackground(self.isFocused ? self.theme.accent.opacity(0.14) : nil)
        .contextMenu { FieldMenu(field: self.field) }
    }

    private var isFocused: Bool { self.navigator.focus == self.field.path }

    private var label: String { self.field.isRequired ? "\(self.field.label) *" : self.field.label }

    @ViewBuilder private var control: some View {
        let field = self.field
        let settings = self.settings
        switch field.kind {
        case .toggle:
            Toggle(self.label, isOn: Binding(
                get: { settings.value(at: field.path)?.bool ?? field.defaultValue?.bool ?? false },
                set: { settings.set(field.path, .bool($0)) }))
        case let .choice(options):
            Picker(self.label, selection: Binding(
                get: { settings.value(at: field.path)?.string ?? "" },
                set: { settings.set(field.path, $0.isEmpty ? nil : .string($0)) })) {
                Text(field.defaultValue?.string.map { "Default (\($0))" } ?? "Not Set").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .secret:
            SecretFieldRow(field: field, label: self.label)
        case .object:
            NavigationLink(value: SettingsRoute.object(field.path)) {
                LabeledContent(self.label) { Text(Self.summary(settings.value(at: field.path))) }
            }
        case .list:
            NavigationLink(value: SettingsRoute.list(field.path)) {
                LabeledContent(self.label) { Text(Self.listSummary(settings.value(at: field.path))) }
            }
        case .json:
            VStack(alignment: .leading, spacing: 4) {
                Text(self.label)
                TextField("JSON", text: self.textBinding, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...12)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        case .text, .integer, .number:
            TextField(self.label, text: self.textBinding,
                      prompt: Text(field.placeholder ?? field.defaultValue.map { field.text(for: $0) } ?? ""))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(field.kind == .text ? .default : (field.kind == .integer ? .numberPad : .decimalPad))
                #endif
        }
    }

    private var textBinding: Binding<String> {
        let field = self.field
        let settings = self.settings
        return Binding(get: { settings.text(for: field) }, set: { settings.setText($0, for: field) })
    }

    static func summary(_ value: JSONValue?) -> String {
        guard let object = value?.object, !object.isEmpty else { return "Not Set" }
        if let enabled = object["enabled"]?.bool { return enabled ? "On" : "Off" }
        return object.count == 1 ? "1 setting" : "\(object.count) settings"
    }

    static func listSummary(_ value: JSONValue?) -> String {
        let count = value?.array?.count ?? 0
        return count == 0 ? "None" : count == 1 ? (value?.array?.first?.string ?? "1 item") : "\(count) items"
    }
}

/// Context menu shared by setting rows.
struct FieldMenu: View {
    let field: ConfigField
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        if settings.isChanged(self.field.path) {
            Button("Revert to Saved", systemImage: "arrow.uturn.backward") { settings.revert(self.field.path) }
        }
        if settings.value(at: self.field.path) != nil, !self.field.isRequired, settings.canEdit {
            Button(self.field.defaultValue == nil ? "Remove Value" : "Reset to Default", systemImage: "eraser") {
                settings.set(self.field.path, nil)
            }
        }
        Button("Copy Setting Path", systemImage: "doc.on.doc") { Clipboard.copy(self.field.id) }
    }
}

/// A secret the Gateway only returns redacted: type a new one to replace it, clear it, or (where
/// the schema allows) have the Gateway read it from an environment variable, file or command.
private struct SecretFieldRow: View {
    let field: ConfigField
    let label: String
    @Environment(GatewayStore.self) private var gateway

    private enum Source: Hashable {
        case value
        case reference(SecretRef.Source)
    }

    var body: some View {
        let settings = self.gateway.settings
        let value = settings.value(at: self.field.path)
        let reference = value.flatMap(SecretRef.init)
        VStack(alignment: .leading, spacing: 6) {
            if self.field.allowsSecretRef {
                Picker(self.label, selection: Binding(
                    get: { reference.map { Source.reference($0.source) } ?? .value },
                    set: { self.choose($0, current: reference) })) {
                    Text("Stored Value").tag(Source.value)
                    ForEach(SecretRef.Source.allCases) { Text($0.label).tag(Source.reference($0)) }
                }
            }
            if let reference {
                TextField(self.field.allowsSecretRef ? reference.source.label : self.label, text: Binding(
                    get: { reference.id },
                    set: { id in
                        var updated = reference
                        updated.id = id
                        settings.set(self.field.path, updated.json)
                    }), prompt: Text(reference.source.prompt))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } else {
                self.secretField(settings, value: value)
            }
        }
    }

    @ViewBuilder private func secretField(_ settings: GatewaySettingsModel, value: JSONValue?) -> some View {
        let saved = settings.savedValue(at: self.field.path) != nil
        let cleared = saved && value == nil
        HStack {
            SecureField(self.field.allowsSecretRef ? "Value" : self.label,
                        text: Binding(get: { settings.text(for: self.field) }, set: { settings.setText($0, for: self.field) }),
                        prompt: Text(cleared ? "Will be removed" : saved ? "Saved on Gateway — type to replace" : self.field.placeholder ?? "Not Set"))
                .disabled(cleared)
            if cleared {
                Button("Undo") { settings.revert(self.field.path) }.buttonStyle(.borderless)
            } else if saved, settings.text(for: self.field).isEmpty, !self.field.isRequired {
                Button("Clear", role: .destructive) { settings.set(self.field.path, nil) }.buttonStyle(.borderless)
            }
        }
    }

    private func choose(_ source: Source, current: SecretRef?) {
        let settings = self.gateway.settings
        switch source {
        case .value:
            let saved = settings.savedValue(at: self.field.path)
            settings.set(self.field.path, saved?.string != nil ? saved : nil)
        case let .reference(kind):
            let saved = settings.savedValue(at: self.field.path).flatMap(SecretRef.init)
            let reference = saved?.source == kind ? saved! : SecretRef(source: kind, id: current?.id ?? "")
            settings.set(self.field.path, reference.json)
        }
    }
}

struct IssueRow: View {
    let issue: ConfigIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.issue.displayPath).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(self.issue.message)
            if let hint = self.issue.fixHint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }
}

enum SettingsSymbols {
    static func symbol(for key: String) -> String {
        switch key {
        case "gateway": "server.rack"
        case "agents": "person.2"
        case "channels": "bubble.left.and.bubble.right"
        case "tools": "wrench.and.screwdriver"
        case "plugins": "puzzlepiece.extension"
        case "models", "providers": "cpu"
        case "skills": "sparkles"
        case "session", "sessions", "messages": "text.bubble"
        case "hooks": "link"
        case "cron", "automations", "heartbeat": "clock"
        case "logging", "diagnostics": "doc.text.magnifyingglass"
        case "ui": "paintbrush"
        case "browser": "globe"
        case "memory": "brain"
        case "secrets", "auth": "key"
        case "discord": "gamecontroller"
        case "telegram": "paperplane"
        case "whatsapp", "signal", "imessage", "sms": "message"
        case "slack", "teams", "mattermost", "matrix": "number"
        case "email", "gmail": "envelope"
        case "web", "webchat": "safari"
        case "voice", "voicecall": "phone"
        default: "gearshape"
        }
    }
}
