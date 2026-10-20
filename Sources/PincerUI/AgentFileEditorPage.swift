import PincerKit
import SwiftUI

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
                    Label(L("Couldn't Open \(self.name)"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(L("Try Again")) { Task { await editor.load() } }
                        .disabled(!self.gateway.state.isConnected)
                }
            } else if !self.gateway.state.isConnected {
                NotConnectedView(description: Text("Connect to the Gateway to open \(self.name).", bundle: .module))
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
        .confirmationDialog(L("Overwrite \(self.name) on the Gateway?"), isPresented: self.$confirmOverwrite,
                            titleVisibility: .visible) {
            Button(L("Overwrite with Mine"), role: .destructive) { Task { await editor.resolveConflictOverwrite() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("The changes made on the Gateway since you opened it will be replaced by yours.", bundle: .module)
        }
        .sheet(isPresented: self.$comparing) {
            if let conflict = editor.conflict {
                AgentFileCompareSheet(conflict: conflict)
            }
        }
    }

    @ViewBuilder private func content(_ editor: AgentFileEditorModel) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                AgentFilesReadOnlyNotice(model: self.model)
                if let conflict = editor.conflict {
                    self.conflictBanner(conflict, editor: editor)
                }
                if editor.loadedTooLarge {
                    Label(L("This file is larger than the \(AgentManagement.formatBytes(AgentManagement.maxFileBytes)) limit, so it can't be edited here."),
                          systemImage: "doc.badge.ellipsis")
                        .foregroundStyle(.orange)
                } else if editor.isNew {
                    Label(L("\(self.name) doesn't exist yet. Saving creates it."), systemImage: "doc.badge.plus")
                        .foregroundStyle(.secondary)
                }
                if let error = editor.error, editor.conflict == nil {
                    Label(error.message, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Picker(L("Mode"), selection: self.$preview) {
                        Text("Edit", bundle: .module).tag(false)
                        Text("Preview", bundle: .module).tag(true)
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
                    .padding(.horizontal, Theme.Spacing.md)
                    .disabled(editor.isSaving || !self.gateway.state.isConnected)
            }
        }
        .overlay(alignment: .bottom) {
            if self.toast != nil {
                Label(L("\(self.name) saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .bottomToastChrome()
            }
        }
    }

    private func conflictBanner(_ conflict: AgentFileConflict, editor: AgentFileEditorModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(conflict.theirsMissing
                ? "\(self.name) was removed on the Gateway since you opened it."
                : "\(self.name) changed on the Gateway since you opened it.",
                systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("Your edits are kept until you choose.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("Reload Theirs")) { Task { await editor.resolveConflictKeepTheirs() } }
                Button(L("Overwrite with Mine")) { self.confirmOverwrite = true }
                    .disabled(!editor.canEdit || editor.exceedsLimit)
                Button(L("Compare")) { self.comparing = true }
            }
            .buttonStyle(.bordered)
            .disabled(!self.gateway.state.isConnected || editor.isSaving)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private func sizeText(_ editor: AgentFileEditorModel) -> String {
        "\(AgentManagement.formatBytes(editor.byteCount)) of \(AgentManagement.formatBytes(AgentManagement.maxFileBytes))"
    }

    @ToolbarContentBuilder private func toolbar(_ editor: AgentFileEditorModel) -> some ToolbarContent {
        let canSave = editor.canSave && self.gateway.state.isConnected
        let label = editor.isNew ? "Create" : "Save"
        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(L("Revert")) { editor.revert() }
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
                Button(L("Revert"), role: .destructive) { editor.revert() }
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
            .navigationTitle(L("Compare \(self.conflict.name)"))
            .inlineNavigationBarTitle()
            .toolbar {
                SheetDoneToolbarItem { self.dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 480)
        #endif
    }

    private func column(_ title: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if blocks.isEmpty {
                Text("Nothing to preview.", bundle: .module).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                        Text(MarkdownBlock.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .quote(text):
            Text(MarkdownBlock.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, Theme.Spacing.lg)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case let .code(_, code):
            Text(code)
                .font(.callout.monospaced())
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        case .rule:
            Divider()
        case let .table(header, _, rows):
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
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
                            Label(L("Back"), systemImage: "chevron.backward")
                        }
                        .help(L("Back"))
                    }
                }
            }
            .confirmationDialog(L("Save changes to \(self.title)?"), isPresented: self.$asking, titleVisibility: .visible) {
                Button(L("Save")) {
                    Task { if await self.save() { self.pop() } }
                }
                Button(L("Don't Save"), role: .destructive) {
                    self.discard()
                    self.pop()
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text("Your changes will be lost if you don't save them.", bundle: .module)
            }
    }

    private func pop() {
        if !self.navigator.path.isEmpty { self.navigator.path.removeLast() }
    }
}
