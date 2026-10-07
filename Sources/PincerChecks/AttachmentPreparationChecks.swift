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
    await runAttachmentPreparationDeadlineChecks()
}

@MainActor
func runAttachmentPreparationDeadlineChecks() async {
    let timers = PreparationCheckTimers()
    let queue = BoundedPreparationQueue<Int>(itemDeadline: .seconds(60), timer: { _ in await timers.wait() })
    let hold = PreparationCheckHold()
    var finished: [Int] = []

    queue.submit(timeoutOutput: -1, operation: { await hold.wait() }) { finished.append($0) }
    queue.submit(timeoutOutput: -1, operation: { 2 }) { finished.append($0) }
    let timerStarted = await waitFor("deadline timer starts", timeout: 2) { hold.started && timers.count == 1 }
    check(timerStarted, "the active item starts its deadline timer")
    check(finished.isEmpty, "nothing times out before the injected timer fires")
    timers.fire(0)
    let freed = await waitFor("deadline frees the slot", timeout: 2) { finished == [-1, 2] && queue.activeCount == 0 }
    check(freed, "a fired deadline completes the hung item with its timeout output and starts the next one")
    hold.release()
    for _ in 0..<5 { await Task.yield() }
    check(finished == [-1, 2], "the hung item's late result is discarded")

    let owner = UUID()
    let other = UUID()
    let ownerHold = PreparationCheckHold()
    var cancelled: [Int] = []
    queue.submit(owner: other, operation: { await ownerHold.wait() }) { cancelled.append($0) }
    queue.submit(owner: owner, retainedBytes: 7, operation: { 3 }) { cancelled.append($0) }
    queue.submit(owner: other, operation: { 4 }) { cancelled.append($0) }
    _ = await waitFor("other owner's item starts", timeout: 2) { ownerHold.started }
    check(queue.pendingCount == 2 && queue.pendingBytes == 7, "owner work queues behind the active item")
    PreparationOwnerCancellation.cancel(owner: owner)
    check(queue.pendingCount == 1 && queue.pendingBytes == 0, "cancelling an owner releases its queued work")
    ownerHold.release()
    let drained = await waitFor("other owner drains", timeout: 2) { cancelled == [1, 4] && queue.activeCount == 0 }
    check(drained, "cancelled work never completes and other owners keep running")

    let activeHold = PreparationCheckHold()
    var abandoned: [Int] = []
    queue.submit(owner: owner, operation: { await activeHold.wait() }) { abandoned.append($0) }
    queue.submit(owner: other, operation: { 5 }) { abandoned.append($0) }
    _ = await waitFor("owner active starts", timeout: 2) { activeHold.started }
    queue.cancel(owner: owner)
    let advanced = await waitFor("cancel advances the queue", timeout: 2) { abandoned == [5] && queue.activeCount == 0 }
    activeHold.release()
    for _ in 0..<5 { await Task.yield() }
    check(advanced && abandoned == [5], "cancelling an owner's active item frees the slot and discards its result")
    timers.fireAll()
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

private final class PreparationCheckTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>?] = []
    var count: Int { self.lock.withLock { self.waiters.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.withLock { self.waiters.append(continuation) }
        }
    }

    func fire(_ index: Int) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.waiters[index] = nil }
            return self.waiters[index]
        }
        continuation?.resume()
    }

    func fireAll() { for index in 0..<self.count { self.fire(index) } }
}
