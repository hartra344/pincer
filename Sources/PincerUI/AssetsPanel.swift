import PincerKit
import SwiftUI
import UniformTypeIdentifiers

/// Fetches an asset's bytes and hands them to Quick Look or the save panel. One per panel; shared by the
/// Assets panel and the Files tab's artifact rows.
@MainActor @Observable
final class AssetFileActions {
    var quickLookURL: URL?
    var exporting: ExportedFile?
    var error: String?
    /// The asset being fetched, for its row's spinner.
    private(set) var busy: String?

    func open(_ asset: SessionAsset, gateway: GatewayStore, sessionKey: String) {
        self.run(asset, gateway: gateway, sessionKey: sessionKey) { [weak self] data in
            let name = asset.name, mimeType = asset.mimeType
            let url = await Task.detached(priority: .userInitiated) {
                try? FilePreviewFiles.write(data, name: name, mimeType: mimeType)
            }.value
            guard let url else { return false }
            self?.quickLookURL = url
            return true
        }
    }

    func save(_ asset: SessionAsset, gateway: GatewayStore, sessionKey: String) {
        self.run(asset, gateway: gateway, sessionKey: sessionKey) { [weak self] data in
            self?.exporting = ExportedFile(name: Self.fileName(for: asset), data: data)
            return true
        }
    }

    private func run(_ asset: SessionAsset, gateway: GatewayStore, sessionKey: String,
                     then finish: @escaping @MainActor (Data) async -> Bool) {
        guard self.busy == nil else { return }
        self.busy = asset.id
        Task {
            defer { self.busy = nil }
            let data: Data? = switch asset.content {
            case let .image(ref): await gateway.images.data(for: ref, sessionKey: sessionKey)
            case let .file(ref): await gateway.files.data(for: ref, sessionKey: sessionKey)
            }
            guard let data, await finish(data) else {
                self.error = String(format: L("“%@” couldn't be downloaded."), asset.name)
                return
            }
        }
    }

    /// An image's alt text rarely has an extension; the save panel needs one.
    static func fileName(for asset: SessionAsset) -> String {
        guard (asset.name as NSString).pathExtension.isEmpty,
              let ext = asset.mimeType.flatMap({ UTType(mimeType: $0)?.preferredFilenameExtension })
        else { return asset.name }
        return "\(asset.name).\(ext)"
    }
}

/// Quick Look, the save panel and the failure alert for `AssetFileActions`.
struct AssetFileActionsPresenter: ViewModifier {
    @Bindable var actions: AssetFileActions

    func body(content: Content) -> some View {
        content
            .modifier(ChatQuickLookLifecycle(url: self.$actions.quickLookURL))
            .fileExporter(
                isPresented: Binding(get: { self.actions.exporting != nil }, set: { if !$0 { self.actions.exporting = nil } }),
                document: self.actions.exporting,
                contentType: self.actions.exporting?.contentType ?? .data,
                defaultFilename: self.actions.exporting?.name) { result in
                    self.actions.exporting = nil
                    if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
                        self.actions.error = String(format: L("The file couldn't be saved: %@"), error.localizedDescription)
                    }
                }
            .alert(L("Couldn't Get File"), isPresented: Binding(get: { self.actions.error != nil }, set: { if !$0 { self.actions.error = nil } })) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(self.actions.error ?? "")
            }
    }
}

/// Every file and image the agent sent in this chat, newest first: open, save or find it in the chat.
struct AssetsPanel: View {
    @Environment(GatewayStore.self) private var gateway
    @Environment(AppModel.self) private var app
    @Environment(\.chatWindowKey) private var windowKey
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        if let key = self.windowKey ?? self.gateway.focusedKey {
            AssetsList(model: self.gateway.assetsModel(for: key), showInChat: { self.showInChat($0, key: key) })
                .id(key)
        } else {
            ContentUnavailableView(L("No chat selected"), systemImage: "bubble.left.and.bubble.right")
                .panelFill()
        }
    }

    private func showInChat(_ messageId: String, key: String) {
        self.app.jump(to: messageId, in: Notifier.Target(gatewayId: self.gateway.id, sessionKey: key))
        #if os(iOS)
        // Compact iPhone shows the panel as a sheet over the chat.
        if self.sizeClass == .compact { self.dismiss() }
        #endif
    }
}

private struct AssetsList: View {
    @Bindable var model: SessionAssetsModel
    let showInChat: (String) -> Void
    @Environment(GatewayStore.self) private var gateway
    @State private var viewerID = UUID()
    @State private var actions = AssetFileActions()

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            if !self.model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.model.shown.isEmpty {
                ContentUnavailableView(
                    self.model.assets.isEmpty ? L("No files yet") : L("No matching files"),
                    systemImage: "tray",
                    description: Text(self.model.assets.isEmpty
                        ? "PDFs, images and other files the agent sends in this chat show up here."
                        : "Try a different search.", bundle: .module))
                .panelFill()
            } else {
                List(self.model.shown) { asset in
                    AssetRow(asset: asset, sessionKey: self.model.sessionKey, isBusy: self.actions.busy == asset.id,
                             open: { self.actions.open(asset, gateway: self.gateway, sessionKey: self.model.sessionKey) },
                             save: { self.actions.save(asset, gateway: self.gateway, sessionKey: self.model.sessionKey) },
                             showInChat: asset.messageId.map { id in { self.showInChat(id) } })
                }
                .listStyle(.plain)
            }
        }
        .panelFill(alignment: .top)
        .modifier(AssetFileActionsPresenter(actions: self.actions))
        .onAppear { self.model.setVisible(true, viewer: self.viewerID) }
        .onDisappear { self.model.setVisible(false, viewer: self.viewerID) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L("Search files"), text: self.$model.search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !self.model.search.isEmpty {
                    Button(L("Clear Search"), systemImage: "xmark.circle.fill") { self.model.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                if self.model.isLoading, self.model.loaded { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, Theme.Spacing.sm).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Picker(L("Show"), selection: self.$model.filter) {
                Text(L("All")).tag(SessionAssetFilter.all)
                Text(L("Files")).tag(SessionAssetFilter.files)
                Text(L("Images")).tag(SessionAssetFilter.images)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(Theme.Spacing.lg)
    }
}

private struct AssetRow: View {
    let asset: SessionAsset
    let sessionKey: String
    let isBusy: Bool
    let open: () -> Void
    let save: () -> Void
    let showInChat: (() -> Void)?
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            self.thumbnail
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(self.asset.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let detail = self.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if self.isBusy { ProgressView().controlSize(.small) }
            Menu {
                self.menuItems
            } label: {
                Label(L("Actions"), systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: self.open)
        .contextMenu { self.menuItems }
        .disabled(!self.asset.isDownloadable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("Save…"), self.save)
        .accessibilityAction(named: L("Show in Chat")) { self.showInChat?() }
    }

    @ViewBuilder private var menuItems: some View {
        Button(L("Open"), systemImage: "eye", action: self.open)
        Button(L("Save…"), systemImage: "square.and.arrow.down", action: self.save)
        if let showInChat { Button(L("Show in Chat"), systemImage: "text.bubble", action: showInChat) }
    }

    @ViewBuilder private var thumbnail: some View {
        if case let .image(ref) = self.asset.content {
            if let image = self.gateway.images.cached(ref) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.5))
                    .onAppear { self.gateway.images.load(ref, sessionKey: self.sessionKey) }
            }
        } else {
            Image(systemName: Self.symbol(for: self.asset)).font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.5))
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let size = self.asset.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = self.asset.timestamp { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        else if self.asset.messageId == nil { parts.append(L("Older message")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(for asset: SessionAsset) -> String {
        let ext = (asset.name as NSString).pathExtension.lowercased()
        let mime = asset.mimeType?.lowercased() ?? ""
        if ext == "pdf" || mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "ogg", "opus", "flac", "aac"].contains(ext) { return "waveform" }
        if mime.hasPrefix("video/") || ["mp4", "mov", "webm", "mkv"].contains(ext) { return "film" }
        if ["zip", "gz", "tar", "tgz", "7z"].contains(ext) { return "doc.zipper" }
        if ["csv", "xlsx", "numbers"].contains(ext) { return "tablecells" }
        return "doc.text"
    }
}

/// The Assets toolbar button (⌥⌘A). On compact iPhone it only shows while the panel is open; "Show Generated
/// Files" in the chat's ⋯ menu covers the rest.
struct AssetsToolbarButton: View {
    @Binding var isPresented: Bool
    let isCompact: Bool
    var isFocused = true
    var focus: () -> Void = {}

    var body: some View {
        if !self.isCompact || self.isPresented {
            let title = self.isPresented ? L("Hide Generated Files") : L("Show Generated Files")
            self.focusedPaneShortcut(Button {
                if self.isFocused {
                    self.isPresented.toggle()
                } else {
                    self.focus()
                    self.isPresented = true
                }
            } label: {
                Label(L("Generated Files"), systemImage: "tray.full")
                    .foregroundStyle(self.isPresented ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            })
            #if os(iOS)
            .buttonStyle(.plain)
            #endif
            .help(self.isPresented ? L("Hide Generated Files (⌥⌘A)") : L("Show Generated Files (⌥⌘A)"))
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder private func focusedPaneShortcut(_ button: some View) -> some View {
        if self.isFocused { button.shortcut(.showAssets) } else { button }
    }
}

/// "Show Generated Files" for the chat's session menu.
struct ShowAssetsButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button(self.isPresented ? L("Hide Generated Files") : L("Show Generated Files"), systemImage: "tray.full") {
            self.isPresented.toggle()
        }
    }
}
