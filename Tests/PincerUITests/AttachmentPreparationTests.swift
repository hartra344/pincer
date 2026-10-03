import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PincerKit
import Testing
@testable import PincerUI

@MainActor
@Suite("Attachment image preparation", .serialized)
struct AttachmentPreparationTests {
    @Test func composerImagePreparationPreservesUploadContractOffMain() async throws {
        let source = try await Task.detached(priority: .utility) {
            try Self.pngFixture(width: 1600, height: 1200)
        }.value
        #expect(source.count > 400_000, "fixture must exercise the oversized-image preparation path")
        let name = "picked-photo-\(UUID().uuidString).PNG"
        let recorder = Recorder()
        let ingest = AttachmentIngest(
            limits: UploadLimits(maxPayload: 1_000_000, maxImageBytes: 400_000, maxAttachmentBytes: 400_000),
            imageQueue: BoundedPreparationQueue<AttachmentIngestResult>(),
            add: { recorder.attachments.append($0) },
            report: { recorder.messages.append($0) })

        ImageCodec.PreparationProbe.track(fileName: name)
        defer { ImageCodec.PreparationProbe.stopTracking(fileName: name) }
        ingest.addImage(source, name: name)

        let successReported = await eventually { recorder.attachments.count == 1 || !recorder.messages.isEmpty }
        #expect(successReported)

        let counts = ImageCodec.PreparationProbe.counts()
        #expect(counts.mainThread == 0, "ImageCodec.prepareForUpload ran on the UI thread")
        #expect(counts.background == 1)

        let attachment = try #require(recorder.attachments.first)
        #expect(recorder.attachments.count == 1)
        #expect(attachment.fileName == "\((name as NSString).deletingPathExtension).jpg")
        #expect(attachment.mimeType == "image/jpeg")
        #expect(!attachment.data.isEmpty && attachment.data.count <= 400_000)
        let decodable = await Task.detached(priority: .utility) { ImageCodec.decode(attachment.data) != nil }.value
        #expect(decodable)
        #expect(recorder.messages == [nil])

        // Invalid source data keeps the existing user-visible failure and adds no partial item.
        ingest.addImage(Data("not an image".utf8), name: "broken.png")
        let failureReported = await eventually { recorder.messages.count == 2 }
        #expect(failureReported)
        #expect(recorder.attachments.count == 1)
        #expect(recorder.messages == [nil, "Couldn’t prepare broken.png for upload."])
    }

    @Test func urlObjectProviderReadsImageBeforeTheNextOwnersPlainText() async throws {
        let source = try await Task.detached(priority: .utility) {
            try Self.pngFixture(width: 256, height: 192)
        }.value
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-image-\(UUID().uuidString).png")
        try source.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // NSURL is an NSItemProviderReading/Writing object. Its file-URL representation exercises
        // AttachmentIngest's URL-object callback path instead of the image-data representation.
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = "provider-image.png"
        #expect(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
        #expect(MediaPasteboard.mediaType(in: provider.registeredTypeIdentifiers) == nil)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

        let limits = UploadLimits(maxPayload: 1_000_000, maxImageBytes: 400_000, maxAttachmentBytes: 400_000)
        let ordered = OrderedRecorder()
        let imageIngest = AttachmentIngest(
            limits: limits,
            add: { attachment in
                ordered.events.append("image:\(attachment.fileName)")
                ordered.attachments.append(attachment)
            },
            report: { ordered.imageMessages.append($0) })
        let textIngest = AttachmentIngest(
            limits: limits,
            add: { attachment in
                ordered.events.append("text:\(attachment.fileName)")
                ordered.attachments.append(attachment)
            },
            report: { ordered.textMessages.append($0) })

        ImageCodec.PreparationProbe.track(fileName: url.lastPathComponent)
        defer { ImageCodec.PreparationProbe.stopTracking(fileName: url.lastPathComponent) }
        imageIngest.ingest([.provider(provider)])
        textIngest.ingest([.data(Data("queued after image".utf8), type: .plainText, name: "after-image.txt")])

        let completed = await eventually(timeout: .seconds(10)) { ordered.events.count == 2 }
        #expect(completed, "the provider image and following item both complete")
        #expect(ordered.events == ["image:\(url.lastPathComponent)", "text:after-image.txt"])
        #expect(ordered.imageMessages == [nil] && ordered.textMessages == [nil])
        let image = try #require(ordered.attachments.first)
        #expect(image.fileName == url.lastPathComponent)
        #expect(image.mimeType == "image/png" && image.data.count <= limits.imageBytes,
                "a fitting PNG keeps its PNG upload contract")
        let decoded = await Task.detached(priority: .utility) { ImageCodec.decode(image.data) != nil }.value
        #expect(decoded)
        let counts = ImageCodec.PreparationProbe.counts()
        #expect(counts.mainThread == 0 && counts.background == 1,
                "the URL callback path reaches the off-main image codec")
    }

    #if os(macOS)
    @Test func demoChatDraftPreparesAndSendsAnOversizedImage() async throws {
        try await Self.verifyDemoChatDraftPreparesAndSendsAnOversizedImage()
    }
    #endif

    static func verifyDemoChatDraftPreparesAndSendsAnOversizedImage() async throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: UIFixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let key = "agent:main:main"
        let chat = gateway.chat(for: key)
        chat.cacheChecked = true
        chat.draftChecked = true
        chat.restoringDraft = true
        gateway.start()
        defer {
            chat.restoringDraft = false
            gateway.stop()
        }

        let connected = await eventually(timeout: .seconds(60)) {
            gateway.state.isConnected && gateway.bootstrapped && gateway.hello != nil && gateway.sessions[key] != nil
        }
        try #require(connected, "the built-in demo loads the seeded main chat")
        gateway.selectedKey = key
        await chat.load()
        let loaded = await eventually(timeout: .seconds(20)) { chat.hasLoaded }
        try #require(loaded, "the seeded chat history is available")
        chat.restoringDraft = true

        let limits = gateway.uploadLimits
        let source = try await Task.detached(priority: .utility) {
            try Self.pngFixture(width: 2400, height: 1600)
        }.value
        #expect(source.count > limits.imageBytes, "the source exceeds the live demo policy cap")
        let name = "demo-upload-\(UUID().uuidString).png"
        let recorder = Recorder()
        let ingest = AttachmentIngest(
            limits: limits,
            add: { chat.draft.attachments.append($0) },
            report: { recorder.messages.append($0) })

        ImageCodec.PreparationProbe.track(fileName: name)
        defer { ImageCodec.PreparationProbe.stopTracking(fileName: name) }
        ingest.addImage(source, name: name)
        let prepared = await eventually(timeout: .seconds(30)) {
            !chat.draft.attachments.isEmpty || !recorder.messages.isEmpty
        }
        #expect(prepared)
        let counts = ImageCodec.PreparationProbe.counts()
        #expect(counts.mainThread == 0 && counts.background == 1, "the production image codec runs off-main")
        let attachment = try #require(chat.draft.attachments.first)
        #expect(chat.draft.attachments.count == 1)
        #expect(attachment.mimeType == "image/jpeg" && attachment.data.count <= limits.imageBytes)
        #expect(recorder.messages == [nil], "a policy-fitting attachment clears the visible ingest error")

        let authored = "A photo from the demo chat. \(UUID().uuidString)"
        let outcome = await chat.sendMessage(authored, attachments: chat.draft.attachments)
        guard case .sent = outcome else {
            Issue.record("the demo accepted-image send did not succeed: \(outcome)")
            return
        }
        let committed = await eventually(timeout: .seconds(10)) {
            chat.items.contains { item in
                item.role == .user && !item.isPending && item.plainText == authored
                    && item.blocks.contains(where: Self.isImageBlock)
            }
        }
        #expect(committed, "the actual demo response commits the uploaded image as a user image block")
        chat.draft.attachments = []
    }

    @Test func timedOutProviderReleasesSharedPreparationSlotAndIgnoresLateCallback() async throws {
        let recorder = Recorder()
        let provider = NSItemProvider()
        provider.suggestedName = "stuck.png"
        let callback = ProviderCallbackBox()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            callback.store(completion, progress: progress)
            return progress
        }
        let ingest = AttachmentIngest(
            limits: UploadLimits(maxPayload: 1_000_000, maxImageBytes: 400_000, maxAttachmentBytes: 400_000),
            providerTimeoutNanoseconds: 100_000_000,
            add: { recorder.attachments.append($0) },
            report: { recorder.messages.append($0) })
        let nextRecorder = Recorder()
        let nextIngest = AttachmentIngest(
            limits: UploadLimits(maxPayload: 1_000_000, maxImageBytes: 400_000, maxAttachmentBytes: 400_000),
            add: { nextRecorder.attachments.append($0) },
            report: { nextRecorder.messages.append($0) })
        #expect(ingest.imageQueue === nextIngest.imageQueue, "composer owners share the process-wide image queue")

        ingest.ingest([.provider(provider)])
        #expect(await eventually { callback.isRegistered }, "the held provider callback is actually active before timeout")
        nextIngest.ingest([.data(Data("kept".utf8), type: .plainText, name: "after-provider.txt")])
        #expect(nextIngest.imageQueue.activeCount == 1 && nextIngest.imageQueue.pendingCount == 1)
        #expect(await eventually { nextRecorder.attachments.count == 1 && nextIngest.imageQueue.activeCount == 0 })
        #expect(callback.progress?.isCancelled == true)
        #expect(nextRecorder.attachments.map(\.fileName) == ["after-provider.txt"])
        #expect(recorder.messages == ["Couldn’t read stuck.png."])
        #expect(nextRecorder.messages == [nil])

        callback.complete(Data("late provider bytes".utf8), nil)
        callback.complete(Data("duplicate late bytes".utf8), nil)
        await Task.yield()
        #expect(nextRecorder.attachments.map(\.fileName) == ["after-provider.txt"], "late and duplicate callbacks cannot enter the released queue")
        #expect(recorder.messages == ["Couldn’t read stuck.png."])
    }

    private nonisolated static func pngFixture(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 0xC0FFEE11
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            // Deterministic high-entropy RGB makes the PNG large enough to force ImageCodec's
            // downsample/re-encode loop without relying on an external fixture file.
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[offset] = UInt8(truncatingIfNeeded: state)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[offset + 3] = 255
        }
        let pixelData = Data(pixels) as CFData
        let provider = try #require(CGDataProvider(data: pixelData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private nonisolated static func isImageBlock(_ block: ContentBlock) -> Bool {
        if case .image = block { true } else { false }
    }

    @MainActor
    private final class Recorder {
        var attachments: [OutgoingAttachment] = []
        var messages: [String?] = []
    }

    @MainActor
    private final class OrderedRecorder {
        var events: [String] = []
        var attachments: [OutgoingAttachment] = []
        var imageMessages: [String?] = []
        var textMessages: [String?] = []
    }

    private final class ProviderCallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: ((Data?, (any Error)?) -> Void)?
        private var trackedProgress: Progress?

        var isRegistered: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.callback != nil
        }

        var progress: Progress? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.trackedProgress
        }

        func store(_ callback: @escaping (Data?, (any Error)?) -> Void, progress: Progress) {
            self.lock.lock()
            self.callback = callback
            self.trackedProgress = progress
            self.lock.unlock()
        }

        func complete(_ data: Data?, _ error: (any Error)?) {
            self.lock.lock()
            let callback = self.callback
            self.lock.unlock()
            callback?(data, error)
        }
    }
}
