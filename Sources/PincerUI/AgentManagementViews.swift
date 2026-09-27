import PincerKit
import SwiftUI

// Gateway Settings → Agents & Models: create, edit, duplicate and delete agents, and edit their
// workspace files (`agents.*`, `agents.files.*`). Reads work with `operator.read`; every write
// needs Full Management, so without it the pages are read-only with one notice.

// MARK: Agent list

/// The Agents section at the top of Agents & Models: every agent from `agents.list`, "New Agent",
/// and each row's page. Duplicate and Delete are also in the row's context menu.
struct AgentManagementSection: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var sheet: AgentEditorSheet.Mode?
    @State private var deleting: AgentSummary?

    var body: some View {
        let model = self.gateway.agentManagement
        let connected = self.gateway.state.isConnected
        let agents = self.gateway.agents.filter { !$0.isSystem }
        Section {
            if let report = model.deletionReport {
                AgentDeletionReportView(report: report) { model.deletionReport = nil }
            }
            AgentReadOnlyNotice(model: model)
            if agents.isEmpty {
                Text(connected ? "No agents." : "Connect to the gateway to see its agents.")
                    .foregroundStyle(.secondary)
            }
            ForEach(agents) { agent in
                NavigationLink(value: SettingsRoute.agent(agent.id)) {
                    AgentRowLabel(agent: agent, isDefault: agent.id == self.gateway.defaultAgentId,
                                  edited: model.agentEdits[agent.id] != nil
                                      || model.dirtyEditors.contains { $0.agentId == agent.id })
                }
                .contextMenu {
                    Button("Duplicate…", systemImage: "plus.square.on.square") {
                        self.sheet = .duplicate(agent)
                    }
                    .disabled(!model.canManageAgents || !connected)
                    Button("Delete…", systemImage: "trash", role: .destructive) { self.deleting = agent }
                        .disabled(!model.canManageAgents || !connected)
                }
            }
            Button {
                self.sheet = .create
            } label: {
                Label("New Agent", systemImage: "plus")
            }
            .disabled(!model.canManageAgents || !connected)
        } header: {
            Text("Agents")
        } footer: {
            Text("Each agent has its own identity, model and workspace.")
        }
        .sheet(item: self.$sheet) { mode in
            AgentEditorSheet(mode: mode) { agentId in
                self.navigator.path.append(.agent(agentId))
            }
            .environment(self.gateway)
        }
        .agentDeleteConfirmation(agent: self.$deleting, onDeleted: {})
    }
}

private struct AgentRowLabel: View {
    let agent: AgentSummary
    let isDefault: Bool
    let edited: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.agent.title)
                Text(self.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if self.edited {
                Spacer()
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Unsaved changes")
            }
        }
    }

    private var detail: String {
        var parts: [String] = [self.agent.id]
        if self.isDefault { parts.append("Default") }
        if let model = self.agent.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

private struct AgentDeletionReportView: View {
    let report: AgentManagementModel.DeletionReport
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Deleted “\(self.report.agentName)”. \(self.report.result.summary)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ForEach(self.report.result.failed, id: \.self) { failure in
                    Text("Couldn't remove \(failure.path): \(failure.reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if self.report.result.purgeFailed {
                    Text("The gateway couldn't finish removing the agent's data. Deleting again retries it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: self.dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// "Editing agents needs Full Management" (with Open Connection) or "can't manage agents".
struct AgentReadOnlyNotice: View {
    let model: AgentManagementModel
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        if !self.model.managementSupported {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Management Isn't Available").font(.callout.weight(.medium))
                    Text(AgentManagement.unsupportedMessage).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            }
        } else if !self.model.hasAdmin {
            VStack(alignment: .leading, spacing: 6) {
                Label("Editing agents needs Full Management", systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                Text("You can view agents and their files. Turn on Full Management under Connection, then approve this device on the Gateway host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Connection") { self.navigator.destination = .connection }
            }
        }
    }
}

/// The file editor's notice: needs Full Management, or the Gateway can't save files.
private struct AgentFilesReadOnlyNotice: View {
    let model: AgentManagementModel
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        if let reason = self.model.filesReadOnlyReason {
            if self.model.hasAdmin {
                Label(reason, systemImage: "lock").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Editing agents needs Full Management", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                    Text("You can read this file. Turn on Full Management under Connection, then approve this device on the Gateway host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Connection") { self.navigator.destination = .connection }
                }
            }
        }
    }
}

// MARK: Agent page

/// One agent (`SettingsRoute.agent`): identity, model, workspace, bindings, workspace files,
/// Duplicate and Delete. Edits are a draft saved with Save (`agents.update`, changed fields only).
struct AgentPage: View {
    let agentId: String
    @Environment(GatewayStore.self) private var gateway
    @Environment(SettingsNavigator.self) private var navigator
    @State private var files: AgentFileList?
    @State private var filesState = OperationState.idle
    @State private var saveState = OperationState.idle
    @State private var needsAdminAtSave = false
    @State private var duplicating: AgentSummary?
    @State private var deleting: AgentSummary?
    @State private var toast: UUID?

    private var model: AgentManagementModel { self.gateway.agentManagement }
    private var agent: AgentSummary? { self.gateway.agents.first { $0.id == self.agentId } }

    private struct FilesKey: Hashable {
        let connected: Bool
        let revision: Int
    }

    var body: some View {
        Group {
            if let agent = self.agent {
                self.form(agent)
            } else if !self.gateway.state.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to see this agent."))
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("“\(self.agentId)” isn't an agent on this gateway anymore."))
            }
        }
        .navigationTitle(self.agent?.title ?? self.agentId)
        .task(id: self.gateway.state.isConnected) {
            guard self.gateway.state.isConnected else { return }
            await self.gateway.loadModels(agentId: self.agentId)
        }
        .task(id: FilesKey(connected: self.gateway.state.isConnected,
                           revision: self.model.filesRevision[self.agentId] ?? 0)) {
            if self.gateway.state.isConnected { await self.loadFiles() }
        }
        .onAppear {
            // Back from a file: its size, date or existence may have changed.
            if self.files != nil, self.gateway.state.isConnected { Task { await self.loadFiles() } }
        }
    }

    private var original: AgentDraft? {
        guard let agent else { return nil }
        let configured = AgentManagement.configuredModel(
            agentId: agent.id, in: self.gateway.settings.hasLoaded ? self.gateway.settings.config : nil)
        return AgentDraft(agent, configuredModel: configured)
    }

    private var edit: AgentManagementModel.AgentEdit? {
        self.original.map { self.model.edit(agentId: self.agentId, original: $0) }
    }

    private var canEdit: Bool {
        self.model.canManageAgents && self.gateway.state.isConnected && !self.saveState.isRunning
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentDraft, Value>) -> Binding<Value> {
        Binding(
            get: { self.edit?.draft[keyPath: keyPath] ?? AgentDraft()[keyPath: keyPath] },
            set: { value in
                guard let edit = self.edit else { return }
                var draft = edit.draft
                draft[keyPath: keyPath] = value
                self.model.setDraft(draft, agentId: self.agentId, original: edit.original)
            }
        )
    }

    @ViewBuilder private func form(_ agent: AgentSummary) -> some View {
        let edit = self.edit ?? .init(original: AgentDraft(agent), draft: AgentDraft(agent))
        Form {
            Section {
                AgentReadOnlyNotice(model: self.model)
                if self.needsAdminAtSave, self.model.hasAdmin == false {
                    Text("Your edits are kept.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = self.saveState.error {
                    Label(error, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            self.identity(agent)
            self.modelSection(edit)
            self.workspace(agent, edit: edit)
            self.bindings(agent)
            self.filesSection(agent)
            if self.gateway.supportsToolsCatalog {
                Section {
                    NavigationLink(value: SettingsRoute.agentTools(agent.id)) {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("The tools this agent can use, and the policy that allows or denies each.")
                }
            }
            self.danger(agent)
        }
        .formStyle(.grouped)
        .toolbar { self.toolbar(edit) }
        .agentUnsavedGuard(isDirty: edit.isDirty, title: agent.name,
                           save: { await self.save() }, discard: { self.model.discardDraft(agentId: self.agentId) })
        .sheet(item: self.$duplicating) { source in
            AgentEditorSheet(mode: .duplicate(source)) { newId in
                self.navigator.path.append(.agent(newId))
            }
            .environment(self.gateway)
        }
        .agentDeleteConfirmation(agent: self.$deleting) {
            self.navigator.path.removeAll { route in
                switch route {
                case let .agent(id), let .agentFile(id, _): id == self.agentId
                default: false
                }
            }
        }
        .overlay(alignment: .bottom) {
            if self.toast != nil {
                Label("Agent saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func identity(_ agent: AgentSummary) -> some View {
        Section {
            TextField("Name", text: self.binding(\.name))
            TextField("Emoji", text: self.emojiBinding, prompt: Text("None"))
            TextField("Avatar", text: self.binding(\.avatar), prompt: Text("URL, data URI or workspace path"))
                .agentPlainTextInput()
            LabeledContent("ID") {
                Text(agent.id).font(.body.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Also written to the agent's IDENTITY.md.")
        }
        .disabled(!self.canEdit)
    }

    private var emojiBinding: Binding<String> {
        let base = self.binding(\.emoji)
        return Binding(get: { base.wrappedValue }, set: { base.wrappedValue = AgentEditorSheet.singleEmoji($0) })
    }

    private func modelSection(_ edit: AgentManagementModel.AgentEdit) -> some View {
        Section("Model") {
            AgentModelPicker(selection: self.binding(\.model), agentId: self.agentId)
                .disabled(!self.canEdit)
        }
    }

    private func workspace(_ agent: AgentSummary, edit: AgentManagementModel.AgentEdit) -> some View {
        Section {
            TextField("Folder", text: self.binding(\.workspace), prompt: Text(agent.workspace ?? "Gateway default"))
                .font(.body.monospaced())
                .agentPlainTextInput()
                .disabled(!self.canEdit)
        } header: {
            Text("Workspace")
        } footer: {
            if edit.draft.changesWorkspace(from: edit.original) {
                Label(AgentManagement.workspaceChangeWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text("The folder on the gateway host with this agent's files.")
            }
        }
    }

    @ViewBuilder private func bindings(_ agent: AgentSummary) -> some View {
        let settings = self.gateway.settings
        Section {
            if settings.hasLoaded {
                let bindings = AgentManagement.bindings(for: agent.id, in: settings.config)
                if bindings.isEmpty {
                    Text("No bindings. Messages reach this agent only when it's the default or chosen directly.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bindings) { binding in
                    Text(binding.summary).textSelection(.enabled)
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Bindings")
        } footer: {
            Text("Which channels and chats route to this agent. Bindings are managed in the config.")
        }
    }

    @ViewBuilder private func filesSection(_ agent: AgentSummary) -> some View {
        Section {
            if !self.model.filesSupported {
                Text("This gateway can't share workspace files. Update OpenClaw to edit them here.")
                    .foregroundStyle(.secondary)
            } else if let files {
                ForEach(files.files) { file in
                    NavigationLink(value: SettingsRoute.agentFile(agentId: agent.id, name: file.name)) {
                        AgentFileRow(file: file, edited: self.model.dirtyEditors.contains {
                            $0.agentId == agent.id && $0.name == file.name
                        })
                    }
                }
            } else if let error = self.filesState.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { Task { await self.loadFiles() } }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Workspace Files")
        } footer: {
            if let workspace = files?.workspace, !workspace.isEmpty {
                Text(workspace).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func danger(_ agent: AgentSummary) -> some View {
        Section {
            Button("Duplicate…", systemImage: "plus.square.on.square") { self.duplicating = agent }
                .disabled(!self.canEdit)
            Button("Delete Agent…", systemImage: "trash", role: .destructive) { self.deleting = agent }
                .disabled(!self.canEdit)
        }
    }

    @ToolbarContentBuilder private func toolbar(_ edit: AgentManagementModel.AgentEdit) -> some ToolbarContent {
        let canSave = edit.isDirty && self.canEdit && !edit.draft.trimmedName.isEmpty
        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Revert") { self.model.discardDraft(agentId: self.agentId) }
                .disabled(!edit.isDirty || self.saveState.isRunning)
            Button("Save") { Task { await self.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
        }
        #else
        ToolbarItem(placement: .confirmationAction) {
            if self.saveState.isRunning {
                ProgressView()
            } else {
                Button("Save") { Task { await self.save() } }.disabled(!canSave)
            }
        }
        if edit.isDirty {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Revert", role: .destructive) { self.model.discardDraft(agentId: self.agentId) }
                    .disabled(self.saveState.isRunning)
                Spacer()
            }
        }
        #endif
    }

    @discardableResult
    private func save() async -> Bool {
        self.saveState = .running
        do {
            try await self.model.saveDraft(agentId: self.agentId)
            self.saveState = .idle
            self.needsAdminAtSave = false
            let id = UUID()
            withAnimation { self.toast = id }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if self.toast == id { withAnimation { self.toast = nil } }
            }
            return true
        } catch {
            let classified = AgentManagementError.classify(error)
            self.needsAdminAtSave = classified == .needsAdmin
            self.saveState = classified == .needsAdmin ? .idle : .failed(classified.message)
            return false
        }
    }

    private func loadFiles() async {
        guard self.model.filesSupported else { return }
        self.filesState = .running
        do {
            self.files = try await self.model.listFiles(agentId: self.agentId)
            self.filesState = .idle
        } catch {
            self.filesState = .failed(AgentManagementError.classify(error).message)
        }
    }
}

private struct AgentFileRow: View {
    let file: AgentFileEntry
    let edited: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.file.name).font(.body.monospaced())
                Text(self.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if self.edited {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Unsaved changes")
            }
            if self.file.missing {
                Text(self.file.expectedAbsent ? "Not Created" : "Missing")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(self.file.expectedAbsent ? Color.secondary : Color.orange)
                    .background((self.file.expectedAbsent ? Color.secondary : Color.orange).opacity(0.15), in: Capsule())
            }
        }
    }

    private var detail: String {
        if self.file.missing { return "Not created yet" }
        return [
            self.file.size.map(AgentManagement.formatBytes),
            self.file.updatedAt.map { "Modified \($0.formatted(.relative(presentation: .named)))" },
        ].compactMap(\.self).joined(separator: " · ")
    }
}

// MARK: Model picker

/// "Gateway default" (no override) or a model from `models.list`.
private struct AgentModelPicker: View {
    @Binding var selection: String
    let agentId: String?
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        let catalogAgent = self.agentId ?? self.gateway.defaultAgentId
        let choices = self.gateway.modelCatalogs[catalogAgent] ?? []
        Picker("Model", selection: self.$selection) {
            Text("Gateway default").tag("")
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
                    TextField("Name", text: self.$draft.name, prompt: Text("Required"))
                    if let id = self.draft.derivedId {
                        LabeledContent("ID") { Text(id).font(.body.monospaced()) }
                    }
                    TextField("Emoji", text: Binding(get: { self.draft.emoji },
                                                     set: { self.draft.emoji = Self.singleEmoji($0) }),
                              prompt: Text("Optional"))
                    TextField("Avatar", text: self.$draft.avatar, prompt: Text("URL, data URI or workspace path"))
                        .agentPlainTextInput()
                } header: {
                    Text("Identity")
                } footer: {
                    if let error = self.draft.validationError(existing: self.gateway.agents), !self.draft.name.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("Model") {
                    AgentModelPicker(selection: self.$draft.model, agentId: nil)
                }
                Section {
                    TextField("Folder", text: self.$draft.workspace, prompt: Text("Default (created by gateway)"))
                        .font(.body.monospaced())
                        .agentPlainTextInput()
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("Leave empty to let the gateway create a new workspace for this agent.")
                }
                if case let .duplicate(source) = self.mode {
                    Section {
                        Toggle("Copy workspace files", isOn: self.$copyFiles)
                    } footer: {
                        Text("Copies \(source.name)'s workspace files (AGENTS.md, SOUL.md…) into the new workspace. \(AgentManagement.bindingsNotCopiedNote)")
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { self.dismiss() }.disabled(self.state.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if self.state.isRunning {
                        ProgressView()
                    } else {
                        Button(self.isDuplicate ? "Duplicate" : "Create") { Task { await self.submit() } }
                            .disabled(self.draft.validationError(existing: self.gateway.agents) != nil
                                || !self.gateway.state.isConnected || !self.model.canManageAgents)
                    }
                }
            }
            .alert("Some Files Weren't Copied", isPresented: Binding(
                get: { self.copyFailures != nil }, set: { if !$0 { self.finish() } }
            )) {
                Button("OK") { self.finish() }
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
    @State private var deleting = false

    func body(content: Content) -> some View {
        let target = self.agent
        let bindingCount = target.map { self.bindingCount($0.id) }
        content
            .confirmationDialog("Delete “\(target?.name ?? "")”?", isPresented: Binding(
                get: { self.agent != nil }, set: { if !$0 { self.agent = nil } }
            ), titleVisibility: .visible, presenting: target) { agent in
                Button("Delete Agent", role: .destructive) { self.delete(agent, deleteFiles: false) }
                Button("Delete and Move Files to Trash", role: .destructive) { self.delete(agent, deleteFiles: true) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(AgentManagement.deleteMessage(agentName: target?.name ?? "", bindingCount: bindingCount ?? nil))
            }
            .alert("Couldn't Delete Agent", isPresented: Binding(
                get: { self.error != nil }, set: { if !$0 { self.error = nil } }
            )) {
                Button("OK", role: .cancel) { self.error = nil }
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

// MARK: File editor

/// One workspace file (`SettingsRoute.agentFile`): a monospaced editor with Markdown preview,
/// saved with the loaded version's hash; a conflict offers Reload Theirs, Overwrite with Mine and Compare.
struct AgentFileEditorPage: View {
    let agentId: String
    let name: String
    @Environment(GatewayStore.self) private var gateway
    @State private var preview = false
    @State private var confirmOverwrite = false
    @State private var comparing = false
    @State private var toast: UUID?

    private var model: AgentManagementModel { self.gateway.agentManagement }
    private var editor: AgentFileEditorModel { self.model.editor(agentId: self.agentId, name: self.name) }

    var body: some View {
        let editor = self.editor
        Group {
            if editor.hasLoaded {
                self.content(editor)
            } else if let error = editor.loadState.error {
                ContentUnavailableView {
                    Label("Couldn't Open \(self.name)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await editor.load() } }
                        .disabled(!self.gateway.state.isConnected)
                }
            } else if !self.gateway.state.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                       description: Text("Connect to the gateway to open \(self.name)."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(editor.isDirty ? "\(self.name) — Edited" : self.name)
        .toolbar { self.toolbar(editor) }
        .agentUnsavedGuard(isDirty: editor.isDirty, title: self.name,
                           save: { await editor.save() }, discard: { editor.revert() })
        .task(id: self.gateway.state.isConnected) {
            if self.gateway.state.isConnected { await editor.loadIfNeeded() }
        }
        .onDisappear { self.model.closeEditor(editor) }
        .onChange(of: editor.lastSave) { self.showToast() }
        .confirmationDialog("Overwrite \(self.name) on the gateway?", isPresented: self.$confirmOverwrite,
                            titleVisibility: .visible) {
            Button("Overwrite with Mine", role: .destructive) { Task { await editor.resolveConflictOverwrite() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The changes made on the gateway since you opened it will be replaced by yours.")
        }
        .sheet(isPresented: self.$comparing) {
            if let conflict = editor.conflict {
                AgentFileCompareSheet(conflict: conflict)
            }
        }
    }

    @ViewBuilder private func content(_ editor: AgentFileEditorModel) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                AgentFilesReadOnlyNotice(model: self.model)
                if let conflict = editor.conflict {
                    self.conflictBanner(conflict, editor: editor)
                }
                if editor.loadedTooLarge {
                    Label("This file is larger than the \(AgentManagement.formatBytes(AgentManagement.maxFileBytes)) limit, so it can't be edited here.",
                          systemImage: "doc.badge.ellipsis")
                        .foregroundStyle(.orange)
                } else if editor.isNew {
                    Label("\(self.name) doesn't exist yet. Saving creates it.", systemImage: "doc.badge.plus")
                        .foregroundStyle(.secondary)
                }
                if let error = editor.error, editor.conflict == nil {
                    Label(error.message, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Picker("Mode", selection: self.$preview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer()
                    Text(self.sizeText(editor))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(editor.exceedsLimit ? .red : .secondary)
                }
                if editor.exceedsLimit {
                    Text(AgentManagement.tooLargeMessage(bytes: editor.byteCount))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            Divider()
            if self.preview {
                ScrollView {
                    AgentMarkdownPreview(text: editor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if !editor.canEdit {
                ScrollView {
                    Text(editor.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .agentPlainTextInput()
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .disabled(editor.isSaving || !self.gateway.state.isConnected)
            }
        }
        .overlay(alignment: .bottom) {
            if self.toast != nil {
                Label("\(self.name) saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func conflictBanner(_ conflict: AgentFileConflict, editor: AgentFileEditorModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(conflict.theirsMissing
                ? "\(self.name) was removed on the gateway since you opened it."
                : "\(self.name) changed on the gateway since you opened it.",
                systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("Your edits are kept until you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Reload Theirs") { Task { await editor.resolveConflictKeepTheirs() } }
                Button("Overwrite with Mine") { self.confirmOverwrite = true }
                    .disabled(!editor.canEdit || editor.exceedsLimit)
                Button("Compare") { self.comparing = true }
            }
            .buttonStyle(.bordered)
            .disabled(!self.gateway.state.isConnected || editor.isSaving)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sizeText(_ editor: AgentFileEditorModel) -> String {
        "\(AgentManagement.formatBytes(editor.byteCount)) of \(AgentManagement.formatBytes(AgentManagement.maxFileBytes))"
    }

    @ToolbarContentBuilder private func toolbar(_ editor: AgentFileEditorModel) -> some ToolbarContent {
        let canSave = editor.canSave && self.gateway.state.isConnected
        let label = editor.isNew ? "Create" : "Save"
        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Revert") { editor.revert() }
                .disabled(!editor.isDirty || editor.isSaving)
            Button(label) { Task { await editor.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
        }
        #else
        ToolbarItem(placement: .confirmationAction) {
            if editor.isSaving {
                ProgressView()
            } else {
                Button(label) { Task { await editor.save() } }.disabled(!canSave)
            }
        }
        if editor.isDirty {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Revert", role: .destructive) { editor.revert() }
                    .disabled(editor.isSaving)
                Spacer()
            }
        }
        #endif
    }

    private func showToast() {
        let id = UUID()
        withAnimation { self.toast = id }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toast == id { withAnimation { self.toast = nil } }
        }
    }
}

/// Theirs (on the gateway) and yours, read-only.
private struct AgentFileCompareSheet: View {
    let conflict: AgentFileConflict
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                HStack(spacing: 0) {
                    self.column("On the Gateway", self.conflict.theirs)
                    Divider()
                    self.column("Yours", self.conflict.yours)
                }
                #else
                VStack(spacing: 0) {
                    self.column("On the Gateway", self.conflict.theirs)
                    Divider()
                    self.column("Yours", self.conflict.yours)
                }
                #endif
            }
            .navigationTitle("Compare \(self.conflict.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { self.dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }

    private func column(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).padding([.horizontal, .top])
            ScrollView {
                Text(text ?? "(The file doesn't exist on the gateway.)")
                    .font(.body.monospaced())
                    .foregroundStyle(text == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A basic Markdown rendering: headings, lists, quotes, code and paragraphs.
private struct AgentMarkdownPreview: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlock.parse(self.text)
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                Text("Nothing to preview.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                self.view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(MarkdownBlock.inline(MarkdownBlock.softBreaks(text)))
        case let .heading(level, text):
            Text(MarkdownBlock.inline(text))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .quote(text):
            Text(MarkdownBlock.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(_, code):
            Text(code)
                .font(.callout.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        case let .table(header, _, rows):
            VStack(alignment: .leading, spacing: 2) {
                Text(header.joined(separator: " | ")).bold()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.joined(separator: " | "))
                }
            }
            .font(.callout.monospaced())
        }
    }
}

// MARK: Unsaved-changes guard

extension View {
    /// While `isDirty`, Back asks "Save changes to <title>?" [Save] [Don't Save] [Cancel] and
    /// swipe-back is off.
    func agentUnsavedGuard(isDirty: Bool, title: String, save: @escaping () async -> Bool,
                           discard: @escaping () -> Void) -> some View
    {
        self.modifier(AgentUnsavedGuard(isDirty: isDirty, title: title, save: save, discard: discard))
    }

    func agentPlainTextInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

private struct AgentUnsavedGuard: ViewModifier {
    let isDirty: Bool
    let title: String
    let save: () async -> Bool
    let discard: () -> Void
    @Environment(SettingsNavigator.self) private var navigator
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(self.isDirty)
            .toolbar {
                if self.isDirty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            self.asking = true
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .help("Back")
                    }
                }
            }
            .confirmationDialog("Save changes to \(self.title)?", isPresented: self.$asking, titleVisibility: .visible) {
                Button("Save") {
                    Task { if await self.save() { self.pop() } }
                }
                Button("Don't Save", role: .destructive) {
                    self.discard()
                    self.pop()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your changes will be lost if you don't save them.")
            }
    }

    private func pop() {
        if !self.navigator.path.isEmpty { self.navigator.path.removeLast() }
    }
}
