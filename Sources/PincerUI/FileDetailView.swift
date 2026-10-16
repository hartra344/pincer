import PincerKit
import SwiftUI

/// One open file, pushed inside the Files tab. Text is laid out lazily line by line (split off-main), an
/// image is decoded by Kit's loader off-main, and editing is offered only when Kit says the file is editable.
struct FileDetailView: View {
    let document: SessionFileDocument
    let model: SessionFilesModel
    let size: Int?
    let state: FilesSession
    let back: () -> Void

    @Environment(GatewayStore.self) private var gateway
    @Environment(\.chatPaneIsActive) private var paneIsActive
    @State private var lines: [Line] = []
    @State private var image: CGImage?
    @State private var message: String?
    @State private var conflict = false
    @State private var confirmOverwrite = false
    @State private var confirmDiscard = false

    private nonisolated static let maxLineLength = 4000

    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private var isDirty: Bool { self.state.isDirty }
    private var editing: Bool { self.state.editing }
    private var draft: Binding<String> { Binding(get: { self.state.draft }, set: { self.state.draft = $0 }) }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            if let message = self.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                Divider()
            }
            self.content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: self.document.content) {
            self.state.refreshDirty()
            await self.splitLines()
        }
        .task(id: self.document.image?.cacheKey) {
            guard let ref = self.document.image else { return }
            self.image = await self.gateway.images.fullImage(ref, sessionKey: self.model.sessionKey)
        }
        .confirmationDialog(L("Discard changes?"), isPresented: self.$confirmDiscard, titleVisibility: .visible) {
            Button(L("Discard Changes"), role: .destructive) { self.state.editing = false; self.back() }
            Button(L("Keep Editing"), role: .cancel) {}
        } message: {
            Text("Your edits to this file haven't been saved.", bundle: .module)
        }
        .sheet(isPresented: self.$conflict) { self.conflictSheet }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(L("Back to Files"), systemImage: "chevron.left") {
                if self.isDirty { self.confirmDiscard = true } else { self.back() }
            }
            .labelStyle(.iconOnly)
            Text(self.document.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.sm)
            if self.document.isSaving { ProgressView().controlSize(.small) }
            if self.document.isEditable {
                if self.editing {
                    Button(L("Revert")) { self.state.draft = self.document.content; self.message = nil }
                        .disabled(!self.isDirty || self.document.isSaving)
                    Button(L("Save")) { self.save() }
                        .keyboardShortcut(self.paneIsActive ? ShortcutStore.shared.activeCombo(for: .saveFile)?.keyboardShortcut : nil)
                        .disabled(!self.isDirty || self.document.isSaving)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Edit")) { self.state.draft = self.document.content; self.message = nil; self.state.editing = true }
                }
            }
            Button(L("Copy Path"), systemImage: "doc.on.doc") { copyToPasteboard(self.document.path) }
                .labelStyle(.iconOnly)
                .help(L("Copy Path"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch self.document.phase {
        case .loading:
            ProgressView()
        case .text:
            if self.editing {
                TextEditor(text: self.draft)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.sm)
                    .accessibilityLabel(L("File contents"))
            } else {
                self.reader
            }
        case .image:
            if let image = self.image {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .padding(Theme.Spacing.lg)
                    .accessibilityLabel(self.document.name)
                    .accessibilityAddTraits(.isImage)
            } else {
                ProgressView()
            }
        case .unsupported:
            ContentUnavailableView {
                Label(L("Pincer can't preview this file"), systemImage: "doc")
            } description: {
                self.sizeDescription
            } actions: {
                Button(L("Copy Path")) { copyToPasteboard(self.document.path) }
            }
        case let .tooLarge(size):
            ContentUnavailableView {
                Label(L("This file is too large to preview"), systemImage: "doc.badge.ellipsis")
            } description: {
                if let bytes = size ?? self.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                }
            } actions: {
                Button(L("Copy Path")) { copyToPasteboard(self.document.path) }
            }
        case .missing:
            ContentUnavailableView {
                Label(L("This file no longer exists on the gateway"), systemImage: "questionmark.folder")
            } actions: {
                Button(L("Copy Path")) { copyToPasteboard(self.document.path) }
            }
        case let .failed(text):
            ContentUnavailableView {
                Label(L("Can't open this file"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(text)
            } actions: {
                Button(L("Try Again")) { Task { await self.document.reload() } }
            }
        }
    }

    @ViewBuilder private var sizeDescription: some View {
        if let size = self.size {
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
    }

    private var reader: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(self.lines) { line in
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .textSelection(.enabled)
            .padding(Theme.Spacing.lg)
        }
        .accessibilityLabel(L("File contents"))
    }

    private func splitLines() async {
        let text = self.document.content
        guard self.document.phase == .text else { self.lines = []; return }
        let split = await Task.detached(priority: .userInitiated) {
            var rows: [Line] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // A minified one-line file would otherwise be a single enormous Text.
                var rest = Substring(line)
                repeat {
                    let chunk = rest.prefix(Self.maxLineLength)
                    rows.append(Line(id: rows.count, text: String(chunk)))
                    rest = rest.dropFirst(chunk.count)
                } while !rest.isEmpty
            }
            return rows
        }.value
        self.lines = split
    }

    // MARK: Saving

    private func save() {
        self.message = nil
        let text = self.state.draft
        Task { self.apply(await self.document.save(text)) }
    }

    private func apply(_ result: SessionFileDocument.SaveResult) {
        switch result {
        case .saved: self.state.editing = false
        case .conflict: self.conflict = true
        case .missing: self.message = L("This file no longer exists on the gateway.")
        case .tooLarge: self.message = L("This file is too large to preview or edit.")
        case let .failed(text): self.message = text
        }
    }

    private var conflictSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("This file changed since you opened it", bundle: .module).font(.headline)
            Text("Reload to see the new version and lose your edits, or overwrite it with yours.", bundle: .module)
                .foregroundStyle(.secondary)
            HStack {
                Button(L("Cancel"), role: .cancel) { self.conflict = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Reload")) {
                    self.conflict = false
                    Task {
                        await self.document.reload()
                        self.state.draft = self.document.content
                    }
                }
                Button(L("Overwrite…"), role: .destructive) { self.confirmOverwrite = true }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(minWidth: 320)
        .presentationDetents([.medium])
        .confirmationDialog(L("Overwrite the file on the gateway?"), isPresented: self.$confirmOverwrite, titleVisibility: .visible) {
            Button(L("Overwrite"), role: .destructive) {
                self.conflict = false
                let text = self.state.draft
                Task { self.apply(await self.document.overwrite(text)) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("The other changes to this file will be lost.", bundle: .module)
        }
    }
}
