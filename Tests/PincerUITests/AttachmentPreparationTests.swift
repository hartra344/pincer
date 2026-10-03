import CoreGraphics
import Foundation
import ImageIO
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
        #expect(ImageCodec.decode(attachment.data) != nil)
        #expect(recorder.messages == [nil])

        // Invalid source data keeps the existing user-visible failure and adds no partial item.
        ingest.addImage(Data("not an image".utf8), name: "broken.png")
        let failureReported = await eventually { recorder.messages.count == 2 }
        #expect(failureReported)
        #expect(recorder.attachments.count == 1)
        #expect(recorder.messages == [nil, "Couldn’t prepare broken.png for upload."])
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

    @MainActor
    private final class Recorder {
        var attachments: [OutgoingAttachment] = []
        var messages: [String?] = []
    }
}
