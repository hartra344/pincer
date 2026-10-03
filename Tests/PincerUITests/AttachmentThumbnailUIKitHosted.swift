#if os(iOS) && DEBUG
import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
@Observable
private final class AttachmentThumbnailFixtureState {
    var attachment: OutgoingAttachment
    var revision = 0

    init(attachment: OutgoingAttachment) { self.attachment = attachment }
}

private struct AttachmentThumbnailUIKitHost: View {
    @Bindable var state: AttachmentThumbnailFixtureState
    var size: CGFloat = 64
    var scale: CGFloat = 2

    var body: some View {
        VStack {
            AttachmentThumb(attachment: self.state.attachment, size: self.size) {}
            Text("fixture \(self.state.revision)")
        }
        .frame(width: 320, height: 120)
        .environment(\.displayScale, self.scale)
    }
}

@MainActor
enum AttachmentThumbnailUIKitHostedVerification {
    static func verifyDownsamplingAndIdentityReplacement() async throws {
        let originalData = await Task.detached(priority: .utility) {
            self.png(width: 2400, height: 1200)
        }.value
        let original = OutgoingAttachment(id: UUID(), fileName: "hosted-thumbnail.png",
                                          mimeType: "image/png", data: originalData)
        var watchedAttachment = original
        AttachmentThumbnailDecodeProbe.watch(original)
        defer { AttachmentThumbnailDecodeProbe.stopWatching(watchedAttachment) }

        let state = AttachmentThumbnailFixtureState(attachment: original)
        let controller = UIHostingController(rootView: AttachmentThumbnailUIKitHost(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        #expect(await self.waitForSamples(1, attachment: original), "UIKit hosts and decodes the real thumbnail")
        let first = AttachmentThumbnailDecodeProbe.samples(for: original)
        let originalOwner = AttachmentThumbnailDecodeProbe.loaderOwner(for: original)
        #expect(originalOwner != nil, "the hosted AttachmentThumb retains one stateful loader owner")
        #expect(first.first?.attachmentID == original.id
                && first.first?.previewIdentity == original.previewIdentity)
        #expect(first.first?.maxPixel == 128, "a 64pt thumbnail at 2x targets at most 128 pixels")
        #expect(first.first?.isMainThread == false, "the actual UIKit thumbnail decodes off-main")
        #expect((first.first?.width ?? 0) > 0 && (first.first?.height ?? 0) > 0)
        #expect(max(first.first?.width ?? 0, first.first?.height ?? 0) <= 128)

        let replacementData = await Task.detached(priority: .utility) {
            self.png(width: 1200, height: 600)
        }.value
        let replacement = OutgoingAttachment(id: original.id, fileName: original.fileName,
                                             mimeType: original.mimeType, data: replacementData)
        #expect(replacement.previewIdentity != original.previewIdentity)
        #expect(replacement == OutgoingAttachment(id: original.id, fileName: original.fileName,
                                                  mimeType: original.mimeType, data: replacementData))
        watchedAttachment = replacement
        AttachmentThumbnailDecodeProbe.watch(replacement)
        state.attachment = replacement
        state.revision += 1
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        #expect(await self.waitForSamples(1, attachment: replacement),
                "a new payload with the same public ID receives a fresh decode")
        let second = AttachmentThumbnailDecodeProbe.samples(for: replacement)
        #expect(second.first?.previewIdentity == replacement.previewIdentity)
        #expect(second.first?.maxPixel == 128)
        #expect(second.first?.isMainThread == false)
        #expect((second.first?.width ?? 0) > 0 && (second.first?.height ?? 0) > 0)
        #expect(AttachmentThumbnailDecodeProbe.loaderOwner(for: replacement) == originalOwner,
                "the SwiftUI thumbnail keeps its identity while its attachment payload changes")
        #expect(await self.waitForDisplayedPreview(replacement),
                "the retained native view displays the replacement bitmap rather than the old payload")

        let smaller = AttachmentThumbnailUIKitHost(state: state, size: 52, scale: 2)
        controller.rootView = smaller
        state.revision += 1
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(await self.waitForSamples(2, attachment: replacement))
        #expect(AttachmentThumbnailDecodeProbe.samples(for: replacement).contains { $0.maxPixel == 104 },
                "the same native host recalculates a 52pt 2x target")
    }

    private static func waitForDisplayedPreview(_ attachment: OutgoingAttachment) async -> Bool {
        for _ in 0..<200 {
            if AttachmentThumbnailDecodeProbe.displayedPreviewIdentity(for: attachment) == attachment.previewIdentity {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func waitForSamples(_ count: Int, attachment: OutgoingAttachment) async -> Bool {
        for _ in 0..<200 {
            if AttachmentThumbnailDecodeProbe.samples(for: attachment).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private nonisolated static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
