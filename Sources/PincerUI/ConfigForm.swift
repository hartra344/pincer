import PincerKit
import SwiftUI

/// Navigation inside Gateway Settings.
enum GatewaySettingsRoute: Hashable {
    case object([String])
    case plugin(String)
}

/// Edits one object of the Gateway config, with fields generated from `config.schema`.
/// Changes stay local until Save, which sends only the changed keys as a `config.patch`.
struct ConfigObjectForm<Header: View>: View {
    let path: [String]
    let title: String
    /// Plugin credentials stored in this object, shown as secret fields first.
    var credentials: [PluginCredential] = []
    @ViewBuilder var header: () -> Header
    @Environment(GatewayStore.self) private var gateway
    @State private var draft = ConfigDraft(path: [], original: nil)
    @State private var texts: [String: String] = [:]
    @State private var inputErrors: [String: String] = [:]
    @State private var attemptedSave = false
    @State private var addingEntry = false
    @State private var newEntryKey = ""

    private var settings: GatewaySettingsStore { self.gateway.settings }
    private var schema: ConfigSchema { self.settings.schema ?? .open }

    private var fields: [ConfigField] {
        var fields = self.schema.fields(at: self.path, value: self.draft.current)
        for credential in self.credentials where Array(credential.path.dropLast()) == self.path {
            let existing = fields.firstIndex { $0.path == credential.path }
            let field = ConfigField.credential(credential, existing: existing.map { fields[$0] })
            if let existing { fields[existing] = field } else { fields.insert(field, at: 0) }
        }
        return fields.sorted { $0.order < $1.order }
    }

    private var isMap: Bool {
        self.path.isEmpty ? false : self.schema.field(at: self.path, value: self.settings.value(at: self.path))?.isMap ?? false
    }

    private var problems: [String: String] {
        var problems: [String: String] = [:]
        for field in self.fields where field.kind != .object {
            if let problem = field.validate(self.draft.value(for: field.key)) { problems[field.id] = problem }
        }
        return problems
    }

    var body: some View {
        let fields = self.fields
        let problems = self.problems
        Form {
            self.header()
            SettingsFeedback(path: self.path)
            let basic = fields.filter { !$0.isAdvanced }
            let advanced = fields.filter(\.isAdvanced)
            if fields.isEmpty {
                Section {
                    Text(self.isMap ? "Nothing here yet." : "This section has no settings Pincer can show.")
                        .foregroundStyle(.secondary)
                }
            }
            if !basic.isEmpty {
                Section {
                    ForEach(basic) { self.row($0, problems: problems) }
                }
            }
            if !advanced.isEmpty {
                Section("Advanced") {
                    ForEach(advanced) { self.row($0, problems: problems) }
                }
            }
            if self.isMap, self.settings.canEdit {
                Section {
                    Button("Add Entry…") { self.addingEntry = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(self.title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await self.save() } }
                    .disabled(!self.draft.hasChanges || self.settings.isSaving || !self.settings.canEdit)
            }
            if self.draft.hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert", action: self.reset)
                }
            }
        }
        .disabled(self.settings.isSaving)
        .onAppear(perform: self.reset)
        .onChange(of: self.settings.config) {
            if !self.draft.hasChanges { self.reset() }
        }
        .alert("Add Entry", isPresented: self.$addingEntry) {
            TextField("Key", text: self.$newEntryKey)
            Button("Cancel", role: .cancel) { self.newEntryKey = "" }
            Button("Add") {
                let key = self.newEntryKey.trimmingCharacters(in: .whitespaces)
                self.newEntryKey = ""
                guard !key.isEmpty, !key.contains("."), self.draft.value(for: key) == nil else { return }
                self.draft.set(key, .object([:]))
            }
        } message: {
            Text("Add a new entry, then open it to fill in its settings after saving.")
        }
    }

    private func reset() {
        self.draft = ConfigDraft(path: self.path, original: self.settings.value(at: self.path))
        self.texts = [:]
        self.inputErrors = [:]
        self.attemptedSave = false
    }

    private func save() async {
        self.attemptedSave = true
        guard self.inputErrors.isEmpty, self.problems.isEmpty, let patch = self.draft.patch else { return }
        if await self.settings.save(patch, note: "Pincer: \(self.title)") {
            self.reset()
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ field: ConfigField, problems: [String: String]) -> some View {
        let changed = self.draft.changes[field.key] != nil
        let problem = self.inputErrors[field.id]
            ?? ((changed || self.attemptedSave) ? problems[field.id] : nil)
            ?? self.settings.issues(under: field.path).first.map { $0.message }
        VStack(alignment: .leading, spacing: 4) {
            self.control(field)
            if let help = field.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
            if let url = field.signupURL {
                Link("Get a key", destination: url).font(.caption)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private func control(_ field: ConfigField) -> some View {
        let label = field.isRequired ? "\(field.label) *" : field.label
        switch field.kind {
        case .toggle:
            Toggle(label, isOn: Binding(
                get: { self.draft.value(for: field.key)?.bool ?? field.defaultValue?.bool ?? false },
                set: { self.draft.set(field.key, .bool($0)) }))
        case let .choice(options):
            Picker(label, selection: Binding(
                get: { self.draft.value(for: field.key)?.string ?? "" },
                set: { self.draft.set(field.key, $0.isEmpty ? nil : .string($0)) })) {
                Text(field.defaultValue?.string.map { "Default (\($0))" } ?? "Not set").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .secret:
            SecretFieldRow(
                label: label,
                placeholder: field.placeholder,
                isSaved: self.draft.original?[field.key].map { !$0.isNull } ?? false,
                isCleared: self.draft.changes[field.key]?.isNull == true,
                text: self.textBinding(field),
                clear: { self.draft.set(field.key, nil); self.texts[field.id] = "" },
                restore: { self.draft.set(field.key, self.draft.original?[field.key]); self.texts[field.id] = "" })
        case .object:
            NavigationLink(value: GatewaySettingsRoute.object(field.path)) {
                LabeledContent(label) {
                    Text(Self.summary(self.draft.value(for: field.key)))
                }
            }
        case .list, .json:
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                TextField(field.kind == .list ? "One per line" : "JSON", text: self.textBinding(field), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...10)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        case .text, .integer, .number:
            TextField(label, text: self.textBinding(field),
                      prompt: Text(field.placeholder ?? field.defaultValue.map { field.text(for: $0) } ?? ""))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(field.kind == .text ? .default : (field.kind == .integer ? .numberPad : .decimalPad))
                #endif
        }
    }

    /// Text-backed fields keep what was typed, even when it doesn't parse yet.
    private func textBinding(_ field: ConfigField) -> Binding<String> {
        Binding(
            get: {
                if let text = self.texts[field.id] { return text }
                if field.kind == .secret { return "" }
                return field.text(for: self.draft.value(for: field.key))
            },
            set: { text in
                self.texts[field.id] = text
                if field.kind == .secret, text.isEmpty {
                    // An empty secret box keeps the saved secret.
                    self.draft.set(field.key, self.draft.original?[field.key])
                    self.inputErrors[field.id] = nil
                    return
                }
                do {
                    self.draft.set(field.key, try field.value(fromText: text))
                    self.inputErrors[field.id] = nil
                } catch {
                    self.inputErrors[field.id] = error.localizedDescription
                }
            })
    }

    static func summary(_ value: JSONValue?) -> String {
        guard let object = value?.object, !object.isEmpty else { return "Not set" }
        if let enabled = object["enabled"]?.bool { return enabled ? "On" : "Off" }
        return object.count == 1 ? "1 setting" : "\(object.count) settings"
    }
}

extension ConfigObjectForm where Header == EmptyView {
    init(path: [String], title: String) {
        self.init(path: path, title: title, header: { EmptyView() })
    }
}

extension ConfigSchema {
    /// Used when the Gateway doesn't serve a schema: fields come from the values alone.
    static let open = ConfigSchema(schema: ["type": "object", "additionalProperties": .object([:])])
}

/// A secret the Gateway only returns redacted: type a new one to replace it, or clear it.
private struct SecretFieldRow: View {
    let label: String
    let placeholder: String?
    let isSaved: Bool
    let isCleared: Bool
    @Binding var text: String
    let clear: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack {
            SecureField(self.label, text: self.$text, prompt: Text(self.prompt))
                .disabled(self.isCleared)
            if self.isCleared {
                Button("Undo", action: self.restore).buttonStyle(.borderless)
            } else if self.isSaved, self.text.isEmpty {
                Button("Clear", role: .destructive, action: self.clear).buttonStyle(.borderless)
            }
        }
    }

    private var prompt: String {
        if self.isCleared { return "Will be removed" }
        if self.isSaved { return "Saved on Gateway — type to replace" }
        return self.placeholder ?? "Not set"
    }
}

/// Result of the last save, and any problems the Gateway reported, for the page at `path`.
struct SettingsFeedback: View {
    var path: [String] = []
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        let writeIssues = settings.writeIssues
        if settings.lastError != nil || settings.lastOutcome != nil || !writeIssues.isEmpty {
            Section {
                if let outcome = settings.lastOutcome {
                    Label(outcome.message, systemImage: outcome == .restarting ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(outcome == .restarting ? .orange : .green)
                }
                if let error = settings.lastError {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                if !writeIssues.isEmpty {
                    Label("The Gateway rejected the change:", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    ForEach(writeIssues) { IssueRow(issue: $0) }
                }
            }
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
