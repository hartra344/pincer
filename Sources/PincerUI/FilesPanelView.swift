import PincerKit
import SwiftUI

/// The open file and its unsaved draft for one chat. The window's inspector chrome owns these, so a draft
/// outlives the panel closing, a tab switch or a Runs/Browser switch, and reopening restores it.
@MainActor @Observable
final class FilesSession {
    var open: FilesPanelView.OpenFile? { didSet { self.refreshDirty() } }
    var draft = "" { didSet { self.refreshDirty() } }
    var editing = false { didSet { self.refreshDirty() } }
    /// Stored, and written only on a change, so typing doesn't invalidate views that watch it.
    private(set) var isDirty = false

    /// Call after the document's text changes (a save or reload).
    func refreshDirty() {
        let dirty = self.editing && self.open.map { self.draft != $0.document.content } == true
        if dirty != self.isDirty { self.isDirty = dirty }
    }
}

@MainActor
final class FilesDraftKeeper {
    private var sessions: [String: FilesSession] = [:]

    func session(for key: String) -> FilesSession {
        if let existing = self.sessions[key] { return existing }
        let made = FilesSession()
        self.sessions[key] = made
        return made
    }

    /// This chat has an edited, unsaved file.
    func isDirty(for key: String?) -> Bool { key.flatMap { self.sessions[$0] }?.isDirty == true }

    func discard(_ key: String?) {
        guard let session = key.flatMap({ self.sessions[$0] }) else { return }
        session.editing = false
        session.draft = ""
    }
}

/// The Files tab: what the agent changed, read and produced in this chat's workspace, plus a lazy
/// project tree. Every list is a finished `SessionFilesSnapshot` from Kit; this view only draws it.
struct FilesPanelView: View {
    let model: SessionFilesModel
    let state: FilesSession
    @State private var viewerID = UUID()
    @State private var searchText = ""
    @SceneStorage("pincer.files.collapsedGroups") private var collapsedRaw = ""

    struct OpenFile {
        let document: SessionFileDocument
        let size: Int?
    }

    private enum FileGroup: String { case changed, read, artifacts, project }

    private var collapsed: Set<String> { Set(self.collapsedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        Group {
            if let open = self.state.open {
                FileDetailView(document: open.document, model: self.model, size: open.size, state: self.state) {
                    self.state.open = nil
                    self.state.editing = false
                }
            } else {
                self.list
            }
        }
        .onAppear {
            self.searchText = self.model.search
            self.model.setVisible(true, viewer: self.viewerID)
        }
        .onDisappear { self.model.setVisible(false, viewer: self.viewerID) }
    }

    @ViewBuilder private var list: some View {
        let snapshot = self.model.snapshot
        VStack(spacing: 0) {
            FilesHeader(model: self.model, searchText: self.$searchText)
            Divider()
            if !self.model.loaded, self.model.error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !self.model.loaded, let error = self.model.error {
                ContentUnavailableView {
                    Label(L("Can't show files"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button(L("Try Again")) { Task { await self.model.refresh() } }
                }
            } else if snapshot.isEmpty {
                ContentUnavailableView(
                    self.searchText.isEmpty ? L("No files yet") : L("No matching files"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(self.searchText.isEmpty ? "Files the agent changes or reads in this chat show up here." : "Try a different search.", bundle: .module))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let error = self.model.error {
                            Text(error.message).font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                        }
                        self.fileGroup(.changed, title: L("Changed"), items: snapshot.changed)
                        self.fileGroup(.read, title: L("Read"), items: snapshot.read)
                        self.artifactGroup(snapshot)
                        self.projectGroup(snapshot)
                    }
                }
            }
        }
    }

    // MARK: Groups

    @ViewBuilder private func fileGroup(_ group: FileGroup, title: String, items: [SessionFileItem]) -> some View {
        if !items.isEmpty {
            self.header(group, title: title, count: items.count)
            if !self.collapsed.contains(group.rawValue) {
                ForEach(items) { item in
                    FileRow(name: item.name, detail: item.path, size: item.size, deleted: item.missing, badge: nil, isDirectory: false) {
                        self.open(path: item.path, name: item.name, size: item.size)
                    }
                }
            }
        }
    }

    @ViewBuilder private func artifactGroup(_ snapshot: SessionFilesSnapshot) -> some View {
        if !snapshot.artifacts.isEmpty {
            self.header(.artifacts, title: L("Artifacts"), count: snapshot.artifacts.count)
            if !self.collapsed.contains(FileGroup.artifacts.rawValue) {
                ForEach(snapshot.artifacts) { artifact in
                    FileRow(name: artifact.title, detail: artifact.mimeType ?? artifact.type, size: artifact.sizeBytes,
                            deleted: false, badge: nil, isDirectory: false, action: nil)
                }
                if snapshot.artifactsOmittedOversized {
                    Text("Some large artifacts aren't listed.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
    }

    @ViewBuilder private func projectGroup(_ snapshot: SessionFilesSnapshot) -> some View {
        if !snapshot.tree.isEmpty {
            self.header(.project, title: L("Project files"), count: nil)
            if !self.collapsed.contains(FileGroup.project.rawValue) {
                ForEach(snapshot.tree) { row in
                    let entry = row.entry
                    FileRow(name: entry.name, detail: nil, size: entry.size, deleted: false,
                            badge: Self.badge(entry.relevance), isDirectory: entry.isDirectory,
                            depth: row.depth, isExpanded: row.isExpanded, isLoading: row.isLoading) {
                        if entry.isDirectory {
                            self.model.toggleFolder(entry.path)
                        } else {
                            self.open(path: entry.path, name: entry.name, size: entry.size)
                        }
                    }
                }
                if snapshot.treeTruncated {
                    Text("Showing the first \(snapshot.treeEntryCount) entries", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                }
            }
        }
    }

    private func header(_ group: FileGroup, title: String, count: Int?) -> some View {
        let isCollapsed = self.collapsed.contains(group.rawValue)
        return Button {
            var next = self.collapsed
            if isCollapsed { next.remove(group.rawValue) } else { next.insert(group.rawValue) }
            self.collapsedRaw = next.sorted().joined(separator: ",")
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(title).font(.subheadline.weight(.semibold))
                if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? L("Collapsed") : L("Expanded"))
        .accessibilityAddTraits(.isHeader)
    }

    private func open(path: String, name: String, size: Int?) {
        self.state.draft = ""
        self.state.editing = false
        self.state.open = OpenFile(document: self.model.open(path: path, name: name), size: size)
    }

    private static func badge(_ relevance: SessionFileTreeEntry.Relevance?) -> String? {
        switch relevance {
        case .modified: L("Changed")
        case .read: L("Read")
        case .mixed: L("Changed")
        case nil: nil
        }
    }
}

// MARK: Header

/// Root path, search and the chips.
private struct FilesHeader: View {
    let model: SessionFilesModel
    @Binding var searchText: String

    var body: some View {
        let snapshot = self.model.snapshot
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let root = snapshot.root {
                Text(root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .contextMenu { Button(L("Copy Path"), systemImage: "doc.on.doc") { copyToPasteboard(root) } }
                    .accessibilityLabel(L("Workspace folder"))
                    .accessibilityValue(root)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Search files"), text: self.$searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !self.searchText.isEmpty {
                    Button(L("Clear Search"), systemImage: "xmark.circle.fill") { self.searchText = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: self.searchText) { _, text in self.model.setSearch(text) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    self.chip(.all, L("All"))
                    self.chip(.changed, L("Changed"), count: snapshot.counts.changed)
                    self.chip(.read, L("Read"), count: snapshot.counts.read)
                    self.chip(.artifacts, L("Artifacts"), count: snapshot.counts.artifacts)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func chip(_ filter: SessionFilesFilter, _ title: String, count: Int? = nil) -> some View {
        let selected = self.model.filter == filter
        return Button { self.model.filter = filter } label: {
            HStack(spacing: 4) {
                Text(title)
                if let count { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
                .frame(minHeight: Self.chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    #if os(iOS)
    private static let chipHeight: CGFloat = 44
    #else
    private static let chipHeight: CGFloat = 0
    #endif
}

// MARK: Rows

private struct FileRow: View {
    let name: String
    let detail: String?
    let size: Int?
    let deleted: Bool
    let badge: String?
    let isDirectory: Bool
    var depth = 0
    var isExpanded = false
    var isLoading = false
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { self.content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(self.isDirectory ? (self.isExpanded ? L("Expanded") : L("Collapsed")) : "")
                .accessibilityAddTraits(.isButton)
        } else {
            self.content.accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if self.isDirectory {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(self.isExpanded ? 90 : 0)).frame(width: 12)
                Image(systemName: "folder").foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(self.name).font(.callout).lineLimit(1).strikethrough(self.deleted)
                    .foregroundStyle(self.deleted ? .secondary : .primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if self.isLoading { ProgressView().controlSize(.mini) }
            if self.deleted {
                Text("Deleted", bundle: .module).font(.caption2).foregroundStyle(.secondary)
            } else if let badge {
                Text(badge).font(.caption2.weight(.medium)).foregroundStyle(.tint)
            }
            if let size { Text(Self.sizeText(size)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.leading, Theme.Spacing.lg + CGFloat(self.depth) * 14)
        .padding(.trailing, Theme.Spacing.lg)
        .frame(minHeight: Self.rowHeight)
        .contentShape(Rectangle())
    }

    #if os(iOS)
    private static let rowHeight: CGFloat = 44
    #else
    private static let rowHeight: CGFloat = 28
    #endif

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
