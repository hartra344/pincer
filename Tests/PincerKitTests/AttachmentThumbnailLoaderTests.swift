import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PincerKit

@Suite("Attachment thumbnail loader")
struct AttachmentThumbnailLoaderTests {
    @Test func targetSizeIsFiniteAndCapped() {
        #expect(AttachmentThumbnailLoader.targetPixelSize(points: 64, displayScale: 2) == 128)
        #expect(AttachmentThumbnailLoader.targetPixelSize(points: 52, displayScale: 3) == 156)
        #expect(AttachmentThumbnailLoader.targetPixelSize(points: .infinity, displayScale: 2) == 512)
        #expect(AttachmentThumbnailLoader.targetPixelSize(points: -10, displayScale: 2) == 1)
        #expect(AttachmentThumbnailLoader.targetPixelSize(points: 1000, displayScale: 4) == 512)
    }

    @Test func replacementIdentityDoesNotChangeAttachmentEqualityOrHashing() {
        let id = UUID()
        let first = OutgoingAttachment(id: id, fileName: "same.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let copy = first
        let replacement = OutgoingAttachment(id: id, fileName: "same.png", mimeType: "image/png", data: Data([1, 2, 3]))

        #expect(first == copy)
        #expect(first == replacement)
        #expect(first.previewIdentity == copy.previewIdentity)
        #expect(first.previewIdentity != replacement.previewIdentity)
        #expect(Set([first, replacement]).count == 1)
    }

    @Test @MainActor func cacheEvictsOldPreviewsByDecodedBytes() async {
        let data = await Task.detached(priority: .utility) { Self.png(width: 200, height: 100) }.value
        let loader = AttachmentThumbnailLoader(byteBudget: 36_000, pendingLimit: 2, pendingByteLimit: 1_000_000)
        let first = OutgoingAttachment(fileName: "first.png", mimeType: "image/png", data: data)
        let second = OutgoingAttachment(fileName: "second.png", mimeType: "image/png", data: data)
        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(loader.request(first, maxPixel: 128, owner: firstOwner))
        #expect(await self.waitForCache(loader, attachment: first, maxPixel: 128))
        #expect(loader.request(second, maxPixel: 128, owner: secondOwner))
        #expect(await self.waitForCache(loader, attachment: second, maxPixel: 128))
        #expect(loader.cached(first, maxPixel: 128) == nil)
        #expect(loader.cached(second, maxPixel: 128) != nil)
        #expect(loader.decodedBytes <= 36_000)
    }

    @Test @MainActor func pendingQueueIsBoundedAndReleasedWorkEventuallyCompletes() async {
        let data = await Task.detached(priority: .utility) { Self.png(width: 160, height: 80) }.value
        let gate = DecodeGate()
        let loader = AttachmentThumbnailLoader(byteBudget: 1_000_000, pendingLimit: 1, pendingByteLimit: data.count,
                                               decoder: { bytes, maxPixel in
            gate.decode(bytes, maxPixel: maxPixel)
        })
        let active = OutgoingAttachment(fileName: "active.png", mimeType: "image/png", data: data)
        let cancelled = OutgoingAttachment(fileName: "cancelled.png", mimeType: "image/png", data: data)
        let retry = OutgoingAttachment(fileName: "retry.png", mimeType: "image/png", data: data)
        let activeOwner = UUID()
        let cancelledOwner = UUID()
        let retryOwner = UUID()

        #expect(loader.request(active, maxPixel: 96, owner: activeOwner))
        #expect(await gate.waitUntilStarted())
        #expect(loader.activeDecodeCount == 1)
        #expect(loader.request(cancelled, maxPixel: 96, owner: cancelledOwner))
        #expect(loader.pendingDecodeCount == 1)
        #expect(loader.pendingDataBytes <= data.count)
        #expect(loader.request(retry, maxPixel: 96, owner: retryOwner) == false)

        loader.release(cancelled, maxPixel: 96, owner: cancelledOwner)
        #expect(loader.pendingDecodeCount == 0)
        #expect(loader.request(retry, maxPixel: 96, owner: retryOwner))
        #expect(loader.pendingDecodeCount == 1)
        loader.release(active, maxPixel: 96, owner: activeOwner)
        gate.releaseFirst()

        #expect(await self.waitForCache(loader, attachment: retry, maxPixel: 96))
        #expect(loader.cached(active, maxPixel: 96) == nil,
                 "a decode with no remaining visible owner cannot populate the cache")
        #expect(loader.pendingDataBytes == 0)
        #expect(gate.decodeCount == 2)
    }

    @Test @MainActor func identicalVisibleOwnersShareDecodeAndCancelledActiveSlotWaitsForDecoderExit() async {
        let data = await Task.detached(priority: .utility) { Self.png(width: 160, height: 80) }.value
        let gate = DecodeGate()
        let loader = AttachmentThumbnailLoader(byteBudget: 1_000_000, decoder: { bytes, maxPixel in
            gate.decode(bytes, maxPixel: maxPixel)
        })
        let attachment = OutgoingAttachment(fileName: "shared.png", mimeType: "image/png", data: data)
        let owners = (0..<AttachmentThumbnailLoader.maximumOwnersPerWork).map { _ in UUID() }

        #expect(loader.request(attachment, maxPixel: 96, owner: owners[0]))
        #expect(await gate.waitUntilStarted())
        for owner in owners.dropFirst() {
            #expect(loader.request(attachment, maxPixel: 96, owner: owner))
        }
        #expect(loader.request(attachment, maxPixel: 96, owner: UUID()) == false,
                 "one image decode has a bounded subscriber set")
        #expect(gate.decodeCount == 1)

        for owner in owners {
            loader.release(attachment, maxPixel: 96, owner: owner)
        }
        #expect(loader.activeDecodeCount == 1,
                 "dropping all owners does not free the global slot while ImageIO is still decoding")
        #expect(loader.cached(attachment, maxPixel: 96) == nil)

        gate.releaseFirst()
        for _ in 0..<100 {
            if loader.activeDecodeCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(loader.activeDecodeCount == 0)
        #expect(loader.cached(attachment, maxPixel: 96) == nil,
                 "an abandoned decode cannot populate the preview cache")
        #expect(gate.decodeCount == 1, "coalesced owners invoke the decoder once")
    }

    @Test @MainActor func rejectedRequestCanRetryAfterQueuePressureClears() async {
        let data = await Task.detached(priority: .utility) { Self.png(width: 160, height: 80) }.value
        let gate = DecodeGate()
        let loader = AttachmentThumbnailLoader(byteBudget: 1_000_000, pendingLimit: 1, pendingByteLimit: data.count,
                                               decoder: { bytes, maxPixel in
            gate.decode(bytes, maxPixel: maxPixel)
        })
        let first = OutgoingAttachment(fileName: "pressure-active.png", mimeType: "image/png", data: data)
        let second = OutgoingAttachment(fileName: "pressure-pending.png", mimeType: "image/png", data: data)
        let retry = OutgoingAttachment(fileName: "pressure-retry.png", mimeType: "image/png", data: data)
        let firstOwner = UUID()
        let secondOwner = UUID()
        let retryOwner = UUID()

        #expect(loader.request(first, maxPixel: 96, owner: firstOwner))
        #expect(await gate.waitUntilStarted())
        #expect(loader.request(second, maxPixel: 96, owner: secondOwner))
        let revisionBeforeOverflow = loader.revision
        #expect(loader.request(retry, maxPixel: 96, owner: retryOwner) == false)
        #expect(loader.pendingDecodeCount == 1 && loader.pendingDataBytes <= data.count)

        gate.releaseFirst()
        #expect(await self.waitForCache(loader, attachment: second, maxPixel: 96))
        #expect(loader.revision > revisionBeforeOverflow)
        #expect(loader.request(retry, maxPixel: 96, owner: retryOwner),
                 "a mounted view can re-request after the loader's retry revision changes")
        #expect(await self.waitForCache(loader, attachment: retry, maxPixel: 96))
        #expect(gate.decodeCount == 3)
        #expect(loader.pendingDataBytes == 0)
    }

    @MainActor private func waitForCache(_ loader: AttachmentThumbnailLoader,
                                        attachment: OutgoingAttachment, maxPixel: Int) async -> Bool {
        for _ in 0..<100 {
            if loader.cached(attachment, maxPixel: maxPixel) != nil { return true }
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

private final class DecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0

    var decodeCount: Int { self.lock.withLock { self.calls } }

    func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        let shouldBlock = self.lock.withLock { () -> Bool in
            self.calls += 1
            return self.calls == 1
        }
        if shouldBlock {
            self.entered.signal()
            self.release.wait()
        }
        return ImageCodec.decode(data, maxPixel: maxPixel)
    }

    func waitUntilStarted() async -> Bool {
        await Task.detached(priority: .utility) { self.waitSynchronouslyUntilStarted() }.value
    }

    private func waitSynchronouslyUntilStarted() -> Bool {
        self.entered.wait(timeout: .now() + 2) == .success
    }

    func releaseFirst() { self.release.signal() }
}
