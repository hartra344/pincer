import PincerKit
import SwiftUI

// MARK: Model picker

/// "Gateway default" (no override) or a model from `models.list`.
struct AgentModelPicker: View {
    @Binding var selection: String
    let agentId: String?
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let catalogAgent = self.agentId ?? self.gateway.defaultAgentId
        let choices = self.gateway.modelCatalogs[catalogAgent] ?? []
        Picker(L("Model"), selection: self.$selection) {
            Text("Gateway default", bundle: .module).tag("")
            if !self.selection.isEmpty, !choices.contains(where: { $0.ref == self.selection }) {
                Text(self.selection).tag(self.selection)
            }
            ForEach(choices.filter { $0.manualSelectionAllowed || $0.ref == self.selection }) { choice in
                Text(choice.isAvailable ? choice.displayName : "\(choice.displayName) (unavailable)")
                    .tag(choice.ref)
            }
        }
        .pickerStyle(.menu)
        .task { await self.gateway.loadModels(agentId: catalogAgent) }
    }
}

// MARK: Create / duplicate sheet

/// New Agent and Duplicate: name (with the id it gets), emoji, avatar, model and workspace.
struct AgentEditorSheet: View {
    enum Mode: Identifiable, Hashable {
        case create
        case duplicate(AgentSummary)

        var id: String {
            switch self {
            case .create: "create"
            case let .duplicate(agent): "duplicate-\(agent.id)"
            }
        }
    }

    let mode: Mode
    /// Called with the new agent's id after the sheet closes.
    let created: (String) -> Void
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AgentDraft()
    @State private var copyFiles = true
    @State private var state = OperationState.idle
    @State private var prepared = false
    @State private var copyFailures: (agentId: String, lines: [String])?

    private var model: AgentManagementModel { self.gateway.agentManagement }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Name"), text: self.$draft.name, prompt: Text("Required", bundle: .module))
                    if let id = self.draft.derivedId {
                        LabeledContent(L("ID")) { Text(id).font(.body.monospaced()) }
                    }
                    TextField(L("Emoji"), text: Binding(get: { self.draft.emoji },
                                                     set: { self.draft.emoji = Self.singleEmoji($0) }),
                              prompt: Text("Optional", bundle: .module))
                    TextField(L("Avatar"), text: self.$draft.avatar, prompt: Text("URL, data URI or workspace path", bundle: .module))
                        .agentPlainTextInput()
                } header: {
                    Text("Identity", bundle: .module)
                } footer: {
                    if self.isDuplicate {
                        Text(AgentManagement.duplicateAvatarNote)
                    }
                    if let error = self.draft.validationError(existing: self.gateway.agents), !self.draft.name.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section(L("Model")) {
                    AgentModelPicker(selection: self.$draft.model, agentId: nil)
                }
                Section {
                    TextField(L("Folder"), text: self.$draft.workspace, prompt: Text("Default (created by Gateway)", bundle: .module))
                        .font(.body.monospaced())
                        .agentPlainTextInput()
                } header: {
                    Text("Workspace", bundle: .module)
                } footer: {
                    Text("Leave empty to let the Gateway create a new workspace for this agent.", bundle: .module)
                }
                if case let .duplicate(source) = self.mode {
                    Section {
                        Toggle(L("Copy workspace files"), isOn: self.$copyFiles)
                    } footer: {
                        Text("Copies \(source.name)'s workspace files (AGENTS.md, SOUL.md…) into the new workspace. \(AgentManagement.bindingsNotCopiedNote)", bundle: .module)
                    }
                }
                if let error = self.state.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(self.state.isRunning)
            .navigationTitle(self.title)
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { self.dismiss() }.disabled(self.state.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if self.state.isRunning {
                        ProgressView()
                    } else {
                        Button(self.isDuplicate ? L("Duplicate") : L("Create")) { Task { await self.submit() } }
                            .disabled(self.draft.validationError(existing: self.gateway.agents) != nil
                                || !self.gateway.state.isConnected || !self.model.canManageAgents)
                    }
                }
            }
            .alert(L("Some Files Weren't Copied"), isPresented: Binding(
                get: { self.copyFailures != nil }, set: { if !$0 { self.finish() } }
            )) {
                Button(L("OK")) { self.finish() }
            } message: {
                Text((self.copyFailures?.lines ?? []).joined(separator: "\n"))
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 440)
        #endif
        .interactiveDismissDisabled(self.state.isRunning)
        .onAppear(perform: self.prepare)
    }

    private var isDuplicate: Bool {
        if case .duplicate = self.mode { return true }
        return false
    }

    private var title: String {
        switch self.mode {
        case .create: "New Agent"
        case let .duplicate(agent): "Duplicate “\(agent.name)”"
        }
    }

    private func prepare() {
        guard !self.prepared else { return }
        self.prepared = true
        if case let .duplicate(source) = self.mode {
            var draft = AgentDraft.duplicate(of: source, existing: self.gateway.agents)
            let settings = self.gateway.settings
            if let configured = AgentManagement.configuredModel(agentId: source.id, in: settings.hasLoaded ? settings.config : nil) {
                draft.model = configured
            }
            self.draft = draft
        }
    }

    private func submit() async {
        self.state = .running
        do {
            switch self.mode {
            case .create:
                let agentId = try await self.model.create(self.draft)
                self.state = .idle
                self.close(with: agentId)
            case let .duplicate(source):
                let result = try await self.model.duplicate(sourceId: source.id, draft: self.draft, copyFiles: self.copyFiles)
                self.state = .idle
                if result.failedFiles.isEmpty {
                    self.close(with: result.agentId)
                } else {
                    self.copyFailures = (result.agentId, result.failureLines)
                }
            }
        } catch {
            self.state = .failed(AgentManagementError.classify(error).message)
        }
    }

    private func finish() {
        guard let failures = self.copyFailures else { return }
        self.copyFailures = nil
        self.close(with: failures.agentId)
    }

    private func close(with agentId: String) {
        self.dismiss()
        self.created(agentId)
    }

    /// The first character when it's an emoji (the Gateway shows one), else the text as typed
    /// while it's still being entered.
    static func singleEmoji(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "" }
        return first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF })
            ? String(first) : trimmed
    }
}

// MARK: Delete

extension View {
    /// "Delete “Name”?" with Delete Agent (files kept) and Delete and Move Files to Trash. Always
    /// sends `deleteFiles` (the Gateway would otherwise trash them).
    func agentDeleteConfirmation(agent: Binding<AgentSummary?>, onDeleted: @escaping () -> Void) -> some View {
        self.modifier(AgentDeleteConfirmation(agent: agent, onDeleted: onDeleted))
    }
}

private struct AgentDeleteConfirmation: ViewModifier {
    @Binding var agent: AgentSummary?
    let onDeleted: () -> Void
    @Environment(GatewayStore.self) private var gateway
    @State private var error: String?

    func body(content: Content) -> some View {
        let target = self.agent
        let bindingCount = target.map { self.bindingCount($0.id) }
        content
            .confirmationDialog("Delete “\(target?.name ?? "")”?", isPresented: Binding(
                get: { self.agent != nil }, set: { if !$0 { self.agent = nil } }
            ), titleVisibility: .visible, presenting: target) { agent in
                Button(L("Delete Agent"), role: .destructive) { self.delete(agent, deleteFiles: false) }
                Button(L("Delete and Move Files to Trash"), role: .destructive) { self.delete(agent, deleteFiles: true) }
                Button(L("Cancel"), role: .cancel) {}
            } message: { _ in
                Text(AgentManagement.deleteMessage(agentName: target?.name ?? "", bindingCount: bindingCount ?? nil))
            }
            .alert(L("Couldn't Delete Agent"), isPresented: Binding(
                get: { self.error != nil }, set: { if !$0 { self.error = nil } }
            )) {
                Button(L("OK"), role: .cancel) { self.error = nil }
            } message: {
                Text(self.error ?? "")
            }
    }

    private func bindingCount(_ agentId: String) -> Int? {
        let settings = self.gateway.settings
        return settings.hasLoaded ? AgentManagement.bindings(for: agentId, in: settings.config).count : nil
    }

    private func delete(_ agent: AgentSummary, deleteFiles: Bool) {
        let model = self.gateway.agentManagement
        Task {
            do {
                let result = try await model.delete(agentId: agent.id, deleteFiles: deleteFiles)
                model.deletionReport = .init(agentName: agent.name, result: result)
                self.onDeleted()
            } catch {
                self.error = AgentManagementError.classify(error).message
            }
        }
    }
}

