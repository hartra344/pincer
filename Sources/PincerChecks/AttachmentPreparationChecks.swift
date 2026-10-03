import CoreGraphics
import Foundation
import ImageIO
@testable import PincerKit

@MainActor
func runAttachmentPreparationChecks() async {
    let queue = BoundedPreparationQueue<Int>()
    let hold = PreparationCheckHold()
    var finished: [Int] = []

    let first = queue.submit(retainedBytes: 64 * 1024 * 1024, operation: { await hold.wait() }) {
        finished.append($0)
    }
    check(first == .started, "the active image job is outside the pending byte budget")
    let started = await waitFor("active preparation starts", timeout: 2) { hold.started }
    check(started, "the active preparation reaches its worker")

    let pending = queue.submit(retainedBytes: BoundedPreparationQueue<Int>.pendingByteLimit, operation: { 2 }) {
        finished.append($0)
    }
    let overBudget = queue.submit(retainedBytes: 1, operation: { 3 }) { finished.append($0) }
    check(pending == .queued && overBudget == .rejectedPendingBytes, "pending image bytes are bounded without dropping admitted work")
    check(queue.activeCount == 1 && queue.pendingCount == 1 && queue.pendingBytes == BoundedPreparationQueue<Int>.pendingByteLimit,
          "the queue retains one active job and only its bounded FIFO")

    hold.release()
    let drained = await waitFor("preparation FIFO drains", timeout: 2) { finished == [1, 2] && queue.activeCount == 0 }
    check(drained && queue.pendingBytes == 0 && queue.pendingCount == 0, "admitted work completes once, in order, and releases its budget")
}

@MainActor
func runDemoAttachmentPreparationChecks() async {
    let queue = BoundedPreparationQueue<OutgoingAttachment?>()
    let source = await Task.detached(priority: .utility) { preparationCheckPNG() }.value
    let attachment = await withCheckedContinuation { continuation in
        let admission = queue.submit(retainedBytes: source.count, operation: {
            await Task.detached(priority: .userInitiated) {
                ImageCodec.prepareForUpload(source, fileName: "demo-paste.png", maxBytes: 64_000)
            }.value
        }) { result in
            continuation.resume(returning: result)
        }
        if case .rejectedPendingBytes = admission { continuation.resume(returning: nil) }
        if case .rejectedPendingCount = admission { continuation.resume(returning: nil) }
    }
    check(attachment?.fileName == "demo-paste.png" && attachment?.mimeType == "image/png",
          "the demo image preparation path preserves a fitting PNG attachment")
    let decodes: Bool
    if let attachment {
        decodes = await Task.detached(priority: .utility) { ImageCodec.decode(attachment.data) != nil }.value
    } else {
        decodes = false
    }
    check(decodes == true, "the prepared demo attachment remains a decodable image")
}

private func preparationCheckPNG() -> Data {
    let context = CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor
private final class PreparationCheckHold {
    private(set) var started = false
    private var continuation: CheckedContinuation<Int, Never>?

    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            self.started = true
            self.continuation = continuation
        }
    }

    func release() {
        self.continuation?.resume(returning: 1)
        self.continuation = nil
    }
}
