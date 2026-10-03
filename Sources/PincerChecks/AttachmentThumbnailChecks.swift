import CoreGraphics
import Foundation
import ImageIO
@testable import PincerKit

@MainActor
func runAttachmentThumbnailChecks() async {
    check(AttachmentThumbnailLoader.targetPixelSize(points: 64, displayScale: 2) == 128
          && AttachmentThumbnailLoader.targetPixelSize(points: 52, displayScale: 3) == 156
          && AttachmentThumbnailLoader.targetPixelSize(points: .infinity, displayScale: 2) == 512,
          "attachment previews target finite display pixels within the decode cap")

    let bytes = await Task.detached(priority: .utility) { attachmentThumbnailFixture(width: 180, height: 90) }.value
    let loader = AttachmentThumbnailLoader(byteBudget: 2 * 1024 * 1024, pendingLimit: 2, pendingByteLimit: 1024 * 1024)
    let attachment = OutgoingAttachment(fileName: "checks-preview.png", mimeType: "image/png", data: bytes)
    let owner = UUID()
    let coalescedOwner = UUID()
    check(loader.request(attachment, maxPixel: 128, owner: owner), "an in-budget preview request is admitted")
    let coalesced = loader.request(attachment, maxPixel: 128, owner: coalescedOwner)
    check(coalesced && loader.activeDecodeCount == 1 && loader.pendingDecodeCount == 0,
          "two views of one payload coalesce into one active decode")
    let ready = await waitFor("downsampled attachment thumbnail", timeout: 2) {
        loader.cached(attachment, maxPixel: 128) != nil
    }
    let image = loader.cached(attachment, maxPixel: 128)
    check(ready && image.map { max($0.width, $0.height) <= 128 } == true
          && loader.decodedBytes <= 2 * 1024 * 1024,
          "the shared thumbnail worker stores a size-limited image within its byte budget")
    loader.release(attachment, maxPixel: 128, owner: owner)
    loader.release(attachment, maxPixel: 128, owner: coalescedOwner)
}

func attachmentThumbnailFixture(width: Int, height: Int) -> Data {
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
