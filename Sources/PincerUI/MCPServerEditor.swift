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
                    TextField(L("Name"), text: self.$draft.name, prompt: Text("filesystem"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    self.problem(shown["name"])
                    Picker(L("Transport"), selection: self.$draft.transport) {
                        ForEach(MCPTransport.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle(L("Enabled"), isOn: self.$draft.enabled)
                } footer: {
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
                    Text("Changes stay with your other unsaved settings until you use Review & Save.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
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
                    Button(L("Apply")) {
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

    @ViewBuilder private func problem(_ text: String?) -> some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: stdio

    @ViewBuilder private func stdioSections(_ problems: [String: String]) -> some View {
        Section {
            TextField(L("Command"), text: self.$draft.command, prompt: Text("npx"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            self.problem(problems["command"])
            TextField(L("Working folder"), text: self.$draft.cwd, prompt: Text("Optional"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
        Section {
            ForEach(self.draft.args.indices, id: \.self) { index in
                HStack {
                    TextField(L("Argument"), text: self.argBinding(index))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button(L("Remove argument"), systemImage: "minus.circle") { self.draft.args.remove(at: index) }
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
                TextField(L("URL"), text: self.$draft.url, prompt: Text("https://example.com/mcp"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
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
