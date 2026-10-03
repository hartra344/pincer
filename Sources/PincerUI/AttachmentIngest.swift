import PincerKit
import CoreGraphics
import Foundation
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Turns pasted, dropped and picked media into attachments sized for the Gateway's limits, for
/// the chat composer and Quick Capture. `add` receives each attachment; `report` gets a problem
/// to show, or nil once something was attached.
@MainActor
struct AttachmentIngest: Sendable {
    let limits: UploadLimits
    /// The limits come from a saved policy while offline, so a size problem says so.
    var limitsAreLastKnown = false
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
        let lastKnown = self.limitsAreLastKnown
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            // Files handed over by a provider may only be readable inside this callback.
            let result = url.map { Self.readFile($0, maxFileBytes: maxFileBytes, lastKnown: lastKnown) }
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
        switch Self.readFile(url, maxFileBytes: self.limits.fileBytes, lastKnown: self.limitsAreLastKnown) {
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
            self.report(Self.tooLarge(name, limit: self.limits.fileBytes, lastKnown: self.limitsAreLastKnown))
        } else {
            self.add(OutgoingAttachment(
                fileName: name,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: data))
            self.report(nil)
        }
    }

    /// "x is larger than the Gateway allows (5 MB)." — "(5 MB, last known limit)" when offline with a saved policy.
    private nonisolated static func tooLarge(_ name: String, limit: Int, lastKnown: Bool) -> String {
        let size = self.byteString(limit)
        return lastKnown ? L("\(name) is larger than the Gateway allows (\(size), last known limit).")
            : L("\(name) is larger than the Gateway allows (\(size)).")
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

    private nonisolated static func readFile(_ url: URL, maxFileBytes: Int, lastKnown: Bool) -> Result<ReadFile, ReadError> {
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
            return .failure(ReadError(message: self.tooLarge(name, limit: maxFileBytes, lastKnown: lastKnown)))
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
    @Environment(\.displayScale) private var displayScale
    @State private var renderedPreview: RenderedPreview?
    @State private var loaderOwner = UUID()

    var body: some View {
        #if DEBUG
        let _ = AttachmentThumbnailDecodeProbe.bodyEvaluated(self.attachment, owner: self.loaderOwner)
        #endif
        let loader = AttachmentThumbnailLoader.shared
        let key = AttachmentThumbnailLoader.Key(
            previewIdentity: self.attachment.previewIdentity,
            maxPixel: AttachmentThumbnailLoader.targetPixelSize(points: Double(self.size), displayScale: Double(self.displayScale)))
        let retryRevision = loader.revision
        let currentImage = self.renderedPreview.flatMap { preview in
            preview.previewIdentity == self.attachment.previewIdentity ? preview.image : nil
        }
        #if DEBUG
        let _ = AttachmentThumbnailDecodeProbe.displayed(self.attachment,
            previewIdentity: currentImage == nil ? nil : self.renderedPreview?.previewIdentity)
        #endif
        return ZStack(alignment: .topTrailing) {
            Group {
                if self.attachment.isImage, let image = currentImage {
                    Image(cgImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "doc").font(.title3)
                        Text(self.attachment.fileName).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .padding(Theme.Spacing.xs)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: self.size, height: self.size)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))

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
        .task(id: ThumbnailRequestTrigger(key: key, revision: retryRevision)) {
            guard self.attachment.isImage else { return }
            if self.renderedPreview?.previewIdentity != key.previewIdentity {
                self.renderedPreview = nil
            }
            if self.renderedPreview?.previewIdentity == key.previewIdentity,
               self.renderedPreview?.maxPixel == key.maxPixel { return }
            if let image = loader.cached(self.attachment, maxPixel: key.maxPixel) {
                self.renderedPreview = RenderedPreview(previewIdentity: key.previewIdentity,
                                                        maxPixel: key.maxPixel, image: image)
                return
            }
            _ = loader.request(self.attachment, maxPixel: key.maxPixel, owner: self.loaderOwner)
        }
        .onChange(of: key) { oldKey, _ in
            loader.release(oldKey, owner: self.loaderOwner)
        }
        .onDisappear {
            loader.release(key, owner: self.loaderOwner)
        }
    }

    private struct RenderedPreview {
        let previewIdentity: UUID
        let maxPixel: Int
        let image: CGImage
    }

    private struct ThumbnailRequestTrigger: Hashable {
        let key: AttachmentThumbnailLoader.Key
        let revision: UInt64
    }
}

#if DEBUG
/// Records only explicitly watched attachment decodes, so hosted tests can prove the real view's
/// decode count, thread, and target without logging image bytes or changing Release behavior.
enum AttachmentThumbnailDecodeProbe {
    struct Sample: Sendable {
        let attachmentID: UUID
        let previewIdentity: UUID
        let fileName: String
        let maxPixel: Int
        let isMainThread: Bool
        let width: Int?
        let height: Int?
    }

    private struct State: Sendable {
        var attachmentID: UUID?
        var previewIdentity: UUID?
        var fileName: String?
        var loaderOwner: UUID?
        var displayedPreviewIdentity: UUID?
        var bodyEvaluations = 0
        var samples: [Sample] = []
    }

    private static let state = Mutex(State())

    @MainActor static func watch(_ attachment: OutgoingAttachment) {
        self.state.withLock { state in
            state.attachmentID = attachment.id
            state.previewIdentity = attachment.previewIdentity
            state.fileName = attachment.fileName
            state.loaderOwner = nil
            state.displayedPreviewIdentity = nil
            state.bodyEvaluations = 0
            state.samples.removeAll(keepingCapacity: true)
        }
        AttachmentThumbnailLoader.shared.debugDecodeObserver = { id, previewIdentity, fileName, maxPixel, isMainThread, image in
            let sample = Sample(attachmentID: id, previewIdentity: previewIdentity, fileName: fileName, maxPixel: maxPixel,
                                isMainThread: isMainThread, width: image?.width, height: image?.height)
            self.state.withLock { state in
                guard state.attachmentID == id, state.previewIdentity == previewIdentity, state.fileName == fileName,
                      state.samples.count < 32 else { return }
                state.samples.append(sample)
            }
        }
    }

    static func bodyEvaluationCount(for attachment: OutgoingAttachment) -> Int {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return 0 }
            return state.bodyEvaluations
        }
    }

    static func bodyEvaluated(_ attachment: OutgoingAttachment, owner: UUID) {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return }
            state.bodyEvaluations = min(state.bodyEvaluations + 1, 32)
            state.loaderOwner = owner
        }
    }

    static func loaderOwner(for attachment: OutgoingAttachment) -> UUID? {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return nil }
            return state.loaderOwner
        }
    }

    static func displayed(_ attachment: OutgoingAttachment, previewIdentity: UUID?) {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return }
            state.displayedPreviewIdentity = previewIdentity
        }
    }

    static func displayedPreviewIdentity(for attachment: OutgoingAttachment) -> UUID? {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return nil }
            return state.displayedPreviewIdentity
        }
    }

    static func samples(for attachment: OutgoingAttachment) -> [Sample] {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return [] }
            return state.samples
        }
    }

    @MainActor static func stopWatching(_ attachment: OutgoingAttachment) {
        self.state.withLock { state in
            guard state.attachmentID == attachment.id, state.previewIdentity == attachment.previewIdentity,
                  state.fileName == attachment.fileName else { return }
            state.attachmentID = nil
            state.previewIdentity = nil
            state.fileName = nil
            state.loaderOwner = nil
            state.displayedPreviewIdentity = nil
            state.bodyEvaluations = 0
            state.samples.removeAll(keepingCapacity: true)
        }
        AttachmentThumbnailLoader.shared.debugDecodeObserver = nil
    }
}
#endif
