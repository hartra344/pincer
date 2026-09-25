import PhotosUI
import PincerKit
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    let chat: ChatStore
    let placeholder: String
    @Environment(GatewayStore.self) private var gateway
    @State private var text = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @State private var isTargeted = false

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
                    text: self.$text,
                    onSubmit: self.submit,
                    onMedia: self.ingest)
                    .padding(.vertical, 8)
                    .frame(minHeight: 34)
                if self.chat.isRunning {
                    Button {
                        Task { await self.chat.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .composerControl()
                    .foregroundStyle(.red)
                    .help("Stop the current run")
                    .keyboardShortcut(".", modifiers: .command)
                }
                Button(action: self.submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .composerControl()
                .disabled(!self.canSend)
                .help(self.chat.isRunning ? "Queue a follow-up" : "Send")
            }
            .padding(.horizontal, 10)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(self.isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), lineWidth: self.isTargeted ? 2 : 1))
        }
        .padding(.horizontal, 16)
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
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.secondary)
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

    private var canSend: Bool {
        self.gateway.state.isConnected
            && (!self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !self.attachments.isEmpty)
    }

    private func submit() {
        guard self.canSend else { return }
        let text = self.text
        let attachments = self.attachments
        self.text = ""
        self.attachments = []
        self.attachmentError = nil
        Task { await self.chat.send(text, attachments: attachments) }
    }

    // MARK: Attachments

    private var maxImageBytes: Int {
        let hello = self.gateway.hello
        // Base64 inflates ~4/3 and the whole frame must fit maxPayload.
        let payloadBudget = Int(Double(hello?.maxPayload ?? 25_000_000) * 0.7)
        return min(hello?.maxImageBytes ?? 5_000_000, payloadBudget)
    }

    private var maxFileBytes: Int {
        let hello = self.gateway.hello
        return min(hello?.maxAttachmentBytes ?? 10_000_000, Int(Double(hello?.maxPayload ?? 25_000_000) * 0.7))
    }

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

private extension View {
    /// Side controls share one box as tall as a single-line field, so with bottom alignment they
    /// centre on the first line and stay pinned to the last line as the field grows.
    func composerControl() -> some View {
        self.frame(width: 28, height: 34)
    }
}
