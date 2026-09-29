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
    private let initial: MCPServerDraft

    init(draft: MCPServerDraft) {
        self._draft = State(initialValue: draft)
        self.initial = draft
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
    private func field(_ title: String, text: Binding<String>, prompt: LocalizedStringKey, url: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt, bundle: .module))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
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
