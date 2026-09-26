import PhotosUI
import PincerKit
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Bindable var chat: ChatStore
    let placeholder: String
    /// Whether the field may focus itself when it appears.
    var autoFocus: @MainActor () -> Bool = { true }
    @Environment(GatewayStore.self) private var gateway
    @Environment(\.appTheme) private var theme
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var isTargeted = false
    @State private var menuSelection = 0
    /// Text the suggestion menu was dismissed at (Escape); it comes back once the text changes.
    @State private var dismissedMenuText: String?
    @State private var caretAtEnd = true

    private static let corner: CGFloat = 22
    /// Height of a single-line field, which the side controls match.
    static let controlHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !self.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(self.attachments) { attachment in
                            AttachmentThumb(attachment: attachment) {
                                self.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                self.attachMenu
                ComposerTextView(
                    placeholder: self.placeholder,
                    text: self.$chat.draft.text,
                    menuActive: !self.suggestions.isEmpty,
                    onSubmit: self.submit,
                    onMedia: self.ingest,
                    onKey: self.menuKey,
                    onCaretAtEnd: { if self.caretAtEnd != $0 { self.caretAtEnd = $0 } },
                    autoFocus: self.autoFocus)
                    .padding(.vertical, 11)
                    .frame(minHeight: Self.controlHeight)
                ContextMeter(chat: self.chat)
                if self.chat.isRunning {
                    Button {
                        Task { await self.chat.abort() }
                    } label: {
                        ComposerActionLabel(systemImage: "stop.fill", tint: .red, active: true)
                    }
                    .buttonStyle(.plain)
                    .composerControl()
                    .help("Stop the current run")
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("Stop")
                    .transition(.scale.combined(with: .opacity))
                }
                Button(action: self.submit) {
                    ComposerActionLabel(systemImage: "arrow.up", tint: self.theme.accent, active: self.canSend)
                }
                .buttonStyle(.plain)
                .composerControl()
                .disabled(!self.canSend)
                .help(self.chat.isRunning ? "Queue a follow-up" : "Send")
                .accessibilityLabel(self.chat.isRunning ? "Queue a follow-up" : "Send")
            }
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .glassSurface(in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .strokeBorder(self.theme.accent, lineWidth: 2)
                    .opacity(self.isTargeted ? 1 : 0))
            .animation(.snappy, value: self.chat.isRunning)
            .animation(.snappy, value: self.canSend)
            // An overlay, so the floating chrome's measured height (and the transcript's inset) stays put.
            .overlay(alignment: .top) {
                let suggestions = self.suggestions
                if !suggestions.isEmpty {
                    // A fixed-height box whose bottom sits just above the field, so the menu grows upward.
                    let box = SlashCommandMenu.maxHeight + 40
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        SlashCommandMenu(suggestions: suggestions, selection: self.$menuSelection, onPick: self.accept)
                    }
                    .frame(height: box, alignment: .bottom)
                    .offset(y: -(box + 8))
                    .transition(.opacity)
                }
            }
            .onChange(of: self.suggestions.map(\.id)) { self.menuSelection = 0 }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .onDrop(of: [.fileURL, .image, .audiovisualContent, .pdf], isTargeted: self.$isTargeted) { providers in
            self.ingest(providers.map(PastedMedia.provider))
            return true
        }
        .fileImporter(isPresented: self.$importing, allowedContentTypes: [.image, .pdf, .plainText, .item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            self.ingest(urls.map(PastedMedia.file))
        }
        .task(id: self.isTypingCommand ? self.chat.sessionKey : nil) {
            guard self.isTypingCommand else { return }
            await self.gateway.loadCommands(sessionKey: self.chat.sessionKey, agentId: self.agentId)
            await self.gateway.loadModels(agentId: self.agentId)
        }
        .task(id: self.chat.sessionKey) {
            // The meter falls back to the model's context window when the session row has none.
            if self.gateway.needsModelCatalogForContext(self.chat.sessionKey) {
                await self.gateway.loadModels(agentId: self.agentId)
            }
        }
        .onChange(of: self.photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        self.addImage(data, name: "photo.jpg")
                    }
                }
                self.photoItems = []
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Choose File…", systemImage: "doc") { self.importing = true }
            #if os(iOS)
            Button("Paste Image", systemImage: "doc.on.clipboard") {
                let items = MediaPasteboard.items(from: .general)
                if !items.isEmpty {
                    self.ingest(items)
                } else if let image = UIPasteboard.general.image, let data = image.pngData() {
                    self.addImage(data, name: "Pasted Image.png")
                } else {
                    self.attachmentError = "There’s no image or file on the clipboard."
                }
            }
            #endif
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        } primaryAction: {
            self.importing = true
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .composerControl()
        .overlay(alignment: .trailing) {
            #if os(iOS)
            PhotosPicker(selection: self.$photoItems, maxSelectionCount: 6, matching: .images) {
                Image(systemName: "photo").font(.title3)
            }
            .offset(x: 30)
            #endif
        }
        #if os(iOS)
        .padding(.trailing, 30)
        #endif
    }

    private var text: String {
        get { self.chat.draft.text }
        nonmutating set { self.chat.draft.text = newValue }
    }

    private var attachments: [OutgoingAttachment] {
        get { self.chat.draft.attachments }
        nonmutating set { self.chat.draft.attachments = newValue }
    }

    private var canSend: Bool {
        self.gateway.state.isConnected
            && (!self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.attachments.isEmpty)
    }

    private func submit() {
        let suggestions = self.suggestions
        if suggestions.indices.contains(self.menuSelection), !suggestions[self.menuSelection].isComplete(for: self.text) {
            self.accept(suggestions[self.menuSelection])
            return
        }
        guard self.canSend else { return }
        let text = SlashCommand.outgoingText(self.text, commands: self.gateway.slashCommands(for: self.chat.sessionKey))
        let attachments = self.attachments
        self.chat.draft = ComposerDraft()
        self.attachmentError = nil
        Task { await self.chat.send(text, attachments: attachments) }
    }

    // MARK: Slash commands

    private var row: SessionRow? { self.gateway.sessions[self.chat.sessionKey] }

    private var agentId: String {
        self.row?.agentId ?? self.chat.agentId ?? SessionKey.agentId(from: self.chat.sessionKey) ?? self.gateway.defaultAgentId
    }

    private var isTypingCommand: Bool { self.text.hasPrefix("/") }

    private var suggestions: [SlashSuggestion] {
        guard self.isTypingCommand, self.caretAtEnd, self.text != self.dismissedMenuText else { return [] }
        // A fully typed command stays listed; Return sends it since accepting wouldn't change anything.
        return SlashCompletion.suggestions(
            for: self.text, commands: self.gateway.slashCommands(for: self.chat.sessionKey), choices: self.choices)
    }

    /// Values for a command's argument: the catalog's, or ones Pincer knows (models, thinking levels).
    private func choices(_ command: SlashCommand, _ index: Int, _ arg: SlashCommandArg?) -> [SlashCommandChoice] {
        if let arg, !arg.choices.isEmpty { return arg.choices }
        guard index == 0 else { return [] }
        if command.matches("model") || arg?.name == "model" {
            return (self.gateway.modelCatalogs[self.agentId] ?? [])
                .filter { $0.isAvailable && $0.manualSelectionAllowed }
                .map { SlashCommandChoice(value: $0.ref, label: $0.displayName, detail: $0.provider) }
        }
        if command.matches("think") {
            let levels = self.row?.thinkingLevelChoices?.nilIfEmpty
                ?? SlashCommand.fallbackThinkingLevels.map { SlashCommandChoice(value: $0) }
            return [SlashCommandChoice(value: "default")] + levels.filter { $0.value != "default" }
        }
        return []
    }

    private func accept(_ suggestion: SlashSuggestion) {
        self.text = suggestion.replacement
        self.dismissedMenuText = nil
        self.menuSelection = 0
        self.caretAtEnd = true
    }

    private func menuKey(_ key: ComposerKey) -> Bool {
        let suggestions = self.suggestions
        guard !suggestions.isEmpty else { return false }
        switch key {
        case .up:
            self.menuSelection = (self.menuSelection - 1 + suggestions.count) % suggestions.count
        case .down:
            self.menuSelection = (self.menuSelection + 1) % suggestions.count
        case .tab:
            self.accept(suggestions[min(self.menuSelection, suggestions.count - 1)])
        case .escape:
            self.dismissedMenuText = self.text
        }
        return true
    }

    // MARK: Attachments

    private var maxImageBytes: Int { UploadLimits(hello: self.gateway.hello).imageBytes }

    private var maxFileBytes: Int { UploadLimits(hello: self.gateway.hello).fileBytes }

    private func ingest(_ items: [PastedMedia]) {
        for item in items {
            switch item {
            case let .file(url):
                self.addFile(url)
            case let .data(data, type, name):
                self.addData(data, type: type, name: name ?? Self.pastedName(for: type))
            case let .provider(provider):
                self.load(provider)
            }
        }
    }

    private func load(_ provider: NSItemProvider) {
        let mediaType = MediaPasteboard.mediaType(in: provider.registeredTypeIdentifiers)
        guard mediaType == nil, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            self.loadData(provider, type: mediaType)
            return
        }
        let maxFileBytes = self.maxFileBytes
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            // Files handed over by a provider may only be readable inside this callback.
            let result = url.map { Self.readFile($0, maxFileBytes: maxFileBytes) }
            Task { @MainActor in
                switch result {
                case let .success(file)?:
                    self.addData(file.data, type: file.type, name: file.name)
                case let .failure(error)?:
                    self.attachmentError = error.message
                case nil:
                    self.attachmentError = "That item can’t be attached."
                }
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType?) {
        guard let type else {
            self.attachmentError = "That item can’t be attached."
            return
        }
        let name = Self.fileName(provider.suggestedName, type: type)
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            Task { @MainActor in
                guard let data else {
                    self.attachmentError = "Couldn’t read \(name)."
                    return
                }
                self.addData(data, type: type, name: name)
            }
        }
    }

    private func addFile(_ url: URL) {
        switch Self.readFile(url, maxFileBytes: self.maxFileBytes) {
        case let .success(file):
            self.addData(file.data, type: file.type, name: file.name)
        case let .failure(error):
            self.attachmentError = error.message
        }
    }

    private func addData(_ data: Data, type: UTType?, name: String) {
        if type?.conforms(to: .image) == true {
            self.addImage(data, name: name)
        } else if data.count > self.maxFileBytes {
            self.attachmentError = "\(name) is larger than the Gateway allows (\(Self.byteString(self.maxFileBytes)))."
        } else {
            self.attachments.append(OutgoingAttachment(
                fileName: name,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: data))
            self.attachmentError = nil
        }
    }

    private struct ReadFile: Sendable {
        let data: Data
        let type: UTType?
        let name: String
    }

    private struct ReadError: Error {
        let message: String
    }

    /// Images may exceed the Gateway limit because they're downscaled before upload.
    private static let maxRawImageBytes = 200_000_000

    private nonisolated static func readFile(_ url: URL, maxFileBytes: Int) -> Result<ReadFile, ReadError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true {
            return .failure(ReadError(message: "\(name) is a folder; attach files instead."))
        }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let limit = type?.conforms(to: .image) == true ? self.maxRawImageBytes : maxFileBytes
        if let size = values?.fileSize, size > limit {
            return .failure(ReadError(message: "\(name) is larger than the Gateway allows (\(self.byteString(maxFileBytes)))."))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(ReadError(message: "Couldn’t read \(name)."))
        }
        return .success(ReadFile(data: data, type: type, name: name))
    }

    private nonisolated static func pastedName(for type: UTType) -> String {
        self.fileName(nil, type: type)
    }

    private nonisolated static func fileName(_ suggested: String?, type: UTType) -> String {
        let base: String
        if let suggested, !suggested.isEmpty {
            base = suggested
        } else if type.conforms(to: .image) {
            base = "Pasted Image"
        } else {
            base = "Pasted File"
        }
        guard (base as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    private nonisolated static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func addImage(_ data: Data, name: String) {
        if let attachment = ImageCodec.prepareForUpload(data, fileName: name, maxBytes: self.maxImageBytes) {
            self.attachments.append(attachment)
            self.attachmentError = nil
        } else {
            self.attachmentError = "Couldn’t prepare \(name) for upload."
        }
    }
}

private struct AttachmentThumb: View {
    let attachment: OutgoingAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if self.attachment.isImage, let image = ImageCodec.decode(self.attachment.data) {
                    Image(cgImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc").font(.title3)
                        Text(self.attachment.fileName).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .padding(4)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: self.remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .accessibilityLabel("Remove \(self.attachment.fileName)")
        }
        .padding(.top, 5)
    }
}

/// The round Send / Stop control: a tinted glass disc when active, a quiet one when not.
private struct ComposerActionLabel: View {
    let systemImage: String
    let tint: Color
    let active: Bool

    var body: some View {
        let icon = Image(systemName: self.systemImage)
            .font(.system(size: 14, weight: .bold))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        if #available(macOS 26, iOS 26, *) {
            icon
                .foregroundStyle(self.active ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .glassEffect(self.active ? Glass.regular.tint(self.tint).interactive() : .identity, in: Circle())
        } else {
            icon
                .foregroundStyle(self.active ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                .background(self.active ? AnyShapeStyle(self.tint.gradient) : AnyShapeStyle(.quaternary), in: Circle())
        }
    }
}

private extension View {
    /// Side controls share one box as tall as a single-line field, so with bottom alignment they
    /// centre on the first line and stay pinned to the last line as the field grows.
    func composerControl() -> some View {
        self.frame(width: 32, height: Composer.controlHeight)
    }
}

private extension Array {
    var nilIfEmpty: Self? { self.isEmpty ? nil : self }
}
