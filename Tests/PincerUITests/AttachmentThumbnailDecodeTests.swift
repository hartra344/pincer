#if os(macOS) && DEBUG
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

private struct AttachmentThumbnailHost: View {
    let attachment: OutgoingAttachment
    let revision: Int
    var mountIdentity = 0
    var size: CGFloat = 64
    var scale: CGFloat = 2

    var body: some View {
        VStack {
            AttachmentThumb(attachment: self.attachment, size: self.size) {}
                .id(self.mountIdentity)
            Text("fixture \(self.revision)")
        }
        .frame(width: 320, height: 120)
        .environment(\.displayScale, self.scale)
    }
}

@Suite("Attachment thumbnail decoding", .serialized)
struct AttachmentThumbnailDecodeTests {
    @Test @MainActor func hostedAttachmentThumbDownsamplesAndDoesNotDecodeOnBodyRebuild() async throws {
        // The compressed fixture is generated away from the main actor, as real ingestion does.
        let data = await Task.detached(priority: .utility) { Self.png(width: 3000, height: 1500) }.value
        let attachment = OutgoingAttachment(fileName: "thumbnail-fixture.png", mimeType: "image/png", data: data)
        var watchedAttachment = attachment
        AttachmentThumbnailDecodeProbe.watch(attachment)
        defer { AttachmentThumbnailDecodeProbe.stopWatching(watchedAttachment) }

        let host = NSHostingView(rootView: AttachmentThumbnailHost(attachment: attachment, revision: 0))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        #expect(await self.waitForBodyEvaluations(1, attachment: attachment), "the real AttachmentThumb body was hosted")
        #expect(await self.waitForSamples(1, attachment: attachment), "the real AttachmentThumb body decoded its hosted image")
        let first = AttachmentThumbnailDecodeProbe.samples(for: attachment)
        #expect(first.first?.attachmentID == attachment.id
                && first.first?.previewIdentity == attachment.previewIdentity
                && first.first?.fileName == attachment.fileName)
        #expect((first.first?.width ?? 0) > 0 && (first.first?.height ?? 0) > 0,
                "the fixture produces an actual decoded image")
        #expect(first.first?.maxPixel == 128, "a 64pt thumbnail at 2x needs at most 128 pixels")
        #expect(first.first?.isMainThread == false, "thumbnail decoding stays off the main thread")
        #expect(max(first.first?.width ?? 0, first.first?.height ?? 0) <= 128,
                "the actual decoded image is bounded to its display size")

        let priorEvaluations = AttachmentThumbnailDecodeProbe.bodyEvaluationCount(for: attachment)
        host.rootView = AttachmentThumbnailHost(attachment: attachment, revision: 1, mountIdentity: 1)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(await self.waitForBodyEvaluations(priorEvaluations + 1, attachment: attachment),
                "the native host rebuilt the AttachmentThumb body")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(AttachmentThumbnailDecodeProbe.samples(for: attachment).count == 1,
                "rebuilding the hosted thumbnail reuses its bounded decoded image")

        let largerPreview = OutgoingAttachment(id: attachment.id, fileName: attachment.fileName,
                                               mimeType: attachment.mimeType,
                                               data: await Task.detached(priority: .utility) {
            Self.png(width: 1200, height: 600)
        }.value)
        #expect(largerPreview == OutgoingAttachment(id: attachment.id, fileName: attachment.fileName,
                                                    mimeType: attachment.mimeType, data: largerPreview.data))
        #expect(largerPreview.previewIdentity != attachment.previewIdentity,
                "a newly initialized payload with a reused public ID receives a distinct preview identity")
        watchedAttachment = largerPreview
        AttachmentThumbnailDecodeProbe.watch(largerPreview)
        host.rootView = AttachmentThumbnailHost(attachment: largerPreview, revision: 2, mountIdentity: 1)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(await self.waitForSamples(1, attachment: largerPreview),
                "the replacement payload is decoded by the hosted thumbnail")
        let replacement = AttachmentThumbnailDecodeProbe.samples(for: largerPreview)
        #expect(replacement.first?.previewIdentity == largerPreview.previewIdentity)
        #expect(replacement.first?.maxPixel == 128)
        #expect(replacement.first?.isMainThread == false)
        #expect((replacement.first?.width ?? 0) > 0 && (replacement.first?.height ?? 0) > 0)

        let smallScaleAttachment = OutgoingAttachment(fileName: "thumbnail-scale.png", mimeType: "image/png", data: data)
        watchedAttachment = smallScaleAttachment
        AttachmentThumbnailDecodeProbe.watch(smallScaleAttachment)
        host.rootView = AttachmentThumbnailHost(attachment: smallScaleAttachment, revision: 3, size: 52, scale: 2)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(await self.waitForSamples(1, attachment: smallScaleAttachment),
                "the actual view decodes the smaller Quick Capture thumbnail")
        #expect(AttachmentThumbnailDecodeProbe.samples(for: smallScaleAttachment).first?.maxPixel == 104,
                "52pt at 2x uses 104 pixels")

        let oneXAttachment = OutgoingAttachment(fileName: "thumbnail-one-x.png", mimeType: "image/png", data: data)
        watchedAttachment = oneXAttachment
        AttachmentThumbnailDecodeProbe.watch(oneXAttachment)
        host.rootView = AttachmentThumbnailHost(attachment: oneXAttachment, revision: 4, scale: 1)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(await self.waitForSamples(1, attachment: oneXAttachment), "the actual view decodes at 1x")
        #expect(AttachmentThumbnailDecodeProbe.samples(for: oneXAttachment).first?.maxPixel == 64,
                "64pt at 1x uses 64 pixels")
    }

    private func waitForSamples(_ count: Int, attachment: OutgoingAttachment) async -> Bool {
        for _ in 0..<100 {
            if AttachmentThumbnailDecodeProbe.samples(for: attachment).count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func waitForBodyEvaluations(_ count: Int, attachment: OutgoingAttachment) async -> Bool {
        for _ in 0..<100 {
            if AttachmentThumbnailDecodeProbe.bodyEvaluationCount(for: attachment) >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func png(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
#endif
