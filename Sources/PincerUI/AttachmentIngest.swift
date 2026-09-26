import PincerKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns pasted, dropped and picked media into attachments sized for the Gateway's limits, for
/// the chat composer and Quick Capture. `add` receives each attachment; `report` gets a problem
/// to show, or nil once something was attached.
@MainActor
struct AttachmentIngest: Sendable {
    let limits: UploadLimits
    let add: @MainActor @Sendable (OutgoingAttachment) -> Void
    let report: @MainActor @Sendable (String?) -> Void

    func ingest(_ items: [PastedMedia]) {
        for item in items {
            switch item {
            case let .file(url):
                self.addFile(url)
            case let .data(data, type, name):
                self.addData(data, type: type, name: name ?? Self.fileName(nil, type: type))
            case let .provider(provider):
                self.load(provider)
            }
        }
    }

    func addImage(_ data: Data, name: String) {
        if let attachment = ImageCodec.prepareForUpload(data, fileName: name, maxBytes: self.limits.imageBytes) {
            self.add(attachment)
            self.report(nil)
        } else {
            self.report("Couldn’t prepare \(name) for upload.")
        }
    }

    private func load(_ provider: NSItemProvider) {
        let mediaType = MediaPasteboard.mediaType(in: provider.registeredTypeIdentifiers)
        guard mediaType == nil, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            self.loadData(provider, type: mediaType)
            return
        }
        let maxFileBytes = self.limits.fileBytes
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            // Files handed over by a provider may only be readable inside this callback.
            let result = url.map { Self.readFile($0, maxFileBytes: maxFileBytes) }
            Task { @MainActor in
                switch result {
                case let .success(file)?:
                    self.addData(file.data, type: file.type, name: file.name)
                case let .failure(error)?:
                    self.report(error.message)
                case nil:
                    self.report("That item can’t be attached.")
                }
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType?) {
        guard let type else {
            self.report("That item can’t be attached.")
            return
        }
        let name = Self.fileName(provider.suggestedName, type: type)
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            Task { @MainActor in
                guard let data else {
                    self.report("Couldn’t read \(name).")
                    return
                }
                self.addData(data, type: type, name: name)
            }
        }
    }

    private func addFile(_ url: URL) {
        switch Self.readFile(url, maxFileBytes: self.limits.fileBytes) {
        case let .success(file):
            self.addData(file.data, type: file.type, name: file.name)
        case let .failure(error):
            self.report(error.message)
        }
    }

    private func addData(_ data: Data, type: UTType?, name: String) {
        if type?.conforms(to: .image) == true {
            self.addImage(data, name: name)
        } else if data.count > self.limits.fileBytes {
            self.report("\(name) is larger than the Gateway allows (\(Self.byteString(self.limits.fileBytes))).")
        } else {
            self.add(OutgoingAttachment(
                fileName: name,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: data))
            self.report(nil)
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
    private nonisolated static let maxRawImageBytes = 200_000_000

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
}

/// A picked or pasted attachment, with a button to remove it.
struct AttachmentThumb: View {
    let attachment: OutgoingAttachment
    var size: CGFloat = 64
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
            .frame(width: self.size, height: self.size)
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
