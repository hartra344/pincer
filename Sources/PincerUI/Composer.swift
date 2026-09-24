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
    @FocusState private var focused: Bool

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
                TextField(self.placeholder, text: self.$text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...12)
                    .focused(self.$focused)
                    .padding(.vertical, 8)
                    .frame(minHeight: 34)
                    #if os(macOS)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            self.text += "\n"
                            return .handled
                        }
                        self.submit()
                        return .handled
                    }
                    .onPasteCommand(of: [.image, .fileURL]) { providers in
                        self.ingest(providers)
                    }
                    #endif
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
        .onDrop(of: [.image, .fileURL], isTargeted: self.$isTargeted) { providers in
            self.ingest(providers)
            return true
        }
        .fileImporter(isPresented: self.$importing, allowedContentTypes: [.image, .pdf, .plainText, .item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls { self.addFile(url) }
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
        .onAppear { self.focused = true }
    }

    private var attachMenu: some View {
        Menu {
            Button("Choose File…", systemImage: "doc") { self.importing = true }
            #if os(iOS)
            Button("Paste Image", systemImage: "doc.on.clipboard") {
                if let image = UIPasteboard.general.image, let data = image.pngData() {
                    self.addImage(data, name: "pasted.png")
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

    private func ingest(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.addImage(data, name: "pasted.png") }
                }
            }
        }
    }

    private func addFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            self.attachmentError = "Couldn’t read \(url.lastPathComponent)."
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            self.addImage(data, name: url.lastPathComponent)
        } else if data.count > self.maxFileBytes {
            self.attachmentError = "\(url.lastPathComponent) is larger than the Gateway allows."
        } else {
            self.attachments.append(OutgoingAttachment(
                fileName: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: data))
        }
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
