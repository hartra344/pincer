import PincerKit
import CoreGraphics
import Foundation
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentIngestResult: Sendable {
    case attachment(OutgoingAttachment)
    case failure(String)
}

/// NSItemProvider is retained only in the main-actor FIFO and touched from its main-actor operation.
private final class ProviderReference: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) { self.provider = provider }
}

/// Turns pasted, dropped and picked media into attachments sized for the Gateway's limits, for
/// the chat composer and Quick Capture. `add` receives each attachment; `report` gets a problem
/// to show, or nil once something was attached.
@MainActor
struct AttachmentIngest: Sendable {
    private static let sharedImageQueue = BoundedPreparationQueue<AttachmentIngestResult>()

    let limits: UploadLimits
    let imageQueue: BoundedPreparationQueue<AttachmentIngestResult>
    let providerTimeoutNanoseconds: UInt64
    /// The limits come from a saved policy while offline, so a size problem says so.
    var limitsAreLastKnown = false
    let add: @MainActor @Sendable (OutgoingAttachment) -> Void
    let report: @MainActor @Sendable (String?) -> Void

    init(
        limits: UploadLimits,
        limitsAreLastKnown: Bool = false,
        imageQueue: BoundedPreparationQueue<AttachmentIngestResult>? = nil,
        providerTimeoutNanoseconds: UInt64 = 30_000_000_000,
        add: @escaping @MainActor @Sendable (OutgoingAttachment) -> Void,
        report: @escaping @MainActor @Sendable (String?) -> Void)
    {
        self.limits = limits
        self.limitsAreLastKnown = limitsAreLastKnown
        self.imageQueue = imageQueue ?? Self.sharedImageQueue
        self.providerTimeoutNanoseconds = providerTimeoutNanoseconds
        self.add = add
        self.report = report
    }

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
        guard data.count <= Self.maxRawImageBytes else {
            self.report(Self.rawImageTooLarge(name))
            return
        }
        self.enqueue(data, type: .image, name: name)
    }

    private func addFile(_ url: URL) {
        let limits = self.limits
        let lastKnown = self.limitsAreLastKnown
        self.submit(retainedBytes: 0, name: url.lastPathComponent, operation: {
            await Task.detached(priority: .userInitiated) {
                switch Self.readFile(url, maxFileBytes: limits.fileBytes, lastKnown: lastKnown) {
                case let .success(file): Self.prepare(file.data, type: file.type, name: file.name, limits: limits, lastKnown: lastKnown)
                case let .failure(error): .failure(error.message)
                }
            }.value
        })
    }

    private func load(_ provider: NSItemProvider) {
        let mediaType = MediaPasteboard.mediaType(in: provider.registeredTypeIdentifiers)
        let providerReference = ProviderReference(provider)
        let limits = self.limits
        let lastKnown = self.limitsAreLastKnown
        let timeout = self.providerTimeoutNanoseconds
        let name = Self.fileName(provider.suggestedName, type: mediaType ?? .data)
        self.submit(retainedBytes: 0, name: name, operation: {
            await Self.prepareProvider(
                providerReference,
                type: mediaType,
                name: name,
                limits: limits,
                lastKnown: lastKnown,
                timeoutNanoseconds: timeout)
        })
    }

    private func addData(_ data: Data, type: UTType?, name: String) {
        let isImage = type?.conforms(to: .image) == true
        let limit = isImage ? Self.maxRawImageBytes : self.limits.fileBytes
        guard data.count <= limit else {
            self.report(isImage
                ? Self.rawImageTooLarge(name)
                : Self.tooLarge(name, limit: self.limits.fileBytes, lastKnown: self.limitsAreLastKnown))
            return
        }
        self.enqueue(data, type: type, name: name)
    }

    private func enqueue(_ data: Data, type: UTType?, name: String) {
        let limits = self.limits
        let lastKnown = self.limitsAreLastKnown
        self.submit(retainedBytes: data.count, name: name, operation: {
            await Task.detached(priority: .userInitiated) {
                Self.prepare(data, type: type, name: name, limits: limits, lastKnown: lastKnown)
            }.value
        })
    }

    private func submit(
        retainedBytes: Int,
        name: String,
        operation: @escaping @MainActor @Sendable () async -> AttachmentIngestResult)
    {
        let add = self.add
        let report = self.report
        let admission = self.imageQueue.submit(retainedBytes: retainedBytes, operation: operation) { result in
            switch result {
            case let .attachment(attachment):
                add(attachment)
                report(nil)
            case let .failure(message):
                report(message)
            }
        }
        switch admission {
        case .started, .queued:
            break
        case .rejectedPendingCount, .rejectedPendingBytes:
            self.report(Self.queueFull(name))
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

    private struct ReadError: Error, Sendable {
        let message: String
    }

    private enum ProviderReadResult: Sendable {
        case file(ReadFile)
        case failure(String)
    }

    /// A provider that never invokes its callback must not pin the shared preparation FIFO.
    /// Once a callback claims the gate, however, its security-scoped URL read retains the active
    /// slot until it finishes. A late callback after timeout returns before touching its URL.
    private final class ProviderLoadGate: @unchecked Sendable {
        private enum State: Equatable { case waiting, callback, finished }

        private let lock = NSLock()
        private var state: State = .waiting
        private var continuation: CheckedContinuation<ProviderReadResult, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var providerProgress: Progress?

        init(_ continuation: CheckedContinuation<ProviderReadResult, Never>) {
            self.continuation = continuation
        }

        func setTimeoutTask(_ task: Task<Void, Never>) {
            self.lock.lock()
            let shouldCancel = self.state != .waiting
            if !shouldCancel { self.timeoutTask = task }
            self.lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func setProviderProgress(_ progress: Progress) {
            self.lock.lock()
            let shouldCancel = self.state == .finished
            if !shouldCancel { self.providerProgress = progress }
            self.lock.unlock()
            if shouldCancel { progress.cancel() }
        }

        func beginCallback() -> Bool {
            self.lock.lock()
            guard self.state == .waiting else {
                self.lock.unlock()
                return false
            }
            self.state = .callback
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            self.providerProgress = nil
            self.lock.unlock()
            timeoutTask?.cancel()
            return true
        }

        func finish(_ result: ProviderReadResult) {
            self.lock.lock()
            guard self.state == .callback else {
                self.lock.unlock()
                return
            }
            self.state = .finished
            let continuation = self.continuation
            self.continuation = nil
            self.providerProgress = nil
            self.lock.unlock()
            continuation?.resume(returning: result)
        }

        func timeout(_ failure: String) {
            self.lock.lock()
            guard self.state == .waiting else {
                self.lock.unlock()
                return
            }
            self.state = .finished
            let continuation = self.continuation
            self.continuation = nil
            self.timeoutTask = nil
            let progress = self.providerProgress
            self.providerProgress = nil
            self.lock.unlock()
            progress?.cancel()
            continuation?.resume(returning: .failure(failure))
        }
    }

    private static func prepareProvider(
        _ reference: ProviderReference,
        type: UTType?,
        name: String,
        limits: UploadLimits,
        lastKnown: Bool,
        timeoutNanoseconds: UInt64) async -> AttachmentIngestResult
    {
        let provider = reference.provider
        if type == nil, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<ProviderReadResult, Never>) in
                let gate = ProviderLoadGate(continuation)
                let timeoutTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                    gate.timeout("That item can’t be attached.")
                }
                gate.setTimeoutTask(timeoutTask)
                let progress = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard gate.beginCallback() else { return }
                    // Provider file URLs are valid only inside this callback; read and close the
                    // security scope before returning, then let the serialized codec job proceed.
                    guard !Thread.isMainThread else {
                        gate.finish(.failure("That item can’t be attached."))
                        return
                    }
                    guard let url else {
                        gate.finish(.failure("That item can’t be attached."))
                        return
                    }
                    switch Self.readFile(url, maxFileBytes: limits.fileBytes, lastKnown: lastKnown) {
                    case let .success(file):
                        gate.finish(.file(file))
                    case let .failure(error):
                        gate.finish(.failure(error.message))
                    }
                }
                gate.setProviderProgress(progress)
            }
            switch loaded {
            case let .file(file):
                return await Task.detached(priority: .userInitiated) {
                    Self.prepare(file.data, type: file.type, name: file.name, limits: limits, lastKnown: lastKnown)
                }.value
            case let .failure(message):
                return .failure(message)
            }
        }
        guard let type else { return .failure("That item can’t be attached.") }
        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<ProviderReadResult, Never>) in
            let gate = ProviderLoadGate(continuation)
            let timeoutTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                gate.timeout("Couldn’t read \(name).")
            }
            gate.setTimeoutTask(timeoutTask)
            let progress = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard gate.beginCallback() else { return }
                guard let data else {
                    gate.finish(.failure("Couldn’t read \(name)."))
                    return
                }
                let byteLimit = type.conforms(to: .image) ? Self.maxRawImageBytes : limits.fileBytes
                guard data.count <= byteLimit else {
                    let message = type.conforms(to: .image)
                        ? Self.rawImageTooLarge(name)
                        : Self.tooLarge(name, limit: limits.fileBytes, lastKnown: lastKnown)
                    gate.finish(.failure(message))
                    return
                }
                gate.finish(.file(ReadFile(data: data, type: type, name: name)))
            }
            gate.setProviderProgress(progress)
        }
        switch loaded {
        case let .file(file):
            return await Task.detached(priority: .userInitiated) {
                Self.prepare(file.data, type: file.type, name: file.name, limits: limits, lastKnown: lastKnown)
            }.value
        case let .failure(message):
            return .failure(message)
        }
    }

    private nonisolated static func prepare(
        _ data: Data,
        type: UTType?,
        name: String,
        limits: UploadLimits,
        lastKnown: Bool) -> AttachmentIngestResult
    {
        if type?.conforms(to: .image) == true {
            guard data.count <= Self.maxRawImageBytes else { return .failure(Self.rawImageTooLarge(name)) }
            guard let attachment = ImageCodec.prepareForUpload(data, fileName: name, maxBytes: limits.imageBytes) else {
                return .failure("Couldn’t prepare \(name) for upload.")
            }
            return .attachment(attachment)
        }
        guard data.count <= limits.fileBytes else {
            return .failure(Self.tooLarge(name, limit: limits.fileBytes, lastKnown: lastKnown))
        }
        return .attachment(OutgoingAttachment(
            fileName: name,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data))
    }

    private nonisolated static func queueFull(_ name: String) -> String {
        L("Couldn’t queue \(name); attachment preparation is full. Try again after current items finish.")
    }

    private nonisolated static func rawImageTooLarge(_ name: String) -> String {
        let limit = Self.byteString(Self.maxRawImageBytes)
        return L("\(name) exceeds the maximum image source size (\(limit)).")
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
            let message = type?.conforms(to: .image) == true
                ? self.rawImageTooLarge(name)
                : self.tooLarge(name, limit: maxFileBytes, lastKnown: lastKnown)
            return .failure(ReadError(message: message))
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
