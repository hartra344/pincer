import PincerKit
import SwiftUI

/// What the add/edit sheet is editing.
struct MCPEditorTarget: Identifiable {
    let id = UUID()
    let draft: MCPServerDraft
}

/// Adds or edits one MCP server. Apply puts it into the shared settings draft; the user then uses
/// Review & Save like on the other settings pages.
struct MCPServerEditor: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPServerDraft
    @State private var showProblems = false
    @State private var touchedFields: Set<String> = []
    @State private var revealed: Set<Int> = []
    @State private var advancedOpen = false
    @State private var probe = MCPProbeState()
    @State private var scrollTarget: MCPScrollTarget?
    private let initial: MCPServerDraft

    init(draft: MCPServerDraft) {
        self._draft = State(initialValue: draft)
        self.initial = draft
        self._advancedOpen = State(initialValue: draft.advancedCount > 0)
    }

    private var isNew: Bool { self.initial.originalName == nil }

    var body: some View {
        let existing = Set(self.gateway.mcp.servers.map(\.name)).subtracting([self.initial.originalName].compactMap { $0 })
        let problems = self.draft.problems(existingNames: existing)
        let shown = MCPFieldProblemVisibility.visible(problems, touched: self.touchedFields, showAll: self.showProblems)
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    self.field(L("Name"), text: self.$draft.name, prompt: "filesystem", problemKey: "name")
                    self.problem(shown["name"], key: "name")
                    Picker(L("Transport"), selection: self.$draft.transport) {
                        ForEach(MCPTransport.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    let dropped = self.draft.droppedFieldsOnTransportChange
                    if !dropped.isEmpty {
                        Label(L("Removed when you save: \(dropped.joined(separator: ", "))"), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle(L("Enabled"), isOn: self.$draft.enabled)
                    if self.draft.resetsSignIn {
                        Label(L("You'll need to sign in again after saving."), systemImage: "person.badge.key")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Name: letters, numbers, . _ - (start with a letter or number).", bundle: .module)
                    if self.draft.isRename {
                        Text("Renaming adds a server under the new name and removes the old one. Saved secrets need to be entered again.", bundle: .module)
                    }
                }
                if self.draft.transport.isRemote {
                    self.remoteSections(shown)
                } else {
                    self.stdioSections(shown)
                }
                self.advancedSection(shown)
                if self.gateway.mcp.supportsProbe {
                    self.testSection(valid: problems.isEmpty)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Changes stay with your other unsaved settings until you use Review & Save. Other settings for this server are kept. Edit them in Raw Config.", bundle: .module)
                }
            }
            .formStyle(.grouped)
            .onChange(of: self.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target.id, anchor: target.anchor) }
            }
            }
            .navigationTitle(self.isNew ? L("Add Server") : L("Edit \(self.initial.originalName ?? "")"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { self.dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) {
                        if problems.isEmpty {
                            self.gateway.mcp.apply(self.draft)
                            self.dismiss()
                        } else {
                            self.showProblems = true
                            self.revealAdvancedProblem(problems)
                        }
                    }
                    .disabled(!self.isNew && self.draft == self.initial && problems.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 620)
        #endif
    }

    /// A labeled text field, so the label stays visible once there's text.
    private func field(_ title: String, text: Binding<String>, prompt: LocalizedStringKey, url: Bool = false,
                       number: Bool = false, problemKey: String? = nil) -> some View
    {
        let binding = problemKey.map { self.tracked(text, key: $0) } ?? text
        return LabeledContent(title) {
            TextField(title, text: binding, prompt: Text(prompt, bundle: .module))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : (number ? .numberPad : .default))
                #endif
        }
    }

    private func tracked(_ binding: Binding<String>, key: String) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { value in
            self.touchedFields.insert(key)
            binding.wrappedValue = value
        })
    }

    private func trackedPairKey(_ binding: Binding<String>, prefix: String) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { value in
            func key(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces) }
            self.touchedFields.insert("\(prefix).\(key(binding.wrappedValue))")
            binding.wrappedValue = value
            self.touchedFields.insert("\(prefix).\(key(binding.wrappedValue))")
        })
    }

    private func trackedPairValue(_ binding: Binding<String>, prefix: String, rowKey: String) -> Binding<String> {
        self.tracked(binding, key: "\(prefix).\(rowKey.trimmingCharacters(in: .whitespaces))")
    }

    @ViewBuilder private func problem(_ text: String?, key: String? = nil) -> some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .accessibilityIdentifier(key.map { "mcp-field-problem-\($0)" } ?? "")
        }
    }

    // MARK: stdio

    @ViewBuilder private func stdioSections(_ problems: [String: String]) -> some View {
        Section {
            self.field(L("Command"), text: self.$draft.command, prompt: "npx", problemKey: "command")
            self.problem(problems["command"], key: "command")
            self.field(L("Working folder"), text: self.$draft.cwd, prompt: "Optional")
        }
        Section {
            let secret = Set(zip(self.draft.args.indices, zip(self.draft.args, MCPServer.maskedArgs(self.draft.args)))
                .filter { $0.1.0 != $0.1.1 }.map(\.0))
            ForEach(self.draft.args.indices, id: \.self) { index in
                HStack {
                    if secret.contains(index), !self.revealed.contains(index) {
                        SecureField(L("Argument"), text: self.argBinding(index))
                        Button(L("Reveal"), systemImage: "eye") { self.revealed.insert(index) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    } else {
                        TextField(L("Argument"), text: self.argBinding(index))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        if secret.contains(index) {
                            Button(L("Hide"), systemImage: "eye.slash") { self.revealed.remove(index) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    Button(L("Remove argument"), systemImage: "minus.circle") {
                        self.draft.args.remove(at: index)
                        self.revealed = []
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button(L("Add Argument"), systemImage: "plus") { self.draft.args.append("") }
        } header: {
            Text("Arguments", bundle: .module)
        }
        self.pairsSection(L("Environment"), rows: self.$draft.env, keyLabel: L("Variable"), prefix: "env", problems: problems)
    }

    private func argBinding(_ index: Int) -> Binding<String> {
        Binding(get: { self.draft.args.indices.contains(index) ? self.draft.args[index] : "" },
                set: { if self.draft.args.indices.contains(index) { self.draft.args[index] = $0 } })
    }

    // MARK: remote

    @ViewBuilder private func remoteSections(_ problems: [String: String]) -> some View {
        Section {
            if self.draft.urlIsRedacted {
                HStack {
                    Text("•••• (saved)", bundle: .module).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Replace")) { self.draft.urlIsRedacted = false; self.draft.url = "" }
                }
            } else {
                self.field(L("URL"), text: self.$draft.url, prompt: "https://…", url: true, problemKey: "url")
            }
            self.problem(problems["url"], key: "url")
            Toggle(L("Requires OAuth sign-in"), isOn: self.$draft.usesOAuth)
            if self.draft.usesOAuth {
                self.field(L("Scope"), text: self.$draft.oauthScope, prompt: "Optional")
            }
        } footer: {
            if self.draft.usesOAuth {
                Text("After saving, sign in from the server's page.", bundle: .module)
            }
        }
        self.pairsSection(L("Headers"), rows: self.$draft.headers, keyLabel: L("Header"), prefix: "headers", problems: problems)
    }

    // MARK: Key-value rows

    private func pairsSection(_ title: String, rows: Binding<[MCPKeyValue]>, keyLabel: String, prefix: String,
                              problems: [String: String]) -> some View {
        Section {
            ForEach(rows) { $row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        TextField(keyLabel, text: self.trackedPairKey($row.key, prefix: prefix))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button(L("Remove"), systemImage: "minus.circle") { rows.wrappedValue.removeAll { $0.id == row.id } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    if row.isRedacted {
                        HStack {
                            Text("Saved", bundle: .module).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Replace")) { row.isRedacted = false; row.value = "" }
                        }
                    } else {
                        SecureField(L("Value"), text: self.trackedPairValue($row.value, prefix: prefix, rowKey: row.key))
                    }
                    self.problem(problems["\(prefix).\(row.key.trimmingCharacters(in: .whitespaces))"],
                                 key: "\(prefix).\(row.key.trimmingCharacters(in: .whitespaces))")
                }
            }
            Button(L("Add"), systemImage: "plus") {
                rows.wrappedValue.append(MCPKeyValue(id: UUID(), key: "", value: "", isRedacted: false))
            }
        } header: {
            Text(title)
        } footer: {
            Text("Values are stored on the Gateway and hidden here once saved.", bundle: .module)
        }
    }
}

// MARK: Advanced

extension MCPServerDraft {
    /// How many Advanced settings differ from their defaults.
    fileprivate var advancedCount: Int {
        let texts = [self.connectionTimeoutMs, self.requestTimeoutMs, self.clientCert, self.clientKey,
                     self.oauthIdentity, self.oauthAuthProfileId]
        let filters = [self.toolInclude, self.toolExclude].filter { !$0.isEmpty }.count
        return texts.filter { !$0.isEmpty }.count + filters + (self.sslVerify ? 0 : 1)
    }
}

extension MCPServerEditor {
    private static let advancedProblemKeys = ["connectionTimeoutMs", "requestTimeoutMs", "oauthIdentity", "oauthAuthProfileId"]

    fileprivate func advancedSection(_ problems: [String: String]) -> some View {
        let forced = Self.advancedProblemKeys.contains { problems[$0] != nil }
        let open = Binding(get: { self.advancedOpen || forced }, set: { self.advancedOpen = $0 })
        return Section {
            DisclosureGroup(isExpanded: open) {
                self.timeoutRows(problems)
                self.toolFilterRows()
                if self.draft.transport.isRemote {
                    self.tlsRows()
                    if self.draft.usesOAuth { self.oauthRows(problems) }
                }
            } label: {
                self.advancedLabel(open: open.wrappedValue)
            }
        }
        .id(MCPScrollTarget.advancedID)
    }

    /// Done with an error inside Advanced: open it and scroll there.
    fileprivate func revealAdvancedProblem(_ problems: [String: String]) {
        guard Self.advancedProblemKeys.contains(where: { problems[$0] != nil }) else { return }
        self.advancedOpen = true
        self.scrollTarget = MCPScrollTarget(id: MCPScrollTarget.advancedID, anchor: .top)
    }

    @ViewBuilder private func advancedLabel(open: Bool) -> some View {
        let count = self.draft.advancedCount
        if !open, count > 0 {
            Text("Advanced · \(count) set", bundle: .module)
        } else {
            Text("Advanced", bundle: .module)
        }
    }

    private func timeoutRows(_ problems: [String: String]) -> some View {
        Group {
            self.millisecondsField(L("Connection timeout"), text: self.$draft.connectionTimeoutMs, prompt: "Default (30 s)",
                                   problemKey: "connectionTimeoutMs")
            self.problem(problems["connectionTimeoutMs"], key: "connectionTimeoutMs")
            self.millisecondsField(L("Request timeout"), text: self.$draft.requestTimeoutMs, prompt: "Default (60 s)",
                                   problemKey: "requestTimeoutMs")
            self.problem(problems["requestTimeoutMs"], key: "requestTimeoutMs")
        }
    }

    private func millisecondsField(_ title: String, text: Binding<String>, prompt: LocalizedStringKey,
                                   problemKey: String) -> some View
    {
        LabeledContent(title) {
            HStack(spacing: Theme.Spacing.xs) {
                TextField(title, text: self.tracked(text, key: problemKey), prompt: Text(prompt, bundle: .module))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("ms", bundle: .module).foregroundStyle(.secondary)
            }
        }
    }

    private func toolFilterRows() -> some View {
        Group {
            self.patternRows(L("Only allow tools"), rows: self.$draft.toolInclude)
            self.patternRows(L("Hide tools"), rows: self.$draft.toolExclude)
            Text("* matches any characters. Include is applied first, then exclude.", bundle: .module)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func patternRows(_ title: String, rows: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.subheadline)
            ForEach(rows.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(L("Pattern"), text: Self.patternBinding(rows, index), prompt: Text("create_*", bundle: .module))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button(L("Remove pattern"), systemImage: "minus.circle") { rows.wrappedValue.remove(at: index) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button(L("Add Pattern"), systemImage: "plus") { rows.wrappedValue.append("") }
                .buttonStyle(.borderless)
        }
    }

    private static func patternBinding(_ rows: Binding<[String]>, _ index: Int) -> Binding<String> {
        Binding(get: { rows.wrappedValue.indices.contains(index) ? rows.wrappedValue[index] : "" },
                set: { if rows.wrappedValue.indices.contains(index) { rows.wrappedValue[index] = $0 } })
    }

    private func tlsRows() -> some View {
        Group {
            Toggle(L("Verify TLS certificate"), isOn: self.$draft.sslVerify)
            if !self.draft.sslVerify {
                Label(L("Pincer can't check this server's identity."), systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
            self.field(L("Client certificate"), text: self.$draft.clientCert, prompt: "Optional")
            self.field(L("Client key"), text: self.$draft.clientKey, prompt: "Optional")
            Text("Paths on the Gateway host.", bundle: .module).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func oauthRows(_ problems: [String: String]) -> some View {
        Group {
            Picker(L("Sign-in"), selection: Binding(get: { self.draft.oauthIdentity }, set: { value in
                self.touchedFields.insert("oauthIdentity")
                self.draft.oauthIdentity = value
            })) {
                Text("Shared (one sign-in for everyone)", bundle: .module).tag(self.draft.oauthIdentity == "shared" ? "shared" : "")
                Text("Per person (each person signs in)", bundle: .module).tag("per-requester")
            }
            self.problem(problems["oauthIdentity"], key: "oauthIdentity")
            self.field(L("Auth profile"), text: self.$draft.oauthAuthProfileId, prompt: "Optional", problemKey: "oauthAuthProfileId")
            self.problem(problems["oauthAuthProfileId"], key: "oauthAuthProfileId")
        }
    }
}

// MARK: Test connection

/// A one-shot request to scroll the form; `token` makes repeats distinct.
struct MCPScrollTarget: Equatable {
    static let advancedID = "mcp-advanced"
    static let resultID = "mcp-probe-result"

    let id: String
    let anchor: UnitPoint
    let token = UUID()
}

/// The state of one Test Connection run. `tested` is the draft that was sent, to spot stale results.
struct MCPProbeState {
    var running = false
    var result: MCPProbeResult?
    var tested: MCPServerDraft?
}

extension MCPServerEditor {
    fileprivate func testSection(valid: Bool) -> some View {
        Section {
            let stale = self.probe.tested.map { $0 != self.draft } ?? false
            MCPTestConnectionRows(state: self.probe, stale: stale, disabledReason: valid ? nil : L("Fix the errors above first."),
                                  run: self.runProbe)
        } footer: {
            Text("Tests these settings from the Gateway without saving.", bundle: .module)
        }
    }

    private func runProbe() {
        let draft = self.draft
        self.probe = MCPProbeState(running: true, result: nil, tested: draft)
        Task {
            let timeout = Int(draft.connectionTimeoutMs) ?? 15000
            let result = await self.gateway.mcp.probe(name: draft.name, draft: draft, timeoutMs: timeout)
            self.probe = MCPProbeState(running: false, result: result, tested: draft)
            await Task.yield()
            self.scrollTarget = MCPScrollTarget(id: MCPScrollTarget.resultID, anchor: .bottom)
        }
    }
}

/// The Test Connection button, its reason when disabled, and the inline result.
struct MCPTestConnectionRows: View {
    let state: MCPProbeState
    var stale = false
    var disabledReason: String?
    /// Where to sign in after a probe reports the server needs it.
    var signInHint = L("Save, then sign in from the server's page.")
    let run: () -> Void

    var body: some View {
        HStack {
            Button(L("Test Connection"), systemImage: "bolt.horizontal", action: self.run)
                .disabled(self.disabledReason != nil || self.state.running)
            if self.state.running {
                ProgressView().controlSize(.small)
                Text("Testing…", bundle: .module).foregroundStyle(.secondary)
            }
        }
        if let reason = self.disabledReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        if let result = self.state.result, !self.state.running {
            MCPProbeResultView(result: result, stale: self.stale, signInHint: self.signInHint).id(MCPScrollTarget.resultID)
        }
    }
}

/// Inline outcome of a probe.
struct MCPProbeResultView: View {
    let result: MCPProbeResult
    var stale = false
    var signInHint = L("Save, then sign in from the server's page.")

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            self.headline
            self.diagnostics
            if self.stale {
                Text("Settings changed since the test.", bundle: .module).font(.caption).foregroundStyle(.orange)
            }
        }
        .opacity(self.stale ? 0.55 : 1)
    }

    private var needsSignIn: Bool {
        guard let auth = self.result.auth else { return false }
        return auth.state != .authorized
    }

    @ViewBuilder private var headline: some View {
        // Auth first: an OAuth server that isn't signed in reports not-ok with `auth` set.
        if self.needsSignIn {
            Label(L("Needs sign-in"), systemImage: "person.badge.key").foregroundStyle(.orange)
            Text(self.signInHint).font(.caption).foregroundStyle(.secondary)
        } else if !self.result.ok {
            Label(L("Couldn't connect"), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Label(self.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var diagnostics: some View {
        let all = self.result.diagnostics
        ForEach(Array(all.prefix(3).enumerated()), id: \.offset) { _, message in
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if all.count > 3 {
            Text("+\(all.count - 3) more", bundle: .module).font(.caption).foregroundStyle(.secondary)
        }
        if !self.result.ok, !all.isEmpty {
            Button(L("Copy Details"), systemImage: "doc.on.doc") { Clipboard.copy(all.joined(separator: "\n")) }
                .buttonStyle(.borderless)
        }
    }

    private var summary: String {
        var parts = [self.count(self.result.tools.count, one: L("1 tool"), many: { L("\($0) tools") })]
        if let resources = self.result.resources, resources > 0 {
            parts.append(self.count(resources, one: L("1 resource"), many: { L("\($0) resources") }))
        }
        if let prompts = self.result.prompts, prompts > 0 {
            parts.append(self.count(prompts, one: L("1 prompt"), many: { L("\($0) prompts") }))
        }
        return L("Connected · \(parts.joined(separator: ", "))")
    }

    private func count(_ value: Int, one: String, many: (Int) -> String) -> String {
        value == 1 ? one : many(value)
    }
}
