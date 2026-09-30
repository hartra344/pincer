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
    @State private var revealed: Set<Int> = []
    @State private var advancedOpen: Bool
    @State private var probe = MCPProbeState()
    private let initial: MCPServerDraft

    init(draft: MCPServerDraft) {
        self._draft = State(initialValue: draft)
        self.initial = draft
        self._advancedOpen = State(initialValue: Self.hasAdvanced(draft))
    }

    /// Open the Advanced group up front when the server already uses any of it.
    private static func hasAdvanced(_ draft: MCPServerDraft) -> Bool {
        let text = [draft.connectionTimeoutMs, draft.requestTimeoutMs, draft.clientCert, draft.clientKey,
                    draft.oauthScope, draft.oauthAuthProfileId, draft.oauthIdentity]
        return text.contains { !$0.isEmpty } || !draft.toolInclude.isEmpty || !draft.toolExclude.isEmpty || !draft.sslVerify
    }

    private var isNew: Bool { self.initial.originalName == nil }

    var body: some View {
        let existing = Set(self.gateway.mcp.servers.map(\.name)).subtracting([self.initial.originalName].compactMap { $0 })
        let problems = self.draft.problems(existingNames: existing)
        let shown = self.showProblems || self.draft != self.initial ? problems : [:]
        NavigationStack {
            Form {
                Section {
                    self.field(L("Name"), text: self.$draft.name, prompt: "filesystem")
                    self.problem(shown["name"])
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
                    self.testSection(problems.isEmpty)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Changes stay with your other unsaved settings until you use Review & Save. Other settings for this server are kept. Edit them in Raw Config.", bundle: .module)
                }
            }
            .formStyle(.grouped)
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
                        }
                    }
                    .disabled(!self.isNew && self.draft == self.initial)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 620)
        #endif
    }

    /// A labeled text field, so the label stays visible once there's text.
    private func field(_ title: String, text: Binding<String>, prompt: LocalizedStringKey, url: Bool = false, number: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt, bundle: .module))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : (number ? .numberPad : .default))
                #endif
        }
    }

    @ViewBuilder private func problem(_ text: String?) -> some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: stdio

    @ViewBuilder private func stdioSections(_ problems: [String: String]) -> some View {
        Section {
            self.field(L("Command"), text: self.$draft.command, prompt: "npx")
            self.problem(problems["command"])
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
                self.field(L("URL"), text: self.$draft.url, prompt: "https://…", url: true)
            }
            self.problem(problems["url"])
            Toggle(L("Requires OAuth sign-in"), isOn: self.$draft.usesOAuth)
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
                        TextField(keyLabel, text: $row.key)
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
                        SecureField(L("Value"), text: $row.value)
                    }
                    self.problem(problems["\(prefix).\(row.key)"])
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

extension MCPServerEditor {
    fileprivate func advancedSection(_ problems: [String: String]) -> some View {
        Section {
            DisclosureGroup(isExpanded: self.$advancedOpen) {
                self.timeoutRows(problems)
                self.toolFilterRows()
                if self.draft.transport.isRemote {
                    self.tlsRows()
                    if self.draft.usesOAuth { self.oauthRows(problems) }
                }
            } label: {
                Text("Advanced", bundle: .module)
            }
        }
    }

    private func timeoutRows(_ problems: [String: String]) -> some View {
        Group {
            self.field(L("Connection timeout (ms)"), text: self.$draft.connectionTimeoutMs, prompt: "30000", number: true)
            self.problem(problems["connectionTimeoutMs"])
            self.field(L("Request timeout (ms)"), text: self.$draft.requestTimeoutMs, prompt: "60000", number: true)
            self.problem(problems["requestTimeoutMs"])
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
                    TextField(L("Pattern"), text: Self.patternBinding(rows, index), prompt: Text("search_*", bundle: .module))
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
                Label(L("Turning this off makes the connection easy to intercept."), systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.orange)
            }
            self.field(L("Client certificate"), text: self.$draft.clientCert, prompt: "Path on the Gateway host", url: false)
            self.field(L("Client key"), text: self.$draft.clientKey, prompt: "Path on the Gateway host", url: false)
        }
    }

    private func oauthRows(_ problems: [String: String]) -> some View {
        Group {
            Picker(L("Sign-in"), selection: self.$draft.oauthIdentity) {
                Text("Default (shared)", bundle: .module).tag("")
                Text("Shared by everyone", bundle: .module).tag("shared")
                Text("Each person signs in", bundle: .module).tag("per-requester")
            }
            self.problem(problems["oauthIdentity"])
            self.field(L("Scope"), text: self.$draft.oauthScope, prompt: "Default")
            self.field(L("Auth profile"), text: self.$draft.oauthAuthProfileId, prompt: "Optional")
            self.problem(problems["oauthAuthProfileId"])
        }
    }
}

// MARK: Test connection

/// The state of one Test Connection run in the editor.
struct MCPProbeState {
    var running = false
    var result: MCPProbeResult?
}

extension MCPServerEditor {
    fileprivate func testSection(_ valid: Bool) -> some View {
        Section {
            HStack {
                Button(L("Test Connection"), systemImage: "bolt.horizontal") { self.runProbe() }
                    .disabled(!valid || self.probe.running)
                if self.probe.running { ProgressView().controlSize(.small) }
            }
            if let result = self.probe.result { MCPProbeResultView(result: result) }
        } footer: {
            Text("Tests the settings above without saving them.", bundle: .module)
        }
    }

    private func runProbe() {
        let draft = self.draft
        self.probe.running = true
        self.probe.result = nil
        Task {
            let result = await self.gateway.mcp.probe(name: draft.name, draft: draft)
            self.probe = MCPProbeState(running: false, result: result)
        }
    }
}

/// Inline outcome of a probe: "Connected · 12 tools" or the failure diagnostics.
struct MCPProbeResultView: View {
    let result: MCPProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if self.result.ok {
                Label(self.summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(L("Couldn't connect"), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(Array(self.result.diagnostics.enumerated()), id: \.offset) { _, message in
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        switch self.result.tools.count {
        case 1: L("Connected · 1 tool")
        case let count: L("Connected · \(count) tools")
        }
    }
}
