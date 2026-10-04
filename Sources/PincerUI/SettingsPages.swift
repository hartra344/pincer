import PincerKit
import SwiftUI

// MARK: Object sections

/// The settings of one config object as form sections: common settings first, then the
/// advanced ones folded away. Nested objects and lists open their own page.
struct ObjectSections: View {
    let path: [String]
    var title: String?
    var footer: String?
    /// Nested objects shown elsewhere on the same page.
    var skipping: Set<[String]> = []
    /// Plugin credentials stored in this object, shown first as secrets.
    var credentials: [PluginCredential] = []
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var showAdvanced = false
    @State private var addingEntry = false

    private var settings: GatewaySettingsModel { self.gateway.settings }

    private var fields: [ConfigField] {
        var fields = self.settings.fields(at: self.path).filter { !self.skipping.contains($0.path) && !self.hasReactionControl($0.path) }
        for credential in self.credentials where Array(credential.path.dropLast()) == self.path {
            let existing = fields.firstIndex { $0.path == credential.path }
            let field = ConfigField.credential(credential, existing: existing.map { fields[$0] })
            if let existing { fields[existing] = field } else { fields.insert(field, at: 0) }
        }
        return fields.sorted { $0.order < $1.order }
    }

    /// The dedicated Reactions section edits this key, so the schema editor leaves it out (when that section shows).
    private func hasReactionControl(_ path: [String]) -> Bool {
        ReactionLevels.isControlled(path: path) && self.gateway.canEditReactionLevels
    }

    var body: some View {
        let fields = self.fields
        let common = fields.filter { !$0.isAdvanced }
        let advanced = fields.filter(\.isAdvanced)
        let isMap = self.settings.field(at: self.path)?.isMap ?? false
        Section {
            ForEach(common) { FieldRow(field: $0) }
            if common.isEmpty, advanced.isEmpty {
                Text(isMap ? L("Nothing here yet.") : L("No settings.")).foregroundStyle(.secondary)
            }
            if isMap, self.settings.canEdit {
                Button(L("Add Entry…"), systemImage: "plus") { self.addingEntry = true }
            }
        } header: {
            if let title = self.title { Text(title) }
        } footer: {
            if let footer = self.footer, advanced.isEmpty { Text(footer) }
        }
        if !advanced.isEmpty {
            Section {
                DisclosureGroup(isExpanded: self.$showAdvanced) {
                    ForEach(advanced) { FieldRow(field: $0) }
                } label: {
                    Text("Advanced (\(advanced.count))", bundle: .module)
                }
            } footer: {
                if let footer = self.footer { Text(footer) }
            }
            .onAppear { if self.focusIsAdvanced(advanced) { self.showAdvanced = true } }
            .onChange(of: self.navigator.focus) { if self.focusIsAdvanced(advanced) { self.showAdvanced = true } }
        }
        EmptyView()
            .newEntryPrompt(isPresented: self.$addingEntry, under: self.path)
    }

    private func focusIsAdvanced(_ advanced: [ConfigField]) -> Bool {
        guard let focus = self.navigator.focus else { return false }
        return advanced.contains { $0.path == focus }
    }
}

extension View {
    /// Asks for a key, adds an empty entry under `path` to the draft, and opens it.
    func newEntryPrompt(isPresented: Binding<Bool>, under path: [String]) -> some View {
        self.modifier(NewEntryPrompt(isPresented: isPresented, path: path))
    }
}

private struct NewEntryPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let path: [String]
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var key = ""

    func body(content: Content) -> some View {
        content.alert(L("Add Entry"), isPresented: self.$isPresented) {
            TextField(L("Name"), text: self.$key)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button(L("Cancel"), role: .cancel) { self.key = "" }
            Button(L("Add")) {
                let key = self.key.trimmingCharacters(in: .whitespaces)
                self.key = ""
                let settings = self.gateway.settings
                guard !key.isEmpty, !key.contains("."), settings.value(at: self.path + [key]) == nil else { return }
                settings.set(self.path + [key], .object([:]))
                self.navigator.path.append(.object(self.path + [key]))
            }
        } message: {
            Text("It's added to your unsaved changes, and saved with them.", bundle: .module)
        }
    }
}

/// One row per entry of an object (channels, agents…), each opening its own page.
struct EntriesSection: View {
    let path: [String]
    var title: String?
    var footer: String?
    @Environment(GatewayStore.self) private var gateway
    @State private var addingEntry = false

    var body: some View {
        let settings = self.gateway.settings
        let fields = settings.fields(at: self.path)
        let entries = fields.filter { $0.kind == .object }
        let leaves = fields.filter { $0.kind != .object && !$0.isAdvanced }
        let isMap = settings.field(at: self.path)?.isMap ?? false
        Section {
            ForEach(entries) { entry in
                NavigationLink(value: SettingsRoute.object(entry.path)) {
                    EntryRow(field: entry)
                }
                .id(entry.id)
            }
            if entries.isEmpty {
                Text("None yet.", bundle: .module).foregroundStyle(.secondary)
            }
            if isMap, settings.canEdit {
                Button(L("Add…"), systemImage: "plus") { self.addingEntry = true }
            }
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { Text(footer) }
        }
        if !leaves.isEmpty {
            Section { ForEach(leaves) { FieldRow(field: $0) } }
        }
        EmptyView()
            .newEntryPrompt(isPresented: self.$addingEntry, under: self.path)
    }
}

private struct EntryRow: View {
    let field: ConfigField
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        let value = settings.value(at: self.field.path)
        let issues = settings.issues(under: self.field.path).count
        let changes = settings.changeCount(under: self.field.path)
        HStack {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(self.field.label)
                    if let help = self.field.help {
                        Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: SettingsSymbols.symbol(for: self.field.key))
            }
            Spacer()
            if issues > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .accessibilityLabel(issues == 1 ? L("1 problem") : L("\(issues) problems"))
            } else if changes > 0 {
                Text("Edited", bundle: .module).font(.caption).foregroundStyle(.tint)
            }
            Text(FieldRow.summary(value)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Pages

/// A curated page from `SettingsCatalog`.
struct CuratedPage: View {
    let page: SettingsPage
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        GatewaySettingsForm {
            if self.page.id == SettingsCatalog.agentsPageId {
                AgentManagementSection()
            }
            ForEach(self.page.sections.filter { settings.shows($0.content) }, id: \.self) { section in
                switch section.content {
                case let .object(path):
                    ObjectSections(path: path, title: section.title, footer: section.footer,
                                   skipping: self.page.inlinePaths)
                case let .entries(path):
                    EntriesSection(path: path, title: section.title, footer: section.footer)
                }
            }
        }
        .navigationTitle(self.page.title)
    }
}

extension GatewaySettingsModel {
    /// Whether the Gateway's schema or config has anything at this part of a curated page.
    func shows(_ content: SettingsPage.Content) -> Bool {
        switch content {
        case let .object(path):
            // An object section with nothing to edit would only say "No settings."
            !self.fields(at: path).isEmpty
        case let .entries(path):
            self.value(at: path) != nil || self.schema?.node(at: path) != nil
        }
    }

    func shows(_ page: SettingsPage) -> Bool {
        page.sections.contains { self.shows($0.content) }
    }
}

/// One object of the config, pushed from a link.
struct ConfigObjectPage: View {
    let path: [String]
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var confirmRemove = false

    var body: some View {
        let settings = self.gateway.settings
        let field = settings.field(at: self.path)
        let parentIsMap = settings.field(at: Array(self.path.dropLast()))?.isMap ?? false
        GatewaySettingsForm {
            if let target = ReactionLevels.target(for: self.path) {
                ReactionLevelSection(channel: target.channel, account: target.account)
            }
            ObjectSections(path: self.path)
            if parentIsMap, settings.canEdit, settings.value(at: self.path) != nil {
                Section {
                    Button("Remove \(field?.label ?? "Entry")", role: .destructive) { self.confirmRemove = true }
                }
            }
        }
        .navigationTitle(field?.label ?? ConfigPath.string(self.path))
        .confirmationDialog("Remove \(field?.label ?? "this entry")?", isPresented: self.$confirmRemove) {
            Button(L("Remove"), role: .destructive) {
                settings.set(self.path, nil)
                if self.navigator.path.last == .object(self.path) { self.navigator.path.removeLast() }
            }
        } message: {
            Text("It's removed from the config when you save.", bundle: .module)
        }
    }
}

/// A list of strings, one row each.
struct StringListPage: View {
    let path: [String]
    @Environment(GatewayStore.self) private var gateway
    @FocusState private var focused: Int?

    var body: some View {
        let settings = self.gateway.settings
        let field = settings.field(at: self.path)
        let items = (settings.value(at: self.path)?.array ?? []).map { $0.string ?? $0.compactString() }
        Form {
            Section {
                ForEach(items.indices, id: \.self) { index in
                    HStack {
                        TextField(L("Item"), text: Binding(
                            get: { items.indices.contains(index) ? items[index] : "" },
                            set: { text in
                                var updated = items
                                if updated.indices.contains(index) { updated[index] = text }
                                self.save(updated)
                            }))
                            .labelsHidden()
                            .focused(self.$focused, equals: index)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        #if os(macOS)
                        Button { self.remove(IndexSet(integer: index), from: items) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(items[index].isEmpty ? L("Remove item \(index + 1)") : L("Remove \(items[index])"))
                        .help(L("Remove"))
                        #endif
                    }
                }
                .onDelete { self.remove($0, from: items) }
                .onMove { from, to in
                    var updated = items
                    updated.move(fromOffsets: from, toOffset: to)
                    self.save(updated)
                }
                Button(L("Add Item"), systemImage: "plus") {
                    self.save(items + [""])
                    self.focused = items.count
                }
            } footer: {
                if let help = field?.help { Text(help) }
            }
            .disabled(!settings.canEdit)
        }
        .formStyle(.grouped)
        .navigationTitle(field?.label ?? "List")
        .settingsChrome()
        .onDisappear {
            let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if trimmed != items { self.save(trimmed) }
        }
    }

    private func remove(_ offsets: IndexSet, from items: [String]) {
        var updated = items
        updated.remove(atOffsets: offsets)
        self.save(updated)
    }

    private func save(_ items: [String]) {
        let settings = self.gateway.settings
        let saved = settings.savedValue(at: self.path)
        // Emptying a list that wasn't set leaves it unset.
        settings.set(self.path, items.isEmpty && saved == nil ? nil : .array(items.map(JSONValue.string)))
    }
}

/// Everything in the config, straight from the schema.
struct AllSettingsPage: View {
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        let fields = settings.fields(at: [])
        GatewaySettingsForm {
            Section {
                ForEach(fields.filter { $0.kind == .object }) { field in
                    NavigationLink(value: SettingsRoute.object(field.path)) {
                        SectionLinkLabel(field: field)
                    }
                    .id(field.id)
                }
            } footer: {
                Text("Every setting the Gateway's schema describes. The other pages show the common ones.", bundle: .module)
            }
            let leaves = fields.filter { $0.kind != .object }
            if !leaves.isEmpty {
                Section(L("Other")) { ForEach(leaves) { FieldRow(field: $0) } }
            }
        }
        .navigationTitle(L("All Settings"))
    }
}

private struct SectionLinkLabel: View {
    let field: ConfigField
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(self.field.label)
                if let help = self.field.help {
                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: SettingsSymbols.symbol(for: self.field.key))
        }
        .badge(settings.issues(under: self.field.path).count)
    }
}

/// A grouped form that scrolls to the focused setting and carries the save controls.
struct GatewaySettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if !self.gateway.settings.hasLoaded {
                    SettingsLoadingSection()
                } else {
                    self.content()
                }
            }
            .formStyle(.grouped)
            .onAppear { self.scroll(proxy) }
            .onChange(of: self.navigator.focus) { self.scroll(proxy) }
        }
        .settingsChrome()
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let focus = self.navigator.focus else { return }
        let id = ConfigPath.string(focus)
        Task {
            // Let the page (and any Advanced group) lay out first.
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            try? await Task.sleep(for: .seconds(2))
            if self.navigator.focus == focus { withAnimation { self.navigator.focus = nil } }
        }
    }
}

struct SettingsLoadingSection: View {
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let settings = self.gateway.settings
        Section {
            if let error = settings.loadState.error {
                Label(error, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                Button(L("Try Again")) { Task { await settings.load() } }
            } else if !settings.configSupported {
                Text("This Gateway doesn't share its settings with Pincer.", bundle: .module).foregroundStyle(.secondary)
            } else if !self.gateway.state.isConnected {
                Text("Settings load once \(self.gateway.profile.name) is connected.", bundle: .module).foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading settings…", bundle: .module).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Overview

struct OverviewPage: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        let settings = self.gateway.settings
        let profile = self.gateway.profile
        Form {
            Section {
                LabeledContent(L("Gateway"), value: profile.name)
                LabeledContent(L("Status")) { ConnectionStateText(state: self.gateway.state) }
                LabeledContent(L("Health")) {
                    let level = self.gateway.health.level
                    Button { self.navigator.destination = .health } label: {
                        Label(level.label, systemImage: level.symbol)
                            .foregroundStyle(GatewayHealthPage.color(level))
                    }
                    .buttonStyle(.borderless)
                }
                if let version = self.gateway.hello?.serverVersion { LabeledContent(L("Version"), value: version) }
                LabeledContent(L("Access")) {
                    Button(settings.canEdit || profile.access == .standard ? profile.access.label : "Waiting for approval") {
                        self.navigator.destination = .connection
                    }
                    .buttonStyle(.borderless)
                }
            }
            SetupGatewaySection()
            if let snapshot = settings.snapshot {
                Section(L("Config")) {
                    if let path = snapshot.path {
                        LabeledContent(L("File")) {
                            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if snapshot.isValid {
                        Label(L("Config is valid"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label(L("Config has problems"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    ForEach(snapshot.issues) { issue in
                        Button { self.navigator.go(to: ConfigPath.parse(issue.path)) } label: {
                            IssueRow(issue: issue).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(snapshot.warnings) { warning in
                        Label(warning.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                if settings.pluginsNeedingAttention > 0 {
                    Section {
                        Button {
                            self.navigator.destination = .plugins
                        } label: {
                            Label(settings.pluginsNeedingAttention == 1 ? L("1 plugin needs attention")
                                    : L("\(settings.pluginsNeedingAttention) plugins need attention"),
                                  systemImage: "puzzlepiece.extension")
                        }
                    }
                }
                if let last = settings.lastSave {
                    Section(L("Last Change")) { SaveOutcomeLabel(outcome: last.outcome) }
                }
            } else {
                SettingsLoadingSection()
            }
            Section {
                Button(L("Reload from Gateway"), systemImage: "arrow.clockwise") { Task { await settings.load() } }
                    .disabled(settings.loadState.isRunning || !self.gateway.state.isConnected)
            } footer: {
                if settings.hasChanges {
                    Text("Reloading keeps your unsaved changes.", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Overview"))
        .settingsChrome()
    }
}

struct ConnectionStateText: View {
    let state: ConnectionState

    var body: some View {
        switch self.state {
        case .connected: Label(L("Connected"), systemImage: "circle.fill").foregroundStyle(.green)
        case .connecting, .idle: Text("Connecting…", bundle: .module).foregroundStyle(.secondary)
        case .reconnecting: Text("Reconnecting…", bundle: .module).foregroundStyle(.orange)
        case .awaitingPairing: Text("Waiting for approval", bundle: .module).foregroundStyle(.orange)
        case let .failed(message): Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct SaveOutcomeLabel: View {
    let outcome: ConfigApplyOutcome

    var body: some View {
        switch self.outcome {
        case .restarting, .restartRequired, .savedNotApplied:
            Label(self.outcome.message, systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
        default:
            Label(self.outcome.message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: Raw config

/// The whole config file as text, saved with `config.apply`.
struct RawConfigPage: View {
    @Environment(GatewayStore.self) private var gateway
    private let injectedSettings: GatewaySettingsModel?
    #if DEBUG
    @Environment(\.rawConfigParserProbe) private var parserProbe
    #endif
    init(settings: GatewaySettingsModel? = nil) { self.injectedSettings = settings }
    private var settings: GatewaySettingsModel { self.injectedSettings ?? self.gateway.settings }
    @State private var draft = RawConfigEditorDraft()

    var body: some View {
        let settings = self.settings
        let raw = settings.snapshot?.raw
        Form {
            if raw == nil {
                Section {
                    Text(settings.hasLoaded ? L("The Gateway didn't send the raw config file.") : L("Loading…"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextEditor(text: Binding(get: { self.draft.text }, set: { self.draft.edit($0) }))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        #if os(iOS)
                        // Keep long files inside the native editor's scrolling viewport.
                        .frame(height: 360)
                        #else
                        .frame(minHeight: 360)
                        #endif
                        .disabled(!settings.canEdit)
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        if let parseError = self.draft.validationError {
                            Label(parseError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        if settings.hasChanges {
                            Text("Save or discard your other unsaved changes before editing the raw file.", bundle: .module)
                                .foregroundStyle(.orange)
                        }
                        Text("Secrets show as \(JSONValue.redactedSentinel); leave them as they are to keep them. Saving replaces the whole config, and the Gateway checks it first.", bundle: .module)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Raw Config"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if self.draft.isEdited {
                    Button(L("Revert")) { self.draft.revert() }
                }
                Button(L("Save")) {
                    let source = self.draft.text
                    guard let admission = self.draft.beginSave() else { return }
                    Task {
                        let saved = await settings.saveRaw(source)
                        self.draft.finishSave(admission: admission, acknowledgedRaw: saved ? settings.snapshot?.raw : nil)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!self.draft.isEdited || self.draft.savePending || self.draft.validationPending || self.draft.validationError != nil || settings.hasChanges || settings.isSaving || !settings.canEdit)
            }
        }
        .onAppear {
            #if DEBUG
            let probe = self.parserProbe
            self.draft.validationObserver = { probe?.record() }
            #endif
            self.sync()
        }
        .onChange(of: settings.snapshot?.hash) { self.sync() }
    }

    private func sync() {
        guard let raw = self.settings.snapshot?.raw else { return }
        self.draft.updateSnapshot(raw)
    }
    static func parseError(_ text: String) -> String? { RawConfigEditorDraft.parseError(text) }
}

#if DEBUG
final class RawConfigParserProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var background = 0
    func record() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.main + self.background < 256 else { return }
        if Thread.isMainThread { self.main += 1 } else { self.background += 1 }
    }
    var counts: (main: Int, background: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.main, self.background)
    }
}
extension EnvironmentValues {
    @Entry var rawConfigParserProbe: RawConfigParserProbe? = nil
}
#endif
